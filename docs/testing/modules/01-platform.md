# 01 Platform health and versions (PLAT)

Runs first in every run. Pins the versions the report refers to and checks that the installation is up before anything else is judged.

Sources: EduIDE-Helm `charts/eduide/templates/{operator,service,landing-page}.yaml`, `charts/eduide-cluster/templates/version-configmap.yaml`, the GC chart in workspace-garbage-collector `helm/`.

### PLAT-01 Deployed versions
Safety: prod-safe
Steps:
1. `helm --kube-context "$CTX" -n "$NS" list` (chart and app version of `eduide`, and of the preloading release if present).
2. `kubectl --context "$CTX" -n eduide-system get cm eduide-cluster-version -o jsonpath='{.data}'` (cluster chart version).
3. `k get deploy -o custom-columns=NAME:.metadata.name,IMAGE:.spec.template.spec.containers[*].image`
4. `k get appdefinitions -o custom-columns=NAME:.metadata.name,IMAGE:.spec.image`
5. `yq .spec.platform environments/$ENV/env.yaml` (the pin this repo declares).
Expect:
- `eduide` and `eduide-cluster` have the same chart version (AGENTS.md: keep them equal by hand).
- The `eduide` chart version matches `spec.platform.chartVersion`, unless the run deliberately tests an override; then the override is recorded.
- Deployments `operator-deployment`, `service-deployment`, `landing-page-deployment`, `garbage-collector` exist. Operator and service run the same EduIDE-Cloud tag; all IDE images in the AppDefinitions share one tag.
- All versions go into the report's run metadata table.

### PLAT-02 Components ready, no restarts
Safety: prod-safe
Steps: `k get deploy operator-deployment service-deployment landing-page-deployment garbage-collector` and `k get pods -l 'app in (operator,service,landing-page)' -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount,AGE:.metadata.creationTimestamp`
Expect: every deployment fully available. Restart counts recorded; any restart of the operator since the last deploy is a finding (check `k logs deploy/operator-deployment --previous | tail -50` for the cause, without copying secret-bearing lines).

### PLAT-03 Public endpoints answer with valid certificates
Safety: prod-safe
Steps:
```bash
for u in "$LANDING/" "$LANDING/config.js" "$SERVICE/service/$APPID"; do
  curl -sS -o /dev/null -w "%{http_code} %{ssl_verify_result} $u\n" "$u"; done
echo | openssl s_client -connect "instance.$ENV:443" -servername "x.webview.instance.$ENV" 2>/dev/null | openssl x509 -noout -subject -ext subjectAltName -enddate
echo | openssl s_client -connect "service.$ENV:443" -servername "service.$ENV" 2>/dev/null | openssl x509 -noout -ext subjectAltName -enddate
```
Expect: `200 0` for all three URLs (the ping returns 200 with the public token). Certificates name the host they are served for (the webview wildcard covers `*.webview.instance.$ENV`) and expire more than 21 days from now. AGENTS.md explains why a wrong-name certificate is otherwise silent.

### PLAT-04 Gateway routes attached
Safety: prod-safe
Steps: `k get httproute -o json | jq -r '.items[] | .metadata.name as $n | .status.parents[]? | $n + " " + .parentRef.sectionName + " " + ([.conditions[] | .type + "=" + .status + ":" + .reason] | join(","))'`
Expect: the chart lists every section of the shared Gateway as a parent; each route (`service-route`, the landing route, the instance routes) is `Accepted=True` and `ResolvedRefs=True` on at least one section, the one whose hostname matches. The other parents show `Accepted=False` with reason `NoMatchingListenerHostname` and nothing else. A route with no status parent is attached to a section that does not exist (AGENTS.md, Gateway section prefix).

### PLAT-05 AppDefinitions consistent with the environment
Safety: prod-safe
Steps: compare `k get appdefinitions -o name` with the deployed `helm --kube-context "$CTX" -n "$NS" get values eduide -o json | jq .appDefinitions` (empty `enabled` = the whole chart catalog) and with the tiles listed in `curl -s $LANDING/config.js` (`additionalApps`). Then compare the deployed values with `environments/$ENV/values.yaml`.
Expect: every app on the landing page has an AppDefinition; a difference between deployed and repo values is either a recorded override of this run or a finding; no AppDefinition without a Helm owner except `ft-` fixtures (`k get appdefinitions -o custom-columns=NAME:.metadata.name,MANAGED:.metadata.labels.app\.kubernetes\.io/managed-by`).

### PLAT-06 Preloading done
Safety: prod-safe
Steps: `k get daemonset` and its pods' readiness.
Expect: the preloading DaemonSet is fully rolled out. If not, the first launches after a deploy time out (rc.1 finding 2); wait before running modules 04, 05 and 08.

### PLAT-07 Leftover sessions
Safety: prod-safe
Steps: list sessions older than the current operator pod, and sessions whose AppDefinition no longer exists:
```bash
k get sessions -o json | jq -r --argjson apps "$(k get appdefinitions -o json | jq '[.items[].metadata.name]')" \
  '.items[] | select(.spec.appDefinition as $a | $apps | index($a) | not) | .metadata.name + " " + .spec.appDefinition + " " + .metadata.creationTimestamp'
```
Expect: no output. Orphaned sessions are never timed out and keep old pod settings (rc.3 finding); report names of `ft-` sessions only, count the others.

## Explore

- Compare the landing page footer version with the deployed landing image tag.
- Check `k get events --sort-by=.lastTimestamp | tail -30` for warnings nobody looks at (FailedMount, BackOff, quota).
- Look for resources that no release owns: `k get all,cm,secret,pvc --show-labels` and anything without `app.kubernetes.io/managed-by` or an owner reference.
