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
Expect: every request returns 302 to the Keycloak login of the environment's realm (verified this way on rc.3); none returns 200, 101 or IDE content.

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
Expect: every port `closed` (default deny plus gateway-only ingress; private ranges blocked for egress). Internet egress still works if `allowExternalEgress` is true (`curl -sI https://github.com` from A). No service account token is mounted in the IDE pod (`automountServiceAccountToken: false`).
Cleanup: `ft_cleanup`.

### SEC-08 Admin API cannot be reached without the toggle and token (CL-05, Cloud 3.0.1)
Safety: prod-safe
Steps: API-11.
Expect: 404 everywhere the toggle is off. If an environment turned it on deliberately, record why and run API-12's 401/403 parts only (no PATCH on production).

### SEC-09 Anonymous mode is off
Safety: prod-safe
Steps: `grep -rn allowUnauthenticated environments/` and `curl -s $LANDING/config.js | grep -o 'useKeycloak: [a-z]*'`
Expect: no environment sets `keycloak.allowUnauthenticated`; `useKeycloak: true` everywhere.

## Explore

- Request smuggling and path normalisation between Envoy and oauth2-proxy (double slashes, dot segments, mixed case) on a fixture session only; describe outcomes, never record payload lists in the report.
- Can a session reach the cloud metadata address (`169.254.169.254`) or node ports of the cluster? (Expected: no.)
- Can one user's session URL be opened by another logged-in user? (Needs a second account; expected: the proxy refuses, the user is not in the authenticated emails list.)
- Are there Secrets in the namespace that a session's env could reference via `fromSecrets` (operator allowlist `operator.allowedEnvFromSecrets`, default empty)?
- Look at response headers of landing, service and session for missing security headers (CSP, HSTS, X-Content-Type-Options).
