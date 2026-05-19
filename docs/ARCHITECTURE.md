# Architecture — mapping to design.md

Every resource this repo creates, tied to the `design.md` clause it satisfies.

## Topology decision (design.md §3.3)

| design.md requirement | Implementation |
|---|---|
| "workload SDKs send OTLP to a **Deployment gateway collector**" | `roles/otel_gateway` — `OpenTelemetryCollector` `mode: deployment`, `replicas: 2`. Both workloads point `OTEL_EXPORTER_OTLP_ENDPOINT` at its service. |
| "for **tail-sampling**" | Gateway `processors.tail_sampling`: composite-OR — `keep-errors` (status_code ERROR) + `keep-slow` (latency > `slow_latency_ms`) + `baseline-sample` (probabilistic `baseline_percent`). Tail-based so the full trace is seen before the keep/drop decision. |
| "**enrichment**" | Gateway `k8sattributes` (resolves `k8s.namespace.name`, `k8s.pod.name`, `k8s.container.name`, `k8s.deployment.name`, `k8s.node.name`) + `resource` (stamps `deployment.environment.name`). |
| "and **export to Tempo**" | Gateway `exporters.otlp` → `tempo-<name>-distributor.<ns>.svc:4317`. |
| "Use a **DaemonSet collector** only for node-local needs … because it increases privilege and resource footprint" | `roles/otel_node` — `mode: daemonset`, **opt-in** (`otel_daemonset_enabled`), `hostmetrics` only, NOT on the trace path, isolated `hostaccess` SCC (not `privileged`). |
| "do not run two log collectors against the same source" | DaemonSet `filelog` ships **disabled** (`otel_node_filelog_enabled: false`) with an in-template guard note; OpenShift Logging/Vector remains the preferred stdout/stderr path. |
| `Instrumentation` "auto-injects supported SDKs via pod annotation" | `roles/instrumentation` — `Instrumentation` CR; Python pod carries `instrumentation.opentelemetry.io/inject-python`. |
| "unsupported language/runtime combinations use manual SDK instrumentation" | Quarkus uses the `quarkus-opentelemetry` extension configured via `OTEL_*` env (manual SDK). The Java agent is **not** auto-injected into Quarkus (runtime+agent combo not recommended). |
| Canonical join fields (`service.name/.namespace/.version`, `deployment.environment.name`, `k8s.*`) | SDKs set `service.*`; Instrumentation CR + `OTEL_RESOURCE_ATTRIBUTES` set `service.namespace`/`service.version`/`deployment.environment.name`; gateway `k8sattributes` adds `k8s.*`. |

## Tempo / COO (design.md §3.4)

| design.md requirement | Implementation |
|---|---|
| "Tempo Operator → `TempoStack` (object-storage backed)" | `roles/operators` installs the Tempo Operator; `roles/tempo` creates `TempoStack` with an S3 `storage.secret`. |
| object storage | `roles/minio` — in-cluster MinIO + bucket. **Demo substitute** for ODF/Noobaa/external S3. |
| COO "delivers … distributed tracing" UIPlugin; "treat each plugin by its published support status" | `roles/tempo` creates `UIPlugin/distributed-tracing`; creation is non-fatal and falls back to the Tempo Jaeger `Route` if the CRD/plugin is unavailable on the target OpenShift version. |
| Hot-trace retention bounded (§4.1: 7–30d hot; trends as metrics) | `tempo_retention` default `168h` (7d); host_vars notes the 30d ceiling. |

## Build order (design.md §8 phase 4)

`site.yml`: operators → minio → tempo → otel_gateway → otel_node (opt-in) →
instrumentation → workload_quarkus → workload_python. This is the trace
portion of "Phase 4 — Logs & traces: Loki/Tempo/OTel Operator + COO UI".

## Production-readiness touchpoints (design.md §9)

| Check | Where |
|---|---|
| Correlation keys (`namespace`, `pod`, `trace_id`, `span_id`) consistent | Enforced by gateway `k8sattributes`+`resource` and SDK resource attributes; `validate.yml` surfaces a Tempo `service.name` search. |
| Cardinality / sampling controls | `tail_sampling` policies + tunable `baseline_percent`. |
| Support status | `UIPlugin` creation is non-fatal with a documented Route fallback; operator channels are pinnable in `host_vars`. |
| Source-of-truth | Tempo (native) is the trace system of record; no external SaaS export in this scope. |

## Expanded demo: namespaces, tenants, DB, UWM, scoped users

The single-namespace demo was grown to exercise the design's RBAC and app-
metrics clauses with a realistic multi-hop, DB-backed workload.

### Multi-namespace + per-tenant trace isolation (design.md §9, §3.4)

| Concern | Implementation |
|---|---|
| App-per-namespace, Dev-owned | `otel-demo-quarkus`, `otel-demo-python` (created by `roles/operators`); observability plane stays Platform-owned in `observability`. |
| One Tempo tenant per app | `TempoStack.spec.tenants` (`tempo_tenants` in group_vars) → tenants `quarkus`, `python` (mode `openshift`). |
| Collector routes spans to the right tenant | `roles/otel_gateway` `routing` connector: `traces/in` (enrich) → table on `service.namespace`/`k8s.namespace.name` → per-tenant pipeline → `otlp/<tenant>` exporter with `X-Scope-OrgID: <tenant>` + `bearertokenauth`. |
| Per-namespace trace RBAC | `roles/tempo` `tenant-rbac`: one `tempo-<tenant>-read` ClusterRole bound to that tenant's user only; one `tempo-collector-write` for the collector SA across all tenants. Proven by SubjectAccessReview in `validate.yml` (dev-quarkus↔quarkus only, dev-python↔python only). |
| 2 scoped Dev users | `roles/users`: htpasswd IdP (`demo-htpasswd`) + `dev-quarkus`/`dev-python`; each `edit`+`monitoring-edit` on only its namespace, and (via tenant-rbac) read on only its Tempo tenant. |

### Database spans (design.md §3.3 — spans/enrichment)

| Concern | Implementation |
|---|---|
| DB per app | `roles/postgres` deploys a PostgreSQL into each app namespace. |
| Quarkus DB spans | Custom app in `roles/workload_quarkus/files/quarkus-app` (REST + Hibernate Panache); `quarkus.datasource.jdbc.telemetry=true` + the `opentelemetry-jdbc` dep → JDBC spans nested under REST server spans. Built via **binary S2I** (`oc start-build --from-dir`). |
| Python DB spans | Extended Flask app; the OTel Operator auto-instruments `psycopg2` → `SELECT/INSERT/UPDATE` spans. |
| Deep multi-hop trace | `/checkout` → `/inventory` (HTTP self) → psycopg2 (own DB) → cross-namespace HTTP → Quarkus `/api/price` → JDBC. One trace whose spans split across **both** tenants — the per-user RBAC demo. |

### App metrics via OpenTelemetry (design.md §3.3 + §3.2)

Refactored from per-app Prometheus scrape to **OTel metrics** — the
design's "collect once, then route deliberately" + §3.3 collector
`exporters: Prometheus`. UWM stays the native store (§3.2 / §2 taxonomy);
only the collection mechanism changed.

| Concern | Implementation |
|---|---|
| Apps emit OTLP metrics | Quarkus: `quarkus.otel.metrics.enabled=true` (Micrometer→OTLP; no `quarkus-micrometer-registry-prometheus`, no `/q/metrics`). Python: Instrumentation CR `OTEL_METRICS_EXPORTER=otlp` (auto HTTP/runtime) + a custom `app.checkout.orders` counter via the OTel metrics API (no `prometheus_client`). |
| Same OTLP channel as traces | Apps already point at the gateway collector; metrics ride the same endpoint. |
| Collector metrics pipeline | `roles/otel_gateway`: `service.pipelines.metrics` = `otlp → memory_limiter,k8sattributes,resource,batch → prometheus` exporter (`:8889`, `resource_to_telemetry_conversion` so `service_name`/`k8s_namespace_name` become labels). NOT tenant-routed (metrics → Prometheus, not Tempo). |
| UWM scrape target | One Platform-owned `ServiceMonitor` (`roles/otel_gateway/templates/servicemonitor.yaml.j2`) on the collector Service `promexporter` port; `roles/uwm` enables UWM (merge-safe). |

### Network Observability (design.md §3.5)

Same per-namespace/per-user model as traces, applied to flows.

| Concern | Implementation |
|---|---|
| Object-storage Loki | `roles/loki`: Loki Operator 6.x + `LokiStack` (tenant mode **`openshift-network`**) on the **same demo MinIO** (new `netobserv-loki` bucket); raised per-tenant ingestion limits (`1x.demo` defaults 429 NetObserv). |
| Platform-owned collection | `roles/netobserv`: NetObserv Operator + cluster-wide `FlowCollector` (eBPF agent DaemonSet → flowlogs-pipeline → LokiStack + Prometheus + console plugin). Dev teams don't edit it. |
| Per-team scoping | `spec.processor.slicesConfig.enable: true` + `AlwaysCollect`: Platform collects cluster-wide; a **`FlowCollectorSlice`** per team namespace tunes that team's sampling/enrichment. |
| Per-team flow RBAC | Namespace-scoped RoleBindings of the operator ClusterRoles **`netobserv-loki-reader`** (flows) + **`netobserv-metrics-reader`** (metrics) to `dev-quarkus`/`dev-python`. The NetObserv console filters flows to namespaces the user can access — proven by SAR: each Dev can `list pods` only in their own namespace. |
| **Developer perspective requirement** | To use **Developer → Observe → Network Traffic** in the OpenShift console, the user must have the **`netobserv-reader` cluster role** *and* the **`netobserv-metrics-reader` namespace role**. Without both, the Developer-perspective view will be empty/inaccessible even when the Admin-perspective Network Traffic view works for the same user. |
| Verified | FLP counters `netobserv_loki_sent_entries_total > 0`, `dropped == 0` (flows captured + written); `validate.yml` checks FlowCollector/LokiStack Ready, slices, FLP counters, and the 4-way namespace SAR. |

### Platform logs & metrics via OpenTelemetry (design.md §3.1 / §3.3)

**Metrics correction:** platform metrics' system of record is **Core
Platform Monitoring** (Platform-owned, already admin-only via
`cluster-monitoring-view`) — *not* OpenTelemetry. We do **not** re-collect
them. The legitimate OTel slice is host/kubelet telemetry.

| Concern | Implementation |
|---|---|
| Host + kubelet metrics | `roles/otel_node` DaemonSet adds `hostmetrics` + `kubeletstats` → `prometheus` exporter; an **admin-scoped** ServiceMonitor in the Platform `observability` namespace (Dev users have no RBAC there). CPM remains the metrics SoR. |
| Infra + audit logs | Same DaemonSet (single log collector — no Vector on cluster, so §3.3 "two collectors" rule holds): `filelog/infra` (all pod logs **excluding app namespaces**) → `infrastructure`; `filelog/audit` (`/var/log/audit` + kube/openshift/oauth-apiserver audit) → `audit`. `log_type` stamped per pipeline (LokiStack OTLP needs ≥1 stream label). |
| Privilege | design.md §3.3 "increases privilege": the DaemonSet runs **privileged, runAsUser 0** (root-only audit files) with `tolerations: [{operator: Exists}]` so it covers **control-plane** nodes (API-server audit lives only on masters). `privileged` SCC bound in `scc-rbac`. |
| Store | `roles/platform_loki`: a **second** LokiStack (tenant mode **`openshift-logging`**) on the same demo MinIO (`platform-logs` bucket) — separate from the NetObserv `openshift-network` stack. |
| Admin-only (infra/audit) | `platform-logs-writer` (collector SA → create `infrastructure`/`audit`/`application`); `platform-logs-admin-reader` (get) bound **only** to `system:cluster-admins`. Dev users never bound. SAR matrix: dev-quarkus/dev-python get infra/audit = **false**; admins/collector = **true**. |
| Application logs (per-team) | A `filelog/app` receiver scoped to **only** the app namespaces (container parser → `k8s.namespace.name` stream label) → `application` tenant. `platform-app-logs-reader` bound as **namespace-scoped RoleBindings** to `dev-quarkus`/`dev-python` — each sees **only their own namespace's** app logs in Observe → Logs (the openshift-logging `application` tenant is per-namespace authorized by the Loki gateway). Same isolation as their traces/metrics/flows; cross-namespace = gateway-denied. |

## Deliberate deviations (demo, not production)

These are demo-grade and called out so they are not mistaken for the design:

1. **MinIO instead of ODF/Noobaa/external S3.** §3.4 only requires
   object-storage-backed Tempo; swap via `host_vars` (`*_storage_class`,
   replace the `tempo-s3` secret).
2. **Insecure in-cluster OTLP hop** gateway→Tempo (`tls.insecure: true`) and
   plaintext MinIO — service-local only. Real deployments terminate TLS;
   §9 "Egress" applies to any external route (none here).
3. **Demo MinIO credentials** in `group_vars` — replace before any shared use.
4. **Python app `pip install` at pod start** — convenience for the demo;
   a real workload ships a built image. Needs PyPI egress.
5. **`insecure_skip_verify` on the collector→Tempo-gateway hop** — avoids a
   service-CA mount; service-local only. Mount the service-CA for real use.
6. **htpasswd IdP + demo passwords in `group_vars`** — replace with the
   real IdP; set `tempo_tenant_reader_*`/user RBAC to your groups.
8. **Metrics ownership shift.** §3.2 has Dev own a `ServiceMonitor` per
   namespace. Routing app metrics through the OTel collector makes the
   single scrape target Platform-owned (the collector). This is the
   natural consequence of "collect once" — per-app labels are preserved
   on the metrics so per-namespace queries/RBAC still work. Revert to
   per-app ServiceMonitors if strict §3.2 Dev ownership is required.
7. **Routing default pipeline = first tenant.** Spans with no
   `service.namespace`/`k8s.namespace.name` fall to the first tenant. All
   real workloads here set `service.namespace`, so this only catches
   genuinely unattributed spans (e.g. leftover workloads in deleted
   namespaces, which age out with Tempo retention).
11. **Console Logs schema = `otel`.** One log source (OTel DaemonSet →
    OTLP → LokiStack). The stored stream labels are otel-style
    (`k8s_namespace_name`, `log_type`) — there is no `kubernetes_*`
    label — so the namespace filter must use **`k8s_namespace_name`**
    and the UIPlugin schema is `otel` (`platform_logs_ui_schema`).
    `viaq` only ever matched `log_type` (tenant), not namespace.
10. **Privileged platform-logs DaemonSet.** Audit collection forces
    `privileged`/root + all-node tolerations + a host-root mount — exactly
    the privilege design.md §3.3 warns about; it's the price of audit log
    tailing. Scope down (drop audit, use `hostaccess`) if not required.
9. **NetObserv on `1x.demo` Loki.** Single ingester (`LokiWarning` is
   expected/cosmetic) and `eBPF sampling=50` to stay under demo ingestion
   limits — production uses a larger LokiStack size and lower sampling.
   Loki `openshift-network` tenant **reads** are authorized by the
   observatorium gateway via SAR, not a plain ClusterRoleBinding — a
   generic SA token gets 403; the NetObserv console (acting as the user)
   is the supported read path.
