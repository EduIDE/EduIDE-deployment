# 10 Monitoring and alerting (MON)

Server module, read-only except MON-10 and MON-12 (they start fixtures). The Go control plane chart ships its own monitoring objects into the release namespace: a PodMonitor, a PrometheusRule (alerts, plus the recording rules `eduide:usage:*`) and, optionally, dashboards. Grafana boards for the Go stack are written to `cattle-dashboards` by `bootstrap-cluster.yml` (`spec.controlPlaneDashboards`). Alert routing is a cluster concern (`docs/monitoring-setup.md`, AGENTS.md notes on `eduide_namespace`).

Sources: control plane `docs/contracts/metrics.md`, `docs/operations/{pool-empty,slow-launch,authz-errors,usage-export}.md`, `charts/eduide-control-plane/templates/monitoring.yaml`, `files/{alerts,alerts-certificates,usage-rules,operator-rules}.yaml`, `files/dashboard.json`, `files/usage-dashboard.json`; this repository `docs/monitoring-setup.md`, `environments/*/values.yaml` (`monitoring.*`), `clusters/*.yaml`.

Set `MON_NS=cattle-monitoring-system` and `kc() { kubectl --context "$CTX" "$@"; }`. Prometheus: `kc -n $MON_NS port-forward svc/rancher-monitoring-prometheus 19090:9090 >/dev/null 2>&1 & PF=$!` (the service name matches `admin.prometheusURL` in the values); stop it at the end of the module.

Facts:
- Metrics (`docs/contracts/metrics.md`): operator on `:9464`, service and authz on `:9090`, all `/metrics`, scraped by the PodMonitor `$P` in the release namespace (port `metrics`). Session pods export nothing (no PodMonitor for them).
- Every alert of the chart has the labels `severity` and `eduide_namespace=<release namespace>`; on `tum-student` the values add `namespace: eduide-system` (`monitoring.rules.extraLabels`) so the cluster's AlertmanagerConfig routes them. Group, silence and inhibit on `eduide_namespace`.
- Alerts (chart 0.2.3): EduIDEAuthzDenyRateHigh, EduIDEAuthzSlow, EduIDEAuthzDown, EduIDELaunchFailures, EduIDEApiErrors, EduIDECapacityPressure, EduIDEPoolEmpty, EduIDEOperatorDown, EduIDEServiceDown, EduIDEAgentRequestErrors, and with `monitoring.rules.certificates` EduIDECertificateExpiringSoon, EduIDECertificateNotReady. Recording rule groups `eduide-usage-1m` and `eduide-usage-5m`.
- Dashboards: ConfigMap `eduide-go-control-plane-dashboards` in `cattle-dashboards` with the boards `eduide-control-plane` and `eduide-usage` (one copy per cluster, namespace picker).

### MON-01 Monitoring objects of the release
Safety: prod-safe
Steps: `k get podmonitor,prometheusrule -o wide`; `k get podmonitor $P -o jsonpath='{.spec}'`; `k get prometheusrule $P -o json | jq -r '.spec.groups[] | .name + ": " + ([.rules[] | (.alert // .record)] | length|tostring)'`; `yq '.eduide-control-plane.monitoring' environments/$ENV/values.yaml`.
Expect: a PodMonitor `$P` selecting pods with `app.kubernetes.io/name=eduide-control-plane` and `app.kubernetes.io/instance=eduide`, port `metrics`, path `/metrics`; a PrometheusRule `$P` with the groups `eduide-control-plane` (10 alerts), `eduide-usage-1m`, `eduide-usage-5m` and, with `rules.certificates`, `eduide-control-plane-certificates` (2 alerts); the values enable them (or the environment opts out with a stated reason: record it).

### MON-02 Targets are up
Safety: prod-safe
Steps (Prometheus port-forward):
```bash
curl -s 'http://127.0.0.1:19090/api/v1/targets?state=active' | jq -r --arg ns "$NS" '.data.activeTargets[] | select(.labels.namespace==$ns) | .scrapePool + " " + .labels.pod + " " + .health'
curl -s 'http://127.0.0.1:19090/api/v1/query' --data-urlencode "query=count by (__name__) ({namespace=\"$NS\",__name__=~\"eduide_.*\"})" | jq -r '.data.result | length'
```
Expect: every target of the namespace `up`: the operator (1), service (2), authz (2) and, where enabled, the pool scaler (1) and nothing `down`; a service or authz replica missing from the list is a finding. Series of the `eduide_` metrics exist for the namespace (some appear only after the first event: `eduide_session_failures_total`, `eduide_claim_total`).
Cleanup: stop the port-forward.

### MON-03 Alert rules are loaded and healthy
Safety: prod-safe
Steps:
```bash
k get prometheusrule $P -o json | jq -r '.spec.groups[].rules[] | select(.alert) | .alert' | sort
curl -s http://127.0.0.1:19090/api/v1/rules | jq -r --arg ns "$NS" '.data.groups[] | select(.file|test($ns)) | .rules[] | .name + " " + .health'
```
Expect: the alert names listed in the Facts (10, or 12 with certificates); every rule `ok` in Prometheus (no evaluation error); each alert has `severity` and `eduide_namespace` labels (`k get prometheusrule $P -o json | jq '[.spec.groups[].rules[] | select(.alert) | .labels | has("eduide_namespace")] | all'` is true).

### MON-04 Alert expressions match something real
Safety: prod-safe
Steps: for each alert, evaluate its inner selector without the threshold in Prometheus, for example `eduide_authz_decisions_total{namespace="$NS"}`, `eduide_api_requests_total{namespace="$NS",code=~"5.."}` (may be empty when no 5xx happened: check the unfiltered `eduide_api_requests_total`), `up{namespace="$NS",pod=~"$P-operator-.*"}`, `eduide_pool_target_idle{namespace="$NS"}`, `eduide_pool_instances{namespace="$NS",state="idle_ready"}`, `eduide_capacity_pressure{namespace="$NS"}`, `eduide_agent_requests_total{namespace="$NS"}`, `eduide_session_startup_seconds_count{namespace="$NS"}`.
Expect: every selector returns series for `$NS` (a selector that returns nothing is a finding even if no alert fires: AGENTS.md); the pod regexes match the real pod names (`$P-operator-*`, `$P-service-*`, `$P-authz-*`). Exceptions that only have series after an event: `result="failed"` startup series, `code=~"5.."`, capacity pressure while no node pool reported (the gauge exists per node pool once seen).

### MON-05 Nothing firing that should not
Safety: prod-safe
Steps: `curl -s http://127.0.0.1:19090/api/v1/alerts | jq -r --arg ns "$NS" '.data.alerts[] | select(.labels.eduide_namespace==$ns) | .labels.alertname + " " + .state'`.
Expect: no firing EduIDE alert for `$NS`, or each one is explained in the report (use `eduide_namespace`, not `namespace`, as the environment label).

### MON-06 Alertmanager routing
Safety: prod-safe
Needs: alerting enabled on the cluster (`docs/monitoring-setup.md`).
Steps: `kc -n eduide-system get alertmanagerconfig -o name` and, for each, `kc -n eduide-system get alertmanagerconfig <name> -o jsonpath='{.spec.route}'` (no webhook URLs are in the manifest; do not read the webhook Secret).
Expect: a route for the cluster's channel groups by `eduide_namespace` and matches the alerts' `namespace: eduide-system` label; receivers exist for the configured channels; `minSeverity` as configured. Record `blocked: alerting not enabled` otherwise.

### MON-07 Dashboards present and not empty
Safety: prod-safe
Steps: `kc -n cattle-dashboards get cm eduide-go-control-plane-dashboards -o json | jq -r '.data | keys[]'`; open the boards `eduide-control-plane` and `eduide-usage` in Grafana for `$NS` (browser, read-only).
Expect: the ConfigMap carries both boards (label `grafana_dashboard=1`); with sessions running, no panel is empty and the namespace picker offers the namespaces of the cluster's Go environments only. The per-user and per-session labels do not exist, so no panel shows a user. Compare the board version with `spec.controlPlaneDashboards` of `clusters/$CLUSTER.yaml`.

### MON-08 Certificate alerts cover only this namespace
Safety: prod-safe
Needs: `monitoring.rules.certificates` enabled (test2 has the group). Otherwise record `skipped`.
Steps: read the expressions: `k get prometheusrule $P -o json | jq -r '.spec.groups[] | select(.name|test("certificates")) | .rules[] | .alert + ": " + .expr'`; evaluate them in Prometheus and group by namespace: `count by (namespace) (certmanager_certificate_ready_status{condition="True"} == 0)`.
Expect: both expressions select `namespace="$NS"` (so other tenants' broken certificates never match: the Java chart's rc.3 finding does not apply); `certmanager_certificate_expiration_timestamp_seconds{namespace="$NS"}` exists for the three TLS certificates (PLAT-09) and none expires in under 21 days. Report counts per namespace only, not certificate names of other tenants.

### MON-09 Metrics follow the contract
Safety: prod-safe
Steps:
```bash
curl -s 'http://127.0.0.1:19090/api/v1/label/__name__/values' | jq -r '.data[] | select(test("^(eduide_|pool_scaler_)"))' | sort 
curl -s 'http://127.0.0.1:19090/api/v1/labels' --data-urlencode "match[]={namespace=\"$NS\",__name__=~\"eduide_.+\"}" | jq -r '.data[]' | sort | tr '\n' ' '
```
Compare the metric names with the table in `docs/contracts/metrics.md` (names starting `eduide_`).
Expect: every name in the table that this environment can produce exists (some only after an event); no `eduide_` name outside the table; the label names across all `eduide_` series are within the contract's labels (`template`, `strategy`, `result`, `persistence`, `start_mode`, `phase`, `pool`, `state`, `node_pool`, `op`, `operation`, `code`, `reason`, `resource`, `kind`) plus Prometheus's own; none of them is `user`, `owner`, `email`, `token`, `session`, `pod` or `instance` (no metric carries a user name, e-mail or token, G18).

### MON-10 A launch moves the metrics
Safety: test-only
Steps: record `eduide_launch_total`, `eduide_session_startup_seconds_count`, `eduide_claim_total`, `eduide_sessions{phase="Ready"}` and `eduide_session_lifetime_seconds_count` for the namespace; start one warm session (`ft_session ft-mon-s <TPL_POOL>`, `ft_wait`) and delete it after a minute; wait one scrape interval (the PodMonitor `interval`); query again. For the API metrics use a launch through the landing page or API-03 (a fixture CR does not pass the service).
Expect: `eduide_session_startup_seconds_count{result="ready",strategy="warm-ready",start_mode="eager"}` +1 (the fixture) and `eduide_claim_total{result="claimed"}` +1; `eduide_sessions{phase="Ready"}` +1 then back; `eduide_session_lifetime_seconds_count{reason="user"}` +1 after the delete (`timeout` after OPR-04, `error` after OPR-11); `eduide_launch_total{result="created"}` and `eduide_api_requests_total{operation="launchSession",code="201"}` +1 for the API launch; `eduide_authz_decisions_total{result="allow"}` rises when the owner opens the IDE.
Cleanup: `ft_cleanup`.

### MON-11 Usage recording rules
Safety: prod-safe
Steps: `curl -s http://127.0.0.1:19090/api/v1/query --data-urlencode 'query=count({__name__=~"eduide:usage:.+",namespace="'$NS'"})' | jq -r '.data.result[0].value[1]'`; `curl -s http://127.0.0.1:19090/api/v1/labels --data-urlencode 'match[]={__name__=~"eduide:usage:.+"}' | jq -r '.data[]' | tr '\n' ' '`.
Expect: series exist for the namespace (some only while sessions run); the label names are `namespace`, `template` and metric-specific ones, never a pod, instance, session or owner label (the usage export holds no identifier, `docs/operations/usage-export.md`).

### MON-12 Failures are counted
Safety: test-only
Steps: after OPR-03 and OPR-11 (or one failing fixture `ft_session ft-mon-bad does-not-exist`): query `eduide_session_failures_total{namespace="$NS"}` by `template` and `code`, and `eduide_session_startup_seconds_count{result="failed"}`.
Expect: `eduide_session_failures_total{code="template-not-found"}` (template label as given) and `{code="start-failed"}` rise by one per failed session; the startup counter has a `result="failed"` series. Four failures in 15 minutes would fire EduIDELaunchFailures; do not provoke it unless the alert path is the test (Explore).
Cleanup: `ft_cleanup`.

## Unverified, check in the first run

- None of the Prometheus queries was run against `rancher-monitoring-prometheus` for this rewrite (only the PrometheusRule objects of test2 were read: the 10 alerts, the usage groups and the certificate group exist, labels `eduide_namespace` and `namespace: eduide-system`).
- MON-01 PodMonitor name `$P` and selector (`eduide-eduide-control-plane` exists on test2; selector from the chart template).
- MON-06: the name and namespace of the AlertmanagerConfig on `tum-student` and `bonn` (the Java chart called it `eduide-alerts`).
- MON-07: that the ConfigMap `eduide-go-control-plane-dashboards` is in `cattle-dashboards` (from `bootstrap-cluster.yml`) and the board uids.
- MON-09: the exact label allowlist.
- MON-10: `start_mode` value for a fixture claim and the scrape interval.
- Where the pool scaler is enabled (test3), its metrics `pool_scaler_*` need the same checks (target `up`, `pool_scaler_last_decision_timestamp_seconds` recent).

## Retired

- The Java service metric `application_application_theiacloud_session_startup_seconds_seconds` and the two PodMonitors `theia-cloud-service` and `theia-cloud-service-legacy`, the cluster-chart rule `eduide-alerts` with `EduIDEWarmPoolEmpty`, `EduIDEComponentDown` and the other 14 Java alerts, and the four Java dashboards are gone: 2026-11-24. The test IDs MON-01 to MON-08 were kept and rewritten for the Go objects; no ID was retired.

## Explore

- Fire an alert on purpose on a test environment (EduIDEPoolEmpty: a fixture pool with a bad image and a target above 0 for 10 minutes; EduIDELaunchFailures: four failed fixture launches in 15 minutes; EduIDEAuthzDown: scale authz to 0 for 5 minutes) and follow it to the channel. Announce it.
- Is there any signal when an agent claim fails for one session (`eduide_agent_requests_total{op="claim",result="error"}`, the Event `Failed`)?
- Start-time p95 per template over the last week: does `eduide_session_startup_seconds` match what the public status says (`slow` above 60 s p95 over 15 minutes)?
- The tracing path: with Jaeger configured (test3, `deployments/test3/jaeger.yaml` in EduIDE-Helm) does a launch produce the root span `launch` with children and no e-mail or name in any attribute?
- The admin panel's Prometheus-backed figures against the same queries here.
