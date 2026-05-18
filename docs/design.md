# Observability Design — Multicluster OpenShift Fleet

> Source of truth for this repo. Reproduced as provided. This repo implements
> only the **trace slice** of §3.3 / §3.4 (Build sequence phase 4). See
> ARCHITECTURE.md for the per-resource mapping.

> Technical architecture for end-to-end visibility. Default backend standard: **Red Hat native**. Datadog can be either an **optional additive** enterprise layer (Design A) or the **central cross-cluster view** with Red Hat components as signal sources (Design B).

## 1. Architectural principles

1. **Signals are first-class and native.** Metrics, logs, traces, network flows, and security events are collected and stored in the Red Hat native stack. No signal depends on a third-party SaaS to exist.
2. **Collect once, then route deliberately.** In Design A, each cluster owns real-time signals and the RHACM hub owns the fleet-wide long-term metric view. In Design B, curated copies of those same signals are routed to Datadog as the central cross-cluster view while native stores remain the in-cluster source and fallback.
3. **Correlation over collection.** More dashboards do not reduce MTTR — linked signals do. Korrel8r is the connective tissue where its COO troubleshooting UI support status fits the environment; otherwise the same labels and trace context still enable manual pivots.
4. **Ownership follows the signal source.** Platform owns infra signals, Dev owns app signals, Security owns security signals. See raci.md.
5. **Datadog posture is explicit.** In Design A, Datadog is opt-in and downstream. In Design B, Datadog is the central view, but OpenShift-native components remain the authoritative signal sources and the fallback path for platform health and security controls.

## 3.3 Red Hat build of OpenTelemetry

- **OpenTelemetry Operator** manages two CRs:
  - `OpenTelemetryCollector` — deployment modes: `deployment`, `daemonset`, `statefulset`, `sidecar`. Pipelines = receivers (OTLP, Prometheus, filelog, k8sobjects) → processors (batch, k8sattributes, resource, filter) → exporters (Tempo/OTLP, Prometheus, Loki or Datadog where approved).
  - `Instrumentation` — auto-injects supported SDKs via pod annotation for baseline traces; unsupported language/runtime combinations use manual SDK instrumentation.
- Standard topology: workload SDKs send OTLP to a **Deployment gateway collector** for tail-sampling, enrichment, and export to Tempo. Use a **DaemonSet collector** only for node-local needs such as host metrics or log tailing, because it increases privilege and resource footprint.
- Resource attributes follow OpenTelemetry semantic conventions: `service.name`, `service.namespace`, `service.version`, `deployment.environment.name`, `k8s.namespace.name`, `k8s.pod.name`, and `k8s.container.name` are the canonical trace/log join fields.
- Logs: the preferred OpenShift path is stdout/stderr → OpenShift Logging/Vector → Loki. Use OTel logs for applications that already emit OTLP logs and for explicit integrations; do not run two log collectors against the same source.

## 3.4 Tempo, Loki & Cluster Observability Operator (COO)

- **Tempo Operator** → `TempoStack` (object-storage backed trace store).
- **Loki Operator / OpenShift Logging** → `LokiStack` (object-storage backed log store) plus log forwarding.
- **ClusterLogForwarder** is the central log-routing control point.
- **COO** delivers console **UIPlugins** such as monitoring, logging, distributed tracing, and the **Troubleshooting Panel** (Korrel8r front-end). Treat each plugin by its published Red Hat support status before making it part of production incident requirements.

> The full design document (sections 2, 3.1-3.7, 4-9 covering CPM/UWM, RHACM
> rollup, Korrel8r, Datadog Designs A/B, retention, and production-readiness
> checks) is the broader program context. This repository deliberately scopes
> to the OpenTelemetry → Tempo trace path only.
