# 04 Operator and session lifecycle (OPR)

Server module. Uses the fixtures from the README (`ft_appdef`, `ft_workspace`, `ft_session`, `ft_wait`, `ft_cleanup`), so no user token is needed. Name every object `ft-opr-...`.

Sources: EduIDE-Cloud `java/operator/.../BasicTheiaCloudOperator.java` (lifetime check every minute), `.../plugins/MonitorActivityTracker.java` (inactivity), `.../handler/session/{LazySessionHandler,EagerSessionHandler,EagerWithLazyFallbackSessionHandler,SessionStatusUtil}.java`, `.../sidecar/{SidecarManager,SidecarResourceFactory}.java`, `src/main/resources/templateDeployment.yaml`, `TheiaCloudOperatorArguments.java`; EduIDE-Helm `charts/eduide/values.yaml` (`appDefinitions.defaults`: `timeout: 1440`, `activityTracker.notifyAfter: 50`, `timeoutAfter: 60`), `charts/eduide/templates/networkpolicies.yaml`.

Facts:
- Lifetime: AppDefinition `spec.timeout` (minutes since session creation), checked every minute; ends with reason `lifetime`.
- Inactivity: `spec.monitor.activityTracker.notifyAfter` (popup) and `timeoutAfter` (stop), defaults 50 and 60 minutes; ends with reason `inactivity`. The reason is written to the Workspace annotation `theia-cloud.io/last-session-end-reason`.
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
Steps:
1. `ft_appdef <APP_STD> ft-opr-idle 0` then `k patch appdefinition ft-opr-idle --type merge -p '{"spec":{"monitor":{"activityTracker":{"notifyAfter":2,"timeoutAfter":4}}}}'`.
2. `ft_workspace ft-opr-idle-ws ft-opr-idle`, `ft_session ft-opr-idle-s ft-opr-idle ft-opr-idle-ws`, `ft_wait ft-opr-idle-s`.
3. For the popup: run the same with the logged-in user's own session in the browser instead (launch via API-04 on `ft-opr-idle`) and leave the tab idle.
4. Watch `k get session ft-opr-idle-s -w` and the operator log (`k logs deploy/operator-deployment -f | grep -i ft-opr-idle`).
Expect: in the browser a notification appears after about 2 minutes; the session is deleted after about 4 minutes (activity interval: `monitor.activityTracker.interval`); the Workspace carries `theia-cloud.io/last-session-end-reason=inactivity`. Typing in the IDE or starting a task resets the timer.
Cleanup: `ft_cleanup`.

### OPR-05 Lifetime timeout
Safety: test-only
Steps: `ft_appdef <APP_STD> ft-opr-life 0`, `k patch appdefinition ft-opr-life --type merge -p '{"spec":{"timeout":3}}'`, workspace and session as in OPR-04, keep the IDE tab active.
Expect: the session is deleted 3 to 4 minutes after creation despite activity; reason `lifetime` on the Workspace.
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
Steps: with OPR-02's session running (and POOL-01's pool if module 05 runs), `k rollout restart deploy/operator-deployment`, wait for the rollout, wait two minutes.
Expect: running sessions keep their pods and URLs (no pod restart: compare pod UIDs before and after); new sessions start afterwards; the operator log shows the resume of data bridge injections and no exception loop.

## Explore

- Delete a session pod by hand (`k delete pod`): does the Deployment bring it back with the same workspace and URL?
- Delete the Workspace while its session runs: what happens to the session and what does the student see?
- Create 20 fixture sessions at once: time to HANDLED, any ERROR, operator memory (`k top pod`).
- Two sessions on the same workspace at once (two Session CRs naming it).
- An AppDefinition with an image tag that does not exist: status, message, and does the session ever leave HANDLING?
- `k get events --field-selector involvedObject.kind=Session` during these tests: are the events useful?
