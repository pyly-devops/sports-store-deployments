# Observability — Milestone 8

Metrics, logs, one dashboard and a handful of alerts, all provisioned from
Git through Argo CD.

```
observability/
  kube-prometheus-stack/values.yaml   Prometheus + Grafana + Alertmanager + the alert rules
  loki/values.yaml                    Loki, single binary, filesystem storage
  alloy/values.yaml                   Alloy DaemonSet, log collection pipeline
  extras/                             a one-ConfigMap chart holding the dashboard
    dashboards/sports-store-overview.json
  argocd/                             the four Applications
```

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

**1. The node group must be large enough.** The stack requests roughly
4–4.5 GiB on top of the application. Two `t3.small` nodes give about 3 GiB
schedulable in total, so Prometheus sits `Pending` on `Insufficient memory` —
which looks like a chart problem and is not. `node_instance_types` in
`sports-store-infrastructure` needs to be `t3.large`. See the Milestone 8 plan
§2 in `cloudcart-workspace`.

**2. The Grafana admin Secret.** Not in Git, because it is a credential:

```sh
kubectl create namespace observability
kubectl -n observability create secret generic grafana-admin \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$(openssl rand -base64 24)"
```

Without it Grafana comes up on the chart's published default
(`admin`/`prom-operator`), which is a finding even behind a port-forward.

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

Each of these is a chart default that breaks this cluster, and each fails in a
way that does not point at its own cause. They are commented in the values
files; listed here so they are findable.

| Where | Default | Why it breaks |
|---|---|---|
| kube-prometheus-stack | `serviceMonitorSelectorNilUsesHelmValues: true` | Prometheus ignores every ServiceMonitor from another release. No error, empty dashboard |
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
card ending `0000`. An alert on non-2xx would fire every time the decline path
is demonstrated working correctly.

Alertmanager routes everything to a **null receiver**. There is no Slack
webhook in this repo and there will not be one — it is a credential. "Wired
up" means the rules evaluate and fire visibly in the Alertmanager and Grafana
UIs. Adding a real receiver is a values change plus a Secret; no rule moves.

To demonstrate one firing:

```sh
kubectl -n sports-store scale deploy/payment-service --replicas=0
# ~2 min -> SportsStoreServiceDown + SportsStoreReplicasUnavailable
kubectl -n sports-store scale deploy/payment-service --replicas=2
```

## Milestone 7 dependencies

The four Applications in `argocd/` carry `# M7` comments on the three values
that depend on how Argo CD was set up: the `argocd` namespace, the
`project` name, and whether sync-waves order Applications relative to each
other (they only do under an app-of-apps root or an ApplicationSet).

**The one that will reject all four:** if the AppProject restricts
`sourceRepos` to this org's own repositories, every Application fails with
`application repo <url> is not permitted in project <name>`, because three of
them pull their chart from an upstream Helm repository. The project needs:

```yaml
sourceRepos:
  - https://github.com/pyly-devops/*
  - https://prometheus-community.github.io/helm-charts
  - https://grafana.github.io/helm-charts
destinations:
  - namespace: observability
    server: https://kubernetes.default.svc
```
