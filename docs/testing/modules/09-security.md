# 09 Security regressions (SEC)

Server module. Checks that the fixes from the 2026-11-16 security audit stay in place (EduIDE-Cloud 3.0.0/3.0.1, EduIDE-Helm 3.0.0, EduIDE-data-bridge 2.0.0, scorpio 3.0.0). It describes what to verify, not how to exploit anything; do not add attack payloads or audit material to this file or to reports. Finding IDs (CL-01 and so on) refer to the audit.

Related tests in other modules: API-02 (anonymous calls), API-07 (owner checks), API-10 (reserved env keys), API-11/12 (admin API), API-13 (CORS), API-14 (management port), DB-01/04/09 (bridge token and reachability), POOL-10 (pool hardening).

### SEC-01 Session proxy skips authentication only for /health (CL-01)
Safety: prod-safe
Steps:
```bash
k get cm -o json | jq -r '.items[] | select(.data["oauth2-proxy.cfg"] != null) | .metadata.name + ": " + ([.data["oauth2-proxy.cfg"] | split("\n")[] | select(test("skip_auth"))] | join(" | "))'
for d in $(k get deploy -o name); do
  k get $d -o json | jq -r --arg d "$d" '[.spec.template.spec.containers[].args[]? | select(test("skip-auth"))] | if length>0 then $d + " " + join(",") else empty end'; done
```
Expect: the proxy config contains exactly `skip_auth_routes=["^/health$"]` and no other skip rule; no session or pool Deployment has a `--skip-auth-route` argument (no output from the loop).

### SEC-02 Anonymous requests to a session redirect to login (CL-01)
Safety: prod-safe (anonymous GETs only, against one running session; on production pick any session URL from `status.url` and do not record it)
Steps: `U=https://$(k get session <name> -o jsonpath='{.status.url}')`, then without cookies request the session root, a path ending in `/monitor`, the socket.io paths of the IDE and the monitor, a health path, and percent-encoded variants of those paths:
```bash
PATHS=(...)   # fill in the paths listed above
for p in "${PATHS[@]}"; do curl -s -o /dev/null -w "%{http_code} %{redirect_url}\n" "$U$p"; done
```
Expect: every request returns 302 to the Keycloak login of the environment's realm, a 307 slash redirect to the same host, or a 302 to the landing page (a normalised path that leaves the session prefix); none returns 101 or IDE content. Known non-redirect answers: `/ping` 200 without content (oauth2-proxy health endpoint), `/oauth2/auth` 401, `/oauth2/callback` without state 500 (upstream behaviour).

### SEC-03 Session names do not reveal or collide (CL-02, CL-03)
Safety: prod-safe
Steps: `k get sessions -o name | grep -c '^session.theia.cloud/eph-'` and `k get sessions -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -v -E '^(eph-.*-[0-9a-f]{16}-session|ws-.*-session|ft-.*)$' | wc -l`
Expect: ephemeral sessions follow `eph-<app>-<user>-<16 hex>-session`; anything else is a persistent `<workspace>-session` or a fixture. The count of other names is 0 (except sessions older than the 3.0 upgrade still using `ws-<app>-<user>-session`, which the service reuses; count them).

### SEC-04 Components run as uid 10001 (CL-14)
Safety: prod-safe
Steps: `for d in service-deployment operator-deployment; do k exec deploy/$d -- id -u; done`
Expect: `10001` twice (images set `USER 10001`). Session IDE containers run as uid 101.

### SEC-05 No env values in operator logs (CL-14, Cloud 3.0.1)
Safety: prod-safe
Steps: count only, never print matching lines:
```bash
k logs deploy/operator-deployment --since=24h | grep -c -E 'GIT_URI=|ARTEMIS_TOKEN|DATA_BRIDGE_TOKEN|secretKeyRef|value: ' || true
k logs deploy/operator-deployment --since=24h | grep -c -E 'eyJ[A-Za-z0-9_-]{10,}' || true
k get deploy operator-deployment -o yaml | grep -c operator-logging-config || true
```
Expect: 0 and 0 since the 3.0.1 operator started (it logs only kind and name of rendered resources). Record the log level: the default `log4j2.xml` sets the operator packages to `trace`; an override via `operator.logging.override` is recorded.

### SEC-06 Bridge tokens are per instance and per session (DB-01)
Safety: prod-safe
Steps: `k get secret -o name | grep -c bridge-token`; compare with the number of pool instances plus lazy sessions of bridge-enabled apps. Check ownership: `k get secret <one> -o jsonpath='{.metadata.ownerReferences[0].kind}'`.
Expect: one Secret per pool instance (owner AppDefinition) and one per lazy session (owner Session); no shared token; no literal `DATA_BRIDGE_TOKEN` value in any pod spec (DB-01).

### SEC-07 Session pods are isolated from each other (CL-12)
Safety: test-only
Steps: start two fixture sessions `ft-sec-a` and `ft-sec-b` (ephemeral, `<APP_STD>`). From the IDE container of A, with a 5 s limit, try TCP connections to B's pod IP on 3000, 5000, 16281 and the monitor port 8081, and to the service pod's management port 9000 (`IP_SERVICE_POD=$(k get pod -l app=service -o jsonpath='{.items[0].status.podIP}')`):
```bash
k exec $POD_A -c $C -- bash -c 'for t in "$0:3000" "$0:5000" "$0:16281" "$0:8081" "$1:9000"; do h=${t%:*}; p=${t#*:}; timeout 5 bash -c "</dev/tcp/$h/$p" 2>/dev/null && echo "OPEN $p" || echo "closed $p"; done' "$IP_B" "$IP_SERVICE_POD"
```
Then the cluster infrastructure (`NODE_IP` = the InternalIP of any node, `k get nodes -o wide` needs cluster read rights): `curl -sk -m5 -o /dev/null -w '%{http_code}' https://kubernetes.default.svc/version`, `https://$NODE_IP:10250/healthz`, a TCP connect to `$NODE_IP:22`, and `http://169.254.169.254/`.
Expect: every port `closed` (default deny plus gateway-only ingress; private ranges blocked for egress). The API server, kubelet, node SSH and the metadata address time out (target). On `tum-student` the nodes and the API server sit on a public subnet that `privateEgressCidrs` does not exclude: API server and kubelet answer 401 and node SSH is open (2026-11-17 report); record it until the cluster values exclude the subnet. Internet egress still works if `allowExternalEgress` is true (`curl -sI https://github.com` from A). No service account token is mounted in the IDE pod (`automountServiceAccountToken: false`).
Cleanup: `ft_cleanup`.

### SEC-08 Admin API cannot be reached without the toggle and token (CL-05, Cloud 3.0.1)
Safety: prod-safe
Steps: API-11.
Expect: 404 everywhere the toggle is off. If an environment turned it on deliberately, record why and run API-12's 401/403 parts only (no PATCH on production).

### SEC-09 Anonymous mode is off
Safety: prod-safe
Steps: `grep -rn allowUnauthenticated environments/` and `curl -s $LANDING/config.js | grep -o 'useKeycloak: [a-z]*'`
Expect: no environment sets `keycloak.allowUnauthenticated`; `useKeycloak: true` everywhere.

### SEC-10 Env from Secrets and ConfigMaps outside the allowlist is dropped
Safety: test-only
Steps: create a fixture Session with `spec.envVarsFromSecrets: [service-admin-api-token, service-config-secret]` and `spec.envVarsFromConfigMaps: [kube-root-ca.crt]` (string lists in v1beta8; add them to the `ft_session` heredoc), `ft_wait`; then `k get pod <pod> -o jsonpath='{.spec.containers[*].envFrom}'` and `k logs deploy/operator-deployment --since=5m | grep -c 'not permitted by the operator allowlist'`.
Expect: the pod has no `envFrom`; the operator logs a WARN that names the dropped objects (names only, no values). The operator allowlist (`operator.allowedEnvFromSecrets`, default empty) decides; record its value.
Cleanup: `ft_cleanup`.

### SEC-11 Security headers
Safety: prod-safe
Steps:
```bash
S="<any running session>"   # on production pick any and do not record its name
for u in "$LANDING/" "$SERVICE/service/$APPID" "https://$(k get session "$S" -o jsonpath='{.status.url}')"; do
  echo "$u"; curl -sS -o /dev/null -D - "$u" | grep -i -E '^(strict-transport-security|x-content-type-options|x-frame-options|content-security-policy|referrer-policy):' | cut -d: -f1; done
```
Expect: `Strict-Transport-Security` on all three hosts; the landing page also sends CSP, `X-Content-Type-Options`, `X-Frame-Options` and `Referrer-Policy`. Chart 3.0.0-rc.3: no HSTS on any host, service and session proxy send none of these headers (2026-11-17 report). Print header names only.

## Explore

- Request smuggling and path normalisation between Envoy and oauth2-proxy (double slashes, dot segments, mixed case) on a fixture session only; describe outcomes, never record payload lists in the report.
- Can a session reach the cloud metadata address (`169.254.169.254`) or node ports of the cluster? (Expected: no.)
- Can one user's session URL be opened by another logged-in user? (Needs a second account; expected: the proxy refuses, the user is not in the authenticated emails list.)
- Which Secrets in the namespace would a non-empty `operator.allowedEnvFromSecrets` expose to sessions (SEC-10)?
- Do Session CRs carry credentials in clear text in `spec.envVars` (for example a token inside `GIT_URI`)? Count only, never print values.
