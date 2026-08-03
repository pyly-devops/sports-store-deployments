# sports-store Helm chart

Packages the whole CloudCart application — five FastAPI services, the NGINX
gateway, and MongoDB — as one parent chart.

This replaces the raw manifests in [`../../k8s/`](../../k8s/). Those stay in the
repo as the readable, un-templated reference: when something here renders
strangely, diff `helm template` output against them.

---

## What is in here, and why it is shaped this way

```text
Chart.yaml            MongoDB declared as a dependency, pinned to 16.5.45
Chart.lock            resolved digest — committed
charts/               the subchart .tgz, VENDORED (see below)
values.yaml           environment-agnostic defaults
environments/
  local/values.yaml            minikube: NodePort, nginx ingress, no registry
  production/values.yaml       EKS: ALB, ECR, gp3            (not yet exercised)
  production/images/*.yaml     one tag per service — CI's only write target
files/init-mongo.js   the seed script, loaded with .Files.Get
templates/
  _helpers.tpl        defaults merge, image builder + `latest` guard, labels
  services.yaml       ONE template -> 6 Deployments, 6 Services, 4 ConfigMaps
  ingress.yaml        one rule: / -> gateway
  secrets.yaml        opt-in only; default is to consume existing Secrets
  mongodb-pvc.yaml    the PVC that outlives the release
  mongo-init-configmap.yaml
```

### One template, six services

The five backends were byte-identical apart from image, secret key and
ConfigMap. `templates/services.yaml` ranges over `.Values.services` and emits all
three resource kinds for every entry, with `if` guards for the parts that are
genuinely optional (`config`, `mongoUriKey`, `jwt`, `nodePort`).

`range` over a **map**, not a list: Helm sorts map keys so output is
deterministic, and `--set services.auth-service.replicas=2` or
`yq '.services.cart-service.image.tag = "…"'` addresses exactly one service.

### The map key is the Kubernetes object name

`gateway/nginx.conf` is baked into the gateway image and contains
`proxy_pass http://auth-service:8000`. A release-name prefix would give the
gateway an NXDOMAIN and a 502 on every `/api/*` request, so Services are **not**
`{{ .Release.Name }}`-prefixed and the port stays 8000.

**Consequence:** two releases of this chart cannot coexist in one namespace. The
alternative — rebuilding the gateway image on every rename — is worse.

### The defaults merge is shallow, on purpose

`serviceDefaults` is applied by `sports-store.svc` in `_helpers.tpl` with
top-level keys replacing wholesale, not Sprig's deep `merge`. A deep merge would
re-add `runAsNonRoot: true` to the gateway (whose nginx master must start as root
to chown its cache dirs) and crashloop it, with an error message pointing at the
pod rather than at the helper. `merge` also mutates its first argument, which
would let the first service through the loop poison the defaults for the rest.

So `securityContext`, `resources`, `service` and `probes` are all-or-nothing per
service.

### `latest` is a render-time error

`sports-store.image` calls `fail` on an empty tag or `latest`. The rule is a
project non-negotiable, and one that lives only in a README gets broken during a
demo. Here the chart will not template.

### The subchart is vendored

`charts/mongodb-16.5.45.tgz` is committed, not gitignored. Milestone 7 has Argo
CD's repo-server resolving this dependency at sync time, which would otherwise
need egress to `charts.bitnami.com` **and** 16.5.45 still being in that index —
and Bitnami's index is exactly what is already known to be shifting (see
`Chart.yaml` for the `bitnamilegacy` story). Vendoring pins content, not just a
version string.

---

## Install

Secrets first — the chart consumes them, it does not create them by default:

```bash
cp ../../k8s/secrets/.env.example ../../k8s/secrets/.env   # then edit
NAMESPACE=sports-store ../../k8s/secrets/apply-secrets.sh
```

Then:

```bash
helm dependency build          # unpacks the vendored .tgz; no network needed
helm install sports-store . -n sports-store --create-namespace \
  -f environments/local/values.yaml
```

Images must already be in the minikube node's Docker daemon —
`make k8s-images` in `cloudcart-workspace`.

For a throwaway cluster with no `.env`, the chart can create the Secrets itself.
Never commit a values file with these populated:

```bash
helm install sports-store . -n sports-store --create-namespace \
  -f environments/local/values.yaml \
  --set secrets.create=true \
  --set secrets.jwtSecret="$(openssl rand -hex 32)" \
  --set secrets.mongodbRootPassword="$(openssl rand -hex 16)"
```

---

## Verify

Nothing here is marked done on assumption. Install, upgrade and rollback are the
easy three; **uninstall is the one that can actually lose the catalogue.**

```bash
helm lint .
helm template . -f environments/local/values.yaml | kubectl apply --dry-run=server -f -

# 1. install  -> six pods Ready, storefront serves, a checkout completes,
#                a card ending 0000 gives HTTP 402 and a payment_failed order
helm install sports-store . -n sports-store --create-namespace \
  -f environments/local/values.yaml

# 2. upgrade  -> revision 2, two auth-service pods, app still serving
helm upgrade sports-store . -f environments/local/values.yaml \
  --set services.auth-service.replicas=2

# 3. rollback -> revision 3, back to one auth-service pod
helm rollback sports-store 1

# 4. uninstall + reinstall  <- THE ONE THAT MATTERS
helm uninstall sports-store
kubectl get pvc -n sports-store sports-store-mongodb-data    # still Bound
helm install sports-store . -n sports-store -f environments/local/values.yaml
#    -> product count still 20, NOT 40
#    -> new mongo pod log contains zero "Seed complete" lines
```

40 products means the PVC wiring is wrong.

### Why the data survives all four

The PVC is declared by **this** chart (`templates/mongodb-pvc.yaml`) and handed
to the subchart via `mongodb.persistence.existingClaim`. If the subchart owned
it, `helm uninstall` would delete it. It carries two annotations that defend
against two different systems:

| Annotation | Protects against |
| --- | --- |
| `helm.sh/resource-policy: keep` | `helm uninstall` deleting the PVC with the release |
| `argocd.argoproj.io/sync-options: Prune=false,Delete=false` | Milestone 7's Argo CD prune / self-heal, which has never heard of the Helm annotation |

On reinstall under the same release name and namespace, Helm adopts the
surviving PVC because its `meta.helm.sh/release-name` annotation still matches.

Seeding does not re-run, for two independent reasons: the Bitnami entrypoint
executes `/docker-entrypoint-initdb.d/*` only against an **empty** data
directory, and the script itself upserts (`$setOnInsert` + `upsert: true`).

### The sharp edge of keeping the PVC

**Changing `secrets.mongodbRootPassword` on an existing volume does not change
the database user.** MongoDB stores its users *in the data directory*, and the
Bitnami entrypoint only creates the root user when that directory is empty. So a
password rotation updates the Secret, updates every `MONGO_URI`, and leaves the
actual database credential untouched — every service then fails with
`MongoServerError: Authentication failed` while the pods themselves look healthy.

Found the hard way during verification, not theorised: a failed install left an
initialised volume behind, the retry generated a fresh password, and the app came
up green with an unreachable database. The tell is in the mongod log —
`"Startup from clean shutdown?": false` with a non-zero `numRecords`.

Rotating for real means changing the password *inside* MongoDB
(`db.changeUserPassword`) and then updating the Secret, or accepting the data
loss and deleting the PVC. This is the cost of the keep policy, and it is the
right trade for a database — but it is a trap worth knowing about before a demo.

---

## Known gaps

Carried forward deliberately, not overlooked.

- **The gateway is not `runAsNonRoot`.** The stock nginx image's master starts as
  root to chown `/var/cache/nginx`, so it gets four capabilities back after
  `drop: [ALL]`. The fix is `nginxinc/nginx-unprivileged`; it touches the gateway
  Dockerfile and the port in three places, so it deserves its own PR.
- **`readOnlyRootFilesystem` is off.** uvicorn writes to `/tmp`; enabling it needs
  an `emptyDir` mounted there.
- **`/health` does not check MongoDB.** Readiness proves the process is serving,
  not that the database is reachable.
- **MongoDB is `bitnamilegacy` and standalone.** Archived, unpatched, and a single
  point of failure. Fine locally; Milestone 5 must resolve it before EKS.
- **One symmetric JWT secret shared by all five services.** Any service that can
  verify a token could forge one. Asymmetric signing is the correct fix.
- **`environments/production/` has never been applied.** It is committed to prove
  the chart is environment-agnostic — every EKS difference is a value, not a
  template change — but the account ID and hostname are placeholders.

## Forward constraints

Do not break these without reading Milestones 5 and 7 first.

- The chart stays environment-agnostic. New environment facts go in
  `environments/`, never in `values.yaml`.
- **Never use `lookup`**, and do not put anything load-bearing in a Helm hook.
  Argo CD runs `helm template` and applies the output; it does not run
  `helm install`, so `lookup` returns empty and the release lifecycle is not in
  play.
- After Milestone 7, `helm rollback` stops being the rollback mechanism. Rollback
  becomes a git revert of an image tag in `environments/production/images/`.
- The Ingress keeps exactly one rule. Path routing belongs in the gateway image.
- Milestone 8's ServiceMonitor is a fourth block inside the existing `range`.
