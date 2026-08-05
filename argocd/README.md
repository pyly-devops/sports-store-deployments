# Argo CD — GitOps for `sports-store-prod`

Milestone 7. Argo CD watches this repo; merging a PR **is** the deploy.
`kubectl apply`/`helm upgrade` against this cluster is retired except for the
one bootstrap step below.

## Why Argo CD is not managed by Argo CD

Three reasons, strongest first:

- The `argo-cd` chart's `crd-applicationset.yaml` renders to 1.39 MB — even
  server-side applied, uncomfortably close to etcd's 1.5 MB object limit, for
  a resource we gain nothing from managing.
- Self-management means a bad commit can prune the thing doing the pruning.
  Recovery is the manual `helm upgrade` this project was trying to avoid, so
  self-managing keeps that step *and* adds a failure mode on top of it.
- Installing it from Terraform needs a `helm` provider in `envs/prod`, which
  needs cluster-admin on the HCP run role — reversing Milestone 4's
  deliberate `enable_cluster_creator_admin_permissions = false` for the sake
  of one Helm release. See `cluster/README.md`.

## Bootstrap runbook

Four manual steps. Steps 1 and 3 are one-time per cluster; step 2 must be
re-run after every `terraform destroy` + re-apply (no secret version resource
in Terraform — see `sports-store-infrastructure/envs/prod/secrets.tf`).

```bash
# 0. terraform apply on sports-store-infrastructure. STOP-and-ask (CLAUDE.md).

# 1. kubeconfig — irreducible: the HCP run role has no cluster admin access
#    by design (envs/prod/eks.tf), so nothing but a human's own AWS identity
#    can do this.
aws eks update-kubeconfig --name sports-store --region us-east-1

# T9 cleanup — only needed if the M2 raw manifests (k8s/) are still live in
# `sports-store` from an earlier milestone. Confirm empty before continuing:
kubectl -n sports-store delete -f ../k8s/ --ignore-not-found
kubectl -n sports-store get all   # expect empty (namespace itself is recreated by wave 0)

# 2. Seed the secret VALUE — irreducible: it must reach neither git nor
#    tfstate. hex only ([0-9a-f]): a password containing @ or / breaks the
#    mongodb://user:PASSWORD@host/ connection string with an error that
#    points at the HOST, not the credential.
JWT=$(openssl rand -hex 32); MPW=$(openssl rand -hex 32)
aws secretsmanager put-secret-value --secret-id sports-store/prod/app \
  --secret-string "$(jq -n --arg j "$JWT" --arg p "$MPW" \
     '{JWT_SECRET:$j, MONGO_ROOT_USERNAME:"root", MONGO_ROOT_PASSWORD:$p}')" >/dev/null
unset JWT MPW

# T16 cutover — only needed if apply-secrets.sh already created
# app-secrets/mongodb-credentials by hand on this cluster. ESO's
# creationPolicy: Owner refuses to adopt a Secret it didn't create. Safe
# while pods run — secretKeyRef env vars resolve at pod start, not
# continuously.
kubectl -n sports-store delete secret app-secrets mongodb-credentials --ignore-not-found

# 3. Install Argo CD — irreducible: something has to install the installer.
helm upgrade --install argocd argo-cd \
  --repo https://argoproj.github.io/argo-helm --version 10.2.3 \
  -n argocd --create-namespace -f install/values.yaml --wait --timeout 10m

# Measure node headroom BEFORE the next step (T10) — everything after this
# depends on there being room to schedule into.
kubectl describe node | grep -A8 Allocatable

# 4. The ONE kubectl apply. Everything after this is git.
kubectl apply -f bootstrap.yaml
kubectl -n argocd get applications -w
```

Reach the UI with `kubectl -n argocd port-forward svc/argocd-server 8080:80`
(decision: no Ingress for it — the gateway's ALB stays the only thing
reachable from outside the cluster).

## First-sync expectations, not bugs

- **5 backends crashloop for 2-4 minutes** waiting for mongod to come up.
  Expected — do not add sync-wave annotations to the Helm chart itself to
  "fix" this. That would couple an environment-agnostic chart (Milestone 3's
  actual achievement) to Argo CD specifically.
- Run `argocd app diff sports-store` once wave 30 is Synced/Healthy and add
  real entries to that Application's `ignoreDifferences` only for whatever
  actually shows drift (see the comment in
  `argocd/applications/50-sports-store.yaml`).

## Mongo password rotation runbook

Rotating `MONGO_ROOT_PASSWORD` in Secrets Manager now propagates into the
`mongodb-credentials`/`app-secrets` k8s Secrets automatically, with no human
approval step — ESO's `refreshInterval: 1h` is the only delay. MongoDB stores
its users inside the data directory and only creates the root user when that
directory is empty, so changing the Secret does **not** change the actual
database credential. Every pod stays `1/1 Running`; every request fails
`MongoServerError: Authentication failed`. Deliberately no Reloader is
installed — auto-restarting pods on Secret change would turn this into an
instant cluster-wide outage instead of a slow, findable one.

Rotate in this order, never any other:

1. `db.changeUserPassword` **inside MongoDB first** (exec into the mongod pod,
   authenticate with the *current* password, change it there).
2. `aws secretsmanager put-secret-value` **second** — now the Secret and the
   real credential agree.
3. `kubectl -n sports-store rollout restart deployment` for the five backends
   **third**, so they pick up the new connection string on their own
   schedule rather than being forced by a Reloader mid-request.

## Known gaps

- The ALB controller's Ingress finalizer (`group.ingress.k8s.aws`) blocks
  deletion while the Ingress exists. Never prune the
  `aws-load-balancer-controller` Application while `sports-store` still has
  one, or the ALB leaks.
- `helm.skipCrds` must never be set on the ALB controller Application — its
  CRDs ship in `crds/`, which `helm template` skips by default but Argo CD's
  `--include-crds` does not. `chart.yml` asserts this in CI.
