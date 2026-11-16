# 10 Monitoring and alerting (MON)

Server module, read-only. Monitoring objects live in the cluster chart (`eduide-cluster`), installed by `bootstrap-cluster.yml`; see `docs/monitoring-setup.md` and the AGENTS.md notes on selectors that match nothing and on `eduide_namespace`.

Sources: EduIDE-Helm `charts/eduide-cluster/templates/monitoring/{podmonitor-operator,podmonitor-service,prometheusrule,alertmanagerconfig,dashboard-*}.yaml`, `charts/eduide-cluster/values.yaml` (`monitoring.*`).

Set `MON_NS=cattle-monitoring-system` (the cluster chart's `monitoring.namespace` default) and `kc() { kubectl --context "$CTX" "$@"; }`.

### MON-01 Environment is in the watched namespaces
Safety: prod-safe
Steps: `kc -n $MON_NS get podmonitor theia-cloud-service theia-cloud-service-legacy theia-cloud-operator -o jsonpath='{range .items[*]}{.metadata.name}: {.spec.namespaceSelector.matchNames}{"\n"}{end}'`
Expect: `$NS` is listed unless the environment sets `monitoring.enabled: false`; `theia-cloud-service` scrapes port `management` path `/q/metrics`, the legacy one port `http` for services without the `eduide.io/metrics-port` label.

### MON-02 Targets are up
Safety: prod-safe
Steps: `kc -n $MON_NS port-forward svc/rancher-monitoring-prometheus 19090:9090 &`, then
```bash
curl -s 'http://127.0.0.1:19090/api/v1/targets?state=active' | jq -r --arg ns "$NS" '.data.activeTargets[] | select(.labels.namespace==$ns) | .scrapePool + " " + .health'
curl -s "http://127.0.0.1:19090/api/v1/query" --data-urlencode "query=count by (__name__) ({namespace=\"$NS\",__name__=~\"application_theiacloud.*\"})" | jq '.data.result'
```
Expect: the service target `up`; exactly one of the two service PodMonitors has a target for this service (no duplicate scrape, no `down` target). The session startup metric exists once a session was launched through `POST /service` since the last service restart (it is registered lazily). Operator target only if `operator.metricsPort > 0`.
Cleanup: stop the port-forward.

### MON-03 Alert rules are loaded and render
Safety: prod-safe
Steps:
```bash
kc -n eduide-system get prometheusrule eduide-alerts -o json | jq -r '.spec.groups[].rules[].alert' | sort
curl -s http://127.0.0.1:19090/api/v1/rules | jq -r '.data.groups[].rules[] | select(.name|startswith("EduIDE")) | .name + " " + .health'
```
Expect: 14 alerts (16 with `monitoring.certManager.enabled`): EduIDEComponentDown, EduIDEConversionWebhookDown, EduIDEComponentCrashLooping, EduIDEServiceScrapeDown, EduIDEWarmPoolEmpty, EduIDESessionOOMKillSpike, EduIDESessionCrashSpike, EduIDESessionStartupSlow, EduIDESessionPodPending, EduIDESessionImagePullFailing, EduIDESessionEvicted, EduIDEWorkspaceVolumeFilling, EduIDEWorkspaceInodesFilling, EduIDEPVCPending (plus EduIDECertificateExpiringSoon, EduIDECertificateNotReady). Every rule `ok` in Prometheus (no evaluation error). The rule only exists when the cluster has `monitoring.enabled` and `monitoring.alerting.enabled`.

### MON-04 Alert expressions match something real
Safety: prod-safe
Steps: for each rule, evaluate the inner selector without the threshold (for example the deployment regex of EduIDEComponentDown: `kube_deployment_status_replicas_available{namespace="$NS",deployment=~"(operator|service|landing-page)-deployment|garbage-collector"}`).
Expect: every selector returns series for `$NS`. A selector that returns nothing is a finding even if no alert fires (AGENTS.md: a selector that matches nothing looks like a healthy platform).

### MON-05 Nothing firing that should not
Safety: prod-safe
Steps: `curl -s http://127.0.0.1:19090/api/v1/alerts | jq -r --arg ns "$NS" '.data.alerts[] | select(.labels.eduide_namespace==$ns) | .labels.alertname + " " + .state'`
Expect: no firing EduIDE alert for `$NS`, or each one is explained in the report (with `eduide_namespace`, not `namespace`, as the environment label).

### MON-06 Alertmanager routing
Safety: prod-safe
Steps: `kc -n eduide-system get alertmanagerconfig eduide-alerts -o jsonpath='{.spec.route}'` (no webhook URLs are in the manifest; do not read the webhook Secret).
Expect: routes group by `eduide_namespace`; receivers exist for the configured channels; `minSeverity` as configured.

### MON-07 Dashboards present and not empty
Safety: prod-safe
Steps: `kc -n cattle-dashboards get cm -l grafana_dashboard=1 | grep -E 'eduide-dashboard|theia-cloud-dashboard'`; open the sessions dashboard in Grafana for `$NS` (browser, read-only).
Expect: the four dashboards `theia-cloud-dashboard-overview`, `theia-cloud-dashboard-session-startup`, `eduide-dashboard-sessions`, `eduide-dashboard-session-detail` exist; with sessions running, no panel is empty and the namespace picker offers only existing namespaces.

## Explore

- Fire an alert on purpose on a test environment (scale a fixture AppDefinition's pool to 0 for longer than `warmPoolFor`, or a fixture with a non-existent image for EduIDESessionImagePullFailing) and follow it to the channel. Test-only; announce it.
- Is there any signal when the data bridge injection fails for a session? (Operator log only today.)
- Startup latency p95 per app over the last week: does EduIDESessionStartupSlow (90 s) match what students see?
