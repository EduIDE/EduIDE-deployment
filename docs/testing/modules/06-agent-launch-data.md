# 06 Agent and launch data (AGT)

Server module (AGT-12 needs the browser). Replaces the Java data bridge module. The agent is a sidecar in every session pod and the only entry into it: it proxies requests from Envoy to the IDE, receives the launch data once per claim from the operator, serves it on localhost to the IDE extension `eduide-session`, and reports activity. Launch data (Artemis URL and token, Git URL, build system, user name and e-mail) lives in a Secret owned by the session and in the agent's memory, never in CR specs, logs, traces, metrics or status.

Sources: control plane `api/agent/v1.yaml`, `internal/agent/{agent,proxy}.go`, `internal/controller/session.go` (`pushClaim`, `allowedData`, `reclaim`), `internal/httpapi/launch.go`, ADR 0006, 0012, 0016, `docs/architecture/data-model.md` ("Session pod"), `extensions/eduide-session/`.

Facts:
- Listeners of the agent: proxy `0.0.0.0:8080` (needs the header `X-EduIDE-Instance-Token`, forwards HTTP and WebSocket to the IDE on `127.0.0.1:<port>`; a wrong, missing or repeated header is 403, an IDE that does not answer 502); control `0.0.0.0:8081` (operator; `Authorization: Bearer <instance token>`; `/healthz` and `/readyz` without auth; `POST /v1/claim`, `GET /v1/status`, `POST /v1/notify`; wrong or missing token 401); local `127.0.0.1:8082` (IDE extension, no auth: `GET /v1/session?after=<n>&timeout=<s>` long-poll, `POST /v1/heartbeat`, `POST /v1/milestones`).
- The instance token is created with the pod (Secret `ide-<instance>-token`, key `token`, mounted at `/var/run/eduide/token` in the agent only) and never changes on a claim. The claim is idempotent for the same session, 409 for another, 400 for a malformed body, 413 above 16 KiB.
- The agent logs `claimed` with the session and the key names, never values. `GET /v1/status` returns `claimed`, `ready`, `session`, `lastActivity` (heartbeats only), `connections` (open proxied WebSockets) and `milestones` (`claim-received`, `first-request`, `first-websocket`, `data-delivered`, and from the extension `plugin-host-started`, `workspace-ready`, `clone-done`, `first-input`).
- The operator reads the Secret `spec.dataSecretRef` (it must carry `app.kubernetes.io/managed-by=eduide`), enforces `injectableKeys` again (unknown keys dropped, values cut to `maxLength`, key names logged), and pushes one claim. When the agent reports `claimed: false` for a `Ready` session (agent container restarted) the operator pushes the claim again.
- Fixture data in this module is fake and carries a marker: `FT_DATA='{"GIT_URI":"https://github.com/ft-marker-<random>/x.git","TEMPLATE":"<variant id>"}'` with a random marker per run (`M=$(openssl rand -hex 6)`). Never use real tokens.

Helpers (read the token without printing it; the header goes through stdin so it stays out of the process list):
```bash
tok() { k get secret "ide-$1-token" -o jsonpath='{.data.token}' | base64 -d; }          # $1 instance id
ctl() { printf 'header = "Authorization: Bearer %s"\n' "$TOK" | curl -s -K - "$@"; }     # needs TOK
# port-forward 8081 (control) and 8082 (local) of a pod:
#   k port-forward $POD 38081:8081 38082:8082 >/dev/null 2>&1 & PF=$!; sleep 3
```

### AGT-01 Agent in every session pod
Safety: prod-safe
Needs: any session pod.
Steps: `k get pod <pod> -o json | jq '.spec.containers[] | select(.name=="agent") | {image, ports: [.ports[] | .name + ":" + (.containerPort|tostring)], env: [.env[] | .name + "=" + (.value // "(ref)")], mounts: [.volumeMounts[].mountPath], ready: .readinessProbe.httpGet.path, live: .livenessProbe.httpGet.path}'`; `k logs <pod> -c agent | head -20`.
Expect: the agent image tag equals the control plane tag (PLAT-01) and the pod's agent `imageID` equals the registry digest of that tag (PLAT-11; a pod created before the last deploy can run an older build); ports `proxy:8080` and `control:8081`; env `AGENT_IDE_PORT` (the template port), `AGENT_PATH_PREFIX=/<instance>/`, `AGENT_TOKEN_FILE=/var/run/eduide/token`, `AGENT_ID_TOKEN_COOKIE=eduide-id` (the `oidc.idTokenCookie`), `AGENT_LOG_LEVEL`; the token mount only in the agent, none in the `ide` container; readiness `/readyz` and liveness `/healthz` on 8081. The log is JSON with `starting`, `ready`, `ide port reachable`, `claimed` lines and no token or data value. The `ide` container holds the template env (`THEIA`, `SCORPIO_THEIA_ENV_STRATEGY`) only.

### AGT-02 Launch data reaches the agent
Safety: test-only
Steps: `M=$(openssl rand -hex 6)`; `FT_DATA="{\"GIT_URI\":\"https://github.com/ft-$M/x.git\",\"TEMPLATE\":\"<a variant id of the template>\"}" ft_session ft-agt-s1 <TPL_POOL>` (warm) and a second one on `<TPL_STD>` with a workspace (cold, `ft_workspace ft-agt-ws <TPL_STD>` first); `ft_wait` both; `k logs <pod> -c agent | grep claimed`; `k get secret ft-agt-s1-data -o json | jq -r '.data|keys[]'`.
Expect: both sessions reach `Ready`; the agent log has one `claimed` line with `session` and `keys` naming the keys of the Secret (names only, no values); warm and cold sessions behave the same. The Secret is owned by the session (`ownerReferences[0].kind` is `IDESession`).
Cleanup: `ft_cleanup`.

### AGT-03 The IDE extension reads the data on loopback
Safety: test-only
Steps: with `ft-agt-s1` (AGT-02): `k port-forward $POD 38082:8082 >/dev/null 2>&1 & PF=$!; sleep 3`; `curl -s http://127.0.0.1:38082/v1/session | jq '{version, claimed, keys: (.data|keys), notices: (.notices|length)}'`; `V=$(curl -s http://127.0.0.1:38082/v1/session | jq .version)`; `time curl -s "http://127.0.0.1:38082/v1/session?after=$V&timeout=3" | jq .version`; `kill $PF`.
Expect: `claimed: true` and `keys` equal to the Secret's keys; the long poll with the current version waits about 3 seconds and returns the same version; without a claim (an idle pod) `claimed: false` and no `data`. Never print `.data` values. The listener has no auth by design: it is reachable only from inside the pod (and through `kubectl port-forward`).

### AGT-04 Heartbeat and status
Safety: test-only
Steps: with the port-forward of AGT-03 plus 8081: `TOK=$(tok $INST)`; `ctl http://127.0.0.1:38081/v1/status | jq '{claimed, ready, session, lastActivity, connections, milestones: [.milestones[]?.name]}'`; `curl -s -o /dev/null -w '%{http_code}\n' -X POST http://127.0.0.1:38082/v1/heartbeat`; status again; `curl -s -X POST -H 'Content-Type: application/json' -d '{"name":"not-allowed"}' -w ' %{http_code}\n' http://127.0.0.1:38082/v1/milestones`; `unset TOK`.
Expect: before the heartbeat `lastActivity` is absent and `connections` is 0 (no browser counts as idle, ADR 0016); the heartbeat is 204 and `lastActivity` appears; milestones include `claim-received` and, after the claim was delivered to the extension, `data-delivered`; a name outside the allowlist is 400. Proxied requests do not set `lastActivity`.

### AGT-05 The control listener needs the instance token
Safety: test-only
Steps: with the 8081 port-forward of a claimed fixture pod:
```bash
for a in "" "Authorization: Bearer wrong"; do curl -s -o /dev/null -w '%{http_code} status\n' ${a:+-H "$a"} http://127.0.0.1:38081/v1/status; done
curl -s -o /dev/null -w '%{http_code} healthz\n' http://127.0.0.1:38081/healthz
curl -s -o /dev/null -w '%{http_code} readyz\n' http://127.0.0.1:38081/readyz
TOK=$(tok $INST)
printf 'header = "Authorization: Bearer %s"\n' "$TOK" | curl -s -K - -o /dev/null -w '%{http_code} claim-other-session\n' -X POST -H 'Content-Type: application/json' -d '{"session":"ft-agt-other","data":{}}' http://127.0.0.1:38081/v1/claim
printf 'header = "Authorization: Bearer %s"\n' "$TOK" | curl -s -K - -o /dev/null -w '%{http_code} claim-no-session\n' -X POST -H 'Content-Type: application/json' -d '{"data":{}}' http://127.0.0.1:38081/v1/claim
unset TOK
```
Expect: 401, 401, 200, 200, then 409 (claimed by another session) and 400 (session missing). The data of the real session is unchanged afterwards (AGT-03 keys). The agent log shows `token check failed` lines without the token (at most 10 per minute and endpoint). The NetworkPolicy keeps the operator the only pod that can reach 8081 (SEC-07); the port-forward bypasses it on purpose.

### AGT-06 The proxy needs the instance header
Safety: test-only
Steps: `k port-forward $POD 38080:8080 >/dev/null 2>&1 & PF=$!; sleep 3`; request `/` with no header, with `X-EduIDE-Instance-Token: wrong`, and with the right token (`TOK=$(tok $INST)`; pass it with `-K -` as in `ctl`, never in the command line); also with the right header twice (`-H` repeated with the same value).
Expect: 403 for no header, a wrong one and a repeated one; with the right header the IDE answers 200 (the page of the IDE, no gateway involved). Never record the token.
Cleanup: `kill $PF`; `unset TOK`.

### AGT-08 Launch data is in no spec, log, event or metric
Safety: test-only
Needs: AGT-02 with its marker `$M` still known; the sessions running.
Steps (counts only):
```bash
for src in "k logs deploy/$P-operator --since=30m" "k logs deploy/$P-service --since=30m" "k logs $POD -c agent" "k get events -o json" "k get idesessions,ideworkspaces,pods,httproutes -o json"; do
  echo "$($src | grep -c "ft-$M") $src"; done
k get secret ft-agt-s1-data -o json | grep -c "ft-$M"      # expected 0: stored base64-encoded, and the fixture helper uses `kubectl create`, so no last-applied-configuration annotation holds the plain value
k get idesession ft-agt-s1 -o json | jq '.spec, .status | keys'
```
Expect: 0 occurrences of the marker in the logs, events, CR specs, status and pod specs; the Secret holds it only as base64 `data` (a plain `grep` finds nothing; compare by decoding in a variable, never print); the session spec has `dataSecretRef` and `display`, no value. The traces and metrics are covered by the same rule (module 10: no label carries a user name or token).
Cleanup: `ft_cleanup`.

### AGT-09 The operator enforces the allowlist again
Safety: test-only
Steps: `FT_DATA='{"GIT_URI":"https://github.com/ft-x/y.git","FT_EXTRA":"x","ARTEMIS_URL":"<a value longer than the template maxLength, 2049 characters>"}' ft_session ft-agt-allow <TPL_STD>`; `ft_wait`; `k logs deploy/$P-operator --since=5m | grep 'allowlist'`; `k logs <pod> -c agent | grep claimed`.
Expect: the operator logs a line that the launch data does not match the template allowlist with `dropped_keys` (`FT_EXTRA`) and `truncated_keys` (`ARTEMIS_URL`), key names only; the agent's `claimed` line lists `GIT_URI` and `ARTEMIS_URL` but not `FT_EXTRA`. The session still reaches `Ready` (a dropped key is not an error). The service would have refused the same request with 400 `unknown-key` (API-09): a direct CR is the only way to test the second line of defence.
Cleanup: `ft_cleanup`.

### AGT-10 Launch data Secret follows the session
Safety: test-only
Steps: `FT_DATA='{"GIT_URI":"https://github.com/ft-x/y.git"}' ft_session ft-agt-own <TPL_POOL>`; `ft_wait`; `k get secret ft-agt-own-data -o jsonpath='{.metadata.ownerReferences[0].kind} {.metadata.labels}{"\n"}'`; `k delete idesession ft-agt-own`; after a minute `k get secret | grep -c ft-agt-own`. Then a session whose Secret does not carry the managed-by label: create the Secret by hand without the label and watch the session for more than 2 minutes.
Expect: the Secret is owned by the session and labelled `managed-by=eduide`; it is gone a minute after the session. A Secret without the label is invisible to the operator: the session stays `Starting` with no message for 2 minutes (`agentWaitLimit`), then fails with `start-failed` and the message "launch data Secret ... missing or not labelled app.kubernetes.io/managed-by=eduide" (confirmed 2026-11-24). The warm pod used by the first session is discarded, not reused (POOL-04).
Cleanup: `ft_cleanup`.

### AGT-12 The template is applied in the IDE
Safety: test-only
Needs: browser; the IDE tab visible (README); a template with variants.
Steps: `FT_DATA='{"TEMPLATE":"<variant id>"}' ft_session ft-agt-ide <TPL_STD>` and `ft_wait`; open the IDE through a port-forward of port 3000; wait for the Explorer and look at it and the status bar.
Expect: within a minute of the IDE opening the project template's files are in the workspace (scorpio reads `TEMPLATE` through the extension's `dataBridge.getEnv`, and `GIT_USER` and `GIT_MAIL` from the token keys when present). The agent status shows the milestones `data-delivered` and `plugin-host-started` (AGT-04). The same works for a warm (`<TPL_POOL>`) and a cold start. Keep the tab in the foreground; a hidden pane delays the data.
Cleanup: `ft_cleanup`.

## Unverified, check in the first run

- AGT-06: the exact status when no IDE answers (502). The 403 for a repeated header was confirmed on 2026-11-24.
- A claim with the right token to a pod whose agent was not yet claimed would claim it for a fixture session: do not run AGT-05 against idle pool pods.

## Retired

The data bridge (a VS Code extension listening on port 16281, called by the operator with a bearer token) no longer exists. Old IDs and where their meaning went:

- DB-01 Bridge config in session pods: 2026-11-24, now AGT-01.
- DB-02 Eager session gets its data and DB-03 Lazy session gets its data: 2026-11-24, warm and cold starts use the same claim; now AGT-02 and AGT-12.
- DB-04 Wrong or missing token is refused: 2026-11-24, now AGT-05 (control) and AGT-06 (proxy).
- DB-05 Known keys and replacement: 2026-11-24, now the allowlist, AGT-09 and API-09.
- DB-06 `DATA_BRIDGE_EXTRA_KEYS`: 2026-11-24, no such variable; the allowlist is the template's `injectableKeys`.
- DB-07 Injection after operator restart: 2026-11-24, no polling; the claim is pushed once and the operator re-pushes only after an agent restart (OPR-10, Explore).
- DB-08 Injection with sidecars: 2026-11-24, no sidecars.
- DB-09 Bridge is reachable only from the operator: 2026-11-24, now SEC-07 (NetworkPolicy) and AGT-05.
- DB-10 `THEIA=1` arrives: 2026-11-24, `THEIA` is static env of the template (AGT-01).
- DB-11 Pool token rotates on release: 2026-11-24, an instance is never reused; the token dies with the pod (POOL-04).
- DB-12 Data survives a session pod restart and DB-13 Operator start re-injects all sessions: 2026-11-24, a lost pod fails the session (OPR Explore); an agent restart is repaired by the operator (Explore).

## Explore

- Restart only the agent container of a `Ready` session: the operator logs `re-claim after agent restart` and emits `Reclaimed`; does the IDE keep its data (it keeps the data in its own memory)?
- Two browser windows on one session: both long-poll the agent; does the first keep working?
- A 16 KiB claim and a 17 KiB claim directly to the control port (with the right token on a fixture): 200 and 413.
- Cookies: send a request through the proxy with the gateway login cookies (`eduide-id`, `eduide-authz`, `IdToken*`) and check on a header-echo IDE that none reach it (needs a fake IDE image; the e2e suite has one).
- Cookie path rewriting: does `theia-connection-token` with `Path=/` of one IDE leak into another session's IDE on the shared instance host?
- WebSocket with large messages and a 100 MB upload through the proxy.
- A session first opened more than 10 minutes after launch (the agent waits for the browser; the operator's agent wait limit is 2 minutes for the claim only).
