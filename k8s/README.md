# Sports Store — Kubernetes manifests (starter)

Starter Kubernetes manifests for Stage 3 — Local Kubernetes Deployment. Every file
under this directory contains inline `TODO` comments instead of working resource
definitions, the same pattern as `services/*/Dockerfile` and `docker-compose.yml`.

Namespace used throughout the rest of this course is **`sports-store`** — later
stages (Helm chart, EKS deploy, CI/CD, Argo CD, observability) all assume that name,
so don't rename it.

## Layout

```
k8s/
├── namespace.yaml
├── secrets/
│   └── app-secrets.yaml        # JWT_SECRET, per-service MONGO_URI, mongo root creds
├── configmaps/
│   ├── auth-config.yaml
│   ├── cart-config.yaml
│   ├── order-config.yaml
│   └── payment-config.yaml     # catalog-service needs no non-secret config
├── auth-service/{deployment,service}.yaml
├── catalog-service/{deployment,service}.yaml
├── cart-service/{deployment,service}.yaml
├── order-service/{deployment,service}.yaml
├── payment-service/{deployment,service}.yaml
├── gateway/{deployment,service}.yaml
└── mongodb/
    ├── values.yaml              # Bitnami MongoDB Helm chart values
    └── init-configmap.yaml      # ConfigMap generated from seed/init-mongo.js
```

## Internal service DNS

`gateway/nginx.conf` is the same file you completed in Stage 2 — its `proxy_pass`
lines already point at the hostnames you chose for your Compose services back
then. This directory's Service `metadata.name` for each backend must resolve to
those exact same hostnames over cluster DNS, or the gateway gets a DNS failure
proxying to it — same constraint as Stage 2, different mechanism (k8s Service DNS
instead of a Compose network alias). Reuse the names you already picked; if you
change a hostname here, update the matching `proxy_pass` line in
`gateway/nginx.conf` too and rebuild the gateway image.

Only the `gateway` Service should be externally reachable (NodePort/LoadBalancer,
or an Ingress if your cluster has a controller) — everything else stays ClusterIP.

## Suggested apply order

```bash
kubectl create namespace sports-store   # or: kubectl apply -f namespace.yaml

# Secrets first — mongodb/values.yaml (if you use existingSecret) and every
# app Deployment below reference app-secrets, so it has to exist already.
kubectl apply -n sports-store -f k8s/secrets/

# MongoDB via the Bitnami chart, values + init script ConfigMap from this repo
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
kubectl apply -n sports-store -f k8s/mongodb/init-configmap.yaml
helm upgrade --install mongodb bitnami/mongodb \
  --namespace sports-store \
  --values k8s/mongodb/values.yaml

kubectl apply -n sports-store -f k8s/configmaps/
kubectl apply -n sports-store -f k8s/auth-service/
kubectl apply -n sports-store -f k8s/catalog-service/
kubectl apply -n sports-store -f k8s/cart-service/
kubectl apply -n sports-store -f k8s/order-service/
kubectl apply -n sports-store -f k8s/payment-service/
kubectl apply -n sports-store -f k8s/gateway/
```

MongoDB should come up first and be healthy before the app Deployments start
successfully connecting — a `readinessProbe` alone won't order that for you; either
retry-friendly app startup (already the case here — see each service's DB
connection code) or an `initContainer` that waits on Mongo is an acceptable
approach. Document whichever you pick.
