# 04 Operator and session lifecycle (OPR)

Server module. Uses the fixtures from the README (`ft_template`, `ft_pool`, `ft_workspace`, `ft_session`, `ft_wait`, `ft_cleanup`), so no user token is needed. Name every object `ft-opr-...`.

Sources (control plane repo): `internal/controller/{template,pool,session,workspace}`, `internal/claim`, ADR 0007, 0008, 0009, 0016, 0019; `api/v1alpha1/*.go`; design G8, G14, G19, U7.

Facts:
- Pods, Services, HTTPRoutes, token Secrets and PVCs hang by ownerReference on their CR (or on the pod), Kubernetes does the cleanup. Pool pods are bare pods owned by their IDEPool; on claim the controller reference moves to the IDESession.
- Per instance: Pod `ide-<instance>`, Service `ide-<instance>` (port 8080 `http` to the agent proxy), HTTPRoute `ide-<instance>`, Secret `ide-<instance>-token`. The instance id has 20 characters (base32) and is unguessable.
- Session phases: `Pending`, `Starting`, `Ready`, `Failed` with `status.errorCode` one of `capacity-exhausted`, `template-not-found`, `workspace-not-found`, `start-failed`. Timestamps `claimed`, `podReady`, `agentReady`, `ready` in `status.timestamps`.
- Timeouts per template (`spec.timeouts`: `idle` 60m, `warning` 50m, `max` 24h by default). Idle time is the agent's `lastActivity` (extension heartbeat and proxied requests); with no browser after the claim the session counts as inactive. The operator polls the agent in a throttled cycle with jitter and writes `status.lastActivity` only when it moves by more than 5 minutes.
- On expiry the operator deletes the session; the pod is always discarded, `volume` workspaces stay.
- The chart's NetworkPolicies: `$FULL-session-default-deny`, `-session-from-envoy`, `-session-from-operator`, `-session-egress`.

### OPR-01 Operator configuration
Safety: prod-safe
Steps: `k get deploy $FULL-operator -o jsonpath='{.spec.template.spec.containers[0].args}{"\n"}{.spec.template.spec.containers[0].resources}'`; `k get cm $FULL-config -o jsonpath='{.data.config\.yaml}'` (PLAT-08); `k get lease eduide-operator -o yaml | grep -E 'holderIdentity|renewTime'`.
Expect: the operator reads `--config`, metrics on `:9464`, probes on `:8081` (`/healthz`, `/readyz`), leader election with lease `eduide-operator`; memory and cpu requests and limits are set; `sessionsPerUser`, `capacity.exhaustedAfter`, `workspaces.retention` and `grace`, `placement.nodePoolLabel` and `prepull` recorded with their source (chart value).

### OPR-02 Cold session with a volume: lifecycle
Safety: test-only
Steps:
1. `ft_workspace ft-opr-w "$T_STD"` and wait until `k get ideworkspace ft-opr-w -o jsonpath='{.status.phase} {.status.claimName}'` shows Ready and a PVC name; `k get pvc` shows it.
2. `ft_session ft-opr-s1 "$T_STD" ft-opr-w` and `ft_wait ft-opr-s1`.
3. `INST=$(k get idesession ft-opr-s1 -o jsonpath='{.status.instance}')`; `k get pod,svc,httproute,secret | grep "ide-$INST"`; `k get pod ide-$INST --show-labels`; `ft_times ft-opr-s1`.
4. `k delete idesession ft-opr-s1` and wait.
Expect: the session reaches Ready with `startStrategy: cold` (a volume session never uses the pool) and `status.url` `https://$INSTANCE_HOST/<instance>/`; Pod, Service, HTTPRoute and token Secret `ide-<instance>` exist, the last three owned by the Pod (`k get svc ide-$INST -o jsonpath='{.metadata.ownerReferences[0].kind}'` is Pod), the Pod owned by the IDESession; the pod has the labels `component=session`, `template`, `instance`, `state=claimed`, `session`, `owner-hash`; the workspace is mounted at the template's `persistence.mountPath` (default `/home/project`, `k get pod ide-$INST -o jsonpath='{.spec.volumes[*].persistentVolumeClaim.claimName}'` equals `status.claimName`). After step 4 pod, Service, HTTPRoute, token Secret and data Secret are gone within two minutes; the workspace and PVC stay and `status.lastUsed` moved; the operator does not restart.
Cleanup: `ft_cleanup`.

### OPR-03 Error status
Safety: test-only
Steps: `ft_session ft-opr-bad does-not-exist-tpl`; `ft_session ft-opr-bad2 "$T_STD" does-not-exist-ws`; wait a minute each with `ft_wait`.
Expect: phase `Failed` with `errorCode` `template-not-found` and `workspace-not-found` and a readable `message`; no pod, Service or HTTPRoute; the operator keeps running; the failed sessions do not count against the user's limit (API-08).
Cleanup: `ft_cleanup`.

### OPR-04 Idle timeout, warning and the no-browser rule
Safety: test-only
Needs: browser pane (README, "Opening a session in the browser"), logged in as `ME`.
Steps:
1. `ft_template "$T_STD" ft-opr-idle '.spec.timeouts={"idle":"4m","warning":"2m"}'`.
2. Session A with a browser: `ft_session ft-opr-ia ft-opr-idle "" "$ME"`, `ft_wait`, open the IDE and type once, then leave the tab focused and untouched.
3. Session B without a browser: `ft_session ft-opr-ib ft-opr-idle "" "$ME"`, `ft_wait`, never open it.
4. Watch `k get idesessions -w`, the agent status of A (`agent_pf` and `agent $INST GET /v1/status`, README) and the operator log (`k logs deploy/$FULL-operator -f | grep ft-opr-i`).
Expect: A shows a notification in the IDE after about `warning` (the operator pushed `POST /v1/notify`, the extension displays it) and is deleted after about `idle` plus one polling interval after the last real input; `status.lastActivity` is never written more often than every 5 minutes. B (claimed, `connections: 0`, no activity) counts as inactive and ends after `idle` counted from the claim. Typing in A before the end resets its timer (repeat once with a keystroke at 3 minutes: the session survives). After the end: pod, Service, HTTPRoute, tokens and data Secret are gone, `ideworkspaces` unaffected.
Cleanup: `ft_cleanup`.

### OPR-05 Maximum lifetime
Safety: test-only
Steps: `ft_template "$T_STD" ft-opr-life '.spec.timeouts={"max":"3m"}'`, `ft_session ft-opr-l ft-opr-life "" "$ME"`, open the IDE and keep typing every minute.
Expect: the session is deleted about 3 minutes after creation (not after the claim) despite activity; the operator log names the reason `max` (or equivalent); the pod is discarded.
Cleanup: `ft_cleanup`.

### OPR-06 Default timeouts on the real templates
Safety: prod-safe
Steps: `k get idetemplates -o custom-columns=NAME:.metadata.name,IDLE:.spec.timeouts.idle,WARN:.spec.timeouts.warning,MAX:.spec.timeouts.max,RETENTION:.spec.retention`.
Expect: unset (defaults 60m, 50m, 24h apply, G14) or explicit values with a recorded source; `warning < idle` always (the CRD refuses otherwise).

### OPR-07 Template removed while a session runs
Safety: test-only
Steps: `ft_template "$T_STD" ft-opr-orph`, `ft_session ft-opr-os ft-opr-orph "" "$ME"`, `ft_wait`, `k delete idetemplate ft-opr-orph`, watch for 5 minutes (`k get idesession ft-opr-os -o jsonpath='{.status.phase} {.status.message}'`, operator log, restarts).
Expect: the operator stays healthy (no crash loop, no error flood). The running session is not killed silently and not left forever: record what happens (kept running with its own timeouts, or Failed with a message). PLAT-07 lists such a session as "template gone". Design note: this case is not specified; propose the behaviour in the report.
Cleanup: `ft_cleanup`.

### OPR-08 Chart NetworkPolicies present
Safety: prod-safe
Steps: `k get networkpolicy`; `k get networkpolicy $FULL-session-from-envoy $FULL-session-from-operator -o yaml`.
Expect: `default-deny` for ingress on session pods; `from-envoy` admits only the Envoy pods of the gateway on 8080 (agent proxy); `from-operator` admits only the operator pods on 8081; `session-egress` allows DNS and the configured egress and blocks private ranges and the metadata address (compare SEC-07). Policies for service, authz, operator and pool scaler exist. No rule admits session pods to each other. Negative tests are SEC-13.

### OPR-10 Operator restart with running sessions
Safety: test-only, disruptive (the operator is down for about a minute)
Steps: one restart can serve OPR-10, POOL-09, AGENT-07 and OPR-13. Before it, prepare: one opened cold session, one opened warm session (claimed pool pod), one unopened warm and one unopened cold session, one idle pool instance, and OPR-13's closed-tab session. Snapshot: session UIDs, `status.url`, pod UIDs and `status.timestamps`, `eduide_claim_total` (MON), the agent's `/v1/status` of each claimed pod. Then `k rollout restart deploy/$FULL-operator`, wait for the rollout and two minutes, snapshot again and diff.
Expect: running sessions keep their pods and URLs (same pod UIDs, still Ready, timestamps unchanged); no session is claimed a second time (`eduide_claim_total{result="claimed"}` did not rise for existing sessions; each agent still reports its session); the leader lease moved to the new pod; the unopened sessions are served as before; new sessions start afterwards; no exception loop in the log.

### OPR-11 Session pod never starts
Safety: test-only
Steps: `ft_template "$T_STD" ft-opr-badimg '.spec.image=(.spec.image|split(":")[0]+":does-not-exist")'`, `ft_session ft-opr-bi ft-opr-badimg "" "$ME"`, wait 5 minutes; `k get idesession ft-opr-bi -o jsonpath='{.status}'`; `k get events --field-selector involvedObject.kind=Pod | grep ide-`.
Expect: the pod is in `ImagePullBackOff`; the session does not claim Ready. Record how long until `phase` is `Failed` with `errorCode: start-failed` and a message that names the image pull (the design lists the code; no time budget exists yet). It must not stay `Starting` for the whole lifetime and must not count against the per-user limit once failed.
Cleanup: `ft_cleanup`.

### OPR-12 Second session on one workspace
Safety: test-only
Steps: `ft_workspace ft-opr-w2 "$T_STD"`, `ft_session ft-opr-d1 "$T_STD" ft-opr-w2`, `ft_session ft-opr-d2 "$T_STD" ft-opr-w2`, wait one minute, `k get idesessions,pods | grep ft-opr-d`; `k get events | grep -i multi-attach`.
Expect: the second session is refused (`Failed` with `start-failed` and a message about the workspace being in use), not left in `ContainerCreating` with a Multi-Attach error. The first session is unaffected. (Via the API the same request is idempotent and returns the first session, API-04.)
Cleanup: `ft_cleanup`.

### OPR-13 Inactivity end survives an operator restart
Safety: test-only, disruptive
Needs: browser pane; run in the OPR-10 window.
Steps: `ft_template "$T_STD" ft-opr-idle2 '.spec.timeouts={"idle":"8m","warning":"6m"}'`; `ft_session ft-opr-i2 ft-opr-idle2 "" "$ME"`, open the IDE, type once, close the tab; within two minutes restart the operator (OPR-10); wait until `idle` plus one polling interval after the last input. Control: OPR-04 session A in the same window without a restart.
Expect: the session ends at about the same time as the control: the state lives in the agent (`lastActivity`), not in operator memory. The session is deleted, not left running.
Cleanup: `ft_cleanup`.

### OPR-14 Operator down while sessions change
Safety: test-only, disruptive
Steps: record the operator replicas (1); a pool fixture (module 05) with one claimed session; `k scale deploy/$FULL-operator --replicas=0`; create a cold and a warm session and delete the claimed session; wait 30 s; scale back to 1; `ft_wait` both; compare `eduide_claim_total` and the agent claim counts.
Expect: both new sessions reach Ready within a minute; the deleted session's pod and its objects are gone; each new warm session was claimed exactly once (one `claimed` count per session; the agent accepted one claim); no `Failed` session.
Cleanup: `ft_cleanup`; replicas restored.

### OPR-15 Capacity pressure per node pool
Safety: test-only, disruptive (idle pods of every pool in that node pool are deleted while it lasts)
Needs: a node pool label configured (`placement.nodePoolLabel`, PLAT-08) and a template placed on it; announce it; no lecture running.
Steps:
1. Record the node pool value `NP` of the template's effective nodeSelector, and the idle pods of all pools with `eduide.github.io/node-pool=$NP`: `k get pods -l eduide.github.io/node-pool=$NP,eduide.github.io/state=idle`.
2. `ft_template "$T_POOL" ft-opr-cap '.spec.resources.requests={"cpu":"512","memory":"1Ti"}'` (nothing can schedule it) and `ft_pool ft-opr-pool "$T_POOL" 1` for an idle pod in the same pool.
3. `ft_session ft-opr-c1 ft-opr-cap "" "$ME"`; watch for 60 s: `k get pod -l eduide.github.io/session=ft-opr-c1`, `k get idepool -o custom-columns=NAME:.metadata.name,TARGET:.spec.targetIdle,READY:.status.idleReady,COND:.status.conditions[*].type`, operator `/metrics` via port-forward (`eduide_capacity_pressure`, `eduide_capacity_evictions_total`, `eduide_pool_target_idle`).
4. After the session failed, delete it and watch the pools refill.
Expect: the pod is `Pending` and `Unschedulable`; the operator deletes the oldest idle pod in the same node pool (one at a time) and holds all pools of that node pool at 0 idle: `eduide_capacity_pressure{node_pool="$NP"}` is 1, `eduide_capacity_evictions_total{node_pool="$NP"}` rises, `eduide_pool_target_idle` is 0, the IDEPool shows condition `CapacityPressure=True`. After `capacity.exhaustedAfter` (45 s) the session is `Failed` with `errorCode: capacity-exhausted` and the message names the node pool; the landing page shows a stable message (LAND-08). Removing the session ends the pressure and the pools refill to their targets (`eduide_capacity_pressure` back to 0). Pods outside that node pool are untouched. There is no HTTP 555 anywhere.
Cleanup: `ft_cleanup`; wait until the real pools are at their targets again and record the time.

### OPR-16 Pressure does not cross node pools
Safety: test-only, disruptive
Needs: two node pools with a placed template each (`blocked` if the cluster has one pool).
Steps: repeat OPR-15 for pool X and watch the idle pods of pool Y (`k get pods -l eduide.github.io/node-pool=$NP_Y,eduide.github.io/state=idle -w`), including `eduide_capacity_pressure{node_pool="$NP_Y"}`.
Expect: idle pods of Y keep running, Y's gauge stays 0, a normal warm launch on a template placed on Y still starts warm during the pressure on X.
Cleanup: as OPR-15.

### OPR-17 Quota-forbidden pod counts as pressure
Safety: test-only, disruptive (new pods in the whole namespace are refused until the quota is removed)
Steps: count pods (`k get pods --no-headers | wc -l`), create a quota with exactly that count: `k create quota ft-opr-quota --hard=pods=<count>` and label it (`k label resourcequota ft-opr-quota eduide.dev/functional-test=$RUN_ID`); `ft_session ft-opr-q1 "$T_STD" "" "$ME"`; watch for 60 s; delete the quota at once afterwards.
Expect: the pod creation is refused (`exceeded quota` event), the operator treats it like Unschedulable (G8): idle pods are evicted, pools held at 0, and after 45 s the session is `Failed` with `capacity-exhausted`. After deleting the quota the pools refill. Record how many idle pods were evicted when quota, not scheduling, was the cause (the design says quota pressure triggers no preemption, so eviction by the operator is the only relief).
Cleanup: delete the quota first, then `ft_cleanup`.

### OPR-18 Writes only on real change
Safety: prod-safe (read-only, needs a Ready session for 10 minutes)
Steps: `k get idesession <ready session> -o jsonpath='{.metadata.resourceVersion}'` now and after 10 minutes with the IDE tab open and used; count writes of the operator: operator `/metrics` or the API server audit is not available, so use `k get idesession <n> -w --output-watch-events -o name | head` for 10 minutes.
Expect: no status update without a change; `status.lastActivity` moves at most every 5 minutes; a Ready idle session produces no events. A resourceVersion that moves every few seconds is a finding (scale target: 1,000 sessions must not write 1,000 times a minute).

### OPR-19 Session pod contract
Safety: prod-safe
Steps: `k get pod ide-<instance> -o json | jq '{containers:[.spec.containers[]|{name,image,ports,readiness:.readinessProbe.httpGet,liveness:.livenessProbe.httpGet,env:[.env[]?|.name]}], automount:.spec.automountServiceAccountToken, links:.spec.enableServiceLinks, vols:[.spec.volumes[]|keys[0]], ann:.metadata.annotations, labels:.metadata.labels}'`.
Expect: containers exactly `ide` (template image, template env, no launch data) and `agent` (ports 8080 `proxy` and 8081 `control`, readiness `GET :8081/readyz`, liveness `/healthz`, env `AGENT_IDE_PORT` and `AGENT_TOKEN_FILE=/var/run/eduide/token` from the token Secret volume); `automountServiceAccountToken: false`, `enableServiceLinks: false`; the workspace volume (PVC for `volume`, `emptyDir` otherwise) at the mount path; bandwidth annotations `kubernetes.io/ingress-bandwidth` and `egress-bandwidth` when the template sets them; labels `managed-by=eduide`, `component=session`, `template`, `instance`, `state`, `node-pool` when a pool label is configured; no env var holds an e-mail, token or URL of the user.

### OPR-20 Per-instance routing objects
Safety: prod-safe
Steps: `k get httproute ide-<instance> -o json | jq '{labels:.metadata.labels, parents:.spec.parentRefs, hosts:.spec.hostnames, rules:[.spec.rules[]|{match:.matches,filters:[.filters[]|{type, hdr:[.requestHeaderModifier.set[]?|{name,valueLen:(.value|length)}], rewrite:.urlRewrite}],backends:.backendRefs}]}'` (never print the header value).
Expect: parentRef is the deployment's Gateway section; hostnames are exactly the instance host and the webview host; one rule with `PathPrefix /<instance>/`; filters `RequestHeaderModifier` setting `X-EduIDE-Instance-Token` (value length 64 hex characters) and `URLRewrite ReplacePrefixMatch /`; backend Service `ide-<instance>` port 8080; labels `managed-by`, `component=session`, `instance`, `eduide.github.io/route=session` (the SecurityPolicy selects on it). The Service selects exactly that pod; the token Secret key is `token`.

### OPR-21 Pod lost under a running session
Safety: test-only
Steps: `ft_session ft-opr-pl "$T_STD" "" "$ME"`, `ft_wait`, `k delete pod ide-<instance>` (simulates a node loss), watch the session for 3 minutes.
Expect: the session does not stay `Ready` with no pod: record the outcome (expected: `Failed` with `start-failed` or a message that the pod is gone, and the user's overview shows it as ended); the route and token Secret are cleaned up with the pod; the URL answers 403 (AUTHZ-06). A cold session has no controller that recreates its pod; record that this is the intended behaviour.
Cleanup: `ft_cleanup`.

## Explore

- Delete the IDESession while it is `Starting`: any leaked pod, Service, route or Secret? (The session finalizer `eduide.github.io/session` records workspace usage.)
- Delete the data Secret `<session>-data` before the operator claims: does the operator wait, fail, or start without data (the spec says it waits)?
- Create 20 fixture sessions at once: time to Ready, any Failed, operator memory (`k top pod`), status write rate.
- Delete an IDEWorkspace while its session runs: what happens to the session and what does the student see?
- Kill the leader operator pod during a claim: second operator takes over within the lease duration; any double claim?
- Template change (image, resources) while sessions run: running sessions keep their pod, new ones use the new spec.
- `k get events` during these tests: are the events on IDESession useful?
