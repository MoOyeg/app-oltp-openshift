# app-oltp-openshift

Demonstrates the **trace slice** of the multicluster observability design
([`design.md`](docs/design.md)) §3.3 / §3.4 on OpenShift:

> Workload Software Development Kits (SDKs) send OpenTelemetry Protocol
> (OTLP) data to a **Deployment gateway collector** for tail-sampling,
> enrichment, and export to **Tempo**. A **DaemonSet collector** is used
> **only** for node-local needs (host metrics / log tailing) because it
> increases privilege and resource footprint.

A custom **Quarkus** app (primary, namespace `otel-demo-quarkus`) and an
extended **Python/Flask** app (secondary, namespace `otel-demo-python`),
each with its **own PostgreSQL**, emit a deep multi-hop trace. The gateway
collector enriches + tail-samples, then **routes spans per namespace** into
a **per-app Tempo tenant**. Two scoped htpasswd users prove Role-Based
Access Control (RBAC) isolation.

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

Covers design.md **§3.3/§3.4** (traces→Tempo), **§3.2** (User Workload
Monitoring (UWM) app metrics via OTLP), **§3.5** (Network Observability:
extended Berkeley Packet Filter (eBPF)→Flowlogs Pipeline (FLP)→LokiStack,
per-team FlowCollectorSlices), **§3.1/§3.3** (platform host/kubelet
metrics + infra/audit logs via the OpenTelemetry (OTel) DaemonSet → a
2nd `openshift-logging` LokiStack, **admin-only**), and **§9**
(per-namespace/per-tenant RBAC isolation across traces, metric labels,
flows, and admin-only platform logs). Red Hat Advanced Cluster Management
(RHACM) rollup remains out of scope — see `design.md`. **Datadog fan-out**
is supported as an opt-in (`datadog_enabled=true`) on top of the native
stack; see "Datadog fan-out" below.

## How OpenTelemetry obtains each signal

Two collection roles do all the work: the **Deployment gateway collector**
(the app trace/metric path) and the **DaemonSet node collector** (node-local
host/kubelet metrics + log tailing). The gateway enriches (`k8sattributes`,
`resource`), routes by namespace, tail-samples, then exports — to TempoStack
for traces and a Prometheus endpoint (UWM-scraped) for metrics. The
DaemonSet ships logs OTLP to the `openshift-logging` LokiStack.

| Signal | Application workloads (otel-demo-*) | Platform |
|---|---|---|
| **Traces** | Quarkus: build-time Software Development Kit (SDK) via `quarkus-opentelemetry` extension → OTLP/gRPC (gRPC Remote Procedure Calls) :4317 to gateway. Python: OTel Operator `Instrumentation` Custom Resource (CR) auto-injects an init container that sets `PYTHONPATH`, so `sitecustomize` loads the SDK and monkey-patches Flask/requests/psycopg2 at import — OTLP/HTTP :4318 to gateway. | None — OpenShift platform components don't emit OTLP traces. |
| **Metrics** | Quarkus: `quarkus-micrometer-opentelemetry` bridge maps Micrometer (Java Virtual Machine (JVM) + HTTP) meters to OTel → OTLP to gateway. Python: auto-instrumentation `OTEL_METRICS_EXPORTER=otlp` for HTTP/runtime + a custom OTel Meter counter (`app.checkout.orders`) → OTLP to gateway. Gateway re-exposes them on a Prometheus endpoint UWM scrapes. | **Cluster Platform Monitoring (CPM) remains the System of Record (SoR)** (admin-only); not re-collected via OTel. Supplementary OTel slice: DaemonSet `hostmetrics` (`/hostfs`) + `kubeletstats` (kubelet `/stats/summary`) → collector Prometheus endpoint scraped by an **admin-scoped** ServiceMonitor. |
| **Logs** | Apps log to stdout/stderr. The DaemonSet's `filelog/app` tails `/hostfs/var/log/pods/{otel-demo-*}/.../*.log` (Container Runtime Interface for the Open Container Initiative (CRI-O) parser → `k8s.namespace.name`/`k8s.pod.name` labels), stamps `log_type=application`, exports OTLP to LokiStack `application` tenant — visible per-team. | DaemonSet `filelog/infra` (all pods **excluding** app namespaces) + `filelog/audit` (`/var/log/audit/*` and kube/openshift/oauth-apiserver audit, masters via `tolerations: Exists`) → `infrastructure` / `audit` tenants of the same `openshift-logging` LokiStack — **admin-only**. |

Common downstream: SDKs/agents never write to Tempo or Loki directly — they
always emit OTLP to a collector, which enriches with k8s metadata, applies
the tail-sampling / namespace routing / log-tenant labels, and writes to
the design's native stores (Tempo, LokiStack, Prometheus/UWM). RBAC is at
those stores (Tempo tenants, Loki tenants, namespace labels on metrics).

## Prerequisites

- An OpenShift cluster + a **cluster-admin** kubeconfig
- `podman` (or `docker`) on the workstation — **no local ansible needed**
- Cluster egress to `registry.redhat.io`, `github.com` (Quarkus
  Source-to-Image (S2I) build), and the Python Package Index (PyPI;
  `python_pip_index_url`) for the Python app's in-pod `pip install`

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
   UPDATE) → cross-namespace HTTP → Quarkus → Java Database Connectivity
   (JDBC)` — a deep tree whose
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
   **Developer-perspective requirement:** to use the *Developer →
   Observe → Network Traffic* view, the user must have the
   **`netobserv-reader` cluster role** *and* the
   **`netobserv-metrics-reader` namespace role**. Without both, the
   Developer view is empty/inaccessible even if Admin-perspective
   Network Traffic works for the same user.
6. Platform + app logs (Observe → Logs): the privileged OTel DaemonSet
   feeds a separate `openshift-logging` LokiStack — `infrastructure` +
   `audit` are **admin-only** (`dev-*` SubjectAccessReview (SAR)-denied;
   only cluster-admins),
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

## Datadog fan-out (optional)

The OTel gateway and DaemonSet collectors can simultaneously fan out to
Datadog without disturbing the native Tempo / Prometheus / Loki path. The
exporter used is the upstream OTel Collector `datadog` exporter, which is
**not** in the Red Hat build — so when `datadog_enabled=true` both
collectors are swapped to `docker.io/otel/opentelemetry-collector-contrib`
(override with `datadog_collector_image`). All other components used here
(routing connector, k8sattributes, tail_sampling, filelog, otlphttp) exist
in contrib too, so the native pipelines keep working unchanged.

| Signal | Source pipeline | Sent to |
|---|---|---|
| Traces | gateway per-tenant `traces/<tenant>` | Tempo tenant **and** Datadog APM |
| Application metrics | gateway `metrics` | Prometheus exporter (UWM scrape) **and** Datadog Metrics |
| Host + kubelet metrics | DaemonSet `metrics` | Prometheus (admin-scoped ServiceMonitor) **and** Datadog Metrics |
| Application logs | DaemonSet `logs/application` | LokiStack `application` tenant **and** Datadog Logs |
| Infra + audit logs | DaemonSet `logs/infrastructure` / `logs/audit` | LokiStack `infrastructure` / `audit` tenants **and** Datadog Logs |
| Network flows (enriched, logs) | FlowCollector `spec.exporters[OpenTelemetry]` → gateway `logs/netobserv` | NetObserv LokiStack `network` tenant **and** Datadog Logs |
| Network flows (enriched, metrics) | FlowCollector `spec.exporters[OpenTelemetry]` → gateway `metrics/netobserv` | In-cluster Prometheus (NetObserv ServiceMonitor) **and** Datadog Metrics |

**Enabling.** Never put the API key in a tracked file. Pick one of:

```bash
# Option A: env var; the runner wrapper plumbs it through.
export DATADOG_API_KEY=<key>
./ansible-runner.sh deploy

# Option B: explicit extra-vars.
./ansible-runner.sh deploy \
  -e datadog_enabled=true \
  -e datadog_api_key=<key> \
  -e datadog_site=datadoghq.com   # or datadoghq.eu, us3.datadoghq.com, ...
```

The `datadog` role creates Secret `datadog-api-key` (key `DD_API_KEY`) in
the `observability` namespace; both collectors mount it as an env var and
the exporter resolves `${env:DD_API_KEY}` at startup. Re-running with
`datadog_enabled=false` (the default) removes the exporter from the
collectors and reverts both to the Red Hat collector image — the Secret
itself is left in place for idempotency; delete it with `oc -n
observability delete secret datadog-api-key` if you need a clean slate.

The enriched network-flow fan-out is gated separately by
`netobserv_datadog_enabled` (default `true`). When both it and
`datadog_enabled` are on, the `FlowCollector` adds an `OpenTelemetry`
exporter pointing at the gateway's dedicated OTLP receiver
(`gateway-collector.observability.svc:4319`) and the gateway picks up two
extra pipelines (`logs/netobserv`, `metrics/netobserv`) that export to
Datadog only. Set `netobserv_datadog_enabled=false` to keep app-side
Datadog fan-out on but suppress the high-volume flow stream.

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
  operators              OTel + Tempo + Cluster Observability Operator
                         (COO) operators via Operator Lifecycle Manager
                         (OLM); app namespaces
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
  datadog                opt-in: Datadog API-key Secret + both collectors
                         swap to contrib image + datadog exporter on the
                         trace/metric/log pipelines [datadog_enabled]
  users                  htpasswd Identity Provider (IdP) + 2
                         namespace/tenant-scoped users
docs/                    design.md (source of truth) + ARCHITECTURE.md
```
