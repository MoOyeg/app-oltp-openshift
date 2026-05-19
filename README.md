# app-oltp-openshift

Demonstrates the **trace slice** of the multicluster observability design
([`design.md`](docs/design.md)) §3.3 / §3.4 on OpenShift:

> Workload SDKs send OTLP to a **Deployment gateway collector** for
> tail-sampling, enrichment, and export to **Tempo**. A **DaemonSet
> collector** is used **only** for node-local needs (host metrics / log
> tailing) because it increases privilege and resource footprint.

A custom **Quarkus** app (primary, namespace `otel-demo-quarkus`) and an
extended **Python/Flask** app (secondary, namespace `otel-demo-python`),
each with its **own PostgreSQL**, emit a deep multi-hop trace. The gateway
collector enriches + tail-samples, then **routes spans per namespace** into
a **per-app Tempo tenant**. Two scoped htpasswd users prove RBAC isolation.

```
 otel-demo-python                         otel-demo-quarkus
 ┌───────────────────────────┐            ┌──────────────────────────┐
 │ python /checkout          │            │ quarkus /api/price/{sku} │
 │   → /inventory (HTTP)     │            │   → JDBC (Hibernate)     │
 │   → psycopg2 → Postgres   │            │   → Postgres             │
 │   → cross-ns HTTP ────────┼───────────▶│   (no scrape endpoint)   │
 │ (traces + OTLP metrics)   │            │ (traces + OTLP metrics)  │
 └────────────┬──────────────┘            └────────────┬─────────────┘
   auto-inject │ OTLP (traces+metrics)   manual SDK     │ OTLP
               └──────────────┬───────────────┬─────────┘
                              ▼               ▼
                  gateway collector (Deployment): memory_limiter →
                  k8sattributes+resource (enrich) →
                   • traces  : ROUTING by service.namespace →
                               per-tenant tail_sampling →
                               otlp/<tenant> (bearer + X-Scope-OrgID)
                   • metrics : prometheus exporter :8889
                              │                         │
                ┌──tenant:quarkus──┐ ┌─tenant:python─┐  │
                ▼                  ▼ ▼               ▼  │
              TempoStack (multitenant, OpenShift authz) │──S3──▶ MinIO
                              ▼                         ▼
   Console Observe→Traces (COO) —          UWM scrapes ONE collector
   dev-quarkus sees ONLY quarkus tenant;   ServiceMonitor (app metrics
   dev-python sees ONLY python tenant.     with service/ns labels)

 node collector (DaemonSet) ── hostmetrics ─▶ Prometheus   [node-local
                                                  only, opt-in, off-path]
```

Covers design.md **§3.3/§3.4** (traces→Tempo), **§3.2** (UWM app metrics
via OTLP), **§3.5** (Network Observability: eBPF→FLP→LokiStack, per-team
FlowCollectorSlices), **§3.1/§3.3** (platform host/kubelet metrics +
infra/audit logs via the OTel DaemonSet → a 2nd `openshift-logging`
LokiStack, **admin-only**), and **§9** (per-namespace/per-tenant RBAC
isolation across traces, metric labels, flows, and admin-only platform
logs). RHACM rollup / Datadog remain out of scope — see `design.md`.

## How OpenTelemetry obtains each signal

Two collection roles do all the work: the **Deployment gateway collector**
(the app trace/metric path) and the **DaemonSet node collector** (node-local
host/kubelet metrics + log tailing). The gateway enriches (`k8sattributes`,
`resource`), routes by namespace, tail-samples, then exports — to TempoStack
for traces and a Prometheus endpoint (UWM-scraped) for metrics. The
DaemonSet ships logs OTLP to the `openshift-logging` LokiStack.

| Signal | Application workloads (otel-demo-*) | Platform |
|---|---|---|
| **Traces** | Quarkus: build-time SDK via `quarkus-opentelemetry` extension → OTLP/gRPC :4317 to gateway. Python: OTel Operator `Instrumentation` CR auto-injects an init container that sets `PYTHONPATH`, so `sitecustomize` loads the SDK and monkey-patches Flask/requests/psycopg2 at import — OTLP/HTTP :4318 to gateway. | None — OpenShift platform components don't emit OTLP traces. |
| **Metrics** | Quarkus: `quarkus-micrometer-opentelemetry` bridge maps Micrometer (JVM + HTTP) meters to OTel → OTLP to gateway. Python: auto-instrumentation `OTEL_METRICS_EXPORTER=otlp` for HTTP/runtime + a custom OTel Meter counter (`app.checkout.orders`) → OTLP to gateway. Gateway re-exposes them on a Prometheus endpoint UWM scrapes. | **CPM remains the SoR** (admin-only); not re-collected via OTel. Supplementary OTel slice: DaemonSet `hostmetrics` (`/hostfs`) + `kubeletstats` (kubelet `/stats/summary`) → collector Prometheus endpoint scraped by an **admin-scoped** ServiceMonitor. |
| **Logs** | Apps log to stdout/stderr. The DaemonSet's `filelog/app` tails `/hostfs/var/log/pods/{otel-demo-*}/.../*.log` (CRI-O parser → `k8s.namespace.name`/`k8s.pod.name` labels), stamps `log_type=application`, exports OTLP to LokiStack `application` tenant — visible per-team. | DaemonSet `filelog/infra` (all pods **excluding** app namespaces) + `filelog/audit` (`/var/log/audit/*` and kube/openshift/oauth-apiserver audit, masters via `tolerations: Exists`) → `infrastructure` / `audit` tenants of the same `openshift-logging` LokiStack — **admin-only**. |

Common downstream: SDKs/agents never write to Tempo or Loki directly — they
always emit OTLP to a collector, which enriches with k8s metadata, applies
the tail-sampling / namespace routing / log-tenant labels, and writes to
the design's native stores (Tempo, LokiStack, Prometheus/UWM). RBAC is at
those stores (Tempo tenants, Loki tenants, namespace labels on metrics).

## Prerequisites

- An OpenShift cluster + a **cluster-admin** kubeconfig
- `podman` (or `docker`) on the workstation — **no local ansible needed**
- Cluster egress to `registry.redhat.io`, `github.com` (Quarkus S2I build),
  and PyPI (`python_pip_index_url`) for the Python app's in-pod `pip install`

## Quick start

```bash
export KUBECONFIG=/path/to/cluster-admin.kubeconfig
./setup.sh                       # validates podman + seeds host_vars
./ansible-runner.sh deploy       # full build
./ansible-runner.sh validate     # post-deploy checks
./ansible-runner.sh destroy      # tear down
```

Subsets via tags, e.g. `./ansible-runner.sh deploy --tags tempo,gateway`.
All tunables live in [`inventory/group_vars/all.yml`](inventory/group_vars/all.yml);
override per cluster in `inventory/host_vars/cluster.yml`.

## Seeing traces (and the RBAC story)

Two htpasswd users are created (passwords in `group_vars`, change them):
`dev-quarkus` and `dev-python`. Each can see **only** its own namespace and
**only** its own Tempo tenant.

1. Log into the console as `dev-quarkus` (or `dev-python`) →
   **Observe → Traces** → it lists TempoStack `demo`, but only the
   **tenant you're entitled to**. The other tenant returns 403 — that's
   the design.md §9 per-namespace isolation, proven.
2. Filter by `service.name`. Open a `python-otel-demo` `/checkout` trace:
   it fans out `flask → requests(/inventory) → psycopg2(SELECT/INSERT/
   UPDATE) → cross-namespace HTTP → Quarkus → JDBC` — a deep tree whose
   spans split across **both** tenants (so `dev-python` sees the python
   half, `dev-quarkus` the quarkus half of the same logical request).
3. Load generators run continuously (incl. `/api/boom` → ERROR spans), so
   `tail_sampling` visibly keeps errors/slow while sampling the rest.
4. App metrics (OpenTelemetry): apps emit **OTLP metrics** to the gateway
   collector, which exposes one Prometheus endpoint that UWM scrapes.
   **Observe → Metrics** — query `app_checkout_orders_total` (Python
   custom OTel counter) or `http_server_*` / JVM series; metrics carry
   `service_name` / `k8s_namespace_name` labels for per-namespace views.
5. Network flows (NetObserv): **Observe → Network Traffic**. As
   `dev-quarkus` you see only flows involving `otel-demo-quarkus` (e.g.
   the cross-namespace `python → quarkus` call as *destination*); as
   `dev-python`, only `otel-demo-python`. The eBPF agent → FLP →
   LokiStack(`openshift-network`); a per-team `FlowCollectorSlice` plus
   namespace-scoped `netobserv-loki-reader`/`netobserv-metrics-reader`
   enforce the split (design.md §3.5).
6. Platform + app logs (Observe → Logs): the privileged OTel DaemonSet
   feeds a separate `openshift-logging` LokiStack — `infrastructure` +
   `audit` are **admin-only** (`dev-*` SAR-denied; only cluster-admins),
   while `application` is **per-team**: `dev-quarkus`/`dev-python` each
   see **only their own namespace's** app logs (namespace-scoped Loki
   RBAC, cross-namespace gateway-denied) — same isolation as their
   traces/metrics/flows. Host/kubelet metrics on an admin-scoped
   ServiceMonitor; CPM stays the platform-metrics SoR. design.md
   §3.1/§3.3.

`validate.yml` automates all of this (Tempo/gateway health, DB-span
presence, per-tenant routing, UWM + collector ServiceMonitors, NetObserv
flows + per-team flow RBAC, the platform-logs admin-only SAR matrix, and
the user↔tenant RBAC matrices).

## What maps to what

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the line-by-line
mapping of every resource to a `design.md` section (incl. the expanded
multi-namespace / per-tenant / DB / UWM / scoped-users design) and the
explicit demo deviations.

## Layout

```
ansible-runner.sh        podman wrapper (regional-dr-example style)
Containerfile            ansible-core + kubernetes.core + oc
deploy/destroy/validate.yml + site.yml
inventory/               hosts, group_vars/all.yml, host_vars example
roles/
  operators              OTel + Tempo + COO operators (OLM); app namespaces
  uwm                    enable User Workload Monitoring (merge-safe)
  minio                  demo S3 backend for Tempo
  tempo                  TempoStack (multitenant) + S3 secret + UIPlugin
                         + per-tenant read/write RBAC
  otel_gateway           Deployment collector: enrich; traces per-ns
                         routing→tenant tail-sampling→Tempo; metrics→
                         prometheus exporter + UWM ServiceMonitor
  otel_node              DaemonSet collector: node-local host metrics (opt-in)
  instrumentation        Instrumentation CR (Python auto-inject, OTLP metrics)
  postgres               one PostgreSQL per app namespace
  workload_quarkus       primary app: custom Quarkus (REST+Panache+DB),
                         binary S2I, manual SDK, OTLP metrics
  workload_python        secondary app: multi-hop Flask + psycopg2,
                         auto-injected SDK, /metrics
  loki                   Loki Operator + LokiStack (openshift-network) on
                         MinIO (netobserv-loki bucket) [netobserv_enabled]
  netobserv              NetObserv Operator + cluster FlowCollector +
                         per-team FlowCollectorSlice + flow RBAC
  platform_loki          2nd LokiStack (openshift-logging) on MinIO
                         (platform-logs bucket) + admin-only tenant RBAC
                         [platform_telemetry_enabled]
  (otel_node extended)   privileged DaemonSet: hostmetrics+kubeletstats
                         + filelog infra/audit -> openshift-logging Loki
  users                  htpasswd IdP + 2 namespace/tenant-scoped users
docs/                    design.md (source of truth) + ARCHITECTURE.md
```
