# 03 Service API (API)

The REST service behind `$API` (`/api/v1`, spec `api/openapi/v1.yaml`). Unauthenticated checks run with curl from the shell. Authenticated checks run inside the landing page tab with `api(...)` and `sse(...)` from the README ("A user token for API tests"), so the token never leaves the browser; never on production.

Sources: `api/openapi/v1.yaml`, `internal/httpapi`, `internal/auth`, `internal/config/config.go`, ADR 0010 and 0012, design G14, G15, G18.

Facts the tests rely on:
- Operations: `GET /templates`, `GET|POST /sessions`, `GET|DELETE /sessions/{name}`, `GET /sessions/{name}/events` (SSE), `GET|POST /workspaces`, `DELETE /workspaces/{name}`, `GET /me/overview`, `GET /me/overview/events` (SSE). There is no admin API, no `performance` and no `setConfigValue` in v1.
- Every operation needs an OIDC bearer token of the deployment's realm. Errors are RFC 9457 Problem Details (`application/problem+json`) with a stable `code`: `unauthorized, forbidden, not-found, invalid-input, unknown-key, persistence-not-allowed, template-not-found, workspace-not-found, workspace-in-use, session-limit-reached, capacity-exhausted, start-failed, rate-limited, payload-too-large, internal`.
- `POST /sessions` is idempotent (G14): the key is template plus workspace, or template plus a hash of the launch data. `201` for a new session, `200` for the existing one. The body is `{template, persistence?, workspace?, data?, display?}`, additional properties are refused, `data` has at most 8 KiB.
- The service creates `IDESession` `s-<10 random [a-z0-9]>` with `spec.owner` from the token claim (`oidc.userClaim`), and Secret `<session>-data` (ownerReference to the session). Launch data is never in the session spec.
- The HTTP status of `session-limit-reached`, `rate-limited` and `capacity-exhausted` is not fixed by the contract: record the status the service uses (expected 429 for the first two).

### API-01 Public endpoint and error format
Safety: prod-safe
Steps: `curl -s -D - $API/templates -o /tmp/p.json`, `jq . /tmp/p.json`; `curl -s -o /dev/null -w '%{http_code}\n' $LANDING/config.json`; from inside the cluster or a port-forward: `curl -s http://127.0.0.1:19090/healthz` and `/readyz` (API-14).
Expect: 401 with `Content-Type: application/problem+json` and a body with `type`, `title`, `status` 401, `code` `unauthorized`; `config.json` 200. No stack trace, no internal host names in the body.

### API-02 Every operation refuses anonymous callers
Safety: prod-safe
Steps:
```bash
for r in "GET /templates" "GET /sessions" "POST /sessions" "GET /sessions/x" "DELETE /sessions/x" "GET /sessions/x/events" \
         "GET /workspaces" "POST /workspaces" "DELETE /workspaces/x" "GET /me/overview" "GET /me/overview/events"; do
  m=${r% *}; p=${r#* }
  printf '%s ' "$r"; curl -s -o /dev/null -w '%{http_code}\n' -X "$m" -H 'Content-Type: application/json' -d '{}' "$API$p"; done
curl -s -o /dev/null -w '%{http_code} garbage-bearer\n' -H 'Authorization: Bearer not.a.jwt' "$API/sessions"
curl -s -o /dev/null -w '%{http_code} wrong-scheme\n' -H 'Authorization: Basic eDp5' "$API/sessions"
```
Expect: 401 for all, also for a malformed token. Never 5xx, never 2xx.

### API-03 Launch a session without persistence
Safety: test-only
Needs: browser token.
Steps: `await api('POST','/sessions',{template:'<T_STD>'})`, then `k get idesession <name> -o yaml` and `k get secret <name>-data -o jsonpath='{.metadata.ownerReferences[0].kind}'`.
Expect: 201 and a Session with `phase` Pending or Starting, `template`, `createdAt`, no `workspace`. The IDESession is named `s-<10 chars>`, `spec.owner` is the user (check by hash: `k get idesession <name> -o jsonpath='{.metadata.labels.eduide\.github\.io/owner-hash}'` equals `OWNER_HASH "$ME"`), `spec.dataSecretRef` is `<name>-data`, the Secret exists with an ownerReference to the session, labels carry `app.kubernetes.io/managed-by=eduide`. The session reaches Ready, `url` is `https://$INSTANCE_HOST/<instance>/` and opens the IDE. No IDEWorkspace was created.
Cleanup: API-05.

### API-04 Launch with persistence and relaunch
Safety: test-only
Needs: browser token; a template that allows `volume`.
Steps:
1. `await api('POST','/sessions',{template:'<T_STD>',persistence:'volume'})`.
2. Note the workspace (`k get ideworkspaces --sort-by=.metadata.creationTimestamp | tail -1`) and repeat step 1 while the session runs, then repeat with `workspace:'<that workspace>'`.
3. Stop the session (API-05) and launch with the same `workspace`.
4. Launch with `workspace` of that workspace but a different `template`.
Expect: 1 creates workspace `w-<16 hex>` (deterministic, get-or-create) and a session with `workspaceRef`; the repeat in 2 returns 200 and the same session name (no second session); 3 creates a new session on the same workspace (`startStrategy cold`, also when the template has a pool); 4 is a 4xx Problem (record the code; `invalid-input` or `workspace-not-found` expected), no session is created.
Cleanup: API-05, API-06.

### API-05 Stop a session
Safety: test-only
Needs: browser token, a session from API-03 or API-04.
Steps: `await api('DELETE','/sessions/<name>')`, then again with the same name.
Expect: 204 the first time; the second call is 204 or a 404 Problem with `not-found` (record which, never a 5xx). The IDESession, its pod, Service, HTTPRoute, token Secret and data Secret are gone within a minute; the pod is always discarded, never reused; a persistent workspace and its PVC stay and its `status.lastUsed` moves (WS-09).

### API-06 Workspaces: list, create, delete
Safety: test-only
Needs: browser token.
Steps: `GET /workspaces`, `POST /workspaces {template, display:{title:'ft api'}}`, start a session on it, `DELETE /workspaces/<name>` (in use), stop the session, `DELETE` again, `DELETE` once more.
Expect: the list contains only the caller's workspaces; create returns 201 with phase Pending or Ready; deleting while a session runs returns 409 with `workspace-in-use`; after the session ended the delete returns 204 and the PVC disappears; the third delete is 404 `not-found`. The operator pod does not restart (`restartCount` unchanged).

### API-07 Owner checks
Safety: test-only
Needs: browser token; fixtures of another owner: `ft_workspace ft-api-ow "$T_STD" ft-other` and `ft_session ft-api-os "$T_STD" "" ft-other`.
Steps: `GET /sessions/ft-api-os`, `DELETE /sessions/ft-api-os`, `GET /sessions/ft-api-os/events`, `DELETE /workspaces/ft-api-ow`, then the same four calls for a name that does not exist (`ft-api-none`), then `GET /sessions` and `GET /workspaces`.
Expect: 403 `forbidden` (or 404 `not-found`) for the foreign objects, and exactly the same status and `code` as for the name that does not exist (no oracle for names); both fixtures still exist afterwards; the lists do not contain them.
Cleanup: `ft_cleanup`.

### API-08 Per-user session limit
Safety: test-only
Needs: browser token; `sessionsPerUser` from PLAT-08 (default 3), at most that many running sessions of the user.
Steps: launch distinct sessions until the user has `sessionsPerUser` (different `data`, for example `FT_PROBE` values on an `ft-` template that allows the key, so the launch keys differ); launch one more; then relaunch the first (same key).
Expect: the extra launch fails with `session-limit-reached` and a `sessions` array holding the running sessions (names, template, phase); the relaunch of an existing key still returns 200 with the existing session. Failed sessions do not count. The status code used is recorded.
Cleanup: stop all sessions of the test.

### API-09 Input validation
Safety: test-only
Needs: browser token; `ft-t2` from the README (adds the injectable keys `FT_PROBE` Token, optional `FT_URL` HTTPSURL).
Steps, each with `await api('POST','/sessions',...)`:
- `{template:'does-not-exist'}`
- `{template:'ft-t2', data:{NOT_ALLOWED:'x'}}`
- `{template:'ft-t2', data:{FT_PROBE:'a b'}}` (space) and a 70 character value (above `maxLength`)
- `{template:'ft-t2', persistence:'volume'}` with a template whose `persistence.allowed` is only `none`
- `{template:'ft-t2', workspace:'does-not-exist'}`
- `{template:'ft-t2', data:{FT_PROBE:'<9000 characters>'}}` (above 8 KiB)
- `{template:'ft-t2', unexpected:true}` and an empty body
Then `k logs deploy/$FULL-service --since=5m | grep -c -i -E 'panic|goroutine|stack'`.
Expect: 404 `template-not-found`; 400 `unknown-key`; 400 `invalid-input` twice; 400 or 409 `persistence-not-allowed`; 404 `workspace-not-found`; 413 `payload-too-large`; 400 `invalid-input` for both malformed bodies. Every error is a Problem with `code`, no session or Secret was created (`k get idesessions -l eduide.dev/functional-test` count unchanged), the service log has no stack trace (count 0), and the log never contains a request value.
Cleanup: `ft_cleanup`.

### API-10 Launch data goes through the allowlist only
Safety: test-only
Needs: browser token; templates with `injectableKeys` of each format. Create `ft-t3` with
```bash
ft_template "$T_STD" ft-t3 '.spec.injectableKeys=[
  {"name":"FT_URL","source":"Request","format":"HTTPSURL"},
  {"name":"FT_TOKEN","source":"Request","format":"Token","maxLength":32},
  {"name":"FT_ENUM","source":"Request","format":"Enum","values":["a","b"]},
  {"name":"FT_PAT","source":"Request","format":"Pattern","pattern":"^[a-z]{3}$"},
  {"name":"FT_USER_NAME","source":"UserName"}]'
```
Steps: launch with `FT_URL` = `http://github.com/x` (not https), `https://not-on-the-allowlist.example/x`, and `https://github.com/example-org/x.git` (a host from `allowedHosts`, PLAT-08); `FT_ENUM` = `c` and `a`; `FT_PAT` = `abcd` and `abc`; `FT_USER_NAME` sent in the request; fields `env`, `fromSecrets`, `fromConfigMaps` at the top level and inside `data`.
Expect: the first and second URL, `c`, `abcd`, the request-supplied `FT_USER_NAME` (source is the token, not the request) and the extra fields are refused with 400 (`invalid-input` or `unknown-key`); the valid combination returns 201. The data Secret `<session>-data` of the valid launch has exactly the keys the request sent plus `FT_USER_NAME` set by the service from the token (`k get secret <n>-data -o json | jq '.data|keys'`); nothing in the pod spec or the IDESession spec holds a value (SEC-14). There is no way to name a Secret or ConfigMap (the Bonn attack path does not exist).
Cleanup: stop the sessions, `ft_cleanup`.

### API-11 No admin API
Safety: prod-safe
Steps:
```bash
for p in /admin /admin/templates /sessions/../admin /performance /sessions/x/config; do
  curl -s -o /dev/null -w "%{http_code} $p\n" --path-as-is "$API$p"; done
curl -s -o /dev/null -w '%{http_code} header\n' -H 'X-Admin-Api-Token: x' "$API/admin/templates"
```
Expect: 401 or 404 for all (no route, never 2xx). v1 has no admin API; admin work is Helm or `kubectl` on the CRDs. The service has no environment toggle for it (`k get deploy $FULL-service -o yaml | grep -ci admin` is 0).

### API-13 CORS
Safety: prod-safe
Steps:
```bash
for o in "$LANDING" "https://evil.example.org"; do
  curl -s -o /dev/null -D - -X OPTIONS -H "Origin: $o" -H 'Access-Control-Request-Method: POST' \
    -H 'Access-Control-Request-Headers: authorization,content-type' "$API/sessions" | grep -i '^access-control-allow-origin' || echo "no ACAO for $o"; done
```
Expect: the foreign origin gets no `Access-Control-Allow-Origin`. The landing page and the API share one host, so the landing origin needs no CORS rule (`no ACAO` is also fine for it, as long as the page works). A wildcard `*` is a finding.

### API-14 Management port is internal only
Safety: prod-safe
Steps:
```bash
for p in /metrics /healthz /readyz; do curl -s -o /dev/null -w "%{http_code} $p\n" "$LANDING$p"; curl -s -o /dev/null -w "%{http_code} api$p\n" "$API$p"; done
k port-forward deploy/$FULL-service 19090:9090 >/dev/null 2>&1 & PF=$!; sleep 3
for p in /metrics /healthz /readyz; do curl -s -o /dev/null -w "%{http_code} $p\n" http://127.0.0.1:19090$p; done
curl -s http://127.0.0.1:19090/metrics | grep -c '^eduide_api_requests_total'
kill $PF
```
Expect: public paths 404 or 401, never metrics; through the port-forward `/metrics`, `/healthz`, `/readyz` are 200 and `eduide_api_requests_total` has series once any request was served. The OpenAPI document is not required to be public.

### API-15 Service configuration and secrets
Safety: prod-safe
Steps: `k get deploy $FULL-service -o jsonpath='{.spec.template.spec.containers[0].args}{"\n"}{.spec.template.spec.containers[0].env[*].name}{"\n"}{.spec.template.spec.volumes[*].name}'`; `k get cm $FULL-config -o json | jq -r '.data|keys[]'`.
Expect: the binary reads `--config` (default `/etc/eduide/config.yaml`) and `POD_NAMESPACE`; OIDC settings come from config.yaml only; secrets (if any) come from files or env references, never from args; `automountServiceAccountToken` is true only where the component needs the API (service, operator, authz need it; check each).

### API-16 Launch on another user's workspace
Safety: test-only
Needs: browser token; `ft_workspace ft-api-ow "$T_STD" ft-other`.
Steps: `await api('POST','/sessions',{template:'<T_STD>',workspace:'ft-api-ow'})`; `k get idesessions | grep ft-api-ow`; `k get ideworkspace ft-api-ow -o jsonpath='{.spec.owner} {.spec.templateRef}'`.
Expect: 403 `forbidden` or 404 `workspace-not-found` (the same answer as for a workspace that does not exist); no session on that workspace; the workspace's owner and template unchanged.
Cleanup: `ft_cleanup`.

### API-18 Service replica lost during a launch
Safety: test-only, disruptive
Needs: browser token; 2 service replicas.
Steps: start a launch and read its events with `sse('/sessions/<name>/events', 60)` in the page while `k delete pod <one service pod> --grace-period=0 --force`; also `k delete pod` of the pod that serves the stream (the one whose log mentions the launch).
Expect: the session still reaches Ready; exactly one IDESession per launch (`k get idesessions -l eduide.github.io/owner-hash=...`); a stream that breaks can be reopened and starts with the current state (API-19); the student sees no error page within the landing page's retry budget.
Cleanup: stop the session; `k rollout status deploy/$FULL-service`.

### API-19 Session events (SSE)
Safety: test-only
Needs: browser token.
Steps: launch (API-03), then at once `await sse('/sessions/<name>/events', 90)`; repeat `sse` after Ready; call it for a foreign session (`ft-api-os` of API-07) and for an unknown name.
Expect: `HTTP 200 text/event-stream`; the stream starts with the current state; each line `event: session` carries one Session (phase changes Pending, Starting, Ready, with `startStrategy`); comment lines `: ping` appear about every 15 s while nothing changes; after Ready or Failed the server sends the final event and closes (`closed by server`); a stream opened after Ready returns the Ready state once and closes. Foreign and unknown names give the same 403 or 404 Problem as API-07. The number of open streams does not grow after closing tabs (`eduide_api_requests_total` is unaffected; the service memory is stable, PERF-01).
Cleanup: API-05.

### API-20 Idempotent launch
Safety: test-only
Needs: browser token.
Steps:
1. `await api('POST','/sessions',{template:'<T_STD>'})` twice in a row.
2. Five parallel identical launches: `await Promise.all([1,2,3,4,5].map(() => api('POST','/sessions',{template:'<T_STD>'})))`.
3. The same with `data` that differs in one key (`FT_PROBE`).
Expect: 1: the first is 201, the second 200 with the same session `name`; 2: exactly one IDESession carries the launch-key label (`k get idesessions -l eduide.github.io/launch-key=<key>` count 1, key read from the new session), all five responses name that session (201 once, 200 four times); 3: a different launch key, a second session (counts towards the limit, API-08). `eduide_launch_total{result="created"}` rose by 2, `result="existing"` by 5 (MON-09).
Cleanup: stop the sessions.

### API-21 Overview endpoint
Safety: test-only
Needs: browser token; `FT_TITLE=... ft_workspace ft-ov-w "$T_STD" "$ME"`, `FT_SESSION_TITLE="ft ov" ft_session ft-ov-s "$T_STD" "" "$ME"`.
Steps: `await api('GET','/me/overview')`; stop the session; `await sse('/me/overview/events', 30)` while launching a session and stopping it.
Expect: `items` hold `kind` workspace (`running:false`, `lastUsed`, `expiresAt`, title from `display.title` or derived from `display.source`) and `kind` session (`running:true`, `session` object); items of other owners are absent; the SSE stream sends `event: overview` with a full Overview at the start and on every change, pings in between. A workspace with a running session is listed once as running.
Cleanup: `ft_cleanup`.

### API-22 Rate limit
Safety: test-only
Needs: browser token; `config.rateLimit.launchesPerMinute` (default 10).
Steps: send 15 identical `POST /sessions` within a few seconds (they are idempotent, so they create at most one session), then once after 60 s.
Expect: record whether repeated idempotent launches count. If they count: the calls above the limit return 429 with `rate-limited` and a `Retry-After` header, and the call after 60 s succeeds. If they do not count, repeat with launches that fail validation (`template-not-found`). The limit is per user: a second user is not affected (needs a second login, otherwise record `blocked` for that part).
Cleanup: stop the session.

### API-23 Template list matches the CRDs
Safety: prod-safe
Needs: browser token (read-only call).
Steps: `await api('GET','/templates')` and compare with `k get idetemplates -o json | jq '.items[] | {name:.metadata.name, persistence:.spec.persistence.allowed, default:.spec.persistence.default, keys:[.spec.injectableKeys[]?.name]}'` and `k get idepools -o jsonpath='{.items[*].spec.templateRef}'`.
Expect: one entry per template with `displayName`, `logoUrl`, `persistence`, `defaultPersistence`; `injectableKeys` lists names only (no values, no patterns); `warm` is true exactly for templates with an IDEPool; keys with source `UserName` or `UserEmail` are not offered to the client for input (or are marked, record which).

### API-24 Trace context is stored on the session
Safety: test-only
Needs: browser token.
Steps: `await api('POST','/sessions',{template:'<T_STD>'},{traceparent:'00-0123456789abcdef0123456789abcdef-0123456789abcdef-01'})`; `k get idesession <name> -o jsonpath='{.metadata.annotations}'`; a second launch (distinct data) with `traceparent: garbage`.
Expect: the annotation `eduide.github.io/traceparent` holds the given context; a malformed header is ignored or rejected with 400, never a 5xx and never stored unchecked. The trace id appears in Jaeger (MON-10).
Cleanup: stop the sessions.

## Explore

- Two launches of the same persistent workspace in the same second from two tabs: one session or two? Any 5xx?
- A very long `display.title`, markup and unicode in `display`; workspace names at the length limit (63).
- Stop a session while it is still Pending or Starting.
- SSE through the gateway: do idle streams survive more than 60 s and 5 minutes (proxy idle timeouts), and do they end when the token expires?
- `GET /sessions` with 100 sessions of one user: response time and size.
- Grep the service log for the Authorization header or JWT fragments (count only): `k logs deploy/$FULL-service --since=1h | grep -c -i -E 'bearer|eyJ'`.
- Launch data in error messages: send a `FT_PROBE` value with a recognisable dummy string that fails validation and grep the response and the log for it (count only).
