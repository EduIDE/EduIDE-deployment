# 06 Data bridge (DB)

Server module. The data bridge is a VS Code extension inside the IDE container. It listens on port 16281 (`DATA_BRIDGE_PORT`) when `DATA_BRIDGE_ENABLED` is `1` or `true`. The operator injects the session's env (`THEIA=1`, `GIT_URI`, `TEMPLATE`, `ARTEMIS_*`, ...) with `POST /data` and a Bearer token from a Secret. Since Cloud 3.0.1 this happens for eager (pool) and lazy sessions alike.

Sources: EduIDE-data-bridge `src/app.ts`, `src/schema.ts`, `src/service/data.ts`, `README.md`; EduIDE-Cloud `java/operator/.../databridge/{AsyncDataInjector,DataBridgeTokenManager,DataBridgeInjectionResumer,DefaultDataBridgeClient}.java`, `java/common/.../util/DataBridgeUtil.java`, `templateDeployment.yaml`.

Facts:
- `POST /data` checks auth first: no `DATA_BRIDGE_TOKEN` configured, missing header, or wrong token: **401** `{"error":"Unauthorized"}`. Then body size (over 64 KiB: 413), then schema `{"environment": {string: string}}` (400). Success: 200 `{"ignored": [names of unknown keys]}`. `GET /health`: 200 `OK` without auth. Other paths: 404.
- Known keys: `THEIA, TEMPLATE, GIT_URI, GIT_USER, GIT_MAIL, GIT_REF, GIT_SOURCE, ARTEMIS_URL, ARTEMIS_TOKEN, GRADLE_PREWARM, GRADLE_PREWARM_AUTO_CONFIRM, THEIACLOUD_SESSION_SECRET`, plus the comma-separated `DATA_BRIDGE_EXTRA_KEYS` of the IDE container.
- Every injection replaces the whole store (also a request with only unknown keys).
- Token Secrets: pool `instance-<n>-<app>-...-bridge-token`, owned by the AppDefinition; lazy session `<session-derived name>-bridge-token`, owned by the Session; key `token`; injected as `DATA_BRIDGE_TOKEN` via `secretKeyRef`.
- The operator targets the session's own IDE Service ClusterIP (not sidecar services, not the internal `-int` service).
- On start the operator resumes injection for every handled session of a bridge-enabled app.

Run the in-pod requests with the IDE container (`-c <ide container>`, see README). The token is expanded inside the pod and never printed.

```bash
bridge() { # $1 pod, $2 container, $3 auth mode: none|wrong|right, $4 JSON body
  k exec "$1" -c "$2" -- sh -c '
    case "$1" in none) H="";; wrong) H="Authorization: Bearer wrong";; right) H="Authorization: Bearer $DATA_BRIDGE_TOKEN";; esac
    curl -s -w " %{http_code}\n" -X POST -H "Content-Type: application/json" ${H:+-H "$H"} -d "$2" http://127.0.0.1:${DATA_BRIDGE_PORT:-16281}/data' _ "$3" "$4"
}
```

### DB-01 Bridge config in session pods
Safety: prod-safe
Steps: for one pool pod and one lazy session pod as `POD=<pod name>` (names only, no values except the non-secret flags):
```bash
k get pod "$POD" -o json | jq '.spec.containers[] | {name, env: [.env[]? | select(.name|startswith("DATA_BRIDGE")) | {name, value: (if .valueFrom then "secretKeyRef:" + .valueFrom.secretKeyRef.name else .value end)}]}'
```
Expect: `DATA_BRIDGE_ENABLED=1`, `DATA_BRIDGE_PORT=16281`, `DATA_BRIDGE_TOKEN` from a `secretKeyRef` (pool: the instance's `-bridge-token`; lazy: the session's `-bridge-token`). No literal token value anywhere in the pod spec.

### DB-02 Eager session gets its data
Safety: test-only
Steps: with `ft-pool` from module 05, `FT_ENV='{TEMPLATE: <a template id of that image>}' ft_session ft-db-eager ft-pool`, `ft_wait ft-db-eager`. Open the session URL in the browser.
Expect: operator log shows the injection succeeded for `ft-db-eager` (no values logged); in the IDE the template is applied (scorpio reads `TEMPLATE` from the bridge) and the status bar or Welcome shows the template files.

### DB-03 Lazy session gets its data
Safety: test-only
Steps: `ft_workspace ft-db-ws <APP_STD>`; `FT_ENV='{THEIA: "1", TEMPLATE: <id>}' ft_session ft-db-lazy <APP_STD> ft-db-ws`; `ft_wait ft-db-lazy`.
Expect: a `-bridge-token` Secret owned by the Session exists; injection succeeds (operator log); the template is applied. Before Cloud 3.0.1 lazy sessions ran with `DATA_BRIDGE_ENABLED=0` (rc.3 user test).

### DB-04 Wrong or missing token is refused
Safety: test-only
Steps: in `ft-db-lazy`: `bridge $POD $C none '{"environment":{"THEIA":"1"}}'`, then `wrong`, then `k exec $POD -c $C -- curl -s -w ' %{http_code}\n' http://127.0.0.1:16281/health`.
Expect: 401, 401, `OK 200`. The store is unchanged (the template session keeps working).

### DB-05 Known keys and replacement
Safety: test-only (overwrites the fixture session's injected data)
Steps: `bridge $POD $C right '{"environment":{"THEIA":"1","FT_UNKNOWN":"x"}}'`, then `bridge $POD $C right '{"environment":{"bad":1}}'`, then a body over 64 KiB.
Expect: 200 with `{"ignored":["FT_UNKNOWN"]}`; 400; 413.

### DB-06 DATA_BRIDGE_EXTRA_KEYS
Safety: test-only
Steps: on the fixture session's Deployment (lazy, not a pool instance): `k set env deploy/<ft-db-lazy deployment> -c <ide container> DATA_BRIDGE_EXTRA_KEYS=FT_EXTRA`, wait for the new pod, then `bridge ... right '{"environment":{"THEIA":"1","FT_EXTRA":"x","FT_OTHER":"y"}}'`.
Expect: `{"ignored":["FT_OTHER"]}`. (Launch requests cannot set `DATA_BRIDGE_*` variables: the operator drops that prefix, API-10.)
Cleanup: `ft_cleanup` removes the session and its Deployment.

### DB-07 Injection after operator restart
Safety: test-only, disruptive
Steps: create a lazy fixture session and, while it is still starting (`operatorStatus` HANDLING, before the IDE is ready), `k rollout restart deploy/operator-deployment`.
Expect: after the restart the operator resumes the injection (log line naming the session); the template is applied when the IDE opens. Combine with OPR-10 to save a restart.

### DB-08 Injection with sidecars
Safety: test-only
Steps: start a lazy session of `ft-opr-side` (OPR-09) with `TEMPLATE` set; check the operator log for the target address and `k get svc | grep <session>`.
Expect: the injection goes to the session's IDE Service, not to the sidecar service; it succeeds; the template is applied.

### DB-09 Bridge is reachable only from the operator
Safety: test-only
Steps: from a second fixture session's IDE container, `curl -s -m 5 -o /dev/null -w '%{http_code}\n' http://<pod IP of ft-db-lazy>:16281/health` (and the service ClusterIP).
Expect: timeout (`000`): `session-allow-operator` admits only `app: operator` on 16281. See also SEC-07.

### DB-10 THEIA=1 arrives
Safety: test-only
Steps: in a fixture session with no other env, open the IDE and run the command palette "Data Bridge: Show Logs" (`dataBridge.showLogs`), or check the scorpio log in the Output view.
Expect: the store holds `THEIA` (the operator adds `THEIA=1` when the session env lacks it); scorpio treats the session as a cloud session (git identity set, see IDE module).

## Explore

- Inject while the IDE is still starting (bridge not yet listening): how many retries, and does it give up after 30 minutes as designed?
- Restart only the IDE container (kill the extension host): is the store reloaded from SecretStorage?
- Two browser windows on one session: the second logs "Port ... is taken"; does the first keep serving?
- Rotate a lazy session's token Secret by hand: does the next injection use the new one?
- The operator's allowlist omits `GIT_REF` and `GIT_SOURCE` while the bridge accepts them: is any flow affected?
