# 03 Service API (API)

The REST API of the service at `$LANDING/api/v1` (the landing page and the API share one host). Unauthenticated checks run with curl from the shell. Authenticated checks run inside the landing page tab with `api(...)` from the README ("A user token for service API tests"), so the token never leaves the browser; never on production.

Sources: control plane `api/openapi/v1.yaml`, `internal/httpapi/{launch,validate,problem,server,overview,admin*,public_status,events,starts}.go`, `internal/auth/auth.go`, ADR 0009, 0010, 0012, 0021; `docs/architecture/data-model.md`; chart `eduide-control-plane` templates `deployments.yaml`, `networkpolicy.yaml`.

Facts the tests rely on:
- Every endpoint except `GET /status` needs `Authorization: Bearer <access token of the realm>`. A missing or bad token is 401 with `WWW-Authenticate: Bearer`. The token's `azp` (else `aud`) must be one of `oidc.clientIDs`; the owner is the claim `oidc.userClaim` (`preferred_username`).
- Errors are RFC 9457 problem details (`application/problem+json`) with a stable `code`: `unauthorized` 401, `forbidden` 403, `not-found` 404, `invalid-input` 400, `unknown-key` 400, `persistence-not-allowed` 400, `template-not-found` 404, `workspace-not-found` 404, `workspace-lost` 409, `workspace-in-use` 409 (unused), `session-limit-reached` 409 (with a `sessions` list), `workspace-limit-reached` 409, `rate-limited` 429, `payload-too-large` 413, `internal` 500.
- Sessions and workspaces of other users are not found (404), never 403, so names do not leak. `/admin/*` answers 404 when the deployment has no `oidc.admin`, 403 without the role.
- `POST /sessions` is idempotent: key = owner + template + workspace, or for no persistence owner + template + a hash of the launch data. A repeat returns the existing active session with 200; a new session is 201. Session names are `s-<10 lowercase alphanumerics>`, workspace names `w-<16 hex>`.
- Launch body (`additionalProperties: false`, at most 64 KiB; `data` at most 8 KiB in total): `template`, `persistence` (`none` or `volume`), `workspace`, `data`, `display` (`title`, `source`). Keys in `data` must be in the template's `injectableKeys` with source `Request`.
- Launch rate limit per user (default 10 per minute); admin API limit 60 per minute; public status 100 per minute per client IP.
- Ports: API `:8080` (routed under `/api/` only), `/metrics` `/healthz` `/readyz` on `:9090` of the service pods (not routed).

### API-01 Public status
Safety: prod-safe
Steps: `curl -s -D - $LANDING/api/v1/status | head -40`, twice within 15 s.
Expect: 200, `application/json`, `Cache-Control: public, max-age=15`. Body fields only `overall` (`ok`, `slow` or `down`), `updatedAt`, `parts` (`signIn`, `starting`, `workspaces`) and `templates` (each `name`, `displayName`, `logoUrl` where a logo is configured (absent otherwise), `startEstimate`, `warm`). No user, hash, session, workspace, host, node, pool target or error text anywhere (`jq -r 'paths|map(tostring)|join(".")'` lists only these paths). `warm` is true exactly for templates whose pool has `idleReady > 0` (`k get idepools`). The second request inside 15 s returns the same `updatedAt`. `overall` is the worst of the three parts.

### API-02 Protected endpoints refuse anonymous callers
Safety: prod-safe
Steps:
```bash
for r in "GET /templates" "GET /sessions" "GET /workspaces" "GET /me/overview" "GET /templates/events" "DELETE /sessions/x" "DELETE /workspaces/x" "GET /admin/status" "GET /admin/config"; do
  set -- $r; curl -s -o /dev/null -w "%{http_code} $r\n" -X $1 "$LANDING/api/v1$2"; done
curl -s -o /dev/null -w '%{http_code} launch\n' -X POST -H 'Content-Type: application/json' -d '{"template":"none"}' "$LANDING/api/v1/sessions"
curl -s -o /dev/null -w '%{http_code} bad-token\n' -H 'Authorization: Bearer x' "$LANDING/api/v1/templates"
curl -s -o /dev/null -w '%{http_code} unknown\n' "$LANDING/api/v1/nothing"
```
Expect: 401 for every protected request, including the admin ones (the token check comes before the role check) and the bad token; 404 for the unknown path. The 401 body is a problem document with `code: unauthorized`.

### API-03 Launch a session without persistence and watch it
Safety: test-only
Needs: browser token.
Steps:
1. `await api('GET','/templates')`: check the list.
2. `await api('POST','/sessions',{template:'<TPL_STD>',persistence:'none'})`.
3. Read the events from the page: `const r = await fetch('/api/v1/sessions/<name>/events',{headers:{Authorization:'Bearer '+sessionStorage.getItem('ft.tok'),Accept:'text/event-stream'}}); const t=await r.text(); t.split('\n\n').map(b=>b.slice(0,160))` (the stream closes after `Ready` or `Failed`; print phases only).
4. `await api('GET','/sessions/<name>')` and `await api('GET','/sessions')`.
Expect: step 1 returns every template with `name`, `displayName`, `listed`, `persistence`, `defaultPersistence`, `injectableKeys` (the keys of `k get idetemplate <n> -o jsonpath='{.spec.injectableKeys[*].name}'`), plus `warm`, `imageVersion`, `variants`, `includes`, `startEstimate` where known. Step 2 is 201 with a session `s-...`, `template`, `phase` (`Pending` or `Starting`), `createdAt`, no `workspace`. Step 3: an initial event with the current state, then `session` events up to `phase: Ready` with `url` (`https://instance.$ENV/<instance>/`) and `startStrategy` (`warm-ready` for a template with a pool and a free instance, else `cold`); `: ping` comments every 15 s. Step 4: `stopsAt` is the earlier of last activity (else ready time) plus the idle timeout and creation plus the maximum, `stopReason` is `idle` or `max`; the list holds only the caller's sessions. `k get idesession <name>` shows the session without `workspaceRef` and with `dataSecretRef`.
Cleanup: API-05.

### API-04 Launch with persistence and relaunch
Safety: test-only
Needs: browser token; a template that allows `volume` (the chart default allows `none` and `volume`).
Steps:
1. `await api('POST','/sessions',{template:'<TPL_STD>',persistence:'volume'})`.
2. Note the workspace (`await api('GET','/workspaces')`) and repeat step 1.
3. `await api('POST','/sessions',{template:'<TPL_STD>',workspace:'<that workspace>'})`.
4. `await api('POST','/sessions',{template:'<another template>',workspace:'<that workspace>'})`.
Expect: 1 is 201 and creates a workspace `w-...` (phase `Pending`, then `Ready`) and a session with `workspace` set and `startStrategy: cold`; 2 and 3 are 200 with the same session name (idempotent, no second session); 4 is 400 `invalid-input` ("workspace belongs to another template"). `k get idesession <name> -o jsonpath='{.metadata.ownerReferences[0].kind}'` is `IDEWorkspace`, and a PVC with the workspace's name exists once the workspace is `Ready`.
Cleanup: API-05, API-06.

### API-05 Stop a session
Safety: test-only
Needs: browser token, a session from API-03 or API-04.
Steps: `await api('DELETE','/sessions/<name>')`, then again with the same name; `await api('DELETE','/sessions/does-not-exist')`.
Expect: the first call is 204; the session, its pod, service, route and token Secret are gone within a minute (`k get idesession,pod,svc,httproute | grep <instance>`); a persistent workspace and its PVC stay (`lastUsed` is updated). The repeat and the unknown name are 404 `not-found`.

### API-06 Workspaces: list, create, delete
Safety: test-only
Needs: browser token.
Steps: `GET /workspaces`; `POST /workspaces` with `{template:'<TPL_STD>',display:{title:'ft-ws'}}` twice; `POST /workspaces` with `{template:'does-not-exist'}`; start a session on the workspace (API-04 step 3), then `DELETE /workspaces/<name>`; `DELETE` again.
Expect: the list holds only the caller's workspaces with `phase`, `lastUsed`, `expiresAt`, `deletesAt`; the two creates return the same workspace (get-or-create, both 201); the unknown template is 404 `template-not-found`; a template that allows only `none` is 400 `persistence-not-allowed`. The delete stops the running session first (waits at most 30 s), then removes the workspace: 204, the PVC disappears, the operator does not restart (`restartCount` unchanged). The second delete is 404.

### API-07 Owner checks
Safety: test-only
Needs: browser token; fixtures of another owner: `ft_workspace ft-api-other-ws <TPL_STD> ft-other` and `ft_session ft-api-other <TPL_STD> "" ft-other`.
Steps:
1. `DELETE /sessions/ft-api-other`, `GET /sessions/ft-api-other`, `GET /sessions/ft-api-other/events`.
2. `DELETE /workspaces/ft-api-other-ws`.
3. `GET /sessions` and `GET /workspaces`.
Expect: 404 `not-found` or `workspace-not-found` for 1 and 2 (names of others are never confirmed), both objects still exist afterwards (`k get idesession,ideworkspace | grep ft-api-other`), neither list shows them.
Cleanup: `ft_cleanup`.

### API-08 Per-user session limit
Safety: test-only
Needs: browser token; `ME` set (README); the limit N from the config (`sessionsPerUser`, 3 by default, 10 on production and Bonn).
Steps: fill the limit with fixture sessions owned by the token user (`ft_session ft-api-lim-1 <TPL_STD> "" "$ME"` and so on up to N, do not wait for Ready), then `POST /sessions` for a new launch; then relaunch one of the running launches (same body).
Expect: the new launch is 409 `session-limit-reached`, the problem body lists the running sessions in `sessions` (name, template, phase, url), `k get idesessions` shows no extra session. The idempotent repeat of an existing launch still returns 200 (it needs no new slot). Failed and deleting sessions do not count. No restart or config change is needed.
Cleanup: `ft_cleanup`.

### API-09 Input validation
Safety: test-only
Needs: browser token.
Steps (one request each; read `status` and `code` only):
1. `{template:'does-not-exist'}`.
2. `{}`, `{template:''}`, a template name of 64 characters, `{template:'<TPL_STD>',persistence:'snapshot'}`, `{template:'<TPL_STD>',unknown:1}`, a body that is not JSON, a body with trailing text.
3. `{template:'<TPL_STD>',data:{NOPE:'x'}}`, `{template:'<TPL_STD>',data:{GIT_USER:'x'}}`.
4. `{template:'<TPL_STD>',data:{TEMPLATE:'not-a-variant'}}`, `{template:'<TPL_STD>',data:{GIT_URI:'http://github.com/x/y.git'}}`, a `GIT_URI` on a host outside `allowedHosts`.
5. A `data` object over 8 KiB, a body over 64 KiB.
6. `{template:'<TPL_STD>',workspace:'x',persistence:'none'}`.
Expect: 1 is 404 `template-not-found`; 2 is 400 `invalid-input`; 3 is 400 `unknown-key` (also for `GIT_USER`: keys from the token are not accepted from the request); 4 is 400 `invalid-input` (the detail names the key and the rule, never the value: "host is not allowed" for the host case); 5 is 413 `payload-too-large`; 6 is 400 `invalid-input` ("workspace needs persistence volume"). No request creates an IDESession or Secret (`k get idesessions | grep -c .` unchanged). Service log lines for these requests (`k logs deploy/$P-service --since=5m | grep '"launch"'`) show `result: rejected` and a `code`, no data values, and 4xx are info level, not error.

### API-11 Admin API needs the role
Safety: prod-safe (anonymous part); test-only for the token part
Steps:
1. Anonymous: API-02 (401).
2. With a token of a user without the admin role: `GET /admin/status`.
3. In the config (`k get cm $P-config -o jsonpath='{.data.config\.yaml}' | yq .oidc.admin`): note whether `oidc.admin` is set.
Expect: 401 anonymous; 403 for a user without the role; 404 on a deployment without `oidc.admin` (the admin API is off there). Record which of the cases the environment shows. A token of another client of the realm is refused even with the role (needs a second client; record `blocked` if none).

### API-13 No cross-origin access
Safety: prod-safe
Steps:
```bash
for o in "$LANDING" "https://evil.example.org"; do
  curl -s -o /dev/null -D - -X OPTIONS -H "Origin: $o" -H 'Access-Control-Request-Method: POST' \
    -H 'Access-Control-Request-Headers: authorization,content-type' "$LANDING/api/v1/sessions" | grep -i -E '^(HTTP|access-control)'; done
```
Expect: 405 for both and no `Access-Control-Allow-Origin` (the landing page and the API share one origin, so no CORS is needed). A permissive answer for the foreign origin is a finding.

### API-14 Management ports are internal only
Safety: prod-safe
Steps:
```bash
for p in /metrics /healthz /readyz /api/metrics /api/v1/../metrics; do curl -s --path-as-is "$LANDING$p" | head -c 80 | tr '\n' ' '; echo " $p"; done
k port-forward deploy/$P-service 19090:9090 >/dev/null 2>&1 & PF=$!; sleep 3
curl -s -o /dev/null -w '%{http_code} metrics\n' http://127.0.0.1:19090/metrics
curl -s http://127.0.0.1:19090/metrics | grep -c '^eduide_api_requests_total'
kill $PF
```
Expect: `/metrics` and `/readyz` return the landing page, `/healthz` the landing server's own `ok`, and `/api/metrics` and `/api/v1/../metrics` the API's JSON 404 problem (`not-found`); never Prometheus text (`# HELP`); the API host routes only `/api/` to the service. Through the port-forward `/metrics` is 200 and contains `eduide_api_requests_total` once a request was served (names in `docs/contracts/metrics.md`). The port-forward is the only way in; the NetworkPolicy `$P-service` admits port 8080 from Envoy only and 9090 from the monitoring namespace.

### API-15 Service configuration
Safety: prod-safe
Steps: `k get deploy $P-service -o jsonpath='{.spec.template.spec.containers[0].args}{"\n"}{.spec.template.spec.containers[0].env[*].name}{"\n"}'`; `k get cm $P-config -o jsonpath='{.data.config\.yaml}' | yq '.oidc | keys'`; `k get secret $P-user-salt -o json | jq -r '.data | keys[]'` (key names only).
Expect: the service gets `--config /etc/eduide/config.yaml`, `LOG_LEVEL` and `POD_NAMESPACE`; the OIDC settings name an issuer, `clientIDs` and a gateway client; the user salt Secret exists (the admin API needs it, and so does the authz cookie). No secret value is printed. The service has 2 replicas and a PodDisruptionBudget.

### API-16 Launch on another user's workspace name
Safety: test-only
Needs: browser token; `ft_workspace ft-api-other-ws <TPL_STD> ft-other`.
Steps: `POST /sessions` with `{template:'<TPL_STD>',workspace:'ft-api-other-ws'}`; `k get idesessions | grep -c ft-api-other-ws`; `k get ideworkspace ft-api-other-ws -o jsonpath='{.spec.owner} {.spec.templateRef}'`.
Expect: 404 `workspace-not-found`; no session on that workspace; owner and template unchanged.
Cleanup: `ft_cleanup`.

### API-18 Service pod lost during a launch
Safety: test-only, disruptive
Needs: logged in on the landing page; the service has 2 replicas.
Steps: install a hook that records status and duration of `POST /api/v1/sessions` (like the token hook in the README; never the headers); click a tile; immediately `k delete pod -l app.kubernetes.io/component=service`; wait for the IDE or an error; stop the session; repeat with `k delete pod -l app.kubernetes.io/component=service --grace-period=0 --force`.
Expect: the student reaches the IDE without an error page; exactly one IDESession per launch (the launch key makes a repeat harmless); the landing page keeps working (the PodDisruptionBudget does not stop a plain delete, but never delete both pods at once in a way that leaves no service for more than a few seconds). Record any 5xx and the time the page needed.
Cleanup: stop the launched sessions; `k rollout status deploy/$P-service`.

### API-19 Launch data allowlist
Safety: test-only
Needs: browser token; a template that lists `GIT_URI` (all chart templates do).
Steps:
1. `POST /sessions` with `{template:'<TPL_STD>',data:{GIT_URI:'https://github.com/<small public repo>.git'}}` (an `allowedHosts` host; record the repository).
2. `k get secret <session>-data -o json | jq -r '.data | keys[]'`; `k get idesession <session> -o json | jq '.spec'`.
3. `k logs deploy/$P-service --since=2m | grep -c '<the repository path>'`.
Expect: 201. The Secret holds the request keys plus the keys from the token (`GIT_USER`, `GIT_MAIL` where the token has name and email), names only; the Secret is owned by the session and labelled `managed-by=eduide`. The session spec holds `display.source` (the URL without user info) but no data value. No log line of the service or operator contains a data value or the token (counts only). A `GIT_URI` with user info is accepted only for templates with `allowCredentials: true` (test2 sets it for all templates, `gitUriAllowCredentials`), and then `display.source` has no user info.
Cleanup: API-05.

### API-20 Admin API with the role
Safety: test-only
Needs: browser token of a user with the admin role.
Steps: `GET` `/admin/status`, `/admin/pools`, `/admin/sessions`, `/admin/sessions/<name>`, `/admin/workspaces`, `/admin/problems`, `/admin/templates`, `/admin/config`; `GET /admin/sessions?limit=1` and follow `cursor`.
Expect: 200 for all. Users appear only as `ownerHash`, never as a name or e-mail; user names in titles are replaced by `***`; launch data appears only as key names in the detail of one session; `/admin/config` holds no secret and no token. Lists are ordered by name, paged with an opaque `cursor`. `stats` and `nodePools` appear only where `admin.prometheusURL` is set and answers. `status.warnings` can hold `pool-empty`, `capacity-pressure` and `scaler-silent`. Only GET exists: `POST /admin/sessions` is 405 or 404. After 60 requests inside a minute the answer is 429 `rate-limited`.

### API-21 Launch rate limit
Safety: test-only
Needs: browser token.
Steps: send 15 launches in a loop inside one minute with `{template:'does-not-exist'}` (they are rejected and create nothing): `for(let i=0;i<15;i++) out.push((await api('POST','/sessions',{template:'does-not-exist'})).status)`.
Expect: the first requests are 404 `template-not-found`, then 429 `rate-limited` once the per-user budget (default 10 per minute) is used up; after a minute launches work again. `eduide_launch_total{result="rejected"}` counts the rejected ones.

### API-22 Overview and event streams
Safety: test-only
Needs: browser token; one running session and one saved workspace without a running session of the test user.
Steps: `GET /me/overview`; open `/me/overview/events` and `/templates/events` for 20 s (read the first event and the comments only).
Expect: the overview lists the running session (`kind: session`, `running: true`, `stopsAt`) and the workspace (`kind: workspace`, `running: false`, `expiresAt`, `deletesAt`), merged with `title` from `display.title` or derived from `display.source`; the streams start with the current state, send at most one event per 5 s and a `: ping` every 15 s, and end when the client leaves (`k logs deploy/$P-service | grep 'stream close'`).

## Unverified, check in the first run

- API-04 step 4 and API-06 `persistence-not-allowed` come from `launch.go`; the answers were not observed. A template that allows only `none` has to be created (`ft_template <TPL_STD> ft-api-none '{"persistence":{"allowed":["none"],"default":"none"}}'`).
- API-18: the effect of deleting one of two service pods on an open launch (SSE stream) is not observed.
- API-20: exact response shapes and the `403`/`404` of the admin API on environments without `oidc.admin`; the paging parameter names (`cursor`, `limit`) come from ADR 0021.
- API-03 step 3: that the page context may read the event stream with `fetch` and the stored token (the CSP allows `connect-src 'self'`).
- API-21: the exact budget and refill (`rateLimit.launchesPerMinute`, default 10; an empty `rateLimit: {}` is configured on test2).
- API-01: that `warm` follows `idleReady` immediately (the answer is cached for 15 s).

## Retired

- API-10 Reserved env keys are dropped: 2026-11-24, a request carries no environment; only allowlisted launch data goes into a Secret (API-19, API-09, SEC-10).
- API-12 Admin API switched on: 2026-11-24, there is no toggle and no admin token Secret; access is a Keycloak role (API-11, API-20).
- API-17 Timed-out launch leaves nothing running: 2026-11-24, the request has no `timeout` field; the start limit is the operator's (OPR-06).
- The Java service codes (470 to 475, 480, 481, 520, 551 to 554, 580) and the `appId` body field no longer exist; the Go codes are listed above.

## Explore

- Two launches of the same workspace in the same second from two tabs: one session or two? Any 5xx? (The service locks per owner and the session name derives from the launch key.)
- Launch with `display.title` and `display.source` at the length limits (200, 2048), with markup, with a query or fragment in `source` (refused).
- `POST /workspaces` and `DELETE /workspaces/<name>` while the workspace has a session in `Starting`.
- Delete a session while it is still starting (`Pending`, `Starting`).
- Grep the service log for the Authorization header or JWT fragments (count only): `k logs deploy/$P-service --since=1h | grep -c -i -E 'bearer|eyJ'`.
- The `traceparent` header on `POST /sessions` (55 characters at most): is the launch trace linked?
- An access token with the right signature but another `azp`; an ID token instead of the access token.
