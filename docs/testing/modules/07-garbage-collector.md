# 07 Workspace garbage collector (GC)

Server module. The collector is a small Go program (Deployment `garbage-collector`, pod label `app: theia-workspace-garbage-collector`) that deletes `Workspace` resources older than `WORKSPACE_TTL`, measured from the Workspace's **creation time** (not its last use). The operator then removes the PVC. It runs on a ticker: the first pass happens one `CHECK_INTERVAL` after start, never at startup. There is no dry-run mode.

Sources: workspace-garbage-collector `main.go`, `helm/values.yaml` (`WORKSPACE_TTL: "1209600s"` = 14 days, `CHECK_INTERVAL: "1800s"`), `helm/templates/{deployment,rbac}.yaml`; EduIDE-Cloud `LazyWorkspaceHandler` (workspace deletion, fixed in 2.0.1).

### GC-01 Configuration and image
Safety: prod-safe
Steps: `k get deploy garbage-collector -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}{.spec.template.spec.containers[0].env}{"\n"}'` and `k get role garbage-collector-role -o yaml`
Expect: image `ghcr.io/eduide/garbage-collector:<GC chart appVersion>` (1.0.0 with chart 3.0.x); TTL and interval as in the GC chart unless the environment overrides them (record); `K8S_NAMESPACE` is the environment's namespace; the Role allows only `get, list, watch, delete` on `workspaces`.

### GC-02 It runs
Safety: prod-safe
Steps: `k logs deploy/garbage-collector --since=2h`
Expect: the start banner (`Starting garbage collector...`, namespace, interval, TTL) after the last restart; `Running garbage collection...` followed by `Garbage collection completed successfully` once per interval; `Will check again at ...`. Any `Error during garbage collection` is a finding: a failed delete aborts the rest of that pass.

### GC-03 Nothing young is deleted
Safety: prod-safe
Steps: `k get workspaces -o custom-columns=NAME:.metadata.name,CREATED:.metadata.creationTimestamp --sort-by=.metadata.creationTimestamp | head -5`
Expect: no Workspace is older than the TTL plus one interval (older ones mean the collector is not working). Report counts and dates only, no names of real users' workspaces.

### GC-04 Workspace deletion does not crash the operator
Safety: test-only
Steps:
1. Record the operator pod's restart count.
2. `ft_workspace ft-gc-ws <APP_STD>`, wait for the PVC.
3. `k delete workspace ft-gc-ws` (the same code path the collector triggers).
4. Wait two minutes.
Expect: the PVC is gone; the operator restart count is unchanged; the operator log has no 403 on PersistentVolume deletion (rc.1 finding 1, fixed in Cloud 2.0.1).

### GC-05 End-to-end deletion with a short TTL
Safety: test-only, destructive: with a short TTL the collector deletes **every** Workspace in the namespace older than that TTL, including other users' saved work. Run only on a namespace whose workspaces may all be lost (for example right after a clean install), and only after the environment owner approved it in chat for this run.
Steps:
1. `k get workspaces` and confirm with the owner that all of them may go.
2. Record the current env, then `k set env deploy/garbage-collector WORKSPACE_TTL=120s CHECK_INTERVAL=60s`.
3. `ft_workspace ft-gc-ttl <APP_STD>`; follow `k logs deploy/garbage-collector -f`.
Expect: about 3 minutes after creation the log shows `Deleting workspace created on ... ft-gc-ttl`, the Workspace and its PVC are gone, the operator did not restart. A session running on that workspace at the time is recorded (observe what the student would see).
Cleanup: restore the recorded `WORKSPACE_TTL` and `CHECK_INTERVAL` (or redeploy the environment) and check GC-01 again.

### GC-06 Bad configuration fails loudly
Safety: test-only, disruptive (the collector is down until restored)
Steps: `k set env deploy/garbage-collector CHECK_INTERVAL=0` and watch the new pod.
Expect: the pod crashes at startup with a clear message (zero, negative, empty and unparsable values panic) and alert `EduIDEComponentCrashLooping`/`EduIDEComponentDown` would cover it; the old pod keeps running until the rollout gives up.
Cleanup: `k rollout undo deploy/garbage-collector` and check GC-02's start banner.

## Explore

- A Workspace with a running session older than the TTL: is the session's PVC deleted under a running pod? What does the student see?
- A Workspace stuck in deletion (finalizer): does the next pass skip it or abort?
- Unit-less durations are seconds: is `WORKSPACE_TTL=14` (14 seconds, not days) a trap worth guarding against in the chart?
- Restart the collector repeatedly within one interval: it never runs (ticker only). Is that acceptable during busy rollouts?
