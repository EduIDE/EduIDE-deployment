# 09 Security regressions and isolation (SEC)

Server module. Checks that the security properties of the design hold: no session without a valid owner (module 13), the instance token and the network as second lines of defence, no launch data leaks, no way to read arbitrary Secrets (the Bonn incident path of the old stack), minimal rights. It describes what to verify, not how to exploit anything; do not add attack payloads or audit material to this file or to reports. Finding IDs of the 2026-11-16 audit are kept in the mapping, not here.

Sources: ADR 0005, 0006, 0012, 0019; `api/v1alpha1` (CEL rules, no `valueFrom`), `charts/eduide-control-plane/templates/{networkpolicy,gateway,rbac}.yaml`.

Related tests in other modules: AUTHZ-* (who may open a session), API-02 (anonymous calls), API-07 and API-16 (owner checks), API-10 (allowlist), API-11 (no admin API), API-13 (CORS), AGENT-04 and AGENT-05 (control port), OPR-08, OPR-19, OPR-20 (policies, pod, route), POOL-10.

Replaced: the old SEC-01 (oauth2-proxy skip rules) and SEC-08 (admin API toggle) have no counterpart; see [../mapping.md](../mapping.md).

### SEC-02 Anonymous requests to a session redirect to login
Safety: prod-safe (anonymous GETs only, against one running session; pick any session URL from `status.url` and do not record it)
Steps: `U=https://$INSTANCE_HOST/<instance>`, then without cookies request the root, a few paths below it, the same on the webview host, a path with `..` segments and percent-encoded variants (`--path-as-is`), and the OIDC paths:
```bash
for h in $INSTANCE_HOST $WEBVIEW_HOST; do
  for p in "/<instance>/" "/<instance>/a/b" "/<instance>/%2e%2e/<other instance>/" "/<instance>/../<other instance>/" "//<instance>/" "/<instance>" "/"; do
    curl -s --path-as-is -o /dev/null -w "%{http_code} $h $p %{redirect_url}\n" "https://$h$p" | sed 's#redirect_url=##; s#\(https://[^/]*\).*#\1#'; done; done
```
Expect: every request returns a 302 to the Keycloak login of the deployment's realm (the OIDC filter), a 307 slash redirect on the same host, or a 404 for paths that match no route; none returns IDE content, a 101, or a body of the session. Paths that traverse into another instance are never served to an anonymous caller. Known non-redirect answers: `/oauth2/...` is handled by the filter or the service (404). The Keycloak host in the redirect is printed as a host only.

### SEC-03 Instance ids do not reveal or collide
Safety: prod-safe
Steps: `k get idesessions -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.instance}{"\n"}{end}' | awk '{print length($1), length($2)}' | sort | uniq -c`; `k get idesessions -o name | grep -vc '^idesession.eduide.github.io/s-'`; instance ids of idle pool pods: `k get pods -l eduide.github.io/state=idle -o jsonpath='{.items[*].metadata.labels.eduide\.github\.io/instance}' | tr ' ' '\n' | awk '{print length}' | sort | uniq -c`.
Expect: session names `s-<10 chars>` (created by the service; fixtures `ft-` and others are counted), instance ids 20 characters of lowercase base32 (no sequence, no counter, no relation to the session name, no owner name), no duplicate instance among live objects (`... | sort | uniq -d` is empty), no instance id derivable from a name.

### SEC-04 Control plane runs unprivileged
Safety: prod-safe
Steps: `k get deploy -l $CP_SEL -o json | jq '.items[] | {name:.metadata.name, pod:.spec.template.spec.securityContext, c:[.spec.template.spec.containers[]|{n:.name,sc:.securityContext,img:.image}]}'`.
Expect: all components run as non-root (`runAsNonRoot: true`), `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, capabilities dropped, seccomp `RuntimeDefault`; images are distroless (no shell: `k exec deploy/$FULL-operator -- sh` fails). Requests and memory limits are set (PERF-01).

### SEC-05 No launch data or secrets in control plane logs
Safety: prod-safe
Steps: count only, never print matching lines:
```bash
for d in operator service authz pool-scaler; do
  printf '%s ' $d; k logs deploy/$FULL-$d --since=24h --all-pods 2>/dev/null | grep -c -E 'ARTEMIS_TOKEN|X-EduIDE-Instance-Token|Authorization|Bearer |eyJ[A-Za-z0-9_-]{10,}|dummy-value' || true; done
k logs deploy/$FULL-operator --since=24h | head -3 | jq -e . >/dev/null && echo "json logs"
```
Expect: 0 for every component; logs are JSON lines with `trace_id` where a trace exists; the log level is `info` (debug only with `LOG_LEVEL=debug`, record if set). The full check with a real launch is SEC-14.

### SEC-06 Instance tokens are per instance
Safety: prod-safe
Steps: `k get secret -o name | grep -c 'ide-.*-token'`; compare with the number of session pods (`k get pods -l eduide.github.io/component=session --no-headers | wc -l`); `k get secret ide-<instance>-token -o jsonpath='{.metadata.ownerReferences[0].kind} {.type}'`; hashes of two tokens (never the values): `for i in <inst1> <inst2>; do k get secret ide-$i-token -o jsonpath='{.data.token}' | base64 -d | shasum -a 256 | cut -c1-12; done`; length: `... | base64 -d | wc -c`.
Expect: one token Secret per session pod (idle and claimed), owned by the Pod, key `token`, 64 hex characters (32 random bytes), no two equal hashes; the token is the same value as in that instance's HTTPRoute header only (compare by hash: `k get httproute ide-<i> -o jsonpath='{.spec.rules[0].filters[?(@.type=="RequestHeaderModifier")].requestHeaderModifier.set[0].value}' | shasum -a 256 | cut -c1-12`). It does not change at claim (POOL-03).

### SEC-07 Session pods are isolated from each other and from the infrastructure
Safety: test-only
Steps: start two fixture sessions `ft-sec-a` and `ft-sec-b` (`ft_session ... "" "$ME"` or fixture owner, any). From the `ide` container of A, with a 5 s limit, try TCP connections to B's pod IP on 8080 (agent proxy), 8081 (agent control), 8082, the IDE port of the template and to the service and authz pods' ports 8080, 9001, 9090 (`IP_SVC=$(k get pod -l app.kubernetes.io/component=service -o jsonpath='{.items[0].status.podIP}')`):
```bash
k exec $POD_A -c ide -- bash -c 'for t in "$0:8080" "$0:8081" "$0:8082" "$0:3000" "$1:8080" "$1:9090"; do h=${t%:*}; p=${t#*:}; timeout 5 bash -c "</dev/tcp/$h/$p" 2>/dev/null && echo "OPEN $t" || echo "closed $t"; done' "$IP_B" "$IP_SVC"
```
Then the cluster infrastructure (`NODE_IP` = the InternalIP of a node): `curl -sk -m5 -o /dev/null -w '%{http_code}' https://kubernetes.default.svc/version`, `https://$NODE_IP:10250/healthz`, a TCP connect to `$NODE_IP:22`, and `http://169.254.169.254/`. Internet egress: `curl -sI -m5 https://github.com | head -1`.
Expect: every port to B, the service and authz `closed` (default deny, no rule admits session pods; the IDE port is on 127.0.0.1 and has no network listener); the API server, kubelet, node SSH and metadata address time out (private ranges are excluded from egress); internet egress works when the deployment allows it. No service account token is mounted in the IDE pod (`k exec $POD_A -c ide -- ls /var/run/secrets/kubernetes.io 2>&1` fails). On stud the nodes sit on a public subnet that `privateEgressCidrs` may not exclude: the old stack's finding; record the answers per target.
Cleanup: `ft_cleanup`.

### SEC-09 No anonymous mode
Safety: prod-safe
Steps: `k get cm $FULL-config -o jsonpath='{.data.config\.yaml}' | grep -ci -E 'anonymous|allowUnauth|skipAuth|insecure'`; API-02; AUTHZ-01.
Expect: no such setting exists in the config schema (strict parsing would reject it, WS-07) and in the chart values (`grep -rn -i anonymous charts/eduide-control-plane/values.yaml` in the control plane repo); every API operation needs a token; every session route is under the SecurityPolicy (AUTHZ-11).

### SEC-10 The CRDs cannot name Secrets or ConfigMaps for sessions
Safety: test-only
Steps: `k get crd idetemplates.eduide.github.io -o json | jq '[.. | objects | keys[]?] | map(select(test("(?i)secret|configMap|valueFrom|envFrom"))) | unique'`; same for `idesessions`; try to create a template with an env var `valueFrom` and a session with extra fields (`k apply` the clone with `.spec.env += [{"name":"X","valueFrom":{"secretKeyRef":{"name":"s","key":"k"}}}]`, and a session spec with `envFrom`).
Expect: the only Secret reference in the types is `IDESession.spec.dataSecretRef` (a name for the operator to read once, created by the service) and the instance token; template env has `name` and `value` only; the API server refuses (pruned or rejected) the `valueFrom` and `envFrom` additions; the Bonn path (`fromSecrets`, `fromConfigMaps`) does not exist anywhere in the CRDs or in the API (API-10).
Cleanup: `ft_cleanup`.

### SEC-11 Security headers
Safety: prod-safe
Steps:
```bash
for u in "$LANDING/" "$API/templates" "https://$INSTANCE_HOST/<instance>/" "https://$WEBVIEW_HOST/<instance>/"; do
  echo "$u"; curl -sS -o /dev/null -D - "$u" | grep -i -E '^(strict-transport-security|x-content-type-options|x-frame-options|content-security-policy|referrer-policy):' | cut -d: -f1; done
```
Expect: `Strict-Transport-Security` on every host; the landing page sends CSP, `X-Content-Type-Options`, `X-Frame-Options` (or `frame-ancestors`) and `Referrer-Policy`; the API sends at least `X-Content-Type-Options`; the session hosts (anonymous answer is the OIDC redirect) at least HSTS. Print header names only. Record what is missing; the old stack sent none of these on the session host.

### SEC-12 Instance token: direct pod access needs the header
Safety: test-only
Needs: a running session; `agent_pf <instance>` (forwards the agent proxy to 18080).
Steps: `proxy $INST none /`; `proxy $INST wrong /`; `proxy $INST right /`; also `/some/other/path` and a WebSocket-style request without the header: `curl -s -o /dev/null -w '%{http_code}\n' -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: ZnRrZXk=' http://127.0.0.1:18080/`.
Expect: 403 without the header and with a wrong one (also for the WebSocket upgrade), 200 with the right token (read from the Secret, header via stdin, never printed). The token Secret's value and the HTTPRoute header value are the same (hash compare, SEC-06). The IDE port itself is not reachable at all: `k port-forward pod/ide-$INST 13000:<template port>` shows connection refused from outside the pod because the IDE binds `127.0.0.1` (the forward goes to the pod's network namespace, so it may connect: record; the NetworkPolicy and agent are the barrier for other pods, SEC-13).
Cleanup: `kill $AGENT_PF`; `ft_cleanup`.

### SEC-13 NetworkPolicy negative test
Safety: test-only
Needs: two session pods A and B (fixtures) and a foreign pod in the namespace without any EduIDE labels:
```bash
k run ft-probe --image=curlimages/curl:8.11.1 --labels=eduide.dev/functional-test=$RUN_ID --restart=Never --command -- sleep 3600
k wait --for=condition=Ready pod/ft-probe --timeout=120s
```
Steps: from `ft-probe`: `k exec ft-probe -- curl -s -m 5 -o /dev/null -w '%{http_code}\n' http://<A pod IP>:8080/` (agent proxy), the same on `:8081/readyz` (control, even the unauthenticated endpoint), `:8082`, and with the right token header on 8080 (`-H @-` fed from the Secret). From the `ide` container of A to B on 8080 and 8081 (SEC-07). Positive controls: A is `Ready` (the kubelet probe reaches 8081), a warm launch works (Envoy reaches 8080, AUTHZ-02), a claim works (the operator reaches 8081, POOL-03). Optionally from the shared Gateway's Envoy pod namespace: not testable here.
Expect: the foreign pod cannot connect to 8080, 8081 or 8082 of any session pod, even with the right token (timeout `000`); A cannot reach B; the positive controls work. If any negative case connects, the cluster does not enforce NetworkPolicies (the first line, the token, still holds): this blocks release for that cluster (ADR 0019). Record the CNI (`k get pods -n kube-system | grep -i -E 'calico|cilium|flannel'`).
Cleanup: `k delete pod ft-probe`; `ft_cleanup`.

### SEC-14 Launch data never in logs, status, specs, traces
Safety: test-only
Needs: browser token; Jaeger port-forward (MON-10); a template with an injectable key (`ft-t2` from the README).
Steps: launch twice (warm and cold) with a recognisable dummy value for each key: `await api('POST','/sessions',{template:'ft-t2',data:{FT_PROBE:'ftsecret-7f3a91'}})`. After both are Ready, count the marker everywhere (count only, never print):
```bash
M=ftsecret-7f3a91
for r in idesessions ideworkspaces idepools idetemplates; do printf '%s ' $r; k get $r -o yaml | grep -c "$M"; done
k get pods,svc,httproute,events,cm -o yaml | grep -c "$M"
k get idesession <n> -o jsonpath='{.status}' | grep -c "$M"
for d in operator service authz; do printf '%s ' $d; k logs deploy/$FULL-$d --since=30m --all-pods | grep -c "$M"; done
k logs <session pod> -c agent | grep -c "$M"; k logs <session pod> -c ide | grep -c "$M"
curl -s "http://127.0.0.1:16686/api/traces?service=<each service>&lookback=1h&limit=200" | grep -c "$M"
curl -s http://127.0.0.1:19090/metrics | grep -c "$M"    # operator, service, authz metrics endpoints
```
Expect: 0 everywhere except one place: the data Secret `<session>-data` (`k get secret <n>-data -o json | jq -r '.data.FT_PROBE|@base64d'` shows the value; check this in a shell variable and compare, do not print) and the agent's memory. The same for the `traceparent` annotation (no data in it), the API responses of `GET /sessions` and `GET /me/overview` (`display` only), and the error responses of rejected launches (API-09). The marker never appears in the pod spec, in any env, label or annotation.
Cleanup: stop the sessions.

### SEC-15 Telemetry holds no personal data
Safety: test-only
Needs: Jaeger port-forward (MON-10), a launch by `ME`.
Steps: fetch the trace of a launch and list its attribute keys and a count of values that look like an e-mail address or contain the user name:
```bash
curl -s "http://127.0.0.1:16686/api/traces/<traceid>" | jq -r '[.data[].spans[].tags[] | .key] | unique[]'
curl -s "http://127.0.0.1:16686/api/traces/<traceid>" | grep -c -E '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+'
curl -s "http://127.0.0.1:16686/api/traces/<traceid>" | grep -c -i "$ME"
k logs deploy/$FULL-operator --since=10m | grep -c -i "$ME"
```
Expect: a user appears only as a pseudonymous id (a 16 character hash: `telemetry.UserID`, salt from `telemetry.userSaltFile`) and the session id; 0 e-mail addresses and 0 occurrences of the user name in spans, operator and service logs (the owner label is a hash too). The salt differs per deployment (record that the Secret exists; never read it). `eduide_*` metrics have no user, e-mail or token label (MON-09).

### SEC-16 Session pod hardening
Safety: prod-safe
Steps: OPR-19's pod JSON plus `k get pod <p> -o json | jq '.spec.containers[] | {n:.name, sc:.securityContext}, .spec.securityContext'`.
Expect: `automountServiceAccountToken: false`, `enableServiceLinks: false`; the agent container runs non-root with a read-only root filesystem and no capabilities; the IDE container runs as the template's `runAsUser` (record) and `runAsNonRoot` where the image allows it; no `hostPath`, `hostNetwork`, `privileged`; the only Secret volume is the instance token (read-only); the workspace volume is a PVC or `emptyDir`.

### SEC-17 Minimal RBAC
Safety: test-only (needs rights to impersonate service accounts; `blocked` otherwise)
Steps: `for sa in operator service authz pool-scaler; do for v in "get secrets" "delete pods" "create pods" "get idesessions" "update idesessions/status" "get secrets -n kube-system" "list nodes"; do printf '%s %s: ' $sa "$v"; kubectl --context $CTX -n $NS auth can-i $v --as=system:serviceaccount:$NS:$FULL-$sa; done; done`
Expect (adapt names): the operator may manage pods, Services, HTTPRoutes, PVCs, Secrets and the four CRDs (with `/status` and `/finalizers`) in its namespace only; the service may create and read IDESessions, IDEWorkspaces and Secrets, and list templates, but not delete pods; authz may only get, list and watch IDESessions; the pool scaler may update IDEPools; nobody may read Secrets or anything else in another namespace, and nobody has cluster-wide rights except the read of CRDs/Nodes the design names (record each yes). Roles are namespaced Roles, not ClusterRoles, where the design says so (`k get clusterrole,clusterrolebinding | grep $FULL`).

## Explore

- Request smuggling and path normalisation between Envoy, authz and the agent (double slashes, dot segments, mixed case, encoded slashes) on a fixture session only; describe outcomes, never record payload lists in the report.
- Can a session reach the cloud metadata address or node ports (SEC-07), and can one reach the operator's metrics port 9464 or the authz port 9001 from a session pod?
- Can one user's session URL be opened by another logged-in user (a second account; AUTHZ-03)?
- Can a user make the service write `display.title` or `display.source` that ends up as markup in the overview (stored XSS in the landing page)?
- Cookie scope: does `eduide-id` reach the webview host and is it `HttpOnly`, `Secure`, `SameSite`? Can a session's own JavaScript read it (it must not)?
- Template `env` values containing secrets: a count of templates whose env names look like tokens (names only).
- Can an authenticated user list or get IDESessions of others by guessing `s-` names (API-07 with 404 vs 403 oracle)?
