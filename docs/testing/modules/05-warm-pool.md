# 05 Warm pool, prewarming (POOL)

Server module. Needs an environment with `operator.eagerStart: true` (all TUM environments via `_base.yaml`; not Mannheim). Pool tests use their own AppDefinition `ft-pool` so the pool students use stays untouched. Prewarming applies to ephemeral sessions only.

Sources: EduIDE-Cloud `java/operator/.../pool/PrewarmedResourcePool.java` (reconcile, reserveInstance, releaseInstance, resetClaimedInstance, resetOrphanedClaims, needsRecreation, isOutdated, scheduleReconcile), `.../handler/appdef/EagerStartAppDefinitionAddedHandler.java`, `.../handler/session/{EagerSessionHandler,EagerWithLazyFallbackSessionHandler}.java`, `java/common/.../util/NamingUtil.java`.

Facts:
- Pool size is the AppDefinition's `spec.minInstances`; reconcile runs when the AppDefinition is added or changed and on operator start. There is no periodic reconcile.
- Instance objects are named `instance-<n>-<app>-<last 12 of AppDefinition UID>-<suffix>`; the bridge token Secret ends in `-bridge-token`.
- A claimed instance's services carry `theia-cloud.io/claimed=<session UID>`; the session carries annotations `theia-cloud.io/session-start-strategy=eager` and `theia-cloud.io/instance-id=<n>`. With no free instance the session falls back to a lazy start (`session-start-strategy=lazy-fallback`) and a one-shot reconcile runs 5 s later.
- Release: the instance is reset (bridge token rotated, pod deleted) or, if it is outdated, incomplete, or shares a workspace with sidecars, discarded and recreated. The claim label is removed last.
- Outdated: the resource label `theia-cloud.io/appdefinition-generation` differs from the AppDefinition generation, or the Deployment lacks NetworkPolicy labels or the bridge token reference, or still has a `--skip-auth-route` argument.
- Orphaned claims (claimed by a session that no longer exists) are reset at the start of every full reconcile, never by the per-instance reconcile after a release.
- Claimed pool pods carry no session label; find them by `theia-cloud.io/instance-id` (README).
- Session containers have no readiness probe: a "ready" pod only means "containers running".

Helper (`custom-columns` cannot read label keys with dots, and a plain `grep` also matches sidecar objects and other apps starting with `ft-pool`):
```bash
pool() { local a=${1:-ft-pool}; k get deploy,svc,secret -o json | jq -r --arg a "$a" '.items[] | select(.metadata.name|test("^instance-[0-9]+-"+$a+"-[0-9a-f]{12}")) | [.kind, .metadata.name, (.metadata.labels["theia-cloud.io/claimed"]//"-"), (.metadata.labels["theia-cloud.io/appdefinition-generation"]//"-"), ([.metadata.ownerReferences[]?.kind]|join("+")), .metadata.resourceVersion] | @tsv'; k get appdefinition "$a" -o jsonpath='generation={.metadata.generation}{"\n"}'; }
```

### POOL-01 Pool is filled
Safety: test-only
Steps: `ft_appdef <APP_POOL> ft-pool 2`, wait up to 10 minutes, `pool`, `k get pods | grep ft-pool`.
Expect: instances 1 and 2 each have a Deployment with a running pod (no readiness probe exists, so "ready" means containers started), their services and a `-bridge-token` Secret; nothing is claimed; generation labels equal the AppDefinition generation.

### POOL-02 Real pools are filled
Safety: prod-safe
Steps: for every AppDefinition with `minInstances > 0`: count ready, unclaimed instance pods.
Expect: unclaimed ready instances equal `minInstances` minus claimed ones, or recovery is visible (pods starting). An empty pool for longer than 5 minutes is what alert `EduIDEWarmPoolEmpty` reports (module 10).

### POOL-03 Claim
Safety: test-only
Steps: `ft_session ft-pool-s1 ft-pool`, `ft_wait ft-pool-s1`, then `k get session ft-pool-s1 -o jsonpath='{.metadata.annotations}'` and `pool`.
Expect: HANDLED within seconds (no image pull, no new Deployment); annotations `session-start-strategy=eager` and `instance-id=1` (the lowest free instance); both services of instance 1 carry `theia-cloud.io/claimed=<session UID>` and an ownerReference to the session. Record the time to HANDLED.

### POOL-04 Release
Safety: test-only
Steps: note the bridge token Secret's `resourceVersion` and the pod UID of instance 1, `k delete session ft-pool-s1`, wait one minute, `pool`.
Expect: the claim label and session ownerReferences are gone; the pod of instance 1 is new (different UID); the token Secret changed (`resourceVersion` differs: the token was rotated; never print the value). Compare the new pod's token with the Secret by hash only: `a=$(k exec $P -c <ide> -- sh -c 'printf %s "$DATA_BRIDGE_TOKEN"' | shasum)`, `b=$(k get secret <secret> -o jsonpath='{.data.token}' | base64 -d | shasum)`; `[ "$a" = "$b" ]`. The instance is free again and ready within a few minutes. Nothing a user wrote in the first session is visible in a new claim of instance 1 (start POOL-03 again, create a file before releasing, check after the second claim).

### POOL-05 Exhaustion falls back to lazy start (NO_CAPACITY)
Safety: test-only
Steps: claim both instances (`ft-pool-s1`, `ft-pool-s2`), then `ft_session ft-pool-s3 ft-pool`, `ft_wait ft-pool-s3`, and check `k logs deploy/operator-deployment --since=5m | grep -E 'pool-no-capacity|ft-pool' | tail`.
Expect: s3 starts lazily (annotation `session-start-strategy=lazy-fallback`, its own Deployment, slower); the operator logs a no-capacity reconcile; the pool does not grow beyond `minInstances`. After deleting all three sessions the pool returns to two free instances.
Cleanup: delete the sessions.

### POOL-06 Outdated instances are recreated
Safety: test-only
Steps: with one instance claimed and one free, change the spec: `k patch appdefinition ft-pool --type merge -p '{"spec":{"requestsCpu":"201m"}}'`; wait two minutes; `pool`.
Expect: the free instance is recreated with the new generation label; the claimed instance keeps running (claimed instances are skipped) and is discarded and recreated only when its session ends (forced recreate instead of reset).

### POOL-07 Pool size change
Safety: test-only
Steps: `k patch appdefinition ft-pool --type merge -p '{"spec":{"minInstances":3}}'`, wait, `pool`; then set 1, wait, `pool`.
Expect: instance 3 appears; then instances with id > 1 that are not claimed are deleted with their Secrets. A claimed instance with id > 1 survives until released. The generation bump of a size change recreates every free instance (Cloud 3.0.1; record, not a failure).

### POOL-08 Orphaned claim
Safety: test-only
Steps: put a claim label for a session that does not exist on a free instance's services: `for s in $(k get svc -o name | grep 'instance-2-ft-pool'); do k label $s theia-cloud.io/claimed=00000000-dead-beef-0000-000000000000; done`, then trigger a reconcile by changing the AppDefinition (an annotation is not enough; set `minInstances` to 3 and back to 2), by restarting the operator (POOL-09), or without touching the spec: claim all free instances plus one more session (the no-capacity reconcile runs 5 s later).
Expect: the operator logs "claimed by a session that no longer exists" and resets instance 2; it becomes free again.

### POOL-09 Operator restart with claimed instances
Safety: test-only, disruptive
Steps: with one claimed and one free instance, `k rollout restart deploy/operator-deployment`, wait for it, then `pool` and open the claimed session's URL.
Expect: the claimed instance keeps its claim and pod (same UID), the session still answers; the free instance is untouched unless outdated; a new claim afterwards works.

### POOL-10 Pool Deployments carry the 3.0 hardening
Safety: prod-safe
Steps: for one instance Deployment of each real pool app:
```bash
D=$(k get deploy -o name | grep -m1 'instance-1-')
k get $D -o json | jq '[.spec.template.spec.containers[] | {name, args, tokenRef: ([.env[]? | select(.name=="DATA_BRIDGE_TOKEN") | .valueFrom.secretKeyRef.name] )}]'
```
Expect: no `--skip-auth-route` argument on the proxy container; the IDE container's `DATA_BRIDGE_TOKEN` comes from a `secretKeyRef` to the instance's `-bridge-token` Secret. Pool pods of Artemis apps have `GRADLE_PREWARM_AUTO_CONFIRM=true` (image env).

### POOL-11 Pool app with a sidecar
Safety: test-only
Needs: a sidecar image as in OPR-09.
Steps: `ft_appdef <APP_POOL> ft-pool-side 1`, patch `spec.sidecars` as in OPR-09, wait one minute, `k get deploy,svc,networkpolicy | grep ft-pool-side`; change `requestsCpu`, wait one minute, list again; claim a session, list again; release.
Expect: after each step a Deployment and Service `instance-1-<sidecar>-ft-pool-side-...` with a running pod and one `...-sidecar-netpol`; no ERROR in the operator log for the reconcile; the claimed session reaches its sidecar on the sidecar port. Cloud 3.0.1: every full reconcile deletes the sidecar Deployment (it is parsed as instance 1); record `fail`.
Cleanup: delete the session, `ft_cleanup`.

### POOL-12 Orphan after release
Safety: test-only
Steps: with `ft-pool` (min 2): claim A (instance 1); label the services of free instance 2 with A's UID (as in POOL-08); delete A; `pool` after one and after five minutes.
Expect (target): instance 2 is reset within a few minutes without a pool exhaustion. Cloud 3.0.1: it stays claimed until the next full reconcile (pool exhaustion, AppDefinition change, operator start); record `fail`.
Cleanup: `ft_cleanup`.

### POOL-13 Broken free instance is not handed out
Safety: test-only
Steps: with `ft-pool` (min 2): delete the `-bridge-token` Secret and then the pod of free instance 2 (the new pod fails with `CreateContainerConfigError`); claim two sessions.
Expect (target): the second session falls back to lazy (or waits) and instance 2 is repaired. Cloud 3.0.1: the second session gets instance 2, HANDLED, with a dead IDE; the release repairs it; record `fail`.
Cleanup: delete the sessions, `ft_cleanup`.

Cleanup for the module: delete all `ft-pool-` sessions, then `ft_cleanup`; check that no `instance-*-ft-pool-*` object remains a few minutes later (they are owned by the AppDefinition).

## Explore

- Claim and delete in a tight loop (10 times): does the pool ever end up with a stuck claim or a missing instance?
- Two sessions created in the same second for one free instance: exactly one eager, one lazy?
- Delete an instance pod or its Secret by hand while it is free, and while it is claimed; then restart the operator: does the full reconcile repair a missing Secret?
- `minInstances` change on a real pool during lecture-like load (all free instances restart, POOL-07).
- Scale `minInstances` to 0 while instances are claimed.
- Node drain or a pod eviction of a free instance: does it come back without a reconcile trigger (there is no periodic reconcile)?
- Resource cost: how long does a fresh instance take to become ready on a node without the image (preloading)?
