# 07 Workspace retention (RET)

Server module. Replaces the Java workspace garbage collector (a separate Deployment that deleted Workspaces by creation time). On the Go stack the operator's workspace controller expires workspaces by last use, in two stages, and there is no garbage collector in any environment.

Sources: control plane `internal/controller/workspace.go`, `internal/controller/session.go` (`touchWorkspace`, `finalize`), `api/v1alpha1/ideworkspace_types.go`, ADR 0007, `docs/architecture/data-model.md`, `docs/operations/workspace-volume-lost.md`, `api/openapi/v1.yaml` (`Workspace`); `internal/httpapi/launch.go` (`ensureWorkspace`).

Facts:
- `status.lastUsed` is set at creation (imports: at import time), at the start and at the end of every session on the workspace. `status.expiresAt = lastUsed + retention`. Retention is the first of `spec.retention` (workspace), `spec.retention` of the template, `workspaces.retention` of the deployment config (default 14 days; Bonn sets 2160h).
- A workspace with a running session (a session that has not failed) never expires, and neither does one with the annotation `eduide.github.io/retain: "true"`. Otherwise, once `now >= expiresAt`, the phase becomes `Expired` and `status.expiredAt` is set; after the grace period `workspaces.grace` (default 24 h) the operator deletes the IDEWorkspace, and the PVC follows through its owner reference. The operator asks the API server live before it expires or deletes, so a session created a moment ago protects the workspace.
- Phases: `Pending`, `Ready`, `Expired`. The API shows `lastUsed`, `expiresAt` and `deletesAt` (expiresAt plus grace; absent while a session runs and with the retain annotation); the landing page warns three days before expiry.
- A missing PVC of a workspace that held data (`status.claimName` set) is not recreated: the workspace gets `Ready=False` reason `VolumeLost`, the Event `VolumeLost`, and a launch on it answers 409 `workspace-lost` (a running or starting session fails with `workspace-lost`).
- The per-user limit is `workspaces.perUser` (default 20): launches that would create one more answer 409 `workspace-limit-reached`.
- Fixture workspaces use `ft_workspace <name> <template> [owner] [retention]` and a short retention such as `2m`. The grace period is a deployment setting (24 h on every environment today); it cannot be shortened by a test, so the deletion stage is only checked by reading (RET-04 note).

### RET-01 Retention configuration
Safety: prod-safe
Steps: `k get cm $P-config -o jsonpath='{.data.config\.yaml}' | yq .workspaces`; `k get idetemplates -o json | jq -r '.items[] | .metadata.name + " " + (.spec.retention // "-")'`; `k get deploy | grep -c -i garbage`; `k get role $P-operator -o json | jq -c '.rules[] | select(.resources | index("ideworkspaces"))'`.
Expect: `workspaces` holds the `storageClassName` of the cluster and the limits (defaults 14 days retention, 24 h grace, 20 per user unless the values override them; record the source); templates carry no retention unless the values set one; no garbage collector Deployment exists; the operator Role can `delete` `ideworkspaces`. Production and Bonn: record the retention that the privacy page states and compare it with the config (it must be the same).

### RET-02 Deleting a workspace removes its volume
Safety: test-only
Steps:
1. Record the operator pod's restart count.
2. `ft_workspace ft-ret-ws <TPL_STD>`, wait for `Ready` and the PVC (`k get pvc ft-ret-ws`).
3. `ft_session ft-ret-s <TPL_STD> ft-ret-ws`, `ft_wait ft-ret-s`.
4. `k delete ideworkspace ft-ret-ws` and wait two minutes.
Expect: the PVC `ft-ret-ws` exists with the workspace's name and the cluster's storage class; the session on the workspace is owned by it, so deleting the workspace removes the session (and with it the pod) and the PVC and its volume; the operator restart count is unchanged and its log has no error for the delete. The API route `DELETE /workspaces/<name>` does the same after stopping the session (API-06).
Cleanup: `ft_cleanup`.

### RET-03 Workspaces carry expiry data
Safety: prod-safe
Steps: `k get ideworkspaces -o json | jq -r '[.items[] | {phase: .status.phase, lastUsed: .status.lastUsed, expiresAt: .status.expiresAt}] | group_by(.phase) | map({phase: .[0].phase, n: length})'`; the workspaces without `expiresAt`; the oldest `lastUsed` (`jq -r '[.items[].status.lastUsed] | sort | first'`); the metric `eduide_workspaces{phase}` (module 10).
Expect: every `Ready` workspace has `lastUsed` and `expiresAt`; no workspace is `Expired` for longer than the grace period (older ones mean the operator does not delete); no workspace without a running session has `expiresAt` older than `now` and still `Ready`. Report counts and dates only, never names of real users' workspaces. `eduide_workspaces` equals the counts.

### RET-04 Workspace expires after its retention
Safety: test-only
Steps: `ft_workspace ft-ret-exp <TPL_STD> "$FT_USER" 2m`; wait for `Ready`; `k get ideworkspace ft-ret-exp -o jsonpath='{.status.lastUsed} {.status.expiresAt} {.status.phase}{"\n"}'`; wait until `expiresAt` plus 10 seconds; read again; `k get pvc ft-ret-exp`; `k logs deploy/$P-operator --since=10m | grep 'workspace expired'`.
Expect: `expiresAt` is `lastUsed` plus 2 minutes; afterwards `phase: Expired` and `expiredAt` is set; the PVC still exists (files stay during the grace period of 24 h); the operator logs `workspace expired` with the grace period and a pseudonymous user. Through the API (API-06) the workspace shows `phase: Expired` and `deletesAt` equal to `expiresAt` plus the grace. The deletion stage ("workspace deleted after its grace period") is not run (the grace is 24 h): confirm only by reading `workspace.go` and the log of real workspaces on a long-lived environment.
Cleanup: `ft_cleanup`.

### RET-05 A session keeps the workspace alive and renews it
Safety: test-only
Steps: `ft_workspace ft-ret-live <TPL_STD> "$FT_USER" 3m`; `ft_session ft-ret-live-s <TPL_STD> ft-ret-live`; `ft_wait`; note `lastUsed`; wait 4 minutes (past `expiresAt` of the creation time); read the phase; `k delete idesession ft-ret-live-s`; wait a minute; read `lastUsed`, `expiresAt`, `phase`.
Expect: while the session runs the workspace is `Ready` (never `Expired`), also after the original `expiresAt`; after the session ends `lastUsed` is the end time and `expiresAt` is that plus 3 minutes (use renews expiry, G19); the phase stays `Ready` until then.
Cleanup: `ft_cleanup`.

### RET-06 Retain annotation and starting an expired workspace
Safety: test-only
Steps: `ft_workspace ft-ret-keep <TPL_STD> "$FT_USER" 2m`; wait until `Expired`; `k annotate ideworkspace ft-ret-keep eduide.github.io/retain=true`; read the phase after 10 s; `k annotate ideworkspace ft-ret-keep eduide.github.io/retain-`; wait for `Expired` again; then `ft_session ft-ret-keep-s <TPL_STD> ft-ret-keep`, `ft_wait`, read the phase.
Expect: with the annotation the phase returns to `Ready` and `expiredAt` is cleared (`deletesAt` is absent in the API); without it the workspace expires again; a session started on an `Expired` workspace reaches `Ready` (the workspace is in use) and the workspace is `Ready` again while it runs.
Cleanup: `ft_cleanup`.

### RET-07 Retention precedence
Safety: test-only
Steps: `ft_template <TPL_STD> ft-ret-tpl '{"retention":"2m"}'`; `ft_workspace ft-ret-w1 ft-ret-tpl` (no own retention) and `ft_workspace ft-ret-w2 ft-ret-tpl "$FT_USER" 4m`; read both `expiresAt - lastUsed`.
Expect: w1 uses the template's 2 minutes, w2 its own 4 minutes; a workspace of a template without retention uses the deployment's (RET-01).
Cleanup: `ft_cleanup`.

### RET-08 Lost volume is not hidden
Safety: test-only
Steps: `ft_workspace ft-ret-lost <TPL_STD>`; wait for `Ready` and the PVC; `k delete pvc ft-ret-lost`; wait 1 minute; `k get ideworkspace ft-ret-lost -o jsonpath='{.status.conditions}'`; `k get events --field-selector involvedObject.name=ft-ret-lost`; then `ft_session ft-ret-lost-s <TPL_STD> ft-ret-lost` and `ft_wait`; `k get pvc | grep -c ft-ret-lost`; finally `k delete ideworkspace ft-ret-lost`.
Expect: `Ready=False` with reason `VolumeLost` and the Event `VolumeLost` (also in the operator log `workspace volume lost`); the operator does not create a new empty volume (`k get pvc` shows none); the session fails with `errorCode: workspace-lost`; through the API a launch on that workspace is 409 `workspace-lost`. After deleting the workspace a new launch creates a fresh workspace and volume. See `docs/operations/workspace-volume-lost.md`.
Cleanup: `ft_cleanup`.

## Unverified, check in the first run

- RET-04 and RET-06: the reconcile happens at `expiresAt + 1 s` (`RequeueAfter`); allow 30 seconds. Whether `kubectl annotate ... retain=true` on an `Expired` workspace clears `expiredAt` at once.
- RET-08: that `kubectl delete pvc` completes while no pod mounts the volume (the PVC protection finalizer) and that the operator's cache sees the deletion within a minute.
- RET-02: that deleting the IDEWorkspace removes a running session on it through the owner reference (the session has the workspace as non-controller owner, data-model "Ownership").
- The deletion stage after the grace period has no live test.
- Bonn's and production's retention statement on the privacy page versus `workspaces.retention` (needs a login-free read of the page).

## Retired

- GC-01 Configuration and image: 2026-11-24, no collector; now RET-01.
- GC-02 It runs: 2026-11-24, no collector log; the operator logs `workspace expired` and `workspace deleted after its grace period` (RET-03, RET-04).
- GC-03 Nothing young is deleted: 2026-11-24, now RET-03.
- GC-04 Workspace deletion does not crash the operator: 2026-11-24, now RET-02.
- GC-05 End-to-end deletion with a short TTL: 2026-11-24, retention is per workspace and by last use, so a short retention on a fixture is safe and not destructive (RET-04); a short global TTL no longer exists.
- GC-06 Bad configuration fails loudly and GC-07 Config parsing without touching the shared collector: 2026-11-24, no collector; the operator parses its config at start and exits on an invalid file (Explore).

## Explore

- A fixture workspace with retention `0s` or `1s`: does a workspace with a running session survive, does the landing page show it as expired at once?
- 20 saved workspaces of one user (`workspaces.perUser`): the 21st launch gives 409 `workspace-limit-reached` and the landing page shows "You have reached the maximum number of saved workspaces. Delete one you no longer need and try again."
- The operator's `config.yaml` with an invalid `workspaces.retention` (for example `2d`): does the operator refuse to start with a clear error? (Disruptive: only on a throwaway environment.)
- Import of an existing PVC (`spec.persistence.existingClaimName`, migration, `docs/operations/migration.md`): `lastUsed` is the import time.
- Workspaces whose session is `Failed`: they count as unused.
- `eduide_workspaces{phase}` against the admin API workspace summary.
