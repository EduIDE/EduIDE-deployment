# 05 Warm pool, prewarming (POOL)

Server module. Needs an environment with `operator.eagerStart: true` (all TUM environments via `_base.yaml`; not Mannheim). Pool tests use their own AppDefinition `ft-pool` so the pool students use stays untouched. Prewarming applies to ephemeral sessions only.

Sources: EduIDE-Cloud `java/operator/.../pool/PrewarmedResourcePool.java` (reconcile, reserveInstance, releaseInstance, resetClaimedInstance, resetOrphanedClaims, needsRecreation, isOutdated, scheduleReconcile), `.../handler/appdef/EagerStartAppDefinitionAddedHandler.java`, `.../handler/session/{EagerSessionHandler,EagerWithLazyFallbackSessionHandler}.java`, `java/common/.../util/NamingUtil.java`.

Facts:
- Pool size is the AppDefinition's `spec.minInstances`; reconcile runs when the AppDefinition is added or changed and on operator start. There is no periodic reconcile.
- Instance objects are named `instance-<n>-<app>-<last 12 of AppDefinition UID>-<suffix>`; the bridge token Secret ends in `-bridge-token`.
- A claimed instance's services carry `theia-cloud.io/claimed=<session UID>`; the session carries annotations `theia-cloud.io/session-start-strategy=eager` and `theia-cloud.io/instance-id=<n>`. With no free instance the session falls back to a lazy start (`session-start-strategy=lazy-fallback`) and a one-shot reconcile runs 5 s later.
- Release: the instance is reset (bridge token rotated, pod deleted) or, if it is outdated, incomplete, or shares a workspace with sidecars, discarded and recreated. The claim label is removed last.
- Outdated: the resource label `theia-cloud.io/appdefinition-generation` differs from the AppDefinition generation, or the Deployment lacks NetworkPolicy labels or the bridge token reference, or still has a `--skip-auth-route` argument.
- Orphaned claims (claimed by a session that no longer exists) are reset at the start of every reconcile.

Helper:
```bash
pool() { k get deploy,svc,secret -o custom-columns=KIND:.kind,NAME:.metadata.name,CLAIM:.metadata.labels.theia-cloud\.io/claimed,GEN:.metadata.labels.theia-cloud\.io/appdefinition-generation,RV:.metadata.resourceVersion | grep -E "KIND|instance-[0-9]+-ft-pool"; k get appdefinition ft-pool -o jsonpath='generation={.metadata.generation}{"\n"}'; }
```

### POOL-01 Pool is filled
Safety: test-only
Steps: `ft_appdef <APP_POOL> ft-pool 2`, wait up to 10 minutes, `pool`, `k get pods | grep ft-pool`.
Expect: instances 1 and 2 each have a Deployment with a ready pod, their services and a `-bridge-token` Secret; nothing is claimed; generation labels equal the AppDefinition generation.

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
Expect: the claim label and session ownerReferences are gone; the pod of instance 1 is new (different UID); the token Secret changed (`resourceVersion` differs: the token was rotated; never print the value). The instance is free again and ready within a few minutes. Nothing a user wrote in the first session is visible in a new claim of instance 1 (start POOL-03 again, create a file before releasing, check after the second claim).

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
Expect: instance 3 appears; then instances with id > 1 that are not claimed are deleted with their Secrets. A claimed instance with id > 1 survives until released. Note whether the generation bump of the size change also recreated free instances (record, not a failure).

### POOL-08 Orphaned claim
Safety: test-only
Steps: put a claim label for a session that does not exist on a free instance's services: `for s in $(k get svc -o name | grep 'instance-2-ft-pool'); do k label $s theia-cloud.io/claimed=00000000-dead-beef-0000-000000000000; done`, then trigger a reconcile by changing the AppDefinition (an annotation is not enough; set `minInstances` to 3 and back to 2) or by restarting the operator (POOL-09).
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

Cleanup for the module: delete all `ft-pool-` sessions, then `ft_cleanup`; check that no `instance-*-ft-pool-*` object remains a few minutes later (they are owned by the AppDefinition).

## Explore

- Claim and delete in a tight loop (10 times): does the pool ever end up with a stuck claim or a missing instance?
- Two sessions created in the same second for one free instance: exactly one eager, one lazy?
- Delete an instance pod or its Secret by hand while it is free, and while it is claimed.
- Scale `minInstances` to 0 while instances are claimed.
- Node drain or a pod eviction of a free instance: does it come back without a reconcile trigger (there is no periodic reconcile)?
- Resource cost: how long does a fresh instance take to become ready on a node without the image (preloading)?
