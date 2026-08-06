# Observability — Milestone 8

Metrics, logs, one dashboard and a handful of alerts, all provisioned from
Git through Argo CD.

```
observability/
  kube-prometheus-stack/values.yaml   Prometheus + Grafana + Alertmanager + the alert rules
  loki/values.yaml                    Loki, single binary, filesystem storage
  alloy/values.yaml                   Alloy Deployment (1 replica), log collection pipeline
  extras/                             a one-ConfigMap chart holding the dashboard
    dashboards/sports-store-overview.json
```

The four Argo CD Applications that install these live in
`argocd/applications/` (`25-monitoring.yaml`, `60-loki.yaml`, `70-alloy.yaml`,
`80-observability-extras.yaml`), under the `observability` AppProject in
`argocd/projects/observability.yaml` — not in this directory. `argocd/`'s root
Application only ever picks up `argocd/{projects,applications}/*.yaml`
(see `argocd/bootstrap.yaml`'s `include` glob), so an Application manifest
committed here would be silently never created.

## How the signals fit together

| Question | Answered by | Where from |
|---|---|---|
| Is it up? | `up`, kube-state-metrics | ServiceMonitors in the app chart |
| How much traffic, and how many errors? | `http_requests_total` | each service's `/metrics` |
| How slow? | `http_request_duration_seconds` | same |
| Which *route* is slow? | same, by `handler` | same |
| What did the edge see? | JSON access logs | gateway → Loki |
| Why did it fail? | application logs | all pods → Alloy → Loki |

The gateway is the one component whose error rate and latency come from
**logs rather than metrics**, and that is not a shortcut: open-source nginx
exposes connection counts and a request total through `stub_status` and
nothing else — per-route status codes and latency are an NGINX Plus feature.
So Loki is load-bearing for two dashboard panels, not a log-tailing demo.

## Prerequisites

**1. The node group must be large enough, and the ebs-csi-controller reclaim
must have landed.** The stack requests ~1560Mi on top of the application.
Three `t3.small` nodes measured only 452Mi free even after reclaiming the
ebs-csi-controller's second replica — 4 nodes plus that reclaim lands the
budget at 5292Mi/5748Mi allocatable (92%). See
`stage8-plan-observability.md` §1 in `cloudcart-workspace` for the full
arithmetic, and `sports-store-infrastructure` PR #10 for the Terraform. If
this Application syncs before that capacity exists, Prometheus (the single
largest consumer at 700Mi) sits `Pending` on `Insufficient memory` — which
looks like a chart problem and is not.

**2. The Grafana admin Secret.** Not in Git, because it is a credential — and
not `kubectl create secret` either, because Milestone 7 exists to remove
exactly that bootstrap pattern. It comes from
`cluster/external-secrets/externalsecret-grafana-admin.yaml`, an ExternalSecret
that reads `GRAFANA_ADMIN_PASSWORD` off the same `sports-store/prod/app`
Secrets Manager entry `app-secrets` already uses. That property has to exist
on the secret before this Application's Grafana pod starts, or it comes up on
the chart's published default (`admin`/`prom-operator`) — a finding even
behind a port-forward.

**3. A `gp3` StorageClass**, already the cluster default from PR #6. All three
PVCs name it explicitly rather than relying on the default.

## Reaching Grafana

```sh
kubectl -n observability port-forward svc/monitoring-grafana 3000:80
```

Then <http://localhost:3000>. **There is deliberately no Ingress and no second
ALB.** The brief's own pre-demo checklist names "Grafana open to the internet
with no auth" as a thing to be caught; a port-forward requires cluster
credentials to establish at all. Putting it on a URL means an internal-scheme
ALB plus real auth — a values change, no templates move.

Prometheus and Alertmanager the same way:

```sh
kubectl -n observability port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090
kubectl -n observability port-forward svc/monitoring-kube-prometheus-alertmanager 9093:9093
```

## Verifying without a cluster

Every file here renders offline, and this is worth running before any PR:

```sh
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts && helm repo update

helm template monitoring prometheus-community/kube-prometheus-stack --version 88.1.5 \
  -n observability -f kube-prometheus-stack/values.yaml >/dev/null
helm template loki  grafana/loki  --version 7.2.0  -n observability -f loki/values.yaml  >/dev/null
helm template alloy grafana/alloy --version 1.11.0 -n observability -f alloy/values.yaml >/dev/null
helm template extras ./extras -n observability >/dev/null
```

The check that actually matters, because it is the failure with no error
message — Prometheus must select **all** ServiceMonitors, not only its own
release's:

```sh
helm template monitoring prometheus-community/kube-prometheus-stack --version 88.1.5 \
  -n observability -f kube-prometheus-stack/values.yaml \
  | grep serviceMonitorSelector
# serviceMonitorSelector: {}      <- empty means "select everything"
```

If that ever renders `matchLabels: release: monitoring`, the six application
ServiceMonitors will be created, listed by `kubectl`, and silently ignored.

## Traps that are already handled

Each of these is a chart default (or a first-draft bug of our own) that
breaks silently, with no error pointing at its own cause. They are commented
in the values files; listed here so they are findable.

| Where | Default / bug | Why it breaks |
|---|---|---|
| kube-prometheus-stack | `serviceMonitorSelectorNilUsesHelmValues: true` | Prometheus ignores every ServiceMonitor from another release. No error, empty dashboard |
| kube-prometheus-stack | `SportsStoreMongoDBDown` querying `kube_statefulset_status_replicas_ready` | Bitnami's `architecture: standalone` renders a **Deployment**, not a StatefulSet — the query matches no series and never fires, silently, forever |
| kube-prometheus-stack | `kubeEtcd`/`kubeScheduler`/`kubeControllerManager` monitors left on, alone | AWS exposes no scrape endpoint for these — 0 targets. Their *paired* default alert rules are `absent(up{job=...})`, which is **permanently true** once the monitor is off but the rule isn't. Both halves must move together |
| Alloy | `controller.type: daemonset` with `loki.source.kubernetes` | That component tails through the Kubernetes API, not the node filesystem — a DaemonSet here means every replica tails every pod. 3-4x duplicate logs, 3-4x ingest, no error anywhere |
| Loki | `deploymentMode: SimpleScalable` | Requires object storage; filesystem is not an option in that mode |
| Loki | `singleBinary.replicas: 0` | Setting the mode is not enough — the StatefulSet renders with zero replicas |
| Loki | `chunksCache.enabled: true` | An 8 GiB memcached. Permanently `Pending`, and the event names memcached, not Loki |
| Loki | `retention_period` without the compactor | Retention silently does nothing; the PVC fills and writes start failing |
| Argo CD | client-side apply | Prometheus Operator CRDs exceed the 262144-byte annotation limit |
| App chart | ServiceMonitor CRD missing | Fails the *whole* release, not the one object — hence `metrics.enabled` |

## Alerts

Six rules in `kube-prometheus-stack/values.yaml`, under
`additionalPrometheusRulesMap`, so they live beside the Prometheus that
evaluates them.

`SportsStoreHighErrorRate` counts **5xx only**, never "anything that is not
2xx". payment-service returns **402** on a declined card and order-service
propagates it — the checkout saga's designed failure path, exercised by any
card ending `0000`. An alert on non-2xx would fire every time the demo shows
the decline path working correctly.

`SportsStoreMongoDBDown` queries the **Deployment** MongoDB actually renders
as (`kube_deployment_status_replicas_available`), not a StatefulSet — see the
traps table above.

Alertmanager routes everything to a **null receiver**. There is no Slack
webhook in this repo and there will not be one — it is a credential. "Wired
up" means the rules evaluate and fire visibly in the Alertmanager and Grafana
UIs. Adding a real receiver is a values change plus a Secret; no rule moves.

To demonstrate one firing:

```sh
kubectl -n sports-store scale deploy/payment-service --replicas=0
# ~2 min -> SportsStoreServiceDown + SportsStoreReplicasUnavailable
# (Argo CD self-heal reverts the scale on its own polling cycle; the alert
# fires first, so scale back manually to resolve it sooner)
kubectl -n sports-store scale deploy/payment-service --replicas=2
```

## Why a third AppProject

`argocd/projects/observability.yaml`, rather than widening `platform`: these
four Applications pull from two upstream Helm repos
(`prometheus-community.github.io/helm-charts`, `grafana.github.io/helm-charts`)
that nothing else in this repository needs, and widening `platform`'s
`sourceRepos` would hand that access to the ALB controller and ESO
Applications too. `clusterResourceWhitelist` is enumerated from the actual
render — kube-prometheus-stack's CRDs, the Prometheus Operator's
ClusterRole/Binding and its admission webhooks — the same discipline
`projects/sports-store.yaml`'s own whitelist follows.

One resource these Applications need lives **outside** this project: the
Grafana admin Secret is created by the `cluster-secrets` Application, which
is in `platform` (it also creates `app-secrets` and `mongodb-credentials`).
That is why `platform.yaml` gained `observability` in its `destinations`
rather than the new project growing a dependency on `cluster/`.
