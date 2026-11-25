# 05 Warm pool and pool scaler (POOL)

Server module. Pool tests use their own fixture template and pool (`ft-pool`, cloned from `<TPL_STD>`), so the pool students use stays untouched. Set `MODULE=05`. A pool serves only sessions without persistence; a session with a workspace always starts cold.

Sources: control plane `internal/controller/{pool,session,build}.go`, `internal/claim`, `api/v1alpha1/idepool_types.go`, ADR 0007, 0008, 0009, `docs/architecture/start-path.md`, `docs/operations/pool-empty.md`, `docs/contracts/metrics.md`, `pool-scaler/README.md`, chart `templates/pool-scaler.yaml`; EduIDE-Helm `charts/eduide/templates/ide-templates.yaml` (the `pool:` entry renders `minIdle` and `maxInstances`, never `targetIdle`).

Facts:
- `IDEPool` (`spec.templateRef`, `minIdle` floor from Helm, `targetIdle` owned by the pool scaler, `maxInstances`). The operator keeps `clamp(max(minIdle, targetIdle), 0, maxInstances - claimed)` idle instances, and 0 under capacity pressure. Status: `replicas`, `idleReady`, `idleStarting`, `claimed`, `selector`; the scale subresource maps to `targetIdle`. Only the oldest pool of a template is active; another one of the same template gets `Ready=False` reason `DuplicateTemplate` and 0 idle instances, so a fixture pool needs its own fixture template.
- Pool instances are bare pods `ide-<instance>` with labels `eduide.github.io/pool=<pool>`, `eduide.github.io/state=idle` (then `claimed` with `eduide.github.io/session=<session>` and `owner-hash`), `eduide.github.io/template`, `eduide.github.io/instance`, the annotation `eduide.github.io/spec-hash` and a Service, HTTPRoute and token Secret `ide-<instance>-token` from the start. A claim patches the pod's labels (optimistic lock on the resourceVersion), then pushes the launch data to the agent once. Service, route and token do not change.
- The pool deletes idle pods with another spec hash (starting ones at once, ready ones only while it has more ready idle pods than its target; while old pods remain it keeps one pod above target, so the ready count never drops during a roll), idle pods with a restarted container or a container that waits for more than 60 s with an error that does not heal, and a claimed pod without a live session after 30 s. Claimed pods are never touched by the roll.
- The spec hash (`internal/controller/build.go`, `specHash`) is the first 16 hex characters of a SHA-256 over: the template spec, the agent image string (the tag, not its digest), the placement, a route version constant, the Git settings (only when providers and a proxy URL are set) and the agent pull policy (only when set). Anything else leaves idle instances alone: a deploy does NOT replace them, and neither does a rebuilt image under an unchanged tag (a mutable `pr-N` tag keeps its hash while the registry content moves). An idle pod can therefore be older than the last deploy; check what it runs with PLAT-11, not with its age.
- Start strategies: `warm-ready` (an idle ready instance), `warm-starting` (none ready, one idle still starting: the session waits), `cold`. Metrics: `eduide_claim_total{result=claimed|conflict|empty}`, `eduide_pool_instances{pool,state}`, `eduide_pool_target_idle`, `eduide_session_startup_seconds{strategy,start_mode}`.
- The pool scaler (only where `poolScaler.enabled`, test3 and others that set it) writes `spec.targetIdle` through `/scale` and Events on the pool (reporting controller `pool-scaler`, reasons `ScaledUp`, `ScaledDown`, `Held`). Annotations on the pool: `eduide.github.io/scaler-mode: shadow|active|off` and `eduide.github.io/scaler-override: "<n>"`. test2 and test1 have no scaler: `targetIdle` stays where it is (0 on test2, so the floor `minIdle` decides).
- On an environment with the scaler, annotate every fixture pool at once: `k annotate idepool <pool> eduide.github.io/scaler-mode=off` (POOL-15 and POOL-16 excepted), so the scaler does not touch it.

Helper (a pool's pods, by label):
```bash
pool() { local p=${1:-ft-pool}; k get pods -l eduide.github.io/pool=$p -L eduide.github.io/state,eduide.github.io/session -o custom-columns='NAME:.metadata.name,STATE:.metadata.labels.eduide\.github\.io/state,SESSION:.metadata.labels.eduide\.github\.io/session,READY:.status.containerStatuses[*].ready,HASH:.metadata.annotations.eduide\.github\.io/spec-hash,AGE:.metadata.creationTimestamp'; k get idepool $p -o jsonpath='target={.spec.targetIdle} min={.spec.minIdle} max={.spec.maxInstances} replicas={.status.replicas} idleReady={.status.idleReady} starting={.status.idleStarting} claimed={.status.claimed}{"\n"}'; }
```

### POOL-01 Pool is filled
Safety: test-only
Steps: `ft_template <TPL_STD> ft-pool`, `ft_pool ft-pool 2 3`, wait up to 5 minutes (a node without the image pulls it), `pool`; `k get svc,httproute,secret | grep -c ide-`.
Expect: two idle pods in state `idle`, both `READY true,true` (the agent is ready when the IDE answers on its loopback port), a Service, an HTTPRoute (label `eduide.github.io/route=session`, `Accepted`) and a token Secret per pod; `idleReady: 2`, `replicas: 2`, `claimed: 0`; all pods carry the same `spec-hash`; the pool condition `Ready=True`. `eduide_pool_instances{state="idle_ready"}` is 2.

### POOL-02 Real pools are filled
Safety: prod-safe
Steps: `k get idepools -o custom-columns=NAME:.metadata.name,MIN:.spec.minIdle,TARGET:.spec.targetIdle,MAX:.spec.maxInstances,READY:.status.idleReady,STARTING:.status.idleStarting,CLAIMED:.status.claimed`; `k get idepools -o json | jq -r '.items[] | .metadata.name + " " + ([.status.conditions[] | .type + "=" + .status + ":" + .reason] | join(","))'`.
Expect: `idleReady` is at least `max(minIdle, targetIdle)` minus claimed ones, or recovery is visible (`idleStarting`); `Ready=True` and `CapacityPressure=False`. An empty pool with a target above 0 for 10 minutes is what the alert `EduIDEPoolEmpty` reports (module 10). Do not expect a deploy to have replaced the idle instances: record their `eduide.github.io/spec-hash` and creation time, and read the Facts above for what changes the hash. Whether their images are current is PLAT-11.

### POOL-03 Claim
Safety: test-only
Steps: with POOL-01's pool: `ft_session ft-pool-s1 ft-pool`, `ft_wait ft-pool-s1`, then `k get idesession ft-pool-s1 -o jsonpath='{.status.startStrategy} {.status.instance} {.status.podName} {.status.timestamps}{"\n"}'`, `pool`, `k get events --field-selector involvedObject.name=ft-pool-s1`.
Expect: `Ready` within seconds (no image pull, no new pod for the session); `startStrategy: warm-ready`; the pod named in the status was an idle pod before (same name as in the earlier `pool` output) and now has `state=claimed` and the session label; its Service, route and token Secret are unchanged; the Event `Claimed` exists; the pool starts a replacement (`idleStarting`, then `idleReady` 2 again). Record the time to `Ready` with `ft_startup ft-pool-s1` (it prints the `Ready` Event: "ready after 2.2s (warm-ready)"; the target is under 2 s). The elapsed time of `ft_wait` is not a measurement: it polls every 5 s and reports about 6 s for a 2.2 s start. `eduide_claim_total{result="claimed"}` rises.

### POOL-04 Release removes the objects
Safety: test-only
Steps: note the claimed pod's name and UID, `k delete idesession ft-pool-s1`, poll every second for 30 seconds until the pod, Service, route, token Secret and data Secret are gone (`k get pod,svc,httproute,secret -o name | grep "${POD#ide-}"`), then `pool` after one minute.
Expect: the claimed pod is deleted and never reused (its name is gone; a claim always gets a fresh pod, so nothing of the first session can be seen by the next one: ADR 0006); its Service, route, token Secret and data Secret are gone within 30 seconds (9 s measured on test2); the pool holds `minIdle` idle pods again. This test proves the removal only and shows no order: the pod starts terminating about 0.7 s before the route is deleted, and the session object still shows `Ready` then. The access part is POOL-18.

### POOL-05 Exhaustion falls back or waits
Safety: test-only
Steps: claim both idle pods (`ft-pool-s1`, `ft-pool-s2`), then at once `ft_session ft-pool-s3 ft-pool`, `ft_wait ft-pool-s3`; `k get idesession ft-pool-s3 -o jsonpath='{.status.startStrategy}{"\n"}'`; check `eduide_claim_total{result="empty"}` (module 10) or the operator log.
Expect: s3 starts anyway: `cold` (its own pod, slower) or `warm-starting` (it waits for the replacement pod that is still starting); never an error. The pool does not grow beyond `maxInstances` (3) counting claimed pods: with three claimed sessions `maxInstances - claimed` is 0 idle. After deleting all three sessions the pool returns to its target.
Cleanup: delete the sessions.

### POOL-06 Outdated instances are recreated
Safety: test-only
Steps: with one session claimed and two idle pods: `k patch idetemplate ft-pool --type merge -p '{"spec":{"resources":{"requests":{"cpu":"201m"}}}}'`; watch `pool` every 20 s for three minutes and record `idleReady` each time.
Expect: the idle pods get a new `spec-hash` (annotation), replaced one by one: a new pod appears before an old ready one is deleted, so `idleReady` never drops below the target; the claimed pod keeps its old hash and keeps running until its session ends.
Cleanup: `ft_cleanup`.

### POOL-07 Pool size change
Safety: test-only
Steps: `k patch idepool ft-pool --type merge -p '{"spec":{"minIdle":3,"maxInstances":3}}'`, wait, `pool`; then `k scale idepool ft-pool --replicas=1`; then `minIdle` 1 and `kubectl scale ... --replicas=0`; then `maxInstances` 2 with `minIdle` 3.
Expect: three idle instances after the first patch; `scale` writes `spec.targetIdle` (`k get idepool ft-pool -o jsonpath='{.spec.targetIdle}'`); the effective idle count is `clamp(max(minIdle, targetIdle), 0, maxInstances - claimed)`: surplus idle pods are deleted when the target falls, never claimed ones; a `minIdle` above `maxInstances` is capped at `maxInstances`.

### POOL-08 Claimed pod without a live session
Safety: test-only
Steps: take an idle pod of `ft-pool` and make it look claimed by a session that does not exist: `k label pod <idle pod> eduide.github.io/state=claimed eduide.github.io/session=ft-pool-ghost --overwrite`; watch `pool` for two minutes.
Expect: after about 30 seconds the operator deletes the pod and the pool starts a replacement; no session is affected, and a launch at that time is never handed this pod. (A fixture changes labels that belong to the operator; this is the only test that does.)
Cleanup: `ft_cleanup`.

### POOL-09 Operator restart with claimed instances
Safety: test-only, disruptive
Steps: with one claimed and one idle pod, `k rollout restart deploy/$P-operator`, wait for it, then `pool` and open the claimed session's URL (or compare the pod UID and `status.url`).
Expect: the claimed pod keeps its claim, UID and URL; the idle pods are untouched (same hash, same UIDs); a new claim afterwards works and is warm. No second claim reaches the agent of the claimed pod (`k logs <pod> -c agent | grep -c claimed` unchanged).

### POOL-10 Idle instances are wired for the gateway
Safety: prod-safe
Steps: for one idle pod of a real pool: `k get pod <pod> -o json | jq '.spec.containers[] | {name, env: [.env[]?.name], ports: [.ports[]?.containerPort]}'`; `k get httproute <pod> -o json | jq '.spec.rules[0] | {match: .matches[0].path, filters: [.filters[] | .type], header: [.filters[] | .requestHeaderModifier.set[]?.name], service: .backendRefs[0].name}'`; `k get secret <pod>-token -o json | jq '.data | keys'`.
Expect: the pod's env holds no token and no launch data; the route matches `PathPrefix /<instance>/`, rewrites the prefix to `/`, sets the header `X-EduIDE-Instance-Token` and points at Service `<pod>` port 8080; the token Secret has the key `token` only (never read the value). The instance id in the route equals the pod's label `eduide.github.io/instance`.

### POOL-13 Broken idle instance is replaced, never handed out
Safety: test-only
Steps: `ft_template <TPL_STD> ft-pool-bad "{\"image\":\"$(k get idetemplate <TPL_STD> -o jsonpath='{.spec.image}' | sed 's/:[^:]*$/:does-not-exist/')\"}"`, `ft_pool ft-pool-bad 1 2`, wait 3 minutes watching `pool ft-pool-bad`; then `ft_session ft-pool-bad-s ft-pool-bad` and `ft_wait`.
Expect: the idle pod never becomes ready (`ImagePullBackOff`); after the container has waited for more than 60 s the pool deletes it and creates a new one (a new pod name every few minutes; `idleReady` stays 0). The session is not handed this pod: it ends `Failed` with `start-failed` and a message about the container (OPR-11). The pool controller does not spin: no tight create and delete loop in the operator log (count `pool` lines per minute).
Cleanup: `ft_cleanup`.

### POOL-14 Pool scaler runs
Safety: prod-safe
Needs: `poolScaler.enabled` (test3). Otherwise record `skipped: no scaler`.
Steps: `k get deploy $P-pool-scaler`; `k get cm $P-pool-scaler -o jsonpath='{.data.config\.yaml}'`; `k logs deploy/$P-pool-scaler --since=10m | tail -20`; `k get idepools -o custom-columns=NAME:.metadata.name,MIN:.spec.minIdle,TARGET:.spec.targetIdle,MAX:.spec.maxInstances`; `k get idepool <pool> -o jsonpath='{.metadata.annotations}'`.
Expect: one replica, ready; `mode` is `active` or `shadow` as the values say (test3: `active`), the Prometheus URL is the cluster's; one JSON log line per pool and round with the decided value and why; `targetIdle` of each pool lies between the floor (at least `minIdle`) and the ceiling of `poolLimits` and never above `maxInstances`; no pool is held at 0 without a `CapacityPressure` reason. Metrics (module 10): `pool_scaler_target_idle`, `pool_scaler_last_decision_timestamp_seconds` recent.

### POOL-15 Scaler decisions are visible
Safety: test-only
Needs: the scaler in `active` mode (test3).
Steps: after POOL-16 (or after a natural change): `k get events --field-selector involvedObject.kind=IDEPool`; `k get events -o json | jq -r '.items[] | select(.reportingController=="pool-scaler") | .reason + " " + .note'`.
Expect: every change of `targetIdle` has an Event with reason `ScaledUp` or `ScaledDown` and a note with strategy, old and new value and the reason; a withheld change has `Held` (once until the message changes). Shadow mode writes none. The admin API (API-20) shows the same events as scaler decisions.

### POOL-16 Scaler override and mode annotations
Safety: test-only
Needs: the scaler in `active` mode (test3); a fixture pool (`ft_template`, `ft_pool ft-pool-sc 1 4`), not annotated `off`.
Steps: `k annotate idepool ft-pool-sc eduide.github.io/scaler-override=2`; wait two scaler rounds (record the interval from the config); then `k annotate idepool ft-pool-sc eduide.github.io/scaler-override-` and `eduide.github.io/scaler-mode=off`; change `targetIdle` by hand with `k scale idepool ft-pool-sc --replicas=3`; wait two rounds.
Expect: with the override `targetIdle` becomes 2 (the override bypasses the strategy, not `maxInstances`) and `pool_scaler_override_active` is 1; after removing it the scaler returns to its own decision within a round; with `scaler-mode=off` the scaler leaves the pool alone and the hand-set 3 stays; a value that is not a non-negative integer is ignored.
Cleanup: `ft_cleanup`.

### POOL-17 Scaler fails static
Safety: test-only, disruptive (the scaler is down for a minute)
Needs: the scaler (test3).
Steps: record the scaler's replicas and the `targetIdle` of all pools; `k scale deploy/$P-pool-scaler --replicas=0`; wait the scaler interval; launch two sessions on a real pool template (warm claims); scale back.
Expect: while the scaler is down nothing changes `targetIdle` (the operator keeps `max(minIdle, targetIdle)`, so the pool still refills after claims); the admin status shows the warning `scaler-silent` after twice the interval (needs Prometheus); after the scale-up the scaler decides again and writes an Event only if the target changes.
Cleanup: replicas restored; sessions deleted.

### POOL-18 Release removes access first
Safety: test-only
Needs: a login (the user logged in in the browser pane, SEC-13); without one the result is `blocked (needs login)`.
Steps: start a session of the logged-in user from a tile and note its URL; `k delete idesession <name>`; at once request the URL again as the logged-in user in the browser, then again after the pod is gone.
Expect: both requests answer 403 (authz denies as soon as the session leaves `Ready` or the pod is gone; the first request does not reach the IDE). The same check is SEC-13 step 3: record one result for both. An anonymous request answers the Keycloak redirect before and after and proves nothing.
Cleanup: the logged-in user's session.

## Unverified, check in the first run

- The `pool` helper's `custom-columns` expressions with escaped dots on the shell in use.
- POOL-06 timing and the claim that `idleReady` never drops (ADR 0008); POOL-07 behaviour of `kubectl scale` on a CRD whose scale subresource maps to `spec.targetIdle` (checked in the docs, not on the cluster).
- POOL-08: that relabelling an idle pod by hand is picked up by the operator's cache (the label selector `managed-by` is unchanged) and that the 30 s rule applies to it.
- POOL-13 duration: pull errors that count as "not found" (see OPR-11).
- POOL-14 to POOL-17: not run on test2 (no scaler there); the scaler interval and mode names come from `pool-scaler/README.md`; the Event field `reportingController` as shown by `kubectl get events -o json` on this cluster.
- Whether the pool of a template with a fixture owner's claimed pod counts toward the namespace quota of the environment.

## Retired

- POOL-11 Pool app with a sidecar: 2026-11-24, templates have no sidecars.
- POOL-12 Orphan after release: 2026-11-24, no claim labels on Services and no timer; a claimed pod without a live session is deleted by the operator after 30 s (POOL-08).
- Old facts about `minInstances` reconcile triggers, `instance-<n>-...` object names, the bridge token rotation and `lazy-fallback` annotations no longer exist.

## Explore

- Claim and delete in a tight loop (10 times): does the pool ever end up with a stuck claim, a missing instance or a leaked pod? `eduide_claim_total{result="conflict"}`?
- Two sessions created in the same second for one idle pod: one `warm-ready`, the other `warm-starting` or `cold`, no pod claimed twice (the claim is a patch with a resourceVersion precondition).
- Delete an idle pod, its Service, its route or its token Secret by hand: the pool repairs the Service and route, and deletes a pod whose token Secret is gone.
- `minIdle` to 0 while instances are claimed; `maxInstances` below the number of claimed pods.
- Node drain or an eviction of an idle pod: does it come back without any trigger?
- How long does a fresh instance take to become ready on a node without the image (prepull off on test2)?
- A second `IDEPool` for the same template: `Ready=False` reason `DuplicateTemplate`, 0 idle pods.
