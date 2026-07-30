# Sports Store — raw Kubernetes manifests

The whole application on a local Kubernetes cluster: MongoDB via the Bitnami
Helm chart, five FastAPI services, and the NGINX gateway.

These are hand-written manifests, deliberately repetitive. Milestone 3 replaces
them with a Helm chart where one template and a `range` generate all five
services — but writing them out longhand first is what makes the chart's
`_helpers.tpl` legible rather than magic.

Namespace is **`sports-store`** everywhere. The Helm chart, the EKS deploy,
Argo CD and the observability stack all assume that name.

## Layout

```
k8s/
├── namespace.yaml
├── secrets/
│   ├── .env.example             # copy to .env, fill in, never commit
│   └── apply-secrets.sh         # creates app-secrets + mongodb-credentials
├── configmaps/
│   ├── auth-config.yaml         # ACCESS_TOKEN_EXPIRE_MINUTES
│   ├── cart-config.yaml         # CATALOG_URL
│   ├── order-config.yaml        # CART/CATALOG/PAYMENT_URL, shipping rules
│   └── payment-config.yaml      # PAYMENT_FAILURE_SUFFIX
│                                # (catalog-service needs no non-secret config)
├── auth-service/{deployment,service}.yaml
├── catalog-service/{deployment,service}.yaml
├── cart-service/{deployment,service}.yaml
├── order-service/{deployment,service}.yaml
├── payment-service/{deployment,service}.yaml
├── gateway/{deployment,service,ingress}.yaml
└── mongodb/
    ├── values.yaml              # Bitnami chart values (version pinned — read the file)
    └── init-configmap.yaml      # GENERATED from ../seed/init-mongo.js
```

---

## Two constraints that are not free choices

**1. Backend Service names are fixed by the gateway image.**
`gateway/nginx.conf` contains `proxy_pass http://auth-service:8000` and five
similar lines, and that file is compiled into the gateway image at build time.
Every backend `Service.metadata.name` must match exactly — `auth-service`,
`catalog-service`, `cart-service`, `order-service`, `payment-service`. Rename
one and the gateway returns 502 with an NXDOMAIN in its logs. Changing a name
means rebuilding and reloading the gateway image, not editing a manifest.

**2. Backend Service `port` is 8000, not 80.** Same reason: the port is part
of that `proxy_pass` line. The obvious-looking "expose port 80, target 8000"
would break every `/api/*` route.

`catalog-service` is referenced most often — twice in `nginx.conf`
(`/api/products` and `/api/internal/`) and again in `cart-config` and
`order-config`.

---

## Prerequisites

A local cluster and the six application images loaded into it. From
`cloudcart-workspace`:

```bash
minikube start --driver=docker
minikube addons enable ingress      # only if you want the Ingress path
make k8s-images                     # builds all 6 with real tags, loads them
```

`make k8s-images` tags each image `0.1.0-<7-char-git-hash>` from that repo's own
`HEAD` and pushes it into the node with `minikube image load`. The tags are
hardcoded in the Deployments; if a repo's `HEAD` has moved since, the target
prints the tags it produced so the manifests can be updated to match.

There is no registry involved yet, which is why every Deployment sets
`imagePullPolicy: IfNotPresent` — `Always` would send the kubelet to Docker Hub
looking for `sports-store/auth-service` and fail with `ErrImagePull`.

---

## Apply order

Order matters in two places: the Secrets must exist before anything references
them, and `mongo-init` must exist before the chart install, because MongoDB
runs seed scripts only on a genuinely empty data directory — there is no second
chance on a later upgrade.

```bash
kubectl apply -f k8s/namespace.yaml

# Secrets first. Generated from k8s/secrets/.env, never committed.
cp k8s/secrets/.env.example k8s/secrets/.env   # then edit it
./k8s/secrets/apply-secrets.sh

# MongoDB. The seed ConfigMap must land BEFORE the chart install.
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
kubectl apply -n sports-store -f k8s/mongodb/init-configmap.yaml
helm upgrade --install mongodb bitnami/mongodb \
  --namespace sports-store \
  --version 16.5.45 \
  --values k8s/mongodb/values.yaml

# Application.
kubectl apply -n sports-store -f k8s/configmaps/
kubectl apply -n sports-store -f k8s/auth-service/
kubectl apply -n sports-store -f k8s/catalog-service/
kubectl apply -n sports-store -f k8s/cart-service/
kubectl apply -n sports-store -f k8s/order-service/
kubectl apply -n sports-store -f k8s/payment-service/
kubectl apply -n sports-store -f k8s/gateway/
```

`--version 16.5.45` is not optional. See the header of
[`mongodb/values.yaml`](mongodb/values.yaml): the current chart resolves to
`bitnami/mongodb:latest`, which this project forbids, so the chart is pinned to
the last version that ships a real image tag and the repository is redirected
to `bitnamilegacy`.

### Startup ordering against MongoDB

There is **no `initContainer` waiting for MongoDB**, deliberately. Each
service's `database.py` uses `AsyncIOMotorClient`, which connects lazily and
retries in the background — a service that starts before the database is ready
recovers on its own without a restart. An init container would add a moving
part to solve a problem the driver already solves.

Worth being honest about the limit of this: `/health` returns a static
`{"status": "ok"}` and does not check MongoDB, so the readiness probe proves
the process is serving HTTP, not that it can reach the database. Making
`/health` a real dependency check is a known, deliberate follow-up.

---

## Reaching the storefront

Two paths, both working:

| Path | URL | Needs |
|---|---|---|
| Ingress | <http://sports-store.local> | `minikube addons enable ingress` + an `/etc/hosts` entry |
| NodePort | `http://$(minikube ip):30080` | nothing |

```bash
echo "$(minikube ip) sports-store.local" | sudo tee -a /etc/hosts
```

On the docker driver on Linux the node IP is routable from the host directly —
no `minikube tunnel` required.

The Ingress is the one that carries forward. Milestone 5 swaps
`ingressClassName: nginx` for `alb` and adds AWS Load Balancer Controller
annotations; the routing rule itself is unchanged. The NodePort exists so the
stack is reachable without an addon, and because a pinned `nodePort: 30080`
keeps the URL above true across a delete-and-reapply.

---

## The seed script lives in two repos

`seed/init-mongo.js` at the root of this repo is a **copy**. The canonical one
is `sports-store-local/seed/init-mongo.js`, which Docker Compose mounts.

That duplication is a deliberate trade: this repo stays independently
deployable with no sibling checkout, at the cost of two files that can drift.
The mitigation is that re-syncing is mechanical —

```bash
cp ../sports-store-local/seed/init-mongo.js seed/init-mongo.js
kubectl create configmap mongo-init \
  --from-file=init-mongo.js=seed/init-mongo.js \
  --dry-run=client -o yaml > k8s/mongodb/init-configmap.yaml
# then re-add the header comment and labels at the top of the generated file
```

`init-configmap.yaml` is generated, never hand-edited. The data key must stay
`init-mongo.js`: the chart mounts the ConfigMap into
`/docker-entrypoint-initdb.d/` and MongoDB uses the key as the filename, then
ignores anything without a `.js` or `.sh` extension.

---

## Verifying, properly

`kubectl get pods` showing `Running` proves the images start, not that the
system works. The checks that actually mean something:

```bash
kubectl get pods -n sports-store          # 7 pods, all Ready

# Seed ran exactly once
kubectl exec -n sports-store deploy/mongodb -- \
  mongosh -u root -p "$MONGO_ROOT_PASSWORD" --authenticationDatabase admin \
  --quiet --eval 'db.getSiblingDB("catalog_db").products.countDocuments({})'
# -> 20

# Data survives a pod restart (the milestone's explicit criterion)
kubectl delete pod -n sports-store -l app.kubernetes.io/name=mongodb
# wait for Ready, then re-count -> still 20, not 40

# Seed does not re-run on upgrade
helm upgrade mongodb bitnami/mongodb -n sports-store --version 16.5.45 \
  --values k8s/mongodb/values.yaml
# re-count -> still 20
```

A count of 40 means the seed re-ran, which means persistence is misconfigured.

Then drive the application itself: register → login → add to cart → checkout,
and confirm stock decremented and the order reached `paid`. A card ending
`0000` must return HTTP 402 and leave the order `payment_failed`.

Recorded results live in `docs/PROGRESS.md` in `cloudcart-workspace`.

---

## Teardown

```bash
kubectl delete namespace sports-store   # takes the PVC with it
helm uninstall mongodb -n sports-store  # if the namespace is being kept
```

Deleting the namespace deletes the PVC and therefore the data — which is also
how you deliberately reset and re-seed, the equivalent of `docker compose
down -v`.
