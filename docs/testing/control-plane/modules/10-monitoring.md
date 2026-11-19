# 10 Monitoring, metrics contract and traces (MON)

Server module, mostly read-only. Metrics are Prometheus endpoints of every binary (operator `:9464`, service and authz `:9090`, all `/metrics`; the service and authz serve `/healthz` and `/readyz` on the same port, the operator on `:8081`); traces go by OTLP to a Jaeger v2 (in `eduide-test3` for this plan; one per cluster later, decision G17); logs are JSON with `trace_id`. The names and labels are a contract: `docs/contracts/metrics.md` in the control plane repo, checked there by `internal/telemetry/metrics_test.go`.

Sources: `charts/eduide-control-plane/templates/monitoring.yaml` (PodMonitor `$FULL`, PrometheusRule `$FULL`, dashboard ConfigMap `$FULL-dashboard`), `docs/contracts/metrics.md`, `internal/telemetry`, ADR 0013.

Set `MON_NS=cattle-monitoring-system` (the monitoring namespace on stud; the chart value is `monitoringNamespace`) and `kc() { kubectl --context "$CTX" "$@"; }`. Prometheus: `kc -n $MON_NS port-forward svc/rancher-monitoring-prometheus 19090:9090 &`. Jaeger: `k port-forward svc/<jaeger service> 16686:16686 &` (find it with `k get svc | grep -i jaeger`, it runs in `eduide-test3`; Jaeger is not public).

### MON-01 Deployment is scraped
Safety: prod-safe
Steps: `k get podmonitor,prometheusrule,cm -l app.kubernetes.io/name=eduide-control-plane` (the chart renders them in the deployment's namespace; check the monitoring namespace too: `kc -n $MON_NS get podmonitor | grep $FULL`); `k get podmonitor $FULL -o jsonpath='{.spec.podMetricsEndpoints}{"\n"}{.spec.selector}'`.
Expect: a PodMonitor selecting all component pods by `app.kubernetes.io/name=eduide-control-plane`, with the metrics port per component (operator 9464, service and authz 9090); it is discovered by Prometheus (Rancher Monitoring discovers PodMonitors by its own selector: record the label it needs). The old stack's operator scrape gap (operator metrics not scraped on stud) must not repeat.

### MON-02 Targets are up
Safety: prod-safe
Steps: with the Prometheus port-forward:
```bash
curl -s 'http://127.0.0.1:19090/api/v1/targets?state=active' | jq -r --arg ns "$NS" '.data.activeTargets[] | select(.labels.namespace==$ns) | .scrapePool + " " + (.labels.pod // "") + " " + .health'
curl -s http://127.0.0.1:19090/api/v1/query --data-urlencode 'query=count by (pod) (up{namespace="'$NS'"} == 1)' | jq '.data.result|length'
```
Expect: one `up` target per operator pod, per service replica, per authz replica (2 each) and the pool scaler; no `down` target, no duplicate scrape. Session pods are not scraped (nothing in them exports metrics; the agent has no metrics endpoint in v1).
Cleanup: stop the port-forward.

### MON-03 Alert rules are loaded and render
Safety: prod-safe
Needs: alerting rendered by the chart (`monitoring.alerts` value).
Steps:
```bash
k get prometheusrule $FULL -o json | jq -r '.spec.groups[].rules[] | .alert + " " + (.labels.severity // "-")' | sort
curl -s http://127.0.0.1:19090/api/v1/rules | jq -r '.data.groups[].rules[] | select(.labels.namespace=="'$NS'" or (.query|test("'$NS'"))) | .name + " " + .health'
```
Expect: the alerts the chart documents (components down, crash looping, authz error rate and latency, claim failures or empty pool, startup slow per strategy, capacity pressure, agent errors; record the list actually rendered, the plan does not fix a count); every rule `health: ok`; each rule has `severity` and a `summary` annotation. With no alerts in the chart, record `blocked: not rendered`.

### MON-04 Alert expressions match something real
Safety: prod-safe
Steps: for each rule, evaluate the inner selector without the threshold in Prometheus (for example `up{namespace="eduide-test3",pod=~"$FULL-authz.*"}` for an authz-down rule, `eduide_capacity_pressure`, `eduide_claim_total`, `histogram_quantile(0.95, sum by (le,strategy) (rate(eduide_session_startup_seconds_bucket[1h])))`).
Expect: every selector returns series for this deployment once the related events happened (counters and histograms that no event has touched yet have no series: run after module 05 and 14, and say so). A selector that returns nothing even after the events is a finding (a healthy-looking platform with a dead alert). Label names match the contract (`template`, `strategy`, `node_pool`, ...); the metric names are the new `eduide_*` ones, never the old `application_application_theiacloud_*`.

### MON-05 Nothing firing that should not
Safety: prod-safe
Steps: `curl -s http://127.0.0.1:19090/api/v1/alerts | jq -r '.data.alerts[] | select(.labels.namespace=="'$NS'") | .labels.alertname + " " + .state'`
Expect: no firing alert for this deployment, or each one is explained in the report. Alerts raised by the disruptive tests of this run (OPR-15 capacity pressure, AUTHZ-09 authz down) are expected; list them with the test that caused them.

### MON-06 Alert routing
Safety: prod-safe
Steps: check the labels the rules carry (`severity`, `namespace`) and how the cluster routes them: `kc -n eduide-system get alertmanagerconfig -o name` (read-only); `k get prometheusrule $FULL -o json | jq '[.spec.groups[].rules[].labels]|unique'`.
Expect: the labels are the ones the cluster's existing routing groups on (the old `eduide-cluster` chart groups by `eduide_namespace`; record whether the new rules set it, so test3 alerts reach the same channels and are not attributed to `eduide-system`). Webhook secrets are never read. `blocked` if no alert routing exists in the cluster for this deployment (record).

### MON-07 Dashboards present and not empty
Safety: prod-safe
Steps: `k get cm $FULL-dashboard -o jsonpath='{.metadata.labels}'` (the Grafana sidecar label); open the dashboard in Grafana for `$NS` (browser, read-only); `k get cm $FULL-dashboard -o json | jq -r '.data|to_entries[].value' | jq -r '.. | .expr? // empty' | sort -u` and run a few of the expressions.
Expect: the dashboard exists and is discovered; with sessions running, no panel is empty: start latency per strategy, claim results, pool state, error rates, authz decisions; every expression uses `eduide_*` names that exist (MON-09); the namespace picker offers `eduide-test3`. A panel that selects a label that no longer exists is the typical silent failure.

### MON-08 Certificate alerts cover this deployment's certificates
Safety: prod-safe
Steps: `k get certificate -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[0].status}{"\n"}{end}'`; evaluate `certmanager_certificate_ready_status{namespace="eduide-test3"}` and `certmanager_certificate_expiration_timestamp_seconds{namespace="eduide-test3"}` in Prometheus; read the expressions of the cluster chart's certificate alerts (`kc -n eduide-system get prometheusrule -o json | jq -r '.items[].spec.groups[].rules[] | select(.alert|test("Certificate")) | .expr'`).
Expect: the certificates of the deployment's own Gateway (host, instance and webview names) are ready and expire in more than 21 days; the cluster's certificate alert expressions select an explicit namespace list (first run: `eduide-e2e-test|eduide-staging|eduide-test1|eduide-test2|eduide-system`), so check that the list contains `eduide-test3` (`echo eduide-test3 | grep -cE '<regex>'`); if not, the certificates of this deployment are covered by no alert (finding) and other tenants' certificates must not match. Counts per namespace only. (The cluster chart is not changed by this deployment, decision U9.)

### MON-09 Metrics contract: every documented name is exposed
Safety: prod-safe (read-only scrape; counters appear only after their event, so run after modules 03, 05, 13)
Steps: take the table of the control plane repo (path of your checkout in `CP_REPO`), scrape the three endpoints through port-forwards and compare:
```bash
CP_REPO=<path to EduIDE-control-plane>
grep -o '`eduide_[a-z_]*`' $CP_REPO/docs/contracts/metrics.md | tr -d '`' | sort -u > /tmp/contract.txt
k port-forward deploy/$FULL-operator 19464:9464 >/dev/null 2>&1 & P1=$!
k port-forward deploy/$FULL-service 19091:9090 >/dev/null 2>&1 & P2=$!
k port-forward deploy/$FULL-authz 19092:9090 >/dev/null 2>&1 & P3=$!
sleep 3
for u in 19464 19091 19092; do curl -s http://127.0.0.1:$u/metrics; done | grep -v '^#' | sed 's/[{ ].*//; s/_\(bucket\|sum\|count\|total\)$//' | sort -u > /tmp/exposed.txt
sed 's/_total$//' /tmp/contract.txt | sort -u | comm -23 - /tmp/exposed.txt     # contract names that are not exposed
kill $P1 $P2 $P3
```
Then check labels of a few series against the table, for example `curl -s http://127.0.0.1:19464/metrics | grep '^eduide_session_startup_seconds_bucket' | head -2`, and look for any label named like `user`, `owner`, `email`, `token`, `session` (a session name label is allowed only where the contract lists it; the contract lists none): `... | grep -c -E '(user|owner|email|token)='`.
Expect: nothing is printed by `comm` once the events happened (metrics without a sample are registered but may be absent as series: record those, run a launch, a claim, an authz allow and a deny and compare again); histograms have `_bucket`, `_sum`, `_count`; label sets are exactly those of the table (`template`, `strategy`, `result` and so on); no metric carries a user name, e-mail address or token (G18). The old `application_application_theiacloud_session_startup_seconds` names do not exist in the new binaries.
Cleanup: `rm /tmp/contract.txt /tmp/exposed.txt`.

### MON-10 A launch trace shows all phases
Safety: test-only
Needs: browser token (or a fixture and the `traceparent` annotation set by hand); Jaeger port-forward. Run once for a warm launch (pool) and once for a cold one.
Steps:
1. Pick a trace id and launch with it: `T=$(openssl rand -hex 16)`; `await api('POST','/sessions',{template:'<T>'},{traceparent:'00-<T>-0123456789abcdef-01'})` (the id is random test data, not a secret).
2. Wait for Ready; `k get idesession <n> -o jsonpath='{.metadata.annotations.eduide\.github\.io/traceparent}'`.
3. `curl -s http://127.0.0.1:16686/api/services | jq -r '.data[]'`.
4. `curl -s http://127.0.0.1:16686/api/traces/$T | jq -r '.data[0].spans[] | [.operationName, (.processID as $p | $p), .startTime, .duration] | @tsv' | sort -k3`; map process ids to service names with `.data[0].processes`.
5. Repeat with `lookback`: `curl -s "http://127.0.0.1:16686/api/traces?service=<operator service>&lookback=1h&limit=20"`.
Expect: services `operator`, `service`, `authz`, `agent` (or the names the binaries register; record them) are listed; the trace `$T` holds spans from the service (launch), the operator (one span per start phase: claim, pod ready, agent ready, ready) and the agent (claim); all in one trace, parent-linked, with start times in the order of `status.timestamps` (`ft_times`); the sum of the phase spans matches the session's creation-to-Ready time within a second. The warm trace has a claim span and no pod creation; the cold trace has pod ready as the dominant span. Start-path traces are sampled 100 percent when the service writes the root span `launch`; a hand-made IDESession without a `traceparent` annotation is sampled at 1 percent only, so set the annotation on fixtures. On Jaeger 2.x use the v3 API (`/api/v3/traces?query.service_name=<name>`); the v1 search was not usable on 2.23. Attribute keys: session id and the pseudonymous user id only (SEC-15).
Cleanup: stop the port-forward and the sessions.

### MON-11 Logs carry the trace id
Safety: test-only
Needs: the trace id of MON-10.
Steps: `for d in service operator; do printf '%s ' $d; k logs deploy/$FULL-$d --since=15m --all-pods | grep -c "$T"; done`; `k logs deploy/$FULL-operator --since=15m | grep "$T" | head -2 | jq '{level,msg,trace_id,service}'` (no data fields beyond those).
Expect: JSON lines with `trace_id` equal to the launch trace for service and operator; `service` field names the binary; no line carries launch data (SEC-14); log volume is sane (a Ready idle session produces no lines per second: `k logs deploy/$FULL-operator --since=1m | wc -l`).

### MON-12 Jaeger is internal and keeps traces
Safety: prod-safe
Steps: `k get svc | grep -i jaeger`; `k get httproute -o name | grep -ci jaeger`; `curl -s -o /dev/null -w '%{http_code}\n' https://$ENV/jaeger/` and `https://$INSTANCE_HOST/jaeger/`; `k get pvc | grep -i jaeger`; storage and retention from the Jaeger config (`k get cm | grep -i jaeger`, read the retention key).
Expect: the Jaeger service is `ClusterIP`; no HTTPRoute exposes it; public probes answer 404, a login redirect or the landing page's SPA fallback (200 with the index page, check that it is not Jaeger), never the UI; a small PVC with Badger storage and a retention of about 7 days (decision G17); the OTLP endpoint in `config.telemetry.otlpEndpoint` points at it. An unreachable Jaeger must not slow down or break launches (spans are dropped, not queued: record the service latency when Jaeger is scaled to 0 on a spare window, test-only, disruptive).

## Explore

- Fire an alert on purpose on a test environment (capacity pressure through OPR-15 for longer than the alert's `for`, or authz down through AUTHZ-09) and follow it to the channel. Test-only; announce it.
- Is there any signal when the claim to an agent fails (`eduide_agent_requests_total{result="error"}`) or when a session stays `Starting` for too long?
- Startup latency p95 per strategy over the last week: does the alert threshold match what students see (PERF-03)?
- A Jaeger restart: do spans of in-flight launches get lost, and does the next launch appear again without any control plane restart?
- Cardinality: number of series per metric after 100 sessions (`count by (__name__)`), especially anything labelled per session or per instance.
