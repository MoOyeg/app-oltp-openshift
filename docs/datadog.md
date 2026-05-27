# Datadog fan-out — how it works

This doc explains the **implementation** of the optional Datadog fan-out
(`datadog_enabled=true`) — what every config block does, why it's there,
and how the bytes flow from a workload all the way to Datadog. For
high-level "what it is and how to turn it on", see the
[README's "Datadog fan-out (optional)" section](../README.md).

The fan-out is **additive**: when off, the stack ships traces to Tempo,
app metrics to UWM, and platform logs to LokiStack as designed. When on,
the same data continues to those native stores **and** is also forwarded
to Datadog. Nothing on the native path changes shape.

## TL;DR

```
                Workload SDKs              Container stdout              Audit logs
                (Quarkus / Python)         (/var/log/pods)               (/var/log/audit, kube/oc/oauth)
                       │                          │                              │
                  OTLP / gRPC :4317               │ filelog                      │ filelog
                  OTLP / HTTP :4318               ▼                              ▼
                       ▼                  ┌──────────────────────────────────────────┐
            ┌────────────────────┐         │       node-collector (DaemonSet,         │
            │  gateway-collector │         │       contrib image when DD on)          │
            │  (Deployment x 2,  │         │  ┌─ hostmetrics (10s) ─┐                 │
            │  contrib image     │         │  │  kubeletstats        │                │
            │  when DD on)       │         │  │  prometheus/self     │                │
            │                    │         │  │  filelog/{infra,     │                │
            │  routing connector │         │  │     app, audit}      │                │
            │   ├─ tempo: per-tenant       │  └──┬───────────────────┘                │
            │   │  otlp/<tenant>           │     ▼ resourcedetection, batch           │
            │   │  + datadog                │  ┌────────────────────┐                  │
            │   │  + datadog/connector     │  │ otlphttp/<tenant>  │ ─▶ LokiStack    │
            │   └─ metrics:                │  │ datadog            │ ─▶ Datadog Logs │
            │      prometheus :8889 (UWM)  │  │ prometheus :8889   │ ─▶ UWM admin SM │
            │      datadog                 │  └────────────────────┘                  │
            └─────┬──────────────┬─────────┘──────────────────────────────────────────┘
                  │              │
                  ▼              ▼
              Tempo per-tenant  Datadog US5 ingest (api.us5.datadoghq.com)
              (otlp/<tenant>)
```

Two collectors, one exporter type (`datadog`), one connector
(`datadog/connector`), one shared Secret (`datadog-api-key`).

## The exporter and the connector

These are two distinct components from the OpenTelemetry Collector
contrib distribution. We use both because Datadog's APM data model
expects more than just raw spans.

### `datadog` exporter

The exporter is the "wire" — it takes OTel data in its pipeline and ships
it to Datadog's HTTP intake using Datadog's native payload format
(Protocol Buffers for traces, Datadog metrics V2 for metrics, Datadog
logs V2 for logs). It handles:

- API key authentication (`api.key`)
- Site routing (`api.site` → `api.<site>` per signal)
- Hostname inference from resource attributes (`host.name`, `k8s.node.name`)
- Per-signal endpoints (traces vs. metrics vs. logs use different paths)
- Batching, retries, and gzip compression

Config:

```yaml
exporters:
  datadog:
    api:
      site: us5.datadoghq.com    # group_vars: datadog_site
      key:  ${env:DD_API_KEY}    # injected from Secret datadog-api-key
```

Listed as an exporter on every Datadog-bound pipeline.

### `datadog/connector`

A connector is "an exporter on one pipeline + a receiver on another." The
`datadog/connector` receives **spans** and emits **APM trace metrics** —
service-level rollups (request count, error count, hit count, latency
histograms by service/operation/resource). Without it, the exporter would
ship raw spans only, and Datadog's APM Service Catalog stats (RPS, error
rate, p95/p99) would either be missing or back-computed lossily.

Config (no tuning needed — defaults match Datadog's expectations):

```yaml
connectors:
  datadog/connector: {}
```

Wiring (gateway only — the DaemonSet doesn't see spans):

```yaml
service:
  pipelines:
    traces/quarkus:
      exporters: [otlp/quarkus, debug, datadog, datadog/connector]
      #                                          │       │
      #                            raw spans ────┘       └──── compute APM stats,
      #                            to Datadog APM             feed into metrics pipeline
    traces/python: [...same shape...]

    metrics:
      receivers: [otlp, prometheus/self, datadog/connector]
      #                                  └──── APM trace metrics come in here
      exporters: [prometheus, datadog]
```

The collector log line that confirms the modern wiring is correct:

```
datadog connector using the native OTel API to ingest OTel spans and produce APM stats
Trace metrics are now disabled in the Datadog Exporter by default. To continue
receiving Trace Metrics, configure the Datadog Connector or disable the feature gate.
```

The second line is the exporter politely declining to do what the
connector now does for it. Good — that's the canonical 2024+ pattern per
the [Datadog OTel migration guide](https://docs.datadoghq.com/opentelemetry/guide/migration/).

## Why we swap to the contrib image

The Red Hat build of OpenTelemetry Collector ships a curated subset of
upstream components. The `datadog` exporter, the `datadog/connector`,
and the `resourcedetection` processor with the `openshift` detector are
all in the upstream **contrib** distribution but **not** in the Red Hat
build. When `datadog_enabled=true`, both `OpenTelemetryCollector` CRs get
`spec.image` set to `docker.io/otel/opentelemetry-collector-contrib:0.120.0`
(override with `datadog_collector_image`).

Every other component we use (`otlp`, `hostmetrics`, `kubeletstats`,
`filelog`, `k8sattributes`, `tail_sampling`, `routing` connector,
`otlphttp`, `prometheus` exporter, `bearertokenauth` extension) is in
contrib too, so the native Tempo/UWM/LokiStack paths keep working
unchanged. The trade-off is losing Red Hat support coverage on the
collector binary — the rest of the stack (Tempo Operator, Loki Operator,
COO, NetObserv Operator) is unaffected.

## API key handling

The key never lives in a tracked file.

1. User provides it at runtime — either `export DATADOG_API_KEY=…` (the
   runner wrapper plumbs it through as an extra-var) or
   `-e datadog_api_key=…` on the playbook command line.
2. The `datadog` role writes Secret `datadog-api-key` (key `DD_API_KEY`)
   in the `observability` namespace via `stringData`. Ansible's
   `kubernetes.core.k8s` module suppresses the value in stdout when the
   resource kind is `Secret`.
3. Both `OpenTelemetryCollector` specs mount the Secret as an env var:

   ```yaml
   env:
     - name: DD_API_KEY
       valueFrom:
         secretKeyRef:
           name: datadog-api-key
           key:  DD_API_KEY
   ```

4. The exporter config dereferences it with `${env:DD_API_KEY}` — the
   literal value is never present in the rendered ConfigMap.

To rotate: update the Secret out-of-band and restart both collectors.

```bash
oc -n observability create secret generic datadog-api-key \
  --from-literal=DD_API_KEY=<new-key> --dry-run=client -o yaml \
  | oc apply -f -
oc -n observability rollout restart deploy/gateway-collector
oc -n observability rollout restart ds/node-collector
```

## Pipeline anatomy

### Gateway collector (Deployment)

The gateway sees app traces (OTLP from SDKs) and app metrics (also OTLP).
It enriches once, then routes by tenant for the Tempo path while also
duplicating to Datadog.

| Pipeline | Receivers | Processors | Exporters / Connectors out |
|---|---|---|---|
| `traces/in` | `otlp` | `memory_limiter, k8sattributes, resource, resourcedetection` | `routing` (connector → per-tenant) |
| `traces/quarkus` | `routing` | `tail_sampling, batch` | `otlp/quarkus, debug, datadog, datadog/connector` |
| `traces/python` | `routing` | `tail_sampling, batch` | `otlp/python, debug, datadog, datadog/connector` |
| `metrics` | `otlp, prometheus/self, datadog/connector` | `memory_limiter, k8sattributes, resource, resourcedetection, batch` | `prometheus` (:8889 → UWM), `datadog` |

`prometheus/self` scrapes the collector's own `otelcol_*` self-telemetry
on `0.0.0.0:8888`. With these series in Datadog you get the official
"OpenTelemetry Collector" dashboard (drops, queue size, exporter latency,
refused payloads, etc.).

### Node collector (DaemonSet)

The node collector tails host log files and scrapes node-local metrics.
It never sees app spans.

| Pipeline | Receivers | Processors | Exporters out |
|---|---|---|---|
| `metrics` | `hostmetrics` (10s), `kubeletstats`, `prometheus/self` | `resource, resourcedetection, batch` | `prometheus` (admin SM), `datadog` |
| `logs/infrastructure` | `filelog/infra` | `resource, resourcedetection, resource/infra, batch` | `otlphttp/infrastructure` (LokiStack admin tenant), `datadog` |
| `logs/application` | `filelog/app` | `resource, resourcedetection, resource/app, batch` | `otlphttp/application` (LokiStack per-team tenant), `datadog` |
| `logs/audit` | `filelog/audit` | `resource, resourcedetection, resource/audit, batch` | `otlphttp/audit` (LokiStack admin tenant), `datadog` |

`hostmetrics.collection_interval` flips from the design default (30s) to
**10s** when `datadog_enabled` — matches Datadog's recommended cadence
for infrastructure metrics without affecting the UWM path when DD is off.

## Resource attributes / host correlation

Datadog's UI keys off a handful of attributes for host, service, and
container identity. We populate them with three processors used in
sequence:

1. **`k8sattributes`** (gateway only). Watches Pods and resolves
   `k8s.namespace.name`, `k8s.pod.name`, `k8s.deployment.name`,
   `k8s.container.name`, `k8s.node.name` from the sender's pod IP. This
   is what makes the Datadog APM service catalog group spans correctly
   by deployment.
2. **`resource`**. Stamps the static dimension
   `deployment.environment.name=demo` (override with
   `otel_environment_name`) so traces/metrics/logs all carry the same
   environment tag.
3. **`resourcedetection`** with detectors `[env, system, openshift]`
   (default — see `datadog_resource_detectors` for cloud-specific
   variants). On OpenShift on AWS this produces:

   ```
   cloud.platform   = aws_openshift
   cloud.provider   = aws
   cloud.region     = us-east-2
   k8s.cluster.name = cluster3-j4vqw
   host.name        = <pod or node name>
   os.type          = linux
   ```

   `override: false` is set so anything `k8sattributes` or the SDK
   supplied wins over the detector. This is what makes Datadog stop
   complaining about missing host correlation.

The `openshift` detector calls `GET infrastructures.config.openshift.io/cluster`,
which requires extra cluster-scoped RBAC. The `datadog` role creates the
ClusterRole + ClusterRoleBinding (`otel-resourcedetection-openshift`)
binding both collector ServiceAccounts. If you drop `openshift` from
`datadog_resource_detectors`, that RBAC is also skipped.

## Site selection

`datadog_site` (default `us5.datadoghq.com`) becomes the `api.site`
field on the exporter. The exporter derives every per-signal endpoint
from this:

- Traces: `https://trace.agent.<site>`
- Metrics: `https://api.<site>`
- Logs: `https://http-intake.logs.<site>`

The API key validation step at collector startup goes to `https://api.<site>/api/v1/validate`. If the site is wrong for the key's org, validation may still succeed (cross-region key lookup) but **payload submission gets 403 Forbidden** because the actual ingest endpoints are region-pinned. That's the failure mode we hit when we briefly had `datadog_site: datadoghq.com` with a US5 key — see "Troubleshooting" below.

Valid sites: `datadoghq.com` (US1), `us3.datadoghq.com`, `us5.datadoghq.com`,
`datadoghq.eu` (EU1), `ddog-gov.com` (US1-FED), `ap1.datadoghq.com`.

## How to verify it's working

End-to-end smoke check (assumes `datadog_enabled=true` is live):

```bash
export KUBECONFIG=/path/to/kubeconfig

# 1. Secret exists, key length sane
oc -n observability get secret datadog-api-key \
  -o jsonpath='{.data.DD_API_KEY}' | base64 -d | wc -c   # expect 32

# 2. Collectors on contrib image, all Running
oc -n observability get pods -l app.kubernetes.io/managed-by=opentelemetry-operator \
  -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.spec.containers[0].image}{"  "}{.status.phase}{"\n"}{end}'

# 3. Live ConfigMap mounts the datadog exporter + connector
GW=$(oc -n observability get pod -l app.kubernetes.io/instance=observability.gateway \
       -o jsonpath='{.items[0].spec.volumes[?(@.name=="otc-internal")].configMap.name}')
oc -n observability get cm $GW -o jsonpath='{.data.collector\.yaml}' \
  | grep -E "datadog:|datadog/connector|api.site|prometheus/self" -A2

# 4. Resource detection succeeded (look for cloud.*, k8s.cluster.name)
oc -n observability logs deploy/gateway-collector --tail=200 \
  | grep "detected resource information"

# 5. No 403s in the last 5 minutes (the canary)
oc -n observability logs deploy/gateway-collector --since=5m \
  | grep -iE "403|forbidden|rejected"        # expect: empty

# 6. APM stats actually generated by the connector
oc -n observability logs deploy/gateway-collector --tail=500 \
  | grep -i "datadogconnector"
```

On the Datadog side (US5 UI):

- **APM → Service Catalog**: `python-otel-demo` and `quarkus-otel-demo`
  should appear with non-zero request/error rates. RED metrics on the
  catalog come from the `datadog/connector`.
- **Metrics → Explorer**: `app.checkout.orders` (custom OTel counter
  from Python) and `system.cpu.user` / `system.memory.usage`
  (`hostmetrics`).
- **Logs → Live Tail**: filter `service:python-otel-demo` or
  `service:quarkus-otel-demo` for the app namespaces; for platform logs
  the `service` is the OpenShift component name.
- **Integrations → OpenTelemetry**: the "OpenTelemetry Collector"
  dashboard shows `otelcol_*` series from `prometheus/self`.

## Troubleshooting

### `403 Forbidden` on every payload

By far the most common failure. Cause: site mismatch between the API key
and `datadog_site`. The exporter's startup-time "Validating API key" log
line can succeed even when the site is wrong, because Datadog's key
metadata is queryable cross-region; the per-signal ingest endpoints are
not.

Fix: confirm the org's site in the Datadog UI URL bar and set
`datadog_site` to match (see "Site selection" above).

### Key validation fails ("invalid API key")

Either the key was deleted/rotated in Datadog, or it's an
**Application Key** rather than an **API Key**. Application Keys (longer,
prefixed differently) authenticate user-facing API calls, not ingest.

### `OpenShift detector metadata retrieval failed` with 403 from k8s

The `openshift` detector lacks `get` on `infrastructures.config.openshift.io`.
Confirm the ClusterRoleBinding exists:

```bash
oc get clusterrolebinding otel-resourcedetection-openshift
```

If missing, re-run `./ansible-runner.sh deploy --tags datadog -e
datadog_enabled=true -e datadog_api_key=$DATADOG_API_KEY`.

### APM Service Catalog shows the service but no RPS / error rate

The connector isn't wired. Confirm:

```bash
GW=$(oc -n observability get pod -l app.kubernetes.io/instance=observability.gateway \
       -o jsonpath='{.items[0].spec.volumes[?(@.name=="otc-internal")].configMap.name}')
oc -n observability get cm $GW -o jsonpath='{.data.collector\.yaml}' \
  | grep -A3 "traces/quarkus:"
```

The exporter list must include both `datadog` AND `datadog/connector`,
and the `metrics` pipeline must list `datadog/connector` among its
receivers.

### Pods CrashLoopBackOff after enabling

Almost always a config parse error from a malformed `-e` extra-var. The
most common offender is passing a list value as a quoted string:

```bash
# WRONG — ansible parses RHS as a string, to_json then double-encodes
-e "datadog_resource_detectors=['env','system','ec2']"

# RIGHT — JSON form preserves list type
-e '{"datadog_resource_detectors":["env","system","ec2"]}'

# RIGHTEST — just set it in inventory/host_vars/cluster.yml (gitignored)
```

Check the previous pod's logs for the exact config-build error:

```bash
oc -n observability logs <pod> --previous | grep -E "failed to build|invalid"
```

### High DaemonSet CPU after enabling

The contrib image's filelog operator with three pipelines + the
`hostmetrics` cadence drop to 10s does cost more than the design default.
If it's hurting nodes, override:

```yaml
# inventory/host_vars/cluster.yml
datadog_hostmetrics_interval_s: 30          # match the non-DD default
```

## NetObserv enriched-flow fan-out

When `netobserv_enabled` AND `datadog_enabled` AND `netobserv_datadog_enabled`
are all true (the last defaults to `true`), the `FlowCollector` CR gets an
extra `spec.exporters[]` entry of type `OpenTelemetry`. NetObserv's
`flowlogs-pipeline` then pushes enriched flow records, as both OTLP **logs**
(one per flow) and OTLP **metrics** (pre-aggregated counters from
flowlogs-pipeline's own metrics stage), to a *dedicated* OTLP/gRPC receiver
on the gateway collector at
`gateway-collector.observability.svc.cluster.local:4319`. This is documented
in the Red Hat docs page
[Network Observability Operators → enriched flows](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/observability/network_observability/configuring-network-observability-operators#network-observability-enriched-flows_network_observability).

### Why a dedicated receiver and dedicated pipelines

The existing `otlp` receiver on 4317/4318 is the entry point for **application**
telemetry (SDK spans + app metrics). If NetObserv's OTLP metrics landed there,
they would flow through the `metrics` pipeline and end up on the gateway's
`prometheus` exporter — the same surface UWM scrapes for application metrics.
That would (a) duplicate the metrics NetObserv already publishes via its own
in-cluster Prometheus path and (b) put network-flow series in the
application-metrics ServiceMonitor, blurring the two stores. Routing through a
second OTLP listener on port 4319 with its own pipelines keeps the two streams
fully isolated:

```
                                  ┌─ FlowCollector (cluster) ──────────────┐
                                  │  agent (eBPF DaemonSet) ──▶ flowlogs-  │
                                  │                              pipeline  │
                                  │                                 │      │
                                  │   spec.loki ──▶ LokiStack (network)    │
                                  │   spec.prometheus ──▶ in-cluster Prom  │
                                  │   spec.exporters[OpenTelemetry]        │
                                  └──────────────────┬─────────────────────┘
                                                     │ OTLP/gRPC :4319
                                                     ▼
            ┌────────────────────── gateway-collector ──────────────────────┐
            │  receivers:                                                   │
            │    otlp           (:4317/:4318) ◀── app SDKs                  │
            │    otlp/netobserv (:4319)       ◀── flowlogs-pipeline         │
            │                                                               │
            │  pipelines:                                                   │
            │    traces/*    : SDK spans → Tempo + Datadog APM              │
            │    metrics     : app metrics → UWM (prom) + Datadog Metrics   │
            │    logs/netobserv    : flow records → datadog, debug          │
            │    metrics/netobserv : flow counters → datadog, debug         │
            └───────────────────────────────────────────────────────────────┘
```

The native NetObserv → LokiStack (network tenant) and NetObserv → in-cluster
Prometheus paths run **unchanged**. The OTel exporter is purely additive.

### What lands in Datadog

- **Logs → Live Tail**, filter `service:netobserv-flowlogs-pipeline` (the
  service.name flowlogs-pipeline emits): one log event per flow with the
  netobserv format-proposal attributes (`SrcAddr`, `DstAddr`, `SrcK8S_*`,
  `DstK8S_*`, `Bytes`, `Packets`, `Flags`, `Proto`, `FlowDirection`, etc.).
- **Metrics Explorer**: NetObserv's flowlogs-pipeline metric series
  (`netobserv_flows_total`, `netobserv_*_bytes_total`,
  `netobserv_workload_*`, etc.) once they're re-shaped through the OTLP
  metrics path. These coexist with the same series in in-cluster Prometheus.

### Field mapping

The `openTelemetry.fieldsMapping[]` knob lets you remap netobserv's default
field names to anything else (Datadog CNM conventions, your own naming, etc.).
The current FlowCollector template ships **no** `fieldsMapping`, so the
[rhobs network-observability format proposal](https://github.com/rhobs/observability-data-model/blob/main/network-observability.md#format-proposal)
applies as-is. To remap, add entries to
`roles/netobserv/templates/flowcollector.yaml.j2` under
`exporters[0].openTelemetry.fieldsMapping`, e.g.:

```yaml
fieldsMapping:
  - input: "SrcAddr"
    output: "network.client.ip"
  - input: "DstAddr"
    output: "network.destination.ip"
```

### Volume / cost considerations

Flow records can dwarf the rest of the Datadog ingest. The relevant knobs:

- `netobserv_sampling` (default 50 in this repo): eBPF-agent-side sampling,
  applies to ALL downstream sinks including this one. Raising it cuts
  Datadog log volume linearly.
- `netobserv_datadog_enabled: false`: keep app-side Datadog fan-out on but
  drop the flow stream entirely (template re-omits both the exporter and
  the gateway pipelines).
- `openTelemetry.logs.enable: false` / `metrics.enable: false`: send only
  one signal. The `logs` stream is the higher-volume of the two; sending
  metrics only is the cheapest "still useful" option.

### Disabling just this fan-out

```bash
./ansible-runner.sh deploy \
  -e datadog_enabled=true \
  -e datadog_api_key=$DATADOG_API_KEY \
  -e netobserv_datadog_enabled=false \
  --tags netobserv,otel
```

This re-renders the `FlowCollector` without the `exporters[]` block and the
gateway `OpenTelemetryCollector` without the `otlp/netobserv` receiver and
the two `*/netobserv` pipelines.

### Troubleshooting

`flowlogs-pipeline` logs `connection refused` on `gateway-collector...:4319`
during the first deploy: expected. `site.yml` applies the `netobserv` role
before `otel_gateway`, so the receiver doesn't exist for the first ~minute.
flowlogs-pipeline retries indefinitely; once the gateway pod is `Running`
the connection establishes. Re-run the playbook if you want clean logs from
the start.

No flow logs in Datadog but the gateway pipelines exist:

```bash
# 1. FlowCollector actually has the exporter
oc get flowcollector cluster -o jsonpath='{.spec.exporters}' | jq

# 2. flowlogs-pipeline picked it up (look for the OTel exporter stage)
oc -n netobserv logs deploy/flowlogs-pipeline | grep -i otel

# 3. Gateway sees inbound on :4319
oc -n observability exec deploy/gateway-collector -- \
  ss -tlnp 2>/dev/null | grep 4319

# 4. No errors on the netobserv pipelines
oc -n observability logs deploy/gateway-collector --tail=500 \
  | grep -E "logs/netobserv|metrics/netobserv|otlp/netobserv"
```

## Disable / roll back


Set `datadog_enabled=false` (or just don't pass `-e datadog_enabled=true`)
and re-apply with `--tags otel`. Both collectors revert to the Red Hat
image and the templates conditionally drop the `datadog` exporter,
connector, `prometheus/self` receiver, `resourcedetection` processor,
and `DD_API_KEY` env var.

The Secret `datadog-api-key` and the ClusterRole/ClusterRoleBinding
`otel-resourcedetection-openshift` are **not** deleted (the `datadog`
role only runs when enabled). Remove them explicitly if you're done:

```bash
oc -n observability delete secret datadog-api-key
oc delete clusterrolebinding otel-resourcedetection-openshift
oc delete clusterrole otel-resourcedetection-openshift
```

## File map

| File | Role |
|---|---|
| [`roles/datadog/tasks/main.yml`](../roles/datadog/tasks/main.yml) | Validates `datadog_api_key`, creates the Secret, conditionally applies the openshift-detector RBAC |
| [`roles/datadog/templates/resourcedetection-openshift-rbac.yaml.j2`](../roles/datadog/templates/resourcedetection-openshift-rbac.yaml.j2) | ClusterRole + ClusterRoleBinding for the `openshift` detector |
| [`roles/otel_gateway/templates/collector.yaml.j2`](../roles/otel_gateway/templates/collector.yaml.j2) | All gateway-side conditional blocks: image swap, env, prometheus/self, resourcedetection, datadog exporter, datadog/connector, pipeline wiring |
| [`roles/otel_node/templates/collector.yaml.j2`](../roles/otel_node/templates/collector.yaml.j2) | All DaemonSet-side conditional blocks: image swap, env, prometheus/self, resourcedetection, hostmetrics 10s, datadog exporter on every pipeline |
| [`roles/netobserv/templates/flowcollector.yaml.j2`](../roles/netobserv/templates/flowcollector.yaml.j2) | Adds `spec.exporters[OpenTelemetry]` pointing at the gateway's `otlp/netobserv` receiver when `netobserv_datadog_enabled` |
| [`inventory/group_vars/all.yml`](../inventory/group_vars/all.yml) | `datadog_*` defaults (site, secret name, collector image, detector list, hostmetrics interval); `netobserv_datadog_enabled`, `netobserv_otlp_port` |
| [`site.yml`](../site.yml) | Conditionally runs the `datadog` role before the two `otel_*` roles |
| [`ansible-runner.sh`](../ansible-runner.sh) | Plumbs `DATADOG_API_KEY` env var through to ansible-playbook as extra-vars |
