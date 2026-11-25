# 09 Security: access, isolation, data (SEC)

Server module. Checks that the security properties of the Go control plane hold: nothing reaches an IDE without a valid login and a matching owner (gateway OIDC plus ext_authz, fail closed), session pods are isolated and hold no cluster credentials, launch data never leaks, and the Bonn attack path of the Java stack (the request naming Secrets to read) does not exist. It describes what to verify, not how to exploit anything; do not add attack payloads or audit material to this file or to reports. Finding IDs of the 2026-11-16 audit (CL-01 and so on) refer to the Java stack and are kept in the retired list only.

Sources: control plane `docs/architecture/{overview,session-access}.md`, ADR 0005, 0006, 0012, 0019, 0021, `docs/operations/authz-errors.md`, `internal/authz/`, `internal/httpapi/validate.go`, chart templates `gateway.yaml`, `networkpolicy.yaml`, `rbac.yaml`; `test/e2e/README.md` (`auth_test.go`).

Related tests in other modules: API-02 (anonymous API calls), API-07 and API-16 (owner checks), API-09 and API-19 (launch data rules), API-11 (admin role), API-13 (no CORS), API-14 (management ports), AGT-05, AGT-06 and AGT-08 (agent tokens, data in logs), OPR-08 and OPR-16 (policies, pod hardening), POOL-10 (instance wiring).

Facts:
- One SecurityPolicy `$P-session` selects every HTTPRoute labelled `eduide.github.io/route=session` and sets the `oidc` filter (gateway client `oidc.gatewayClientID`, ID token cookie `eduide-id`, cookie domain `instance.$ENV`, refresh token, `denyRedirect` for requests with `Sec-Fetch-Mode` `cors|no-cors|same-origin|websocket`, plain token cookies) and `extAuth` to the authz service on gRPC with `failOpen: false`. The chart adds a catch-all route (`$P-session-fallback`) on the instance and webview host so unknown paths also pass the policy, and a route for `/oauth2/`.
- authz decides per request: no auth cookie at all: allow (the OIDC filter that follows forces the login); an ID token cookie that is invalid or expired: 302 to the same URL with the auth cookies expired; a valid token: allow only when the first path segment is the `status.instance` of an `IDESession` in phase `Ready`, not being deleted, whose `spec.owner` equals the token claim `preferred_username`; everything else (unknown, free pool, foreign, released instance, internal error) 403. It verifies the ID token cookie itself (issuer, audience = gateway client) and keeps its own signed cookie `eduide-authz` so a refreshed login survives the short token cookie.
- Release removes access first: the session leaves `Ready`, authz denies at once, then the operator deletes the pod.
- Session pods have `automountServiceAccountToken: false`. The NetworkPolicies: default deny ingress, 8080 only from Envoy, 8081 only from the operator, no session-to-session path, egress to DNS and the public internet minus private, link-local and the cluster's own ranges.
- The service creates no pods; its Role can create and delete sessions, workspaces and Secrets and read objects; the operator owns pods, services, routes, token Secrets and PVCs; authz can only list and watch sessions.

### SEC-02 Anonymous requests to a session route redirect to login
Safety: prod-safe (anonymous requests, no real session URL needed)
Steps:
```bash
I=instance.$ENV; X=aaaaaaaaaaaaaaaaaaaa      # an instance id that does not exist
for u in "https://$I/" "https://$I/$X/" "https://$I/$X/some/path" "https://webview.instance.$ENV/" "https://webview.instance.$ENV/$X/"; do
  curl -s -o /dev/null -w "%{http_code} %{redirect_url}\n" "$u" | cut -c1-110; done
curl -s -o /dev/null -w '%{http_code} cors-style request\n' -H 'Sec-Fetch-Mode: cors' "https://$I/$X/api"
curl -s -o /dev/null -w '%{http_code} oauth2 callback without state\n' "https://$I/oauth2/callback"
curl -s -o /dev/null -w '%{http_code} http to https\n' "http://$I/$X/"
```
Expect: every request to the session hosts returns 302 to the Keycloak login of the environment's realm (host and realm from `/config.json`), never IDE content and never 101; the cors-style request is 401 with no redirect (and sets no flow cookies); the callback without a login flow is 401; port 80 answers 301 to https. Request a real session route the same way on a test environment only (a fixture's URL, SEC-13). Flow cookies (`OauthNonce-*`, `CodeVerifier-*`) on a redirect are expected.

### SEC-03 Names do not reveal or collide
Safety: prod-safe
Steps: `k get idesessions -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.instance}{"\n"}{end}' | awk '{print $1}' | grep -v -E '^(s-[a-z0-9]{10}|ft-.*)$' | wc -l`; `k get idesessions -o jsonpath='{range .items[*]}{.status.instance}{"\n"}{end}' | grep -v -E '^[a-z2-7]{20}$' | grep -c .`; `k get ideworkspaces -o name | sed 's#.*/##' | grep -v -E '^(w-[0-9a-f]{16}|ft-.*)$' | wc -l`.
Expect: 0 for all three (sessions `s-<10>`, instance ids 20 lowercase base32 characters from `crypto/rand`, workspaces `w-<16 hex>`; an imported workspace may carry another name: count those). No name or URL contains a user name or e-mail (`k get idesessions -o json | jq -r '.items[].status.url' | grep -c -i '@'` is 0).

### SEC-04 Control plane workloads run unprivileged
Safety: prod-safe
Steps: `for d in $P-operator $P-service $P-authz eduide-landing-page; do k get deploy $d -o json | jq -c --arg d $d '{d: $d, podSC: .spec.template.spec.securityContext, sc: .spec.template.spec.containers[0].securityContext, automount: .spec.template.spec.automountServiceAccountToken}'; done`; `k get pods -l app.kubernetes.io/instance=eduide -o json | jq -r '.items[] | .metadata.name + " " + ([.spec.containers[].securityContext.runAsUser // "image"]|join(","))'`.
Expect: `runAsNonRoot: true`, seccomp `RuntimeDefault`, `allowPrivilegeEscalation: false`, all capabilities dropped and a read-only root filesystem for operator, service and authz (the landing page: the same, `automountServiceAccountToken: false`). Session pods: SEC-07 and OPR-16.

### SEC-05 No secrets in logs
Safety: prod-safe
Steps: count only, never print matching lines:
```bash
for c in operator service authz; do
  echo "$c bearer/jwt: $(k logs deploy/$P-$c --since=24h | grep -c -E 'Bearer |eyJ[A-Za-z0-9_-]{10,}')"
  echo "$c cookie/token words: $(k logs deploy/$P-$c --since=24h | grep -c -i -E 'cookie:|set-cookie|ARTEMIS_TOKEN|client-secret|password')"; done
k logs deploy/eduide-landing-page --since=24h | grep -c -E 'eyJ[A-Za-z0-9_-]{10,}'
POD=$(k get pods -l eduide.github.io/component=session -o name | head -1); k logs $POD -c agent | grep -c -E 'Bearer |eyJ[A-Za-z0-9_-]{10,}'
k logs deploy/$P-service --since=24h | jq -r '.level' 2>/dev/null | sort | uniq -c
```
Expect: 0 everywhere. Authz and agent log decisions and key names, never cookie or token values (`docs/operations/logging.md`); users appear only as a 16 character hash (`user`). Record the log levels (`LOG_LEVEL`, default `info`); `debug` lines may name launch rules but never values. The same counts on a test environment after a run with fake launch data are AGT-08.

### SEC-06 Instance tokens are per instance
Safety: prod-safe
Steps: `k get secret -o json | jq -r '.items[] | select(.metadata.name|test("^ide-.*-token$")) | .metadata.name + " " + (.metadata.ownerReferences[0].kind // "-") + " " + (.data|keys|join(","))'`; compare the number with `k get pods -l eduide.github.io/component=session --no-headers | wc -l`; hash the values pairwise without printing them: `k get secret -o json | jq -r '.items[] | select(.metadata.name|test("^ide-.*-token$")) | .data.token' | sort | uniq -d | wc -l`; check no pod spec carries a token value: `k get pods -o json | jq -r '.items[].spec.containers[].env[]? | select(.name|test("TOKEN";"i")) | .name + " " + (if .valueFrom then "valueFrom" elif (.value|startswith("/")) then "path" else "literal" end)' | sort | uniq -c`.
Expect: one Secret `ide-<instance>-token` per session pod, owner `Pod`, key `token` only; no two equal tokens (0 duplicates); no env variable carries a token value. The agent has `AGENT_TOKEN_FILE` (a file path, listed as `path`) and `AGENT_ID_TOKEN_COOKIE` (a cookie name, listed as `literal`) by design (AGT-01): those two names are expected. Forbidden: any `valueFrom` (a Secret reference) and any other env name matching `TOKEN`. The token reaches the agent only as a mounted file. The IDE container has no token at all.

### SEC-07 Session pods are isolated
Safety: test-only
Needs: two fixture sessions and one probe pod. Create the probe from the image the namespace already pulls (`k get deploy eduide-oidc-bridge -o jsonpath='{.spec.template.spec.containers[0].image}'`, an alpine nginx with `wget`, `nc`, `timeout` and `nslookup`) with `restartPolicy: Never`, `command: [sleep, "600"]`, label `eduide.dev/functional-test=$RUN_ID`, `automountServiceAccountToken: false`, in the same namespace.
Steps:
1. Start `ft-sec-a` and `ft-sec-b` (`<TPL_STD>`, no persistence) with `ft_session`; `IP_B=$(k get pod <pod b> -o jsonpath='{.status.podIP}')`; `IP_SVC=$(k get pod -l app.kubernetes.io/component=service -o jsonpath='{.items[0].status.podIP}')`.
2. From the IDE container of A (`k exec <pod a> -c ide -- ...`). The container has `curl` and `bash` but no `nc`, `wget` or `timeout`: use `curl -m 5 -s -o /dev/null http://<ip>:<port>/` and read the exit code (28 timeout, 7 refused), with a 5 s limit, connect to B on 8080, 8081 and 3000 and to the service pod on 8080 and 9090.
3. From the probe pod: the same connections to B on 8080, 8081, 3000 and 8082.
4. Control: from the probe, `wget -q -T 5 -O /dev/null https://github.com` and a DNS lookup.
5. From A (egress): the cluster's own ranges and the metadata address: `https://kubernetes.default.svc/version`, a TCP connect to a node IP on 22 and 10250 (`k get nodes -o wide` needs cluster read rights; take the node range from `sessionEgressExtraDeny`), `http://169.254.169.254/`; and a public host (`https://github.com`).
6. `k get pod <pod a> -o jsonpath='{.spec.automountServiceAccountToken}'` and `k exec <pod a> -c ide -- ls /var/run/secrets/kubernetes.io 2>&1`.
Expect: every connection in 2 and 3 fails (timeout): ingress to 8080 is only from Envoy, to 8081 only from the operator, nothing between sessions, and the IDE port 3000 listens on loopback only; the control (4) works, so the probe is not itself broken; in 5 the API server, node addresses, node SSH, kubelet and the metadata address time out and the public host answers (the IDE can still clone from the internet); no service account token is mounted. A foreign pod that can reach 8080 or 8081 means the cluster does not enforce NetworkPolicies: the deployment is not fit for production (ADR 0019). Record the CNI (`k get pods -n kube-system` is outside the namespace; ask the cluster owner).
Cleanup: `ft_cleanup` (it deletes the labelled probe pod).

### SEC-08 Admin API cannot be reached without the role
Safety: prod-safe
Steps: API-02 (anonymous 401) and API-11.
Expect: 401 without a token everywhere; with a token and without the role 403; 404 where the deployment has no `oidc.admin`. No environment exposes a way to switch the check off (there is no toggle).

### SEC-09 No anonymous mode and no fail-open
Safety: prod-safe
Steps: `grep -rn -i 'allowUnauthenticated\|failOpen\|anonymous' environments/ || true`; `k get securitypolicy $P-session -o jsonpath='{.spec.extAuth.failOpen}{"\n"}'`; `yq .oidc.issuerURL` of the config (PLAT-10); `curl -s -o /dev/null -w '%{http_code}\n' $LANDING/api/v1/templates`.
Expect: no environment file sets such a key; `failOpen: false`; the config names an issuer (the service and authz refuse to start without `oidc.issuerURL`, `gatewayClientID` and `clientIDs`); the API answers 401. "No anonymous mode and no switch to turn auth off" is a design rule (overview, trust boundaries): any such switch found is a finding.

### SEC-10 No way to make the control plane read Secrets
Safety: test-only
Needs: browser token.
Steps: `POST /sessions` with the unknown fields `fromSecrets` and `fromConfigMaps` (a list naming `$P-user-salt` is enough as a name; the value is never read) next to a valid `template`, and with the same names under `data`; then `k get idesessions | grep -c <names>`; `k get pods -o json | jq '[.items[].spec.containers[] | select(.envFrom != null)] | length'`; `k get idetemplates -o json | jq '[.items[].spec | has("envFrom")] | any'`.
Expect: both launches are refused with 400 (`invalid-input` for the unknown fields, `unknown-key` for the data keys) and create nothing; no pod has `envFrom`; no template field can name a Secret or ConfigMap (the CRD has none: `kubectl explain idetemplate.spec` lists `env` with literal values only). The Bonn attack path of the Java stack does not exist.

### SEC-11 Security headers
Safety: prod-safe
Steps:
```bash
for u in "$LANDING/" "$LANDING/api/v1/status" "$LANDING/config.json"; do
  echo "$u"; curl -sS -o /dev/null -D - "$u" | grep -i -E '^(strict-transport-security|x-content-type-options|x-frame-options|content-security-policy|referrer-policy|cache-control):' | cut -d: -f1; done
curl -sS -o /dev/null -D - "https://instance.$ENV/aaaaaaaaaaaaaaaaaaaa/" | grep -i -E '^(strict-transport-security|set-cookie)' | cut -d= -f1 | cut -c1-40
```
Expect: the landing page sends `Content-Security-Policy` (only `'self'` and the Keycloak origin in `connect-src`, `frame-ancestors 'none'`), `Strict-Transport-Security` (with `includeSubDomains`, which covers the instance and webview hosts once a browser has seen the landing host), `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`; `/config.json` has `Cache-Control: no-store`; the API answers carry `Strict-Transport-Security` and `X-Content-Type-Options`. The instance host's login redirect carries the flow cookies and may carry no HSTS of its own (record it; HSTS comes from the landing host, `hstsIncludeSubdomains` default true). Print header names only.

### SEC-12 SecurityPolicy and authz configuration
Safety: prod-safe
Steps: `k get securitypolicy $P-session -o jsonpath='{.spec}' | jq '{targets: .targetSelectors, extAuth: .extAuth, oidc: {clientID: .oidc.clientID, secret: .oidc.clientSecret.name, cookieDomain: .oidc.cookieDomain, cookieNames: .oidc.cookieNames, redirectURL: .oidc.redirectURL, denyRedirect: .oidc.denyRedirect, refreshToken: .oidc.refreshToken, disableTokenEncryption: .oidc.disableTokenEncryption}}'`; `k get httproute -l eduide.github.io/route=session -o name`; `k get deploy $P-authz -o jsonpath='{.spec.replicas}'`.
Expect: the policy selects HTTPRoutes by `eduide.github.io/route=session`; `extAuth.failOpen: false` with the authz Service on port 9001; the OIDC client id is the gateway client of the config and the secret is the Secret `eduide-oidc` (name only; never read it); `cookieDomain` is the instance host; `redirectURL` is `https://instance.$ENV/oauth2/callback`; `denyRedirect` matches `Sec-Fetch-Mode` `cors|no-cors|same-origin|websocket`; token encryption is disabled on purpose (authz must read the cookie; ADR 0005 amendment). Every session route, the fallback route and the `/oauth2/` route carries the label; authz runs two replicas. A route without the label is not protected: none may exist (`k get httproute -o json | jq -r '.items[] | select(.metadata.name|startswith("ide-")) | select(.metadata.labels["eduide.github.io/route"] != "session") | .metadata.name'` prints nothing).

### SEC-13 Only the owner of a Ready session gets in
Safety: test-only
Needs: the user logged in in the browser pane (any test account); a fixture session of another owner; a session of the logged-in user (start one from a tile).
Steps:
1. `ft_session ft-sec-own <TPL_STD>` (owner `ft-sec`), `ft_wait`; open its URL (`status.url`) in the browser as the logged-in user.
2. Open the URL of the logged-in user's own session.
3. Delete the own session (`k delete idesession <name>`, or the landing page "Delete") and open its old URL again, within a few seconds and after the pod is gone.
4. Open `https://instance.$ENV/<a made-up instance id>/` and, if a pool exists, the URL of an idle pool instance (`https://instance.$ENV/<instance label of an idle pod>/`).
Expect: 1 is 403 (a foreign owner never gets in; the response shows no IDE content and no information about the session); 2 loads the IDE; 3 is 403 as soon as the session leaves `Ready` (authz denies before the pod is gone; WebSockets end with the pod); 4 is 403 for the logged-in user (unknown and free instances are indistinguishable from foreign ones). A request without any login to the same URLs is the redirect of SEC-02. `eduide_authz_decisions_total{result="deny"}` rises, with reasons.
Cleanup: `ft_cleanup`; the logged-in user's session.

### SEC-14 Authz fails closed
Safety: test-only, disruptive (new IDE connections fail for a short time)
Steps: record the replicas of `$P-authz` (2); open an IDE of the logged-in user and keep it open; `k scale deploy/$P-authz --replicas=0`; wait 30 s; open a new tab on the session URL and on a made-up instance URL; scale back; `k rollout status deploy/$P-authz`.
Expect: while both authz pods are down no new request reaches any IDE: the gateway answers 403 or a 5xx, never content (the policy has `failOpen: false`); the already open IDE keeps its WebSockets (decided at the upgrade request) but new HTTP requests fail; after the scale-up access works again without a new login. The PodDisruptionBudget (minimum 1) keeps a node drain from taking both pods down. Never set `failOpen` to "get users in" (`docs/operations/authz-errors.md`).
Cleanup: replicas restored.

### SEC-15 Workload permissions (RBAC)
Safety: prod-safe
Steps: `for r in operator service authz; do k get role $P-$r -o json | jq -c --arg r $r '[.rules[] | {r: .resources, v: .verbs}] | {role: $r, rules: .}'; done`; `k get role,rolebinding -o json | jq -r '.items[] | select(.kind=="Role") | .rules[] | select((.resources|index("pods/exec")) or (.resources|index("pods/attach")) or (.resources|index("pods/portforward")) or (.resources|index("*")) or (.verbs|index("*"))) | .resources'`; `k auth can-i --list --as=system:serviceaccount:$NS:$P-service | head -30`; `k auth can-i --list --as=system:serviceaccount:$NS:default | head -20`.
Expect: no Role of the release grants `pods/exec`, `pods/attach`, `pods/portforward` or a wildcard (the second command prints nothing); the service can create and delete sessions, workspaces and Secrets and read objects but not touch pods, services or routes; authz can only list and watch sessions; the operator owns pods, services, secrets, PVCs, routes, leases and daemonsets and updates status; `default` has nothing. Record that the service Role includes `get` on Secrets (needed for the launch data Secret) so the service can read every Secret of its namespace: that is why the OIDC client secret and the user salt must stay out of reach of anything but the service pods' own volumes. Use the Role rules, not `can-i` answers for `pods/exec` (README, "Unverified").

## Unverified, check in the first run

- SEC-02 against a real session route on a test environment (SEC-13 covers it with a login);  the webview host behaviour were observed only for a made-up instance id on test2 (302 to Keycloak for plain paths).
- SEC-07: the probe pod's image, that `exec` into the `ide` container works and which tools it has (`bash`, `nc`, `curl`); the node range and SSH answer on `tum-student` with the current `sessionEgressExtraDeny` (the Java plan recorded node SSH and kubelet as reachable before that setting existed).
- SEC-10: the exact 400 codes for a body field `fromSecrets` (`invalid-input`) and a data key (`unknown-key`).
- SEC-11: that the instance host's redirect carries no HSTS of its own (observed: no).
- SEC-13: the page the browser shows for 403 (plain 403 from Envoy or authz's body) and the timing of the deny after a delete.
- SEC-14: the status the gateway returns while authz is down (403 or 5xx), and WebSocket behaviour.
- SEC-15: the `can-i` answers (see the README note); the `jq` filter for wildcard verbs.
- Whether the access token's audience and `azp` rule rejects a token of another client of the realm (needs a second client).

## Retired

- SEC-01 Session proxy skips authentication only for `/health` (CL-01): 2026-11-24, oauth2-proxy and its ConfigMap are gone; the gateway policy is SEC-12 and the anonymous behaviour SEC-02.
- The old SEC-03 to SEC-11 wordings (ephemeral session name patterns `eph-...`, uid 10001 images, `operator-logging-config`, bridge tokens, `privateEgressCidrs`, admin API toggle, `allowUnauthenticated`, `envVarsFromSecrets`, headers of the Java service) are replaced by the tests above under the same IDs where the intent is the same (SEC-03 names, SEC-04 non-root, SEC-05 logs, SEC-06 tokens, SEC-07 isolation, SEC-08 admin, SEC-09 anonymous, SEC-10 secrets, SEC-11 headers).
- Audit finding references (CL-01 to CL-14, SC-03) belong to the Java stack.

## Explore

- Path normalisation between Envoy, authz and the agent (double slashes, dot segments, encoded slashes, mixed case in the first segment) against a fixture session only; describe outcomes, never record payload lists. The first path segment must be the same before and after unescaping.
- An expired ID token cookie: does the next request get the 302 that expires the cookies and log in silently, and does the IDE reconnect (ADR 0005, amendments)? Is `eduide-authz` set, HttpOnly, Secure, SameSite Lax, 12 hours?
- A browser with many stale flow cookies: does Envoy reject its requests (`http2.too_many_headers`)? The `denyRedirect` rule should prevent the build-up.
- Can a session reach the cloud metadata address or node ports (SEC-07)? Can it reach the OIDC bridge, the service or authz pods?
- Can one user open another user's session by guessing the instance id? (Needs a second account; the id has 100 bits of randomness; expected: 403.)
- Rotate the user salt Secret: does everybody get signed out of open IDEs once (the `eduide-authz` cookie key changes)? Test environment only.
- Which Secrets in the namespace could the service read (SEC-15)?
- Do IDE responses leak the gateway login cookies to the IDE (the agent strips `eduide-id`, `eduide-authz`, `IdToken*`, `RefreshToken*` and others)? Needs a header-echo IDE image.
