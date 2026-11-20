# 06 Agent and data path (AGENT)

Server module. The agent is a sidecar in every session pod and the only entry into it (ADR 0006). It replaces the data bridge: the operator pushes the launch data once per claim (`POST /v1/claim` on the control port), the agent keeps it in memory, and the IDE extension `eduide-session` reads it over loopback by long-poll (`127.0.0.1:8082`). The old polling by the operator (2 s, up to 900 attempts) is gone.

Sources (control plane repo): `api/agent/v1.yaml`, `internal/agent`, `internal/agentclient`, ADR 0006, 0012, 0016; design G4, G7, G18. Extension `extensions/eduide-session`.

Facts:
- Control port 8081: `Authorization: Bearer <instance token>`; `/healthz` and `/readyz` need no auth. Token comparison is constant-time. The token comes from the file `/var/run/eduide/token` (Secret `ide-<instance>-token`, key `token`), is created with the pod and never changes at claim.
- `POST /v1/claim` body `{session, data, traceparent?}`, at most 16 KiB (413 above), idempotent for the same session (200), 409 for another session, 401 wrong token. Data is kept in memory only, never written to disk or logs.
- `GET /v1/status` returns `{claimed, session, ready, lastActivity, connections}`. `ready` means claimed and data stored. The operator sets the session Ready only after the agent answers.
- `POST /v1/notify` `{kind, message, at?}` queues a notice for the extension (`idle-warning`, `max-warning`, `info`; message at most 1024 characters), 204.
- Local port: `GET /v1/session?after=<n>&timeout=<s>` (long-poll, timeout 0 to 60, default 30) returns `{version, claimed, data, notices}`; `POST /v1/heartbeat` returns 204.
- The extension exposes the unchanged commands `dataBridge.getEnv` and `dataBridge.getEnvState` (Scorpio and others use them).

Helpers `agent_pf`, `agent`, `proxy` and the local API one-liner are in the README. Fixtures use dummy values only. Print data keys, never values.

### AGENT-01 Agent container configuration
Safety: prod-safe
Steps: `k get pod <session pod> -o json | jq '.spec.containers[] | select(.name=="agent") | {image, ports, env:[.env[]?|{name, value:(if .valueFrom then "ref" else .value end)}], readiness:.readinessProbe.httpGet, liveness:.livenessProbe.httpGet, mounts:.volumeMounts, sc:.securityContext, resources}'`
Expect: image equals `config.agent.image`; ports 8080 `proxy` and 8081 `control`; env `AGENT_IDE_PORT` (template port) and `AGENT_TOKEN_FILE=/var/run/eduide/token`; the token mounted read-only from the Secret `ide-<instance>-token`; readiness `/readyz` on 8081, liveness `/healthz`; resource requests and a memory limit set (target under 10 MiB, PERF-02); no literal token and no launch data in any env or arg of either container.

### AGENT-02 Warm claim delivers the data
Safety: test-only
Steps: `ft_template "$T_POOL" ft-ag-t '.spec.injectableKeys += [{"name":"FT_PROBE","source":"Request","format":"Token","maxLength":64}]'`, `ft_pool ft-ag-pool ft-ag-t 1`, wait for an idle pod, then `FT_DATA='{"FT_PROBE":"dummy-value-1"}' ft_session ft-ag-s1 ft-ag-t "" "$ME"`, `ft_wait`; `INST=$(k get idesession ft-ag-s1 -o jsonpath='{.status.instance}')`; `agent_pf $INST`; `agent $INST GET /v1/status`; the local API one-liner (README) in the pod.
Expect: status `{"claimed":true,"session":"ft-ag-s1","ready":true,...}`; the local API returns `claimed:true`, `version >= 1` and `keys` containing `FT_PROBE`; `timestamps.agentReady` is set and equals `timestamps.ready` (both are taken at the same moment); the agent log has the line `claimed` for `ft-ag-s1` (the operator logs the claim too since the logging fix) and no value (`k logs deploy/$FULL-operator --since=5m | grep -c dummy-value-1` is 0, SEC-14).
Cleanup: `kill $AGENT_PF`; `ft_cleanup`.

### AGENT-03 Cold session gets its data, also when the Secret is late
Safety: test-only
Steps: create the session before its Secret: `k apply` the IDESession of `ft_session` (without the Secret step), wait 20 s with the session still `Pending` or `Starting`, then create the Secret (the second half of `ft_session`, or run `ft_session` twice: the apply of the session is idempotent). Then `ft_wait`, `agent_pf`, status and local API as in AGENT-02.
Expect: the operator waits for the Secret (no `Failed`, no crash loop); after the Secret appears the cold pod gets the claim, `ready: true`, the key is in the local API. The window is real: the service creates the session first and the Secret right after.
Cleanup: `kill $AGENT_PF`; `ft_cleanup`.

### AGENT-04 Control port refuses wrong or missing tokens
Safety: test-only
Needs: a running session (AGENT-02).
Steps: through the port-forward: `curl -s -o /dev/null -w '%{http_code} none\n' http://127.0.0.1:$PF_CTRL/v1/status`; with `Authorization: Bearer wrong`; with a valid token (`agent $INST GET /v1/status`); `/healthz` and `/readyz` without any header; `POST /v1/notify` without token.
Expect: 401, 401, 200 with the status; `/healthz` 200 and `/readyz` 200 without auth; notify without token 401 and nothing queued (the local `notices` stays empty). Status after the failed attempts is unchanged.

### AGENT-05 Claim validation and idempotence
Safety: test-only
Needs: a claimed pod of a fixture session `ft-ag-s1`.
Steps: `agent $INST POST /v1/claim '{"session":"ft-ag-s1","data":{"FT_PROBE":"dummy-value-1"}}'` (same session), then with `"session":"ft-ag-other"`, then `'notjson'`, then `'{"session":"ft-ag-s1","data":{"a":1}}'`, then a body over 16 KiB written to a file (`jq -n --arg v "$(head -c 17000 /dev/zero | tr '\0' x)" '{session:"ft-ag-s1",data:{FT_PROBE:$v}}' > "$BODY"`, then `curl ... --data-binary @"$BODY"`; the token header comes from stdin, so the body must not: curl reads stdin only once) with and without the token.
Expect: 200 (idempotent, `version` unchanged or only increased as the spec allows: record); 409 for the other session; 400 for malformed JSON and for a non-string value; 413 with the token and 401 without (auth before the size check). Error bodies name the problem and never echo a data value. Status still reports `ft-ag-s1`.

### AGENT-07 Claim after operator restart
Safety: test-only, disruptive
Steps: in the OPR-10 window: create a warm and a cold session and do not open them; restart the operator at once; after it is back `ft_wait` both and check `agent $INST GET /v1/status` for each, and open both as owner.
Expect: both sessions reach Ready after the restart, each agent is claimed exactly once (`eduide_agent_requests_total{op="claim"}` rose by one per session, no repeated claims), and the IDE has the data when it opens. Nothing polls: with no operator running the agent just waits.

### AGENT-10 Static environment stays in the template
Safety: test-only
Steps: `k get pod <session pod> -o jsonpath='{.spec.containers[?(@.name=="ide")].env[*].name}'` and the local API keys of that session.
Expect: `THEIA` is a literal env var of the `ide` container, set from the template's static `env` (G18); it is not a launch data key and not in the local API's `data`. The only dynamic data keys are the ones in `injectableKeys` (`GIT_URI`, `GIT_USER`, `GIT_MAIL`, `ARTEMIS_URL`, `ARTEMIS_TOKEN`, `TEMPLATE`, ... as the template allows). Scorpio treats the session as a cloud session (IDE-01: git identity set).

### AGENT-12 IDE restart keeps the data
Safety: test-only
Needs: browser pane, a session of `ME` with data.
Steps:
1. Note `version` from the local API (`after=0&timeout=0`).
2. Restart only the IDE container: `k exec $POD -c ide -- sh -c 'kill 1'` (the `ide` container restarts; `k get pod -o jsonpath='{.status.containerStatuses[?(@.name=="ide")].restartCount}'` rises, the `agent` container keeps its count).
3. Wait for the pod to be ready again; query the local API and `agent $INST GET /v1/status`; reload the IDE tab.
Expect: the agent still holds the data (`claimed:true`, same keys, same `version`); the extension re-reads it on start (the template applies, git identity set); the session stays Ready for the operator and the URL keeps working; `/readyz` is 503 only while the IDE is down. Restarting the whole pod loses everything by design (the pod is discarded when the session ends).
Cleanup: `ft_cleanup`.

### AGENT-13 Local long-poll semantics and loopback only
Safety: test-only
Needs: a claimed session pod.
Steps: from the `ide` container: `V=$(curl -s "http://127.0.0.1:8082/v1/session?after=0&timeout=0" | sed 's/.*"version":\([0-9]*\).*/\1/')`; time `curl -s -o /dev/null -w '%{time_total}\n' "http://127.0.0.1:8082/v1/session?after=$V&timeout=3"`; immediately `agent $INST POST /v1/notify '{"kind":"info","message":"ft"}'` while a second long-poll waits; `timeout=61`. From a foreign pod (SEC-13's `ft-probe`): `curl -m 3 http://<pod IP>:8082/v1/session`.
Expect: `after=<current>` waits about 3 s and returns the same `version`; a poll in flight returns early when the notice arrives, with a higher `version` and the notice in `notices`; `after=0` returns at once; `timeout=61` is refused (400) or clamped to 60; the foreign pod cannot connect to 8082 (it listens on 127.0.0.1 only).
Cleanup: `ft_cleanup`.

### AGENT-14 Heartbeat, activity and connections
Safety: test-only
Needs: browser pane, a session of `ME`.
Steps: `agent $INST GET /v1/status` before opening the IDE (`lastActivity` absent, `connections: 0`); open the IDE tab and wait for it to load; status again; type in the IDE and check `lastActivity` moves (the heartbeat is sent at most once per minute); `k exec $POD -c ide -- curl -s -X POST -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8082/v1/heartbeat`; close the tab and status after 30 s.
Expect: before the browser: no activity and 0 connections (counts as inactive, OPR-04); with the tab open `connections` is at least 1 (WebSocket through the proxy) and `lastActivity` is set; the manual heartbeat returns 204 and moves `lastActivity`; after closing the tab `connections` returns to 0. Only heartbeats count for `lastActivity`; proxied requests do not (ADR 0016).
Cleanup: `ft_cleanup`.

### AGENT-15 Notify reaches the IDE
Safety: test-only
Needs: browser pane, a session of `ME`.
Steps: `agent $INST POST /v1/notify '{"kind":"info","message":"ft notice","at":"2026-12-31T23:00:00Z"}'`; watch the IDE tab; then a message of 1025 characters; then an unknown `kind`.
Expect: 204 and a notification "ft notice" appears in the IDE within seconds (via the long-poll); the long message and the unknown kind are refused (400 or 413), nothing is queued. The same path carries the idle warning of OPR-04.
Cleanup: `ft_cleanup`.

### AGENT-16 Proxy forwards HTTP and WebSocket
Safety: test-only
Needs: a running session, `agent_pf`.
Steps: `proxy $INST right /` (token from the Secret, header on stdin); a large request body through the proxy (`head -c 52428800 /dev/zero > "$BODY"`, then `curl -s -o /dev/null -w '%{http_code} %{size_upload}\n' -X POST --data-binary @"$BODY" -H @- http://127.0.0.1:$PF_PROXY/` with the token header from stdin; the IDE may answer 404 or 405, what counts is that the upload is accepted whole); open the IDE in the browser, run a terminal command and open a file.
Expect: HTTP 200 with the IDE page for the right token; the 50 MiB upload is forwarded completely (`size_upload` 52428800) without the agent buffering it into memory (agent memory stays within PERF-02); the IDE terminal and editor work over WebSocket through the proxy; the instance token header is not visible to the IDE (it is stripped, check the IDE's request log if available, otherwise record `blocked`).
Cleanup: `kill $AGENT_PF`; `ft_cleanup`.

### AGENT-17 Agent container restart is re-claimed
Safety: test-only
Needs: a Ready cold session with data (`FT_DATA`), `agent_pf`.
Steps: record the local API `version` and keys; kill only the agent container: an ephemeral container with the agent's uid 65532 on the same pod (`k debug pod/ide-$INST --target=agent -c ft-kill --image=<the template's IDE image> --custom=<file with {"securityContext":{"runAsUser":65532}}> -- sh -c 'kill -TERM 1'`); watch `agent` restartCount, `agent $INST GET /v1/status` and the local API; repeat for a warm (pool) session.
Expect: the `agent` container restarts (restartCount 1, `ide` 0), the operator claims again within one poll interval (first run: 2 s), status `claimed:true` with the same keys, `version` changed, the session stays `Ready`; `eduide_agent_requests_total{op="claim",result="ok"}` rises by exactly one per restart and no repeated claims follow. Before fix batch 1 the data was lost silently.
Cleanup: `kill $AGENT_PF`; `ft_cleanup`.

### AGENT-18 Operator enforces the template allowlist on launch data
Safety: test-only
Steps: `ft_template "$T_STD" ft-ag-t '.spec.injectableKeys += [{"name":"FT_PROBE","source":"Request","format":"Token","maxLength":64}]'`; a session whose data Secret holds `FT_PROBE`, a key outside the allowlist (`NOT_ALLOWED`) and an `FT_PROBE` value of 123 characters (dummy strings; `FT_DATA` built with `jq`); read the local API keys (names only) and the session phase.
Expect: record what happens (key dropped, value cut, or the session `Failed`); the extension never sees a key that the template does not list; no value in any log (SEC-14). The first run saw both sessions Ready with every key (defense in depth missing, fixed in fix batch 1).
Cleanup: `ft_cleanup`.

### AGENT-19 Parallel claims for two sessions: one wins
Safety: test-only
Needs: an unclaimed pod (an idle pool pod), `agent_pf <instance>`.
Steps: 20 parallel `POST /v1/claim` with `session` `ft-ag-a` (10 calls) and `ft-ag-b` (10 calls), data of dummy strings; then `agent $INST GET /v1/status`; `k logs pod/ide-$INST -c agent | grep -c claimed`.
Expect: all calls for one session answer 200, all calls for the other 409; status shows exactly one session; one `claimed` line in the agent log.
Cleanup: `kill $AGENT_PF`; `ft_cleanup`.

## Explore

- Kill the agent container (it is distroless: `kubectl debug` is needed; or delete the pod): what does the operator do with a `Ready` session whose agent restarted and lost its data (`claimed:false`)? Does it push the claim again, or does the session stay Ready without data?
- Two claims for the same session at the same time (two operators, or a retry): `claimed` once, same `version`?
- A claim payload with keys that are not in the template: the operator should have refused it before the agent; does the agent also validate?
- A foreign pod posting to `:8081` with a guessed token, 10 000 times: rate or CPU impact on the agent?
- The extension with the agent unreachable (kill the agent's listener): does the IDE degrade without errors popping up?
- IDE images built before `eduide-session` (IDE-10): the agent is ready, the IDE never reads the data.
