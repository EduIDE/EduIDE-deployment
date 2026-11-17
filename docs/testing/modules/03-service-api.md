# 03 Service API (API)

The REST service behind `$SERVICE/service`. Unauthenticated checks run with curl from the shell. Authenticated checks run inside the landing page tab with `api(...)` from the README ("A user token for service API tests"), so the token never leaves the browser; never on production.

Sources: EduIDE-Cloud `java/service/.../service/{RootResource,SessionResource,WorkspaceResource,AppDefinitionResource,AppDefinitionAdminResource,BaseResource,AppDefinitionAdminApiTokenFilter,ApplicationProperties}.java`, `java/common/.../util/{TheiaCloudError,WorkspaceUtil}.java`, `java/service/.../resources/application.properties`, `dockerfiles/service/Dockerfile`; EduIDE-Helm `charts/eduide/templates/{service,service-configmap,httproute-service}.yaml`.

Facts the tests rely on:
- Every request body carries `appId` (the public service auth token, `$APPID`) and `kind`. Missing body or wrong `appId`: **470**.
- Custom codes: 470 invalid app id, 471 invalid workspace name, 473 invalid app definition, 474 invalid session name, 475 workspace belongs to another app definition, 480/481 missing workspace/session name, 520 workspace launch timeout, 551 session launch timeout, 552 max instances reached, 553 per-user session limit, 554 no sessions allowed, 580 config store unavailable.
- Someone else's session or workspace: plain **403**. A body `user` that differs from the token's `email` claim: 403. No token on a protected endpoint: 401.
- Ephemeral session names: `eph-<app>-<user>-<16 hex>-session`. Persistent workspaces: `ws-...`; `eph-` workspace names are reserved (471).
- Public port 8081 is routed only under `/service`. Port 9000 (management) serves `/q/metrics` and the OpenAPI document and is not routed.
- `PATCH /service/session` was removed in Cloud 3.0.0.

### API-01 Ping
Safety: prod-safe
Steps: `curl -s -w ' %{http_code}\n' $SERVICE/service/$APPID` and `curl -s -o /dev/null -w '%{http_code}\n' $SERVICE/service/wrong-token`
Expect: `true 200`; `470`.

### API-02 Protected endpoints refuse anonymous callers
Safety: prod-safe
Steps:
```bash
curl -s -o /dev/null -w '%{http_code} list\n' "$SERVICE/service/session/$APPID/someone@example.org"
curl -s -o /dev/null -w '%{http_code} appdefs\n' "$SERVICE/service/appdefinition/$APPID"
curl -s -o /dev/null -w '%{http_code} launch\n' -X POST -H 'Content-Type: application/json' \
  -d "{\"kind\":\"launchRequest\",\"appId\":\"$APPID\",\"appDefinition\":\"none\",\"ephemeral\":true}" "$SERVICE/service"
curl -s -o /dev/null -w '%{http_code} patch-session\n' -X PATCH -H 'Content-Type: application/json' -d '{}' "$SERVICE/service/session"
```
Expect: 401 for the first three on any environment with Keycloak enabled (all on main). `PATCH /service/session` returns 405 or 404, never 2xx.

### API-03 Launch an ephemeral session
Safety: test-only
Needs: browser token.
Steps: `await api('POST','/service',{kind:'launchRequest',appId:theiaCloudConfig.serviceAuthToken,appDefinition:'<APP_STD>',ephemeral:true,env:{fromMap:{THEIA:'true'}}})`
Expect: 200 with a URL under `instance.$ENV`. `k get sessions` shows `eph-<app>-<user>-<16 hex>-session`, no new Workspace. The URL opens the IDE.
Cleanup: API-05.

### API-04 Launch a persistent session and relaunch it
Safety: test-only
Needs: browser token.
Steps:
1. `await api('POST','/service',{kind:'launchRequest',appId:theiaCloudConfig.serviceAuthToken,appDefinition:'<APP_STD>',ephemeral:false,env:{fromMap:{THEIA:'true'}}})`
2. Note the Workspace (`k get workspaces --sort-by=.metadata.creationTimestamp | tail -1`) and repeat with `workspaceName:'<that workspace>'`.
3. Repeat with the same workspace and a different `appDefinition`.
Expect: 1 creates `ws-...` and `<workspace>-session`; 2 returns the URL of the same running session (no second session); 3 returns **475**.
Cleanup: API-05, API-06.

### API-05 Stop a session
Safety: test-only
Needs: browser token, a session from API-03 or API-04.
Steps: `await api('DELETE','/service/session',{kind:'sessionStopRequest',appId:theiaCloudConfig.serviceAuthToken,sessionName:'<name>'})`, then again with the same name.
Expect: 200 `true` both times (a missing session counts as stopped); the Session CR and its pod are gone within a minute; a persistent workspace and its PVC stay.

### API-06 Workspaces: list, create, delete
Safety: test-only
Needs: browser token.
Steps: list (`GET /service/workspace/<appId>/<user>`), create (`POST /service/workspace`, `kind:'workspaceCreationRequest'`, `appDefinition`, `label`), delete (`DELETE /service/workspace`, `kind:'workspaceDeletionRequest'`, `workspaceName`), delete again, delete with no `workspaceName`.
Expect: list contains only the caller's workspaces; delete returns `true` twice; missing name returns **480**. The PVC disappears and the operator does not restart (`restartCount` of the operator pod unchanged, rc.1 finding 1).

### API-07 Owner checks
Safety: test-only
Needs: browser token; a fixture session and workspace of another user: `ft_workspace ft-api-other-ws <APP_STD> ft-other@functional-test.invalid` and `ft_session ft-api-other <APP_STD> "" ft-other@functional-test.invalid`.
Steps:
1. `DELETE /service/session` with `sessionName:'ft-api-other'`.
2. `DELETE /service/workspace` with `workspaceName:'ft-api-other-ws'`.
3. `POST /service/session/ft-api-other/config` with `{kind:'sessionSetConfigValueRequest', appId, key:'x', value:'y'}`.
4. `GET /service/session/performance/<appId>/ft-api-other`.
5. `GET /service/session/<appId>/ft-other@functional-test.invalid` and a launch with `user:'ft-other@functional-test.invalid'` in the body.
Expect: 403 for 1 to 4, both objects still exist afterwards; 5 is 403 (body user differs from the token user).
Cleanup: `ft_cleanup`.

### API-08 Per-user session limit (553)
Safety: test-only, disruptive (restarts the service)
Needs: browser token.
Steps:
1. Record the current value: `k get cm -o yaml | grep SESSIONS_PER_USER` (TUM `_base.yaml` sets 10, the chart default is 1).
2. `k set env deploy/service-deployment SESSIONS_PER_USER=1` and wait for the rollout.
3. Launch app A ephemeral (200), then app B ephemeral, then relaunch A.
Expect: B returns **553**; relaunching A (same session name) still returns 200. Sessions in error state do not count.
Cleanup: stop both sessions; `k set env deploy/service-deployment SESSIONS_PER_USER-` and wait for the rollout.

### API-09 Input validation
Safety: test-only
Needs: browser token.
Steps: launch with `appDefinition:'does-not-exist'`; start a session on `workspaceName:'eph-anything'` (`POST /service/session`, `kind:'sessionStartRequest'`); stop with an empty body; then `k logs deploy/service-deployment --since=5m | grep -c -A3 'Failed to launch session'`.
Expect: 473; 471; 470 (no body or missing appId). The service log has no stack trace for any of them (Cloud 3.0.1 logs 47x and 403 at ERROR with stack traces: record `fail`). A launch with a `workspaceName` that does not exist is not an error: `RootResource.launch` creates that workspace (200); the ownership case is API-16.

### API-10 Reserved env keys are dropped
Safety: test-only
Needs: browser token.
Steps: launch ephemeral with `env:{fromMap:{THEIA:'true', DATA_BRIDGE_TOKEN:'x', SCORPIO_THEIA_ENV_STRATEGY:'x', LD_PRELOAD:'x', FT_HARMLESS:'1'}}`; then inspect the pod spec env names only: `k get pod -l theia-cloud.io/session=<name> -o jsonpath='{range .spec.containers[*].env[*]}{.name}{"\n"}{end}' | sort | uniq -c`
Expect: `DATA_BRIDGE_TOKEN` exists only as a `secretKeyRef` (never a literal value), `LD_PRELOAD` absent, `SCORPIO_THEIA_ENV_STRATEGY` has the operator's value (check with `-o jsonpath` on that one variable, it is not secret). `FT_HARMLESS` present (operator `--allowCustomEnvFromMap`, chart default true). `fromSecrets`/`fromConfigMaps` names that are not in the operator allowlist are ignored.
Cleanup: API-05.

### API-11 Admin API off by default
Safety: prod-safe
Steps:
```bash
curl -s -o /dev/null -w '%{http_code}\n' "$SERVICE/service/admin/appdefinition"
curl -s -o /dev/null -w '%{http_code}\n' -H 'X-Admin-Api-Token: wrong' "$SERVICE/service/admin/appdefinition"
k get deploy service-deployment -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="THEIA_CLOUD_ADMIN_API_ENABLED")].value}'
```
Expect: with `service.adminApiEnabled` false (chart default; from Cloud 3.0.1): 404 for both, whatever the token. Record the env value.

### API-12 Admin API switched on
Safety: test-only, disruptive (restarts the service)
Needs: the admin token Secret exists (`k get secret service-admin-api-token`; `_base.yaml` sets `adminApiTokenSecret.create: true`).
Steps:
1. Record the env value from API-11, then `k set env deploy/service-deployment THEIA_CLOUD_ADMIN_API_ENABLED=true` and wait for the rollout.
2. Read the token without printing it: `ADM=$(k get secret service-admin-api-token -o jsonpath='{.data.ADMIN_API_TOKEN}' | base64 -d)`
3. Requests:
```bash
curl -s -o /dev/null -w '%{http_code} no-header\n' "$SERVICE/service/admin/appdefinition"
curl -s -o /dev/null -w '%{http_code} wrong\n' -H 'X-Admin-Api-Token: wrong' "$SERVICE/service/admin/appdefinition"
curl -s -w ' %{http_code} list\n' -H "X-Admin-Api-Token: $ADM" "$SERVICE/service/admin/appdefinition" | tail -c 300
curl -s -o /dev/null -w '%{http_code} min>max\n' -X PATCH -H "X-Admin-Api-Token: $ADM" -H 'Content-Type: application/json' \
  -d '{"minInstances":5,"maxInstances":1}' "$SERVICE/service/admin/appdefinition/<ft appdef>"
curl -s -o /dev/null -w '%{http_code} unknown\n' -H "X-Admin-Api-Token: $ADM" "$SERVICE/service/admin/appdefinition/does-not-exist"
curl -s -o /dev/null -w '%{http_code} patch\n' -X PATCH -H "X-Admin-Api-Token: $ADM" -H 'Content-Type: application/json' \
  -d '{"minInstances":1}' "$SERVICE/service/admin/appdefinition/<ft appdef>"
unset ADM
```
Expect: 401, 403, 200, 400, 404, 200; the fixture's `spec.minInstances` is 1 afterwards. Use only an `ft-` AppDefinition for PATCH.
Cleanup: set `THEIA_CLOUD_ADMIN_API_ENABLED` back to the recorded value, wait for the rollout, re-run API-11.

### API-13 CORS
Safety: prod-safe
Steps:
```bash
for o in "$LANDING" "https://evil.example.org"; do
  curl -s -o /dev/null -D - -X OPTIONS -H "Origin: $o" -H 'Access-Control-Request-Method: POST' \
    -H 'Access-Control-Request-Headers: authorization,content-type' "$SERVICE/service" | grep -i '^access-control-allow-origin' || echo "no ACAO for $o"; done
```
Expect: the landing origin is echoed back; the foreign origin gets no `Access-Control-Allow-Origin`. (The chart always prepends the landing origin to `service.corsOrigins`.)

### API-14 Management port is internal only
Safety: prod-safe
Steps:
```bash
for p in /q/metrics /q/openapi /q/health /service/../q/metrics; do curl -s -o /dev/null -w "%{http_code} $p\n" --path-as-is "$SERVICE$p"; done
k port-forward deploy/service-deployment 19000:9000 >/dev/null 2>&1 & PF=$!; sleep 3
curl -s -o /dev/null -w '%{http_code} metrics\n' http://127.0.0.1:19000/q/metrics
curl -s http://127.0.0.1:19000/q/openapi | head -5
kill $PF
```
Expect: all public paths 404 (only `/service` is routed). Through the port-forward `/q/metrics` is 200 and the OpenAPI document is served. After at least one launch since the last service restart, the metrics contain the session startup timer (`application_application_theiacloud_session_startup_seconds_seconds...`).

### API-15 Service needs its auth token
Safety: prod-safe
Steps: the service gets its env through `envFrom`: `k get deploy service-deployment -o jsonpath='{.spec.template.spec.containers[0].envFrom}'`, then key names only: `k get cm service-config -o json | jq -r '.data|keys[]'` and `k get secret service-config-secret -o json | jq -r '.data|keys[]'`. Read `KEYCLOAK_ENABLE` from the ConfigMap; never print Secret values.
Expect: the service auth token is configured (the service refuses to start without one since Cloud 3.0.0); Keycloak is enabled; record whether an audience is set.

### API-16 Launch on another user's workspace name
Safety: test-only
Needs: browser token; `ft_workspace ft-api-other-ws <APP_STD> ft-other@functional-test.invalid`.
Steps: `await api('POST','/service',{kind:'launchRequest',appId:theiaCloudConfig.serviceAuthToken,appDefinition:'<APP_STD>',workspaceName:'ft-api-other-ws',ephemeral:false,env:{fromMap:{THEIA:'true',FT_PROBE:'1'}}})`; `k get sessions | grep ft-api-other-ws`; `k get workspace ft-api-other-ws -o jsonpath='{.spec.user} {.spec.appDefinition}'`.
Expect: 403; no session `ft-api-other-ws-session`; the Workspace's user and appDefinition unchanged.
Cleanup: `ft_cleanup`.

### API-17 Timed-out launch leaves nothing running
Safety: test-only
Needs: browser token.
Steps: launch `<APP_STD>` ephemeral with `timeout:0`; after 60 s `k get sessions` for the test account's sessions of that app.
Expect (target): 551 and no running session of that app for the user. Cloud 3.0.1: the session keeps starting and runs until the idle timeout; record `fail`.
Cleanup: API-05.

### API-18 Service pod lost during a launch
Safety: test-only, disruptive
Needs: logged in on the landing page.
Steps: install an XHR hook that records status and duration of `POST /service` (like the token hook in the README, never the headers); click a tile; immediately `k delete pod -l app=service`; wait for the IDE or an error; stop the session; repeat with `k delete pod -l app=service --grace-period=0 --force`.
Expect: graceful delete: the in-flight launch completes. Force delete: the student reaches the IDE without an error page within the landing page's retry budget; exactly one Session per launch. Chart 3.0.0-rc.3: the request hangs 60 s before the retry succeeds; record it.
Cleanup: stop the launched sessions; `k rollout status deploy/service-deployment`.

## Explore

- Two launches of the same persistent workspace in the same second: one session or two? Any 5xx?
- Launch with `timeout` values 1 and very large (0 is API-17).
- `POST /service/workspace` with an unknown `appDefinition`, `POST /service` with an unknown `kind`.
- Very long `label`, unicode in `label`, workspace names at the length limit.
- Stop a session while it is still starting (`operatorStatus` HANDLING).
- `POST /service/session/{session}/config` on a session with no config store: 580 and a useful message?
- Does `GET /service/appdefinition/{appId}` list apps hidden from the landing page, and should it?
- With the admin API on: PATCH `maxInstances` below the number of running sessions; PATCH `{}`, negative values, strings.
- Grep the service log for the Authorization header or JWT fragments (count only): `k logs deploy/service-deployment --since=1h | grep -c -i -E 'bearer|eyJ'`.
