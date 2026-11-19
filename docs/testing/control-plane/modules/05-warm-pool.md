# 05 Warm pool and start strategies (POOL)

Server module. Pool tests use their own template clone and IDEPool (`ft_template`, `ft_pool`) so the pool students use stays untouched. Prewarming applies to sessions without persistence only (matrix below).

Sources (control plane repo): `internal/controller/pool`, `internal/claim`, ADR 0007, 0008, 0009; `api/v1alpha1/idepool_types.go`; `docs/contracts/metrics.md` (`eduide_pool_instances`, `eduide_pool_target_idle`, `eduide_claim_total`).

Facts:
- `IDEPool.spec`: `templateRef` (immutable), `minIdle` (floor, Helm), `targetIdle` (pool scaler, also via `/scale`), `maxInstances`. The operator keeps `clamp(max(minIdle, targetIdle), 0, maxInstances - claimed)` idle instances, and 0 under capacity pressure (OPR-15).
- Status: `replicas` (idleReady plus idleStarting, the `/scale` status), `idleReady`, `idleStarting`, `claimed`, `selector`, conditions. Pool pods are bare pods `ide-<instance>`; Service, HTTPRoute and token Secret exist from the start (routes are created while warming, under an unguessable path), labelled `eduide.github.io/pool=<pool>`, `state=idle`.
- Readiness: the agent's `/readyz` is ready when the IDE answers on its loopback port, so "idleReady" means a usable IDE (unlike the old stack).
- Claim (ADR 0009): the operator picks the oldest idle ready pod from the cache and patches `state=claimed`, `session` and `owner-hash` with a `resourceVersion` precondition; a conflict means the next candidate. Then one `POST /v1/claim` to the agent. A claim changes no Service, HTTPRoute or token.
- Strategies in `status.startStrategy`: `warm-ready` (claimed an idle ready pod), `warm-starting` (waited for an idle pod that was still starting), `cold` (own pod, no pool or no idle pod). Matrix: `none` with pool is warm; `none` without pool, `volume` without pool and `volume` with pool are cold.
- Release: the session leaves Ready first (authz denies), then the pod is discarded (never reused) and the pool refills asynchronously.

Helper `pool_pods <pool>` is in the README.

### POOL-01 Pool is filled
Safety: test-only
Steps: `ft_template "$T_POOL" ft-pool-t` (clone of a template that allows `none`), `ft_pool ft-pool ft-pool-t 2`, wait up to 10 minutes, `pool_pods ft-pool`, `k get svc,httproute,secret | grep -c ide-`, `k get deploy,rs | grep -c ft-pool`.
Expect: two pods `ide-<instance>` with `state=idle`, all containers ready (IDE answers through the agent), each with its Service, HTTPRoute (label `eduide.github.io/route=session`) and token Secret (all found by the label `eduide.github.io/instance=<instance>`; only the Pod carries the pool label); `IDEPool` status `idleReady=2`, `idleStarting=0`, `claimed=0`, `replicas=2`; no Deployment and no ReplicaSet exist for the pool.

### POOL-02 Real pools are filled
Safety: prod-safe
Steps: `k get idepools -o custom-columns=NAME:.metadata.name,MIN:.spec.minIdle,TARGET:.spec.targetIdle,MAX:.spec.maxInstances,READY:.status.idleReady,STARTING:.status.idleStarting,CLAIMED:.status.claimed`
Expect: `idleReady + idleStarting` equals `max(minIdle, targetIdle)` (capped), or recovery is visible (pods starting) and no `CapacityPressure=True` condition. `eduide_pool_instances` agrees with the status (MON-09).

### POOL-03 Warm claim
Safety: test-only
Steps: `ft_session ft-pool-s1 ft-pool-t` (a session finds the pool of its template through `templateRef`), `ft_wait ft-pool-s1`, `ft_times ft-pool-s1`, `pool_pods ft-pool`, `k get idesession ft-pool-s1 -o jsonpath='{.status.startStrategy} {.status.instance}'`, and note the `resourceVersion` of the HTTPRoute `ide-<instance>` before and after.
Expect: Ready within a few seconds (no image pull, no new pod created for it); `startStrategy: warm-ready`; the claimed pod now has `state=claimed`, `session=ft-pool-s1`, `owner-hash`, keeps its `pool` label, and its controller reference points to the IDESession; the HTTPRoute, Service and token Secret did not change (same resourceVersion); the pool shows `claimed=1` and starts a replacement (a third pod appears, `idleStarting` 1). Record the time to Ready and `timestamps` (claimed to agentReady).

### POOL-04 Release
Safety: test-only
Steps: note the pod UID and name of the claimed instance, `k delete idesession ft-pool-s1`, immediately check the instance URL as the owner in the browser (AUTHZ-06), wait one minute, `pool_pods ft-pool`, `k get pod,svc,httproute,secret | grep <instance>`.
Expect: the pod is discarded (the name and UID are gone, it is not reset and not reused); its Service, HTTPRoute, token Secret and the data Secret are gone with it (ownerReferences); the pool is back at its target with new pods; the old URL no longer opens. Nothing a user wrote in the first session is visible in a new claim: claim again, `k exec ide-<new> -c ide -- ls -A /home/project` holds no file of the first session (create a file before releasing, `ft-persist.txt`).

### POOL-05 Exhaustion falls back to a cold start
Safety: test-only
Steps: with `minIdle 2`, `maxInstances 5`: claim both idle pods (`ft-pool-s1`, `ft-pool-s2`), then at once `ft_session ft-pool-s3 ft-pool-t`, `ft_wait ft-pool-s3`, `k get idesession -o custom-columns=NAME:.metadata.name,STRATEGY:.status.startStrategy`, and the metric `eduide_claim_total` (`conflict`, `empty`).
Expect: s3 starts with `startStrategy` `warm-starting` (a replacement pod was already starting and the session waits for it) or `cold` (own pod, slower); never an error; `eduide_claim_total{result="empty"}` rose; the pool never grows beyond `maxInstances` counting claimed pods; after deleting all three sessions the pool returns to two idle pods. The old NO_CAPACITY error and the 555 status do not exist: running out of idle pods is a normal cold start, running out of cluster room is OPR-15.
Cleanup: delete the sessions.

### POOL-06 Template change replaces idle pods
Safety: test-only
Steps: with one claimed and one idle pod: `k patch idetemplate ft-pool-t --type merge -p '{"spec":{"resources":{"requests":{"cpu":"201m"}}}}'`; wait two minutes; `pool_pods ft-pool`; compare pod UIDs.
Expect (design intent, check ADR 0008 and the controller; record what happens): idle pods created from the old spec are replaced by pods with the new spec, so a new claim gets the new template; the claimed pod keeps running and is simply discarded when its session ends. A template change never leaves idle pods with a stale spec for good.

### POOL-07 Pool size via targetIdle, minIdle and maxInstances
Safety: test-only
Steps: `k patch idepool ft-pool --type merge -p '{"spec":{"targetIdle":4}}'`, wait, `pool_pods ft-pool`; then `targetIdle` 1 (floor `minIdle` 2 applies), then `minIdle` 0 and `targetIdle` 0 (no idle pods), then `maxInstances: 1` with one claimed session, then try `maxInstances: 1` with `minIdle: 2` and `targetIdle: 3`.
Expect: idle pods follow `clamp(max(minIdle, targetIdle), 0, maxInstances - claimed)` after each step: 4, then 2, then 0; with one claimed and `maxInstances 1` no idle pod is kept; the last patch is rejected by the CRD (`minIdle must not exceed maxInstances`; a `targetIdle` above `maxInstances` says `targetIdle must not exceed maxInstances`). Surplus idle pods are deleted with their Service, HTTPRoute and Secret; a claimed pod is never touched by a resize.
Cleanup: reset the pool, delete sessions.

### POOL-08 Orphaned claim
Safety: test-only
Steps: take one idle pod and label it as claimed by a session that does not exist: `k label pod <idle pod> eduide.github.io/state=claimed eduide.github.io/session=ft-pool-ghost --overwrite`; wait two minutes; `pool_pods ft-pool`.
Expect: the operator finds a claimed pod whose session no longer exists and discards it (pods are never reset or reused); the pool refills with a new idle pod. The ghost pod's URL never opens for anybody (AUTHZ-04). An operator restart (OPR-10) has the same effect for pods claimed while the operator was down.

### POOL-09 Operator restart with claimed instances
Safety: test-only, disruptive
Steps: with one claimed and one idle instance, `k rollout restart deploy/$FULL-operator`, wait for it, then `pool_pods ft-pool` and open the claimed session's URL as its owner.
Expect: the claimed instance keeps its claim and pod (same UID), the session still opens, the agent reports the same session; the idle pod is untouched; a new claim afterwards works and `eduide_claim_total` counts it once.

### POOL-10 Pool pods carry the session pod contract
Safety: prod-safe
Steps: for one idle pod of each real pool: OPR-19's `jq` on `k get pod <idle pod> -o json`, plus `k get secret ide-<instance>-token -o jsonpath='{.metadata.ownerReferences[0].kind}'`.
Expect: containers `ide` and `agent` only, readiness probe on `:8081/readyz`, `automountServiceAccountToken: false`, token from the Secret volume, no launch data anywhere in the spec (a pool pod has none yet), token Secret owned by the Pod, `state=idle`, node-pool label when configured.

### POOL-13 A broken idle instance is not handed out
Safety: test-only
Steps: with `ft-pool` at `minIdle 2`: break idle pod 2 by changing the image of its IDE container (`k patch pod <idle pod 2> --type json -p '[{"op":"replace","path":"/spec/containers/0/image","value":"example.org/does-not-exist:1"}]'`, check the `ide` container index first); wait until it is not ready; claim two sessions at once.
Expect: the first session gets the healthy pod (`warm-ready`), the second does not get the broken one: `warm-starting` or `cold` with a running IDE. The broken pod is not counted in `idleReady` and is replaced by the controller.
Cleanup: delete the sessions, `ft_cleanup`.

### POOL-14 Start strategy matrix
Safety: test-only
Needs: `ft-pool-t` with the pool `ft-pool` (min 2) and `T_STD` clone `ft-nopool-t` without a pool; both allow `none` and `volume`.
Steps: four sessions, one per cell, `ft_wait` each and read `status.startStrategy`:
1. `none`, with pool: `ft_session ft-pool-m1 ft-pool-t`.
2. `none`, no pool: `ft_session ft-pool-m2 ft-nopool-t`.
3. `volume`, no pool: `ft_workspace ft-pool-w3 ft-nopool-t`; `ft_session ft-pool-m3 ft-nopool-t ft-pool-w3`.
4. `volume`, with pool: `ft_workspace ft-pool-w4 ft-pool-t`; `ft_session ft-pool-m4 ft-pool-t ft-pool-w4`.
Expect: `warm-ready`, `cold`, `cold`, `cold`. Cell 4 leaves the idle pods of the pool untouched (same UIDs, `claimed` count unchanged) and mounts the PVC; cell 1 has no PVC. Time to Ready per cell goes into the report.
Cleanup: `ft_cleanup`.

### POOL-15 Warm-starting
Safety: test-only
Steps: create a fresh pool (`ft_pool ft-pool-fresh ft-pool-t 1`) and, as soon as its pod exists but is not ready (`pool_pods ft-pool-fresh` shows `false`), `ft_session ft-pool-fs ft-pool-t` (the pool of that template). Alternative: claim all idle pods of a pool and launch once more within the refill window.
Expect: the session waits for the starting pod: `startStrategy: warm-starting`, `timestamps.claimed` is set when that pod became ready, time to Ready is shorter than a cold start of the same template (`ft_times`). If the session instead starts cold, record the timing window.
Cleanup: `ft_cleanup`.

### POOL-16 Concurrent claims never double-assign
Safety: test-only
Steps: pool with `minIdle 3`, `maxInstances 10`; create 10 sessions at once (`for i in $(seq 1 10); do ft_session ft-pool-c$i ft-pool-t & done; wait`); `ft_wait` each; then count claims per pod: `k get pods -l eduide.github.io/pool=ft-pool -o json | jq -r '.items[]|.metadata.labels["eduide.github.io/session"]' | sort | uniq -d`.
Expect: no duplicate session label (no pod serves two sessions), no session has two pods, all 10 reach Ready (up to 3 `warm-ready`, the others `warm-starting` or `cold`); `eduide_claim_total{result="conflict"}` may be above 0 (lost optimistic locks are retried with the next candidate); each agent reports exactly its session (`agent $INST GET /v1/status`). The pool never exceeds `maxInstances`.
Cleanup: `ft_cleanup`.

### POOL-17 /scale subresource
Safety: test-only
Steps: `k scale idepool ft-pool --replicas=3`; `k get idepool ft-pool -o jsonpath='{.spec.targetIdle} {.status.replicas} {.status.selector}'`; `k scale idepool ft-pool --replicas=0`.
Expect: `/scale` writes `spec.targetIdle` (3, then the floor `minIdle` applies for 0) and reads `status.replicas`; `status.selector` selects the idle pods of the pool (`k get pods -l "$(k get idepool ft-pool -o jsonpath='{.status.selector}')"` lists them). This is what HPA, KEDA and the pool scaler use.

### POOL-18 Pool scaler integration
Safety: prod-safe
Needs: the pool scaler deployed (`poolScaler.enabled`); record `blocked` otherwise (not deployed on test3).
Steps: `k get deploy $FULL-pool-scaler` and its logs (`--since=1h`, no values), `k get idepools -o json | jq '.items[]|{name:.metadata.name,ann:(.metadata.annotations|with_entries(select(.key|startswith("eduide.github.io/scaler"))))}'`, and the metrics the scaler reads (`eduide_pool_instances`, `eduide_sessions`, MON-09).
Expect: the scaler runs and logs no errors about missing metrics; annotations use the prefix `eduide.github.io/` (`scaler-mode`, `scaler-override`), none the old `pool-scaler.eduide/`; it writes only `spec.targetIdle` (not `minIdle`, not the template) and reads the status instead of counting pods.

### POOL-19 Prepull and placement
Safety: prod-safe
Steps: `k get ds`; `k get ds <one> -o jsonpath='{.spec.template.spec.nodeSelector} {.spec.template.spec.initContainers[*].image} {.spec.template.spec.containers[*].image}'`; `k get pods -l eduide.github.io/component=session -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName,NP:.metadata.labels.eduide\.github\.io/node-pool`.
Expect: one prepull DaemonSet per template that pulls the template image in an init container and then runs the pause image, on the nodes of the template's placement only; session and pool pods run on nodes whose pool label equals the pod's `node-pool` label.

### POOL-20 Idle instance children are repaired
Safety: test-only
Needs: the pool of POOL-01 with at least three ready idle pods.
Steps: for three different ready idle pods delete one child each: the HTTPRoute `ide-<instance>`, the token Secret `ide-<instance>-token` and the Service `ide-<instance>`; wait 60 s; `k get httproute,svc,secret | grep <instance>`; then create three sessions at once (`ft_session`, `ft_wait`).
Expect: the deleted objects are recreated (route and Secret agree on the token, SEC-06) or the pod is replaced; every session reaches Ready, none stays `Starting` (first run: a claimed pod without its token Secret hung, fixed in fix batch 1). Record which repair happened.
Cleanup: `ft_cleanup`.

## Explore

- Claim and delete in a tight loop (10 times): does the pool end up with a stuck claim, a missing instance or leaked Services and routes?
- Two sessions in the same second for one idle pod: exactly one warm, one not?
- Delete an idle pod, its token Secret or its HTTPRoute by hand: is it repaired (a pod needs no reconcile trigger, the controller is the replica set)?
- Scale `targetIdle` to 0 while instances are claimed; node drain or eviction of an idle pod: does a replacement appear without a trigger?
- How many HTTPRoutes does the gateway hold for a pool of 50? Time until a pre-created route works (first request after pod ready).
- Resource cost: how long does a fresh instance take to become ready on a node without the image (prepull)?
