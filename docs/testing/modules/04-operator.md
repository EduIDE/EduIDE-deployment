# 04 Operator and session lifecycle (OPR)

Server module. Uses the fixtures from the README (`ft_appdef`, `ft_workspace`, `ft_session`, `ft_wait`, `ft_cleanup`), so no user token is needed. Name every object `ft-opr-...`.

Sources: EduIDE-Cloud `java/operator/.../BasicTheiaCloudOperator.java` (lifetime check every minute), `.../plugins/MonitorActivityTracker.java` (inactivity), `.../handler/session/{LazySessionHandler,EagerSessionHandler,EagerWithLazyFallbackSessionHandler,SessionStatusUtil}.java`, `.../sidecar/{SidecarManager,SidecarResourceFactory}.java`, `src/main/resources/templateDeployment.yaml`, `TheiaCloudOperatorArguments.java`; EduIDE-Helm `charts/eduide/values.yaml` (`appDefinitions.defaults`: `timeout: 1440`, `activityTracker.notifyAfter: 50`, `timeoutAfter: 60`), `charts/eduide/templates/networkpolicies.yaml`.

Facts:
- Lifetime: AppDefinition `spec.timeout` (minutes since session creation), checked every minute; ends with reason `lifetime`.
- Inactivity: `spec.monitor.activityTracker.notifyAfter` (popup) and `timeoutAfter` (stop), defaults 50 and 60 minutes; ends with reason `inactivity`. The operator polls the IDE's monitor every `--monitorInterval` minutes (3 on TUM environments), so an end comes up to one interval late. The monitor listens only after a browser connected, and Cloud 3.0.1 never ends a session by inactivity whose monitor never answered (`MonitorActivityTracker.stopIfGoneSinceTimeout`); a session whose tab was closed is ended once `timeoutAfter` has passed since the last reported activity. The reason is written to the Workspace annotation `theia-cloud.io/last-session-end-reason`.
- Status: `status.operatorStatus` is HANDLING, HANDLED or ERROR, with `status.operatorMessage`.
- Sessions whose AppDefinition is gone are skipped by both timeouts (no cleanup on Cloud 3.0.1).
- The chart renders the session NetworkPolicies `session-default-deny`, `session-allow-dns`, `session-allow-gateway-ingress`, `session-allow-operator` and, with `allowExternalEgress`, `session-allow-external-egress`. The operator adds one `...-sidecar-netpol` per session (lazy) or per pool instance only for apps with sidecars.

### OPR-01 Operator configuration
Safety: prod-safe
Steps: `k get deploy operator-deployment -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n'`
Expect: `--eagerStart` present where the environment sets `operator.eagerStart: true` (TUM `_base.yaml`; Mannheim sets false); `--sessionsPerUser` matches the values; `--enableMonitor` and `--enableActivityTracker` present; `--oAuth2ProxyVersion` recorded. Record the full flag list (it contains no secrets; check before pasting).

### OPR-02 Lazy persistent session lifecycle
Safety: test-only
Steps:
1. `ft_workspace ft-opr-ws <APP_STD>` and wait until its PVC exists (`k get pvc | grep ft-opr-ws` or via the Workspace `spec.storage`).
2. `ft_session ft-opr-s1 <APP_STD> ft-opr-ws` and `ft_wait ft-opr-s1`.
3. `k get pod -l theia-cloud.io/session=ft-opr-s1 --show-labels`; `k get httproute | grep -i ft-opr`.
4. `k delete session ft-opr-s1`.
Expect: the session reaches HANDLED with a URL within the launch timeout; the pod has `app.kubernetes.io/component=session` and `app.kubernetes.io/part-of=theia-cloud`; one HTTPRoute for the session. After step 4 pod, route and session-owned objects go away within two minutes; the Workspace and PVC stay; the operator does not restart.
Cleanup: `ft_cleanup`.

### OPR-03 Error status
Safety: test-only
Steps: `ft_session ft-opr-bad does-not-exist-app` and wait one minute.
Expect: `operatorStatus=ERROR` with a readable `operatorMessage`; no pod; the operator keeps running.
Cleanup: `ft_cleanup`.

### OPR-04 Inactivity timeout and popup
Safety: test-only
Needs: browser pane (README, "Opening a fixture session in the browser").
Steps:
1. `ft_appdef <APP_STD> ft-opr-idle 0` then `k patch appdefinition ft-opr-idle --type merge -p '{"spec":{"monitor":{"activityTracker":{"notifyAfter":2,"timeoutAfter":4}}}}'`.
2. `ft_workspace ft-opr-idle-ws ft-opr-idle`, `ft_session ft-opr-idle-s ft-opr-idle ft-opr-idle-ws`, `ft_wait ft-opr-idle-s`.
3. Open the IDE through a port-forward until the operator logs `Last reported activity` for the session, then close the tab and stop the port-forward.
4. For the popup: launch the logged-in user's own session on `ft-opr-idle` (API-04) and leave the tab focused and idle.
5. Watch `k get session ft-opr-idle-s -w` and the operator log (`k logs deploy/operator-deployment -f | grep -i ft-opr-idle`).
Expect: step 3: `Monitor stopped answering ... Deleting session as timeout of 4 minutes was reached!` within `timeoutAfter` plus one `--monitorInterval` after the last activity; the Workspace carries `theia-cloud.io/last-session-end-reason=inactivity`. Step 4: a notification after about `notifyAfter` (plus up to one monitor interval), deletion after `timeoutAfter` (plus up to one interval). Typing in the IDE or starting a task resets the timer. A fixture session that was never opened is not ended (log `This poll is no evidence of inactivity`): that is by design, not a pass.
Cleanup: `ft_cleanup`.

### OPR-05 Lifetime timeout
Safety: test-only
Steps: `ft_appdef <APP_STD> ft-opr-life 0`, `k patch appdefinition ft-opr-life --type merge -p '{"spec":{"timeout":3}}'`, workspace and session as in OPR-04, keep the IDE tab active.
Expect: the session is deleted between 4 and 5 minutes after creation (timeout + 1 to timeout + 2: `isSessionTimedOut` compares whole minutes with `>` and runs every minute) despite activity; reason `lifetime` on the Workspace.
Cleanup: `ft_cleanup`.

### OPR-06 Default timeouts on the real apps
Safety: prod-safe
Steps: the AppDefinition listing from the README (TIMEOUT, NOTIFY, IDLE columns).
Expect: every app has notifyAfter 50, timeoutAfter 60 and timeout 1440 unless the environment's values override them (then the override is recorded with its source).

### OPR-07 Session whose AppDefinition is gone
Safety: test-only
Steps: `ft_appdef <APP_STD> ft-opr-orphan 0`, `ft_session ft-opr-orphan-s ft-opr-orphan` (ephemeral), `ft_wait`, then `k delete appdefinition ft-opr-orphan` and watch for 5 minutes.
Expect (target behaviour): the session ends by itself. Known state on Cloud 3.0.1: nothing ends it (timeouts skip it); record `fail` with reference to the rc.3 finding until the operator follow-up ships, and check that PLAT-07 catches it.
Cleanup: `k delete session ft-opr-orphan-s`; `ft_cleanup`.

### OPR-08 Chart NetworkPolicies present
Safety: prod-safe
Steps: `k get networkpolicy -l app.kubernetes.io/component=session-network-policy`; `k get networkpolicy session-allow-operator -o yaml`
Expect: the four (five with external egress) policies listed above. `session-allow-operator` admits only pods with `app: operator`, on the data bridge port 16281 and the monitor port. The egress policy excludes the private CIDRs of `networkPolicies.privateEgressCidrs` (test2 adds `198.18.0.0/15`) and the metadata address.

### OPR-09 Sidecar session and its NetworkPolicy
Safety: test-only
Needs: a sidecar image that runs as a non-root uid and listens on one port (prefer one the organisation already uses; otherwise `nginxinc/nginx-unprivileged` on 8080). Record the image.
Steps:
1. `ft_appdef <APP_STD> ft-opr-side 0` and `k patch appdefinition ft-opr-side --type merge -p '{"spec":{"sidecars":[{"name":"ftside","image":"<image>","port":8080}]}}'`.
2. Workspace and lazy session as in OPR-02.
3. `k get pods,svc,networkpolicy | grep ft-opr-side` and the sidecar pod's `securityContext`.
4. Delete the session.
Expect: a sidecar pod and service; one `...-sidecar-netpol` owned by the Session that allows traffic only between the session pod and the sidecar on the sidecar port; sidecar pod with `automountServiceAccountToken: false`, `allowPrivilegeEscalation: false`, all capabilities dropped, seccomp `RuntimeDefault`. Step 4 removes sidecar pod, service and policy.
Cleanup: `ft_cleanup`.

### OPR-10 Operator restart with running sessions
Safety: test-only, disruptive (the operator is down for about a minute)
Steps: one restart can serve OPR-10, POOL-09, DB-07 and OPR-13. Before it, prepare: an opened lazy session, an opened claimed pool instance, an unopened lazy and an unopened eager session (DB-07), one orphan claim (`k label svc instance-N-<app>-<hash>{,-int} theia-cloud.io/claimed=00000000-dead-beef-0000-000000000000`), one free instance, and OPR-13's closed-tab session. Snapshot Session UIDs and URLs, pool objects with claim labels and pod UIDs, and token hashes (POOL-04). Then `k rollout restart deploy/operator-deployment`, wait for the rollout and two minutes, snapshot again and diff.
Expect: running sessions keep their pods and URLs (same pod UIDs, same token hashes); only the orphaned instance is reset; new sessions start afterwards; the operator log shows `Resumed N data bridge injection(s)` and no exception loop.

### OPR-11 Session whose pod never starts
Safety: test-only
Steps: `ft_appdef <APP_STD> ft-opr-badimg 0`, `k patch appdefinition ft-opr-badimg --type merge -p '{"spec":{"image":"<same image>:does-not-exist"}}'`, `ft_session ft-opr-badimg-s ft-opr-badimg`, wait 5 minutes; `k get session ft-opr-badimg-s -o jsonpath='{.status}'`, `k get events --field-selector involvedObject.kind=Session`.
Expect (target): `operatorStatus=ERROR` with a message naming the image pull, or the session ended; Events on the Session. Cloud 3.0.1: HANDLED with a URL for the whole lifetime (24 h), counting against the per-user limit; record `fail`.
Cleanup: `ft_cleanup`.

### OPR-12 Second session on the same workspace
Safety: test-only
Steps: `ft_workspace ft-opr-ws2 <APP_STD>`, `ft_session ft-opr-d1 <APP_STD> ft-opr-ws2`, `ft_session ft-opr-d2 <APP_STD> ft-opr-ws2`, wait one minute, `k get sessions,pods | grep ft-opr-d`.
Expect (target): the second session is refused with ERROR. Cloud 3.0.1: both HANDLED, the second pod hangs in `ContainerCreating` with `Multi-Attach error`; record `fail`. (The service API refuses this case itself; this checks the operator.)
Cleanup: `ft_cleanup`.

### OPR-13 Inactivity end survives an operator restart
Safety: test-only, disruptive
Needs: browser pane; run in the OPR-10 window.
Steps: `ft_appdef <APP_STD> ft-opr-idle2 0`, patch `monitor.activityTracker` to `notifyAfter 6, timeoutAfter 8`; `ft_session ft-opr-idle2-s ft-opr-idle2`; open the IDE (port-forward) until the operator logs `Last reported activity` for it; close the tab; within two minutes restart the operator (OPR-10); wait until 8 minutes plus two monitor intervals after the last activity. Control: OPR-04 step 3 in the same window, without a restart in between.
Expect: the Session carries `theia-cloud.io/monitor-answered=true` after the first answered poll; after the restart `Monitor stopped answering ... Deleting session` at the first poll after the timeout (monitor interval 3 min). Cloud 3.0.1 kept the state in memory and never ended the session; `fail` there. Sessions that never answered before a restart still end only by the lifetime.
Cleanup: `ft_cleanup`.

### OPR-14 Operator down while sessions change
Safety: test-only, disruptive
Steps: record the operator replicas; a pool fixture (module 05) with one claimed session; `k scale deploy/operator-deployment --replicas=0`; create a lazy and a pool session, delete the claimed session; wait 30 s; scale back; `pool`; count `Attempting to reserve instance for session <name>` per session in the operator log.
Expect: both new sessions HANDLED within a minute; the deleted session's instance is reset (`claimed by a session that no longer exists`); exactly one reservation per session and no ERROR. Cloud 3.0.1: two reservations and two injection pollers per session at start, a 409 ERROR on the orphan cleanup; record them.
Cleanup: `ft_cleanup`; replicas restored.

## Explore

- Delete a session pod by hand (`k delete pod`): does the Deployment bring it back with the same workspace and URL?
- Delete the Workspace while its session runs: what happens to the session and what does the student see?
- Create 20 fixture sessions at once: time to HANDLED, any ERROR, operator memory (`k top pod`).
- Delete a lazy session's `-bridge-token` Secret, then its pod: is the Secret recreated (Cloud 3.0.1: no, `CreateContainerConfigError`)?
- Helm upgrade that removes an app from the catalog while a pool instance of it is claimed.
- `k get events --field-selector involvedObject.kind=Session` during these tests: are the events useful?
