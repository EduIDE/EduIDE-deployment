# 01 Platform health and versions (PLAT)

Runs first in every run. Pins the versions the report refers to and checks that the installation is up before anything else is judged.

Sources (control plane repo): `charts/eduide-control-plane/templates/{deployments,gateway,networkpolicy,config,templates}.yaml`, `charts/eduide-control-plane-crds`, `internal/config/config.go`, ADR 0005, 0014, 0018.

### PLAT-01 Deployed versions
Safety: prod-safe
Steps:
1. `helm --kube-context "$CTX" -n "$NS" list` (read-only; chart and app version of `eduide-control-plane`, plus the CRD chart release in its namespace: `helm --kube-context "$CTX" list -A | grep eduide-control-plane-crds`). Do not run any other helm command.
2. `k get deploy -l $CP_SEL -o custom-columns=NAME:.metadata.name,REPLICAS:.spec.replicas,IMAGE:.spec.template.spec.containers[*].image`
3. The agent image the operator injects: `k get cm $FULL-config -o jsonpath='{.data.config\.yaml}' | grep -A1 '^agent:'` (key names and image only).
4. `k get idetemplates -o custom-columns=NAME:.metadata.name,IMAGE:.spec.image` and `k get idepools`.
5. `k get crd | grep eduide.github.io` and `k get crd idesessions.eduide.github.io -o jsonpath='{.status.storedVersions}'`.
Expect:
- Operator, service, authz, pool scaler and agent run the same release tag (one `vX.Y.Z` versions the whole repo, decision U2; before the first release the tags are `sha-<commit>` of main); the chart `appVersion` matches.
- The four CRDs `idetemplates`, `idepools`, `ideworkspaces`, `idesessions` exist, stored version `v1alpha1`.
- Replicas: operator 1, service 2, authz 2 (decision G5).
- All versions go into the report's run metadata table, with the discovered `$FULL` prefix and the IDE image tags (do they contain `eduide-session`?).

### PLAT-02 Components ready, no restarts
Safety: prod-safe
Steps: `k get deploy -l $CP_SEL`; `k get pods -l $CP_SEL -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount,AGE:.metadata.creationTimestamp`; `k get pdb`; `k get lease eduide-operator -o jsonpath='{.spec.holderIdentity}'` (holder is the operator pod).
Expect: every deployment fully available; PodDisruptionBudgets for service and authz; the lease holder is the running operator pod. Restart counts recorded; any restart since the last deploy is a finding (`k logs deploy/$FULL-operator --previous | tail -50`, without copying secret-bearing lines).

### PLAT-03 Public endpoints answer with valid certificates
Safety: prod-safe
Steps:
```bash
for u in "$LANDING/" "$LANDING/config.json" "$API/templates"; do
  curl -sS -o /dev/null -w "%{http_code} %{ssl_verify_result} $u\n" "$u"; done
for h in $ENV $INSTANCE_HOST $WEBVIEW_HOST; do
  echo | openssl s_client -connect "$INSTANCE_HOST:443" -servername "$h" 2>/dev/null | openssl x509 -noout -subject -ext subjectAltName -enddate; done
k get certificate
```
Expect: `200 0`, `200 0` and `401 0` (the API without a token). Each certificate names the host it is served for; the webview host is one exact name, not a wildcard (G3); expiry more than 21 days away. The operator's own Gateway and certificates are in `eduide-test3` (decision U9): the `Certificate` objects are `Ready=True`. The old plan's note applies: a wrong-name certificate is silent in the Gateway status.

### PLAT-04 Gateway routes and SecurityPolicy attached
Safety: prod-safe
Steps: `k get httproute -o json | jq -r '.items[] | .metadata.name as $n | .status.parents[]? | $n + " " + (.parentRef.sectionName // "-") + " " + ([.conditions[] | .type + "=" + .status + ":" + .reason] | join(","))'` and `k get securitypolicy $FULL-session -o jsonpath='{range .status.ancestors[*].conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'`.
Expect: `$FULL-api`, `$FULL-oauth2`, the landing route and one route `ide-<instance>` per session or idle pool pod are `Accepted=True` and `ResolvedRefs=True` on the section whose hostname matches. The SecurityPolicy is `Accepted=True`. A route with no status parent is attached to a section that does not exist.

### PLAT-05 Templates and pools consistent with the deployment
Safety: prod-safe
Steps: compare `k get idetemplates -o name` with the tiles of the landing page and with `GET /templates` (token, API-23); every IDEPool `spec.templateRef` names an existing template (`k get idepools -o jsonpath='{range .items[*]}{.metadata.name} {.spec.templateRef}{"\n"}{end}'`); compare the live specs with the Helm values of the deployment (`values.templates`).
Expect: every template on the landing page exists; no pool without a template; a difference between live and Helm values is either a recorded override of this run or a finding; no template or pool without the Helm label except `ft-` fixtures (`k get idetemplates,idepools -L app.kubernetes.io/managed-by`; Helm sets only `managed-by`, no `instance` label).

### PLAT-06 Image prepull done
Safety: prod-safe
Steps: `k get daemonset` (one per template when `config.placement.prepull.enabled`) and the pods' readiness; `k get ds -o json | jq -r '.items[] | .metadata.name + " " + (.status.numberReady|tostring) + "/" + (.status.desiredNumberScheduled|tostring)'`.
Expect: every prepull DaemonSet fully rolled out, on the nodes of the template's placement only (U7). If not, the first cold starts after a deploy are slow; wait before running modules 04, 05, 08 and 14.

### PLAT-07 Leftover and orphaned objects
Safety: prod-safe
Steps:
```bash
# sessions whose template is gone
k get idesessions -o json | jq -r --argjson t "$(k get idetemplates -o json | jq '[.items[].metadata.name]')" \
  '.items[] | select(.spec.templateRef as $a | $t | index($a) | not) | .metadata.name + " " + .spec.templateRef'
# claimed pods without a session, sessions in phase Ready without a pod
k get pods -l eduide.github.io/state=claimed -o json | jq -r --argjson s "$(k get idesessions -o json | jq '[.items[].metadata.name]')" \
  '.items[] | select(.metadata.labels["eduide.github.io/session"] as $x | $s | index($x) | not) | .metadata.name'
k get idesessions -o json | jq -r '.items[] | select(.status.phase=="Ready") | .status.podName' | while read -r p; do k get pod "$p" -o name >/dev/null 2>&1 || echo "no pod: $p"; done
k get ideworkspaces -o json | jq -r '.items[] | select(.status.phase=="Pending" or .status.phase==null) | .metadata.name'
```
Expect: no output. Report names of `ft-` objects only, count the others.

### PLAT-08 Config is sane and holds no secrets
Safety: prod-safe
Steps: `k get cm $FULL-config -o jsonpath='{.data.config\.yaml}'` (the file holds no secrets by design; check before pasting) and `yq '.. | select(tag == "!!str") | select(test("(?i)secret|password|token"))'` on it.
Expect: `hosts.service`, `hosts.instance` and `hosts.webview` equal the test3 hosts; `gateway` names the deployment's own Gateway and section; `oidc.issuerURL`, `clientIDs`, `gatewayClientID` set, `idTokenCookie` as in the SecurityPolicy (`k get securitypolicy $FULL-session -o jsonpath='{.spec.oidc.cookieNames}'`); `sessionsPerUser` recorded (default 3); `capacity.exhaustedAfter` recorded (default 45s); `telemetry.otlpEndpoint` points at the Jaeger of the namespace; no value that looks like a secret (the OIDC client secret lives in a Secret the SecurityPolicy references). Strict parsing means unknown keys stop the binaries (WS-07).

### PLAT-09 CRD validation rules are active
Safety: test-only
Steps: `ft_template "$T_STD" ft-bad 'del(.spec.persistence.allowed) | .spec.persistence.default="volume"'`; then `ft_template "$T_STD" ft-bad2 '.spec.timeouts={"idle":"10m","warning":"20m"}'`; then `ft_template "$T_STD" ft-bad3 '.spec.timeouts={"idle":"10m","warning":"2m","max":"5m"}'` and a workspace with `retention: 2d` (`ft_workspace ft-bad4 "$T_STD" "$FT_USER" 2d`); then try to change the owner of a fixture session: `ft_session ft-v1 "$T_STD"; k patch idesession ft-v1 --type merge -p '{"spec":{"owner":"someone-else"}}'`.
Expect: the first two are rejected by the API server with the CEL messages (`default must be one of allowed` or schema error, `warning must be shorter than idle`), and so are `max` below `idle` and the duration `2d` (not a Go duration); the same fixtures were accepted before fix batch 1 and stalled the workspace informer; the patch fails with `spec is immutable`. No admission webhook pod exists in the namespace (`k get pods | grep -ci webhook` is 0, decision: CEL instead of webhook).
Cleanup: `ft_cleanup`.

### PLAT-10 Control plane loggers are configured
Safety: prod-safe
Steps: `for d in operator service authz; do printf '%s ' $d; k logs deploy/$FULL-$d --all-pods | head -50 | grep -c 'log.SetLogger(...) was never called'; done`; `k logs deploy/$FULL-operator --all-pods | head -3 | jq -e . >/dev/null && echo json`.
Expect: 0 for every component (controller-runtime and client-go logs reach the JSON handler, so reconcile errors are visible); the first lines are JSON, the start line names the version.

### PLAT-11 Gateway listeners without overlapping TLS configuration
Safety: prod-safe
Steps: `k get gateway -o json | jq -r '.items[].status.listeners[] | .name + " " + ([.conditions[] | select(.status=="True") | .type] | join(","))'`; for `$ENV`, `$INSTANCE_HOST` and `$WEBVIEW_HOST`: `openssl s_client -alpn h2,http/1.1 -servername $h -connect $h:443 </dev/null 2>/dev/null | grep -i 'ALPN protocol'`.
Expect: no listener has the condition `OverlappingTLSConfig`; all three hosts negotiate `h2`. A host that falls back to `http/1.1` is a finding: the certificate of another Gateway lists the same name (first run: webview host of test3, shared Gateway's static certificate).

## Explore

- `k get events --sort-by=.lastTimestamp | tail -30` for warnings nobody looks at (FailedMount, BackOff, quota, Unschedulable).
- Objects that nothing owns: `k get all,cm,secret,pvc --show-labels` and anything labelled `app.kubernetes.io/managed-by=eduide` without an ownerReference.
- Two operator replicas (scale to 2 on a spare window): does only one reconcile, and does the lease move when the leader pod is deleted?
- Compare the landing page footer version with the deployed landing image tag.
