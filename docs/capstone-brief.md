# CloudCart - Capstone Brief

This is the only document you'll get, alongside the starter application code. There's no stage-by-stage task list and no success-criteria checklist — this brief tells you the stack, the repo/team structure, and what "done" looks like. Working out the concrete steps, manifests, and commands to get there is the assignment. Work in pairs or more over two weeks and present a live demo at the end.

Running locally with Docker Compose and on a local Kubernetes cluster (milestones 1-2 below) is **optional** — good practice for getting to know the app, but not what this project is graded on. The real focus is Helm and EKS: packaging the app properly and running it for real in the cloud, because that's the experience that actually gets asked about in interviews. If you're already comfortable with Compose and raw Kubernetes manifests, skip straight to the Helm chart.

## Starting point

You're given the application source, not the infrastructure:

- 5 Python/FastAPI microservices — auth, catalog, cart, order, payment — each owning its own MongoDB database
- A React + Vite JavaScript frontend
- An NGINX gateway meant to be the app's single entrypoint
- A MongoDB seed script at `seed/init-mongo.js`

Everything else — how it's containerized, orchestrated, provisioned, deployed, and observed — is what you're building.

## Repository & team structure

Treat this as a real polyrepo project, not a monorepo. Create a GitHub organization and, inside it, one repo per deployable unit:

- `sports-store-frontend`
- `sports-store-gateway`
- `sports-store-auth-service`
- `sports-store-catalog-service`
- `sports-store-cart-service`
- `sports-store-order-service`
- `sports-store-payment-service`
- `sports-store-local` — the Docker Compose environment that wires the above together for local dev
- `sports-store-deployments` — Kubernetes manifests, the Helm chart, Argo CD config, and observability config
- `sports-store-infrastructure` — Terraform

For every repo: protect `main` (no direct pushes, PR required, at least one approval), add a README describing its purpose, add an appropriate `.gitignore`, and settle on a branching convention (`feature/`, `bugfix/`, `hotfix/`). Track work in a project management tool (Linear, Jira, or GitHub Projects) and coordinate in a shared chat platform (Slack or Discord) — both are part of the deliverable, not just nice-to-haves.

## Stack and recommended tools, milestone by milestone

### 1. Containerize and run locally *(optional — practice)*

Docker + Docker Compose. NGINX is the only service exposed to the host; everything else talks over the Compose network by service name, never `localhost`. MongoDB gets a named volume for persistence and is seeded via `docker-entrypoint-initdb.d` using the provided `init-mongo.js` — seeding must only run against an empty data directory, never on a normal restart.

### 2. Deploy to a local Kubernetes cluster *(optional — practice)*

A local cluster (kind or minikube) and raw manifests — Deployments, Services, ConfigMaps, Secrets, all in a dedicated namespace. Install MongoDB separately via the **Bitnami MongoDB Helm chart** rather than hand-rolling it. The seed script becomes a ConfigMap mounted read-only at `/docker-entrypoint-initdb.d/init-mongo.js`, with the same "first-init only" behavior as Compose. Expose the app the same way Compose did — through the gateway (Ingress or a gateway Service), not by exposing every backend.

**This is where the graded work starts.** Milestones 3 onward — Helm through observability — are the actual focus of the project.

### 3. Package it as a Helm chart

One parent chart, conventionally at `sports-store-deployments/helm/sports-store/`, with the Bitnami MongoDB chart declared as a dependency. The services are near-identical Kubernetes resources — use `range`, `if`, and `_helpers.tpl` so one template generates all of them instead of five copy-pasted ones; push differences (image, replicas, ports, env, resources) into `values.yaml`. The chart needs to genuinely support install, upgrade, rollback, and uninstall, with MongoDB's persistent data surviving all of them.

### 4. Provision cloud infrastructure

Terraform, built on public modules rather than hand-rolled resources — at minimum `terraform-aws-modules/vpc/aws` and `terraform-aws-modules/eks/aws`. Connect the `sports-store-infrastructure` repo to a **Terraform Cloud** workspace (VCS-driven runs, remote state with locking — state is never committed to Git). This provisions the VPC (public/private subnets, NAT, routing), the EKS control plane and node group, one ECR repository per component, required IAM (cluster role, node role, EBS CSI permissions), and core add-ons (VPC CNI, CoreDNS, kube-proxy, EBS CSI driver). No application workload goes on the cluster during this step — it's infrastructure only.

### 5. Deploy the app to the cloud

Build each image, tag it `<semver>-<7-char-git-hash>` (e.g. `1.2.0-a1b2c3d`) — `latest` is never used, anywhere — and push to ECR. Point your Helm chart at those images via a dedicated AWS values file, keeping the chart itself environment-agnostic. MongoDB's storage now needs to be a PVC dynamically provisioned by the **Amazon EBS CSI driver**. Install the **AWS Load Balancer Controller** and front the gateway with an Ingress/ALB — it should be the only thing reachable from outside the cluster.

### 6. Automate the pipeline (CI)

**GitHub Actions**, one workflow per app repo. Pull requests only lint/test/build-validate — they must never publish an image or touch the cluster. Pushes to `main` additionally version the build (a `VERSION` file plus the short git hash), authenticate to AWS via **OIDC** (a dedicated IAM role trusted for this org/repo/branch — no static access keys, ever), and push the tagged image to that service's ECR repo. Deploys stay manual for now.

### 7. Automate deployment (GitOps)

**Argo CD**, installed as its own Helm release in its own namespace, watching `sports-store-deployments`. Split per-service image config into its own file (e.g. `environments/production/images/cart-service.yaml`) so each app's CI only ever edits its own file, using a YAML-aware tool like `yq` — never a text replace. An Argo CD `AppProject` scopes what repos/destinations are allowed; an `Application` resource points at the chart plus all the values files and turns on automated sync, self-heal, and pruning. From here on, nobody runs `helm upgrade` by hand — every deploy is a Git commit to `main`, made by a scoped automation identity (a GitHub App installation token, ideally) that's the *only* thing allowed to bypass branch protection. Verify the full loop, drift correction, pruning, and a rollback done purely by committing an older tag.

### 8. Observability

**kube-prometheus-stack** (Prometheus, Grafana, Alertmanager, kube-state-metrics, node-exporter) and **Loki + Grafana Alloy** for logs, both deployed as their own Argo CD Applications — not installed by hand. Every service exposes an internal-only `/metrics` endpoint (request count, status, duration, process stats — no user/order/request IDs in labels), discovered via `ServiceMonitor` resources. Logs are structured JSON with no secrets or PII. Ship exactly one Grafana dashboard ("Sports Store Overview": node/pod health, request rate, error rate, latency) and a handful of Alertmanager alerts (service down, replicas unavailable, crash-looping, high error rate), all provisioned from Git rather than clicked together in the UI.

## Final deliverable — what "done" looks like

The application is running on an Amazon EKS cluster that Terraform provisioned. It's deployed via your Helm chart, and the image tags in that deployment are kept current by a CI pipeline that builds, tests, tags, and pushes images to ECR on every change. Nobody runs `helm upgrade` or `kubectl apply` by hand — Argo CD watches your deployment repo's `main` branch and reconciles the cluster to match it automatically, healing drift and able to roll back via a Git revert. Traffic reaches the app through an ALB in front of the NGINX gateway. Prometheus and Grafana show one dashboard covering the whole system, a handful of basic alerts are wired up, and logs are queryable through Loki. At demo time, every Argo CD Application involved — the app itself and the monitoring/logging stack — should show `Synced` and `Healthy`.

## Required extension

The stack above is the floor, not the ceiling. Every team must introduce and actually implement at least one piece of technology beyond it — either a new capability bolted on top (e.g. a WAF, Secrets Manager, RDS, Lambda, Route 53, CloudFront) or a swap of one of the prescribed tools for an alternative (e.g. Jenkins instead of GitHub Actions, GitLab CI, CircleCI, Flux instead of Argo CD, a different observability stack). It has to be real and working, not a config stub, and you should be ready to explain at the demo why you picked it and what it changes about the system.

## Checklist — things to think about before you demo

These aren't extra tasks with their own success criteria — they're lenses to look at the system you already built through. Be ready to talk about each one; don't be surprised if we ask.

- **Security** — Where do credentials actually live? Is anything sensitive ever committed to Git or printed to a log? Does every AWS auth path use short-lived/federated credentials instead of long-lived static keys? Do IAM roles and Kubernetes RBAC follow least privilege? Is anything more exposed than it needs to be?
- **Resources and costs** — Do your Deployments set resource requests/limits? What's actually costing money right now, and could any of it be smaller or cheaper? Do you have a real teardown path? Would your setup survive a node or pod dying?
- **Performance** — What have you actually measured versus just assumed? Where's the slowest hop in the system? Do your Grafana dashboards tell you anything about this?
- **Caching** — Is anything being recomputed or refetched that doesn't need to be? Have you considered a caching layer anywhere in the request path?

We'd rather see you bring in something we didn't teach than watch you tick these boxes with the bare minimum. That instinct is exactly what the required extension above is for.

## What's not here

There's no per-milestone task list, no exact manifests, and no success-criteria checklist. The tools and conventions above are fixed; the specific YAML, the order you tackle things in, and the judgment calls in between are yours. If you get stuck on a specific technology rather than the overall shape of the project, that's a sign to go read that tool's docs, not a sign this brief is missing a step.
