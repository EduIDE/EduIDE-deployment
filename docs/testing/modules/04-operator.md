# 04 Operator and session lifecycle (OPR)

Server module. Uses the fixtures from the README (`ft_template`, `ft_pool`, `ft_workspace`, `ft_session`, `ft_wait`, `ft_cleanup`), so no user token is needed. Name every object `ft-opr-...` and set `MODULE=04`.

Sources: control plane `internal/controller/{session,lifecycle,workspace,pool,build,setup}.go`, `internal/claim`, `api/v1alpha1/{idesession,idetemplate}_types.go`, `docs/architecture/start-path.md`, ADR 0007, 0008, 0009, 0016, 0019, `docs/operations/{slow-launch,pool-empty}.md`, `docs/contracts/metrics.md`; chart `eduide-control-plane` templates `networkpolicy.yaml`, `rbac.yaml`.

Facts:
- Session phases: `Pending`, `Starting`, `Ready`, `Failed` (`status.phase`), with `status.errorCode` and `status.message` on `Failed`. Timestamps `status.timestamps.{claimed,podReady,agentReady,ready}`, `status.startStrategy` `warm-ready`, `warm-starting` or `cold`. A session with a workspace always starts cold.
- A session carries the finalizer `eduide.github.io/session`; the operator records the workspace use when it ends and removes the finalizer. Pod, Service, HTTPRoute and token Secret of a cold instance are owned by the pod and go with it; the pod is a bare pod controlled by the session.
- Timeouts come from the template (`spec.timeouts` `idle`, `warning`, `max`; defaults 60m, 50m, 24h; durations are Go durations such as `3m`, the CRD rejects `2d`; `warning` must be shorter than `idle`, `max` not shorter than `idle`). Idle time counts from the latest of the agent's `lastActivity` and `agentReady`; the only activity source is the IDE extension's heartbeat on real input, and a claimed session with no browser counts as inactive. Maximum counts from session creation. At the warning time the operator pushes a notice to the agent and sets the condition `IdleWarningSent` (or `MaxWarningSent`); at the end it deletes the session and writes the Event `Ended` with reason `idle` or `max`. `status.lastActivity` moves only when activity advances by more than 5 minutes.
- A session whose agent cannot be polled never ends by idleness (missing data alone does not end a session); the maximum lifetime still applies.
- Start failures: a pod that does not become ready within 10 minutes, or a container that waits 60 s with an error that does not heal (`InvalidImageName`, `CreateContainerConfigError`, `CrashLoopBackOff`, pull errors "not found" or "denied"), fails the session with `start-failed`. An unschedulable pod or a quota refusal fails it with `capacity-exhausted` after `capacity.exhaustedAfter` (45 s by default). A failed session loses its pods at once and is deleted after 10 minutes.
- Events on the session (`k get events --field-selector involvedObject.name=<session>`): `Created` (cold), `Claimed` (warm), `Ready`, `Ended`, `Failed`, `Reclaimed`, `QuotaExceeded`. Log lines of the operator are JSON, `msg` such as `session ready` or `session ended`, with `session`, `template` and a pseudonymous `user`.
- Sessions of a deleted template: with an instance they keep running and end by the default timeouts; without an instance they fail with `template-not-found`.
- Policies of the chart: `$P-session-default-deny`, `$P-session-from-envoy` (8080 from Envoy pods of `envoy-gateway-system`), `$P-session-from-operator` (8081 from the operator), `$P-session-egress`, plus one each for operator, service, authz and the OIDC bridge.

### OPR-01 Operator configuration
Safety: prod-safe
Steps: `k get deploy $P-operator -o jsonpath='{.spec.template.spec.containers[0].args}{"\n"}{.spec.template.spec.containers[0].env}{"\n"}'`; `k get cm $P-config -o jsonpath='{.data.config\.yaml}' | yq '{sessionsPerUser, workspaces, capacity, placement, agent, telemetry}'`; `k get lease eduide-operator -o jsonpath='{.spec.holderIdentity} {.spec.renewTime}{"\n"}'`.
Expect: the operator runs one replica with `--config /etc/eduide/config.yaml`; the config names the agent image (same tag as the operator), the placement (node selector and node pool label of the cluster), `telemetry.userSaltFile`; the Lease is held by the operator pod and renewed within the last minute. Record the values (they hold no secrets).

### OPR-02 Cold session with a workspace: lifecycle and cleanup
Safety: test-only
Steps:
1. `ft_workspace ft-opr-ws <TPL_STD>`; wait until `k get ideworkspace ft-opr-ws -o jsonpath='{.status.phase} {.status.claimName}'` is `Ready ft-opr-ws`.
2. `ft_session ft-opr-s1 <TPL_STD> ft-opr-ws` and `ft_wait ft-opr-s1`.
3. `k get idesession ft-opr-s1 -o jsonpath='{.status}'`; `POD=$(k get idesession ft-opr-s1 -o jsonpath='{.status.podName}')`; `k get pod,svc,httproute,secret | grep "${POD#ide-}"`; `k get httproute $POD --show-labels`; `k get pod $POD -o jsonpath='{.spec.volumes[*].name} {.spec.containers[0].volumeMounts[*].mountPath}'`.
4. `k get events --field-selector involvedObject.name=ft-opr-s1`.
5. `k delete idesession ft-opr-s1` and wait.
Expect: step 2 reaches `Ready` with a URL `https://instance.$ENV/<instance>/`; `startStrategy` is `cold` and `timestamps` has `claimed`, `podReady`, `agentReady`, `ready` in that order. Step 3: pod `ide-<instance>` with containers `ide` and `agent`, a Service `ide-<instance>` (port 8080), an HTTPRoute `ide-<instance>` labelled `eduide.github.io/route=session`, a Secret `ide-<instance>-token` owned by the pod; the workspace volume is mounted at `/home/project` (the template's `persistence.mountPath`). Step 4: Events `Created` and `Ready`. After step 5 the pod, Service, route, token Secret and the data Secret are gone within two minutes, the IDEWorkspace and its PVC stay, the workspace `status.lastUsed` is newer than before, and the operator did not restart.
Cleanup: `ft_cleanup`.

### OPR-03 Failed sessions
Safety: test-only
Steps:
1. `ft_session ft-opr-bad-tpl does-not-exist` and `ft_wait`.
2. `ft_session ft-opr-bad-ws <TPL_STD> does-not-exist` and `ft_wait` (up to 60 s).
3. Watch both for 11 minutes.
Expect: 1 is `Failed` with `errorCode: template-not-found` at once and a readable message; 2 is `Failed` with `workspace-not-found` after about 30 s (the operator waits that long for a workspace that is not in its cache yet). No pod exists for either; the Events `Failed` carry the code; the operator keeps running. Both sessions are deleted by the operator about 10 minutes after the failure, so the landing page can read the error meanwhile. `eduide_session_failures_total{code=...}` counts them.
Cleanup: `ft_cleanup`.

### OPR-04 Idle timeout and warning
Safety: test-only
Needs: an environment where an IDE image can start (about 1 to 2 minutes).
Steps:
1. `ft_template <TPL_STD> ft-opr-idle '{"timeouts":{"idle":"3m","warning":"1m","max":"20m"}}'`; `ft_session ft-opr-idle-s ft-opr-idle`; `ft_wait ft-opr-idle-s`; note the `agentReady` time.
2. After about the warning time: `k get idesession ft-opr-idle-s -o jsonpath='{.status.conditions}'`.
3. Watch `k get idesession ft-opr-idle-s -w` and `k get events --field-selector involvedObject.name=ft-opr-idle-s`.
4. For the activity half (browser): second session `ft-opr-idle-s2`, open the IDE through a port-forward (README), type in the editor every minute for 5 minutes, then close the tab and the port-forward.
Expect: no browser ever connects in steps 1 to 3, so the session counts as inactive: `IdleWarningSent=True` about `warning` after `agentReady`, then the session is deleted about `idle` (3 minutes) after `agentReady` (plus at most one polling step), the Event `Ended` says "ended by the idle timeout", the pod and its objects are gone. Step 4: `status.lastActivity` appears and moves (only when it advances by more than 5 minutes, so within 5 minutes it may stay unset: read the agent's view instead, AGT-04), the end comes `idle` after the last typing, not after the start; the warning appears as a notice in the IDE (a message from the extension) about one minute before the end; typing again after the warning clears `IdleWarningSent` (`Active`).
Cleanup: `ft_cleanup`.

### OPR-05 Maximum lifetime
Safety: test-only
Steps: `ft_template <TPL_STD> ft-opr-life '{"timeouts":{"idle":"4m","warning":"2m","max":"4m"}}'`, `ft_session ft-opr-life-s ft-opr-life`, `ft_wait`, then watch the Events and `k get idesession ft-opr-life-s -w`.
Expect: the session is deleted 4 minutes after its creation (maximum counts from creation, idle from `agentReady`, so the maximum comes first by the start time), the Event `Ended` says "ended by the max timeout" (`reason: max` in the log line `session ended`), a `MaxWarningSent` condition appears before. With a browser that keeps typing (as in OPR-04 step 4) the session still ends at the maximum, not later.
Cleanup: `ft_cleanup`.

### OPR-06 Default timeouts on the real templates
Safety: prod-safe
Steps: the IDETemplate listing from the README (IDLE, WARN, MAX columns); `k get idetemplates -o json | jq -r '.items[] | .metadata.name + " " + (.spec.timeouts|tostring)'`.
Expect: every template has `idle: 60m`, `warning: 50m`, `max: 24h` (chart `templateDefaults`) unless the environment's values override them (then the override is recorded with its source). The operator exports the resolved values as `eduide_template_timeout_seconds{template,kind}`.

### OPR-07 Session whose template is gone
Safety: test-only
Steps: `ft_template <TPL_STD> ft-opr-orphan`, `ft_session ft-opr-orphan-s ft-opr-orphan`, `ft_wait`, then `k delete idetemplate ft-opr-orphan`; watch 3 minutes; then `ft_session ft-opr-orphan-s2 ft-opr-orphan`.
Expect: the running session stays `Ready` with its pod and URL (a chart upgrade that removes a template must not kill sessions); it ends by the default timeouts (60m idle, 24h max): do not wait for that, record the `eduide_template_timeout_seconds` default or check the Event later. The new session fails at once with `template-not-found`. PLAT-07 reports the first one as a session with a missing template.
Cleanup: `k delete idesession ft-opr-orphan-s`; `ft_cleanup`.

### OPR-08 Chart NetworkPolicies present
Safety: prod-safe
Steps: `k get networkpolicy`; `k get networkpolicy $P-session-from-operator -o jsonpath='{.spec}'`; `k get networkpolicy $P-session-egress -o jsonpath='{.spec.egress}'`.
Expect: eight policies: `$P-session-default-deny` (ingress, pods `eduide.github.io/component=session`), `$P-session-from-envoy` (port 8080 from `app.kubernetes.io/name=envoy` in `envoy-gateway-system`), `$P-session-from-operator` (port 8081 from the operator pods), `$P-session-egress`, and `$P-operator`, `$P-service`, `$P-authz`, `eduide-oidc-bridge-from-envoy` for the control plane. The egress policy allows DNS to `kube-system` and `0.0.0.0/0` and `::/0` except the private and link-local ranges (`networkPolicy.sessionEgressDeny`) and the cluster's own node, pod and service ranges (`sessionEgressExtraDeny`: on `tum-student` `131.159.88.0/24`, `198.18.0.0/16`, `198.19.0.0/16` and the IPv6 node range, from `environments/$ENV/values.yaml`). Enforcement is SEC-07.

### OPR-10 Operator restart with running sessions
Safety: test-only, disruptive (the operator is down for a few seconds up to a minute)
Steps: one restart can serve OPR-10, POOL-09 and OPR-13. Before it, prepare: a cold session with a workspace (opened in the browser through a port-forward), a warm claimed session (module 05), an unopened session, and a session being started. Snapshot UIDs of the sessions and their pods, the instance ids, URLs, the Secret `resourceVersion` of the token Secrets (never values), and the Lease holder. Then `k rollout restart deploy/$P-operator`, `k rollout status`, wait two minutes, snapshot again and diff.
Expect: running sessions keep their pods and URLs (same pod UIDs, same instance ids, same token Secrets); the starting session still reaches `Ready`; no session is re-claimed (no `Reclaimed` Event and no second `claimed` log line in the agent: `k logs $POD -c agent | grep -c claimed` unchanged; the claim is idempotent for the same session); new sessions start afterwards; the Lease holder is the new pod; the log shows no error loop.

### OPR-11 Session whose pod never starts
Safety: test-only
Steps: `ft_template <TPL_STD> ft-opr-badimg "{\"image\":\"$(k get idetemplate <TPL_STD> -o jsonpath='{.spec.image}' | sed 's/:[^:]*$/:does-not-exist/')\"}"`, `ft_session ft-opr-badimg-s ft-opr-badimg`, wait 2 minutes; `k get idesession ft-opr-badimg-s -o jsonpath='{.status.phase} {.status.errorCode} {.status.message}{"\n"}'`; `k get events --field-selector involvedObject.name=ft-opr-badimg-s`; `k get pods | grep ft-opr`.
Expect: the session is `Failed` with `errorCode: start-failed` about 60 seconds after the pod was created, the message names the container and the waiting reason ("the instance cannot start: container ide waits with ..."); its pod is deleted; the Event `Failed` exists; the session no longer counts against the user's limit (failed sessions do not) and is deleted after 10 minutes. `eduide_session_failures_total{code="start-failed"}` rises.
Cleanup: `ft_cleanup`.

### OPR-12 Second session on the same workspace
Safety: test-only
Steps: `ft_workspace ft-opr-ws2 <TPL_STD>`, wait for `Ready`; `ft_session ft-opr-d1 <TPL_STD> ft-opr-ws2`, `ft_wait ft-opr-d1`; `ft_session ft-opr-d2 <TPL_STD> ft-opr-ws2`, `ft_wait ft-opr-d2`; `k get idesessions,pods | grep ft-opr-d`.
Expect: the older session keeps running; the second is `Failed` with `errorCode: workspace-in-use` ("the workspace is used by another running session") and has no pod (a volume cannot attach twice). After the first session is deleted, a new session on the workspace starts. (The service API returns the existing session for the same launch, API-04; this checks the operator.)
Cleanup: `ft_cleanup`.

### OPR-13 Inactivity end survives an operator restart
Safety: test-only, disruptive
Needs: run in the OPR-10 window.
Steps: `ft_template <TPL_STD> ft-opr-idle2 '{"timeouts":{"idle":"6m","warning":"4m","max":"20m"}}'`; `ft_session ft-opr-idle2-s ft-opr-idle2`; `ft_wait`; restart the operator (OPR-10) about 2 minutes after `agentReady` and wait for the rollout. Control: OPR-04 without a restart.
Expect: the session ends about 6 minutes after `agentReady`, as in the control: timers derive from the session's status and the agent, not from operator memory. `IdleWarningSent` is set once (no second notice after the restart).
Cleanup: `ft_cleanup`.

### OPR-14 Operator down while sessions change
Safety: test-only, disruptive
Steps: record the operator replicas; make a pool fixture (module 05) with one claimed session `ft-opr-c1`; `k scale deploy/$P-operator --replicas=0`; create `ft-opr-c2` (warm) and `ft-opr-c3` (cold, workspace), delete `ft-opr-c1`; wait 30 s; scale back; count `claimed` and `claim` log lines per session.
Expect: both new sessions reach `Ready` within a minute after the operator is back, each with exactly one claim (one `Claimed` or `Created` Event); the pod of the deleted session is gone (a claimed pod without a live session is deleted after 30 s, the pool refills); no `Failed` session.
Cleanup: `ft_cleanup`; replicas restored.

### OPR-15 Capacity exhausted
Safety: test-only
Steps: `ft_template <TPL_STD> ft-opr-big '{"resources":{"requests":{"cpu":"1000"}}}'`, `ft_session ft-opr-big-s ft-opr-big`, wait one minute; `k get idesession ft-opr-big-s -o jsonpath='{.status.conditions}{"\n"}{.status.errorCode} {.status.message}{"\n"}'`; `k get idepools`.
Expect: the pod stays `Pending` (`Unschedulable`), the condition `CapacityPressure` is `True` on the session, then the session is `Failed` with `errorCode: capacity-exhausted` after `capacity.exhaustedAfter` (45 s by default; the message names the node pool, `eduide` on `tum-student`). While the pressure lasts the operator may delete the oldest idle pod of any pool in the same node pool (`eduide_capacity_evictions_total`) and holds those pools at 0 idle; afterwards the pools refill (POOL-03, `CapacityPressure=False` on the pool, `NoPressure`). The landing page shows "The cluster is full right now. Please try again in a few minutes." for this code (LAND-08 text list).
Cleanup: `ft_cleanup`; check `k get idepools` returns to the normal idle counts.

### OPR-16 Session pod hardening
Safety: prod-safe
Needs: any session pod (an idle pool instance is enough).
Steps: `k get pod <pod> -o json | jq '{automount: .spec.automountServiceAccountToken, podSC: .spec.securityContext, nodeSel: .spec.nodeSelector, c: [.spec.containers[] | {name, sc: .securityContext, res: .resources, env: [.env[]?.name]}]}'`
Expect: `automountServiceAccountToken: false` (no Kubernetes credentials in the pod); pod seccomp `RuntimeDefault`; `ide` runs `runAsNonRoot` with the template's `runAsUser` (101), no privilege escalation, all capabilities dropped; `agent` runs as uid 65532 with a read-only root filesystem, the ports `proxy` 8080 and `control` 8081 and probes on 8081; the `ide` container's env names hold only the template's env (`THEIA`, `SCORPIO_THEIA_ENV_STRATEGY`) and no launch data; the node selector is the cluster's pool.

## Unverified, check in the first run

- Timings in OPR-04, OPR-05, OPR-13: the polling interval of the operator (`r.poll`, jittered) delays an end by at most one step; the code ends a session at the exact deadline once it looks, so expect seconds, not a monitor interval.
- OPR-04 step 4: whether the notice shows in the IDE as a notification and the condition `IdleWarningSent` flips back to `False` with reason `Active` after activity.
- OPR-10: that no `Reclaimed` Event appears after an operator restart.
- OPR-15: the exact message and that the pod stays `Pending` on `tum-student` (a request of 1000 CPUs is refused by the scheduler, not by quota). Evictions touch the real pool of the environment.
- OPR-11: whether the pull error of a missing tag on `ghcr.io` counts as "not found" for `Hopeless` (otherwise the 10 minute start limit applies; record the time).
- `k get events` field selector names (`involvedObject.name`) on the Kubernetes version of the cluster.

## Retired

- OPR-09 Sidecar session and its NetworkPolicy: 2026-11-24, the Go stack has no sidecars in templates; the agent is the only sidecar (OPR-16, module 06).
- The old facts about monitor polling (`--monitorInterval`), `last-session-end-reason` and `monitor-answered` annotations, the lifetime check every minute, and the Java status values `HANDLING`, `HANDLED`, `ERROR` no longer exist.

## Explore

- Delete a session pod by hand (`k delete pod`): the session fails with `start-failed` ("the instance is gone" or "stopped") and a saved workspace stays; what does the student see (LAND rows)?
- Delete the IDEWorkspace while its session runs: what happens (the session has the workspace as owner and goes with it)?
- Create 20 fixture sessions at once: time to `Ready`, any `Failed`, operator memory (`k top pod`), `eduide_claim_total{result="conflict"}`.
- Delete the token Secret `ide-<instance>-token` of a running instance: the operator repairs children or fails the session with "the access token Secret of the instance is missing".
- Restart only the `agent` container of a running session (for example by making its process exit through the node): the operator pushes the launch data again (Event `Reclaimed`, log `re-claim after agent restart`).
- Helm upgrade that removes a template while a session of it runs (OPR-07 for real).
- Quota: a namespace `ResourceQuota` smaller than the pool (Event `QuotaExceeded`, one log line per session).
