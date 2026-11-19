# 07 Workspace retention (WS)

Server module. The operator removes workspaces that nobody has used for a while; the old `workspace-garbage-collector` (age since creation, no dry-run) is gone (decision G19, ADR 0007). Retention counts from `status.lastUsed`, which is set at the start and the end of every session and on import, and a workspace with a running session never expires.

Sources (control plane repo): `internal/controller/workspace`, `api/v1alpha1/ideworkspace_types.go`, `internal/config/config.go` (`Workspaces`), ADR 0007; labels `AnnotationRetain`.

Facts:
- Retention: `config.workspaces.retention` (default 14 days, Mannheim 150), overridden per template (`spec.retention`) and per workspace (`spec.retention`).
- `status.expiresAt = lastUsed + retention`. Two stages: at expiry the phase becomes `Expired` and `status.expiredAt` is set; after `config.workspaces.grace` (default 24 h) the operator deletes the PVC and the CR. The annotation `eduide.github.io/retain: "true"` on the workspace cancels expiry.
- The overview shows a warning from 3 days before expiry; "Starten" extends it.
- Workspace phases: `Pending`, `Ready`, `Expired`. The PVC is owned by the workspace, so deleting the CR deletes it.
- Check no workspace is `Expired` before any test that shortens the grace (WS-06).

### WS-01 Configuration and ownership
Safety: prod-safe
Steps: `k get cm $FULL-config -o jsonpath='{.data.config\.yaml}' | grep -A4 '^workspaces:'`; `k get deploy | grep -ci garbage` (expect 0); `k get role,clusterrole -o name | grep $FULL` and the operator's rules for `ideworkspaces`, `persistentvolumeclaims`: `k get role $FULL-operator -o json | jq '.rules[] | select(.resources|index("ideworkspaces") or index("persistentvolumeclaims"))'` (role name from `k get role`); `k get idetemplates -o custom-columns=NAME:.metadata.name,RET:.spec.retention`.
Expect: retention and grace recorded (defaults 14d and 24h unless the chart value overrides them); no garbage collector Deployment exists; the operator may delete `ideworkspaces` and PVCs in the namespace and nothing else cluster-wide; per-template overrides recorded.

### WS-02 Every workspace has lastUsed and expiresAt
Safety: prod-safe
Steps: `k get ideworkspaces -o json | jq -r '.items[] | [.metadata.name, .status.phase, .status.lastUsed, .status.expiresAt] | @tsv'`; for one, compare `expiresAt - lastUsed` with the effective retention (workspace, then template, then config).
Expect: no workspace without `lastUsed` and `expiresAt` once it is `Ready`; `expiresAt = lastUsed + retention` exactly. An import (`existingClaimName`) has `lastUsed` equal to the import time, not the PVC's age.

### WS-03 Nothing is deleted too early, nothing lingers
Safety: prod-safe
Steps: `k get ideworkspaces -o json | jq -r --arg now "$(date -u +%FT%TZ)" '.items[] | select(.status.expiresAt < $now) | [.metadata.name,.status.phase,.status.expiredAt] | @tsv'`; count of workspaces by phase.
Expect: every workspace past `expiresAt` is `Expired` and not older than the grace period beyond `expiredAt` (older ones mean the operator does not delete); no `Ready` workspace has `expiresAt` in the past. Report counts and dates only, no owner names.

### WS-04 Deleting a workspace removes the PVC and does not hurt the operator
Safety: test-only
Steps:
1. Record the operator pod's restart count.
2. `ft_workspace ft-ws-d "$T_STD"`, wait for `status.claimName` and the PVC.
3. `k delete ideworkspace ft-ws-d` (the path the retention uses).
4. Wait two minutes.
Expect: the PVC is gone (ownerReference), no PersistentVolume left Released for it that the operator cannot delete, the operator restart count is unchanged, the operator log has no RBAC error (403).

### WS-05 Expiry stage 1: per-workspace retention
Safety: test-only
Steps: `ft_workspace ft-ws-r "$T_STD" "" 2m` (retention 2 minutes on this workspace only, no deployment-wide change); `k get ideworkspace ft-ws-r -o jsonpath='{.status.phase} {.status.lastUsed} {.status.expiresAt} {.status.expiredAt}'` at start, after 2 and after 3 minutes; the operator's reconcile of expiry runs on a requeue, so allow a few extra minutes and record the delay.
Expect: `expiresAt = lastUsed + 2m`; shortly after expiry the phase is `Expired` and `expiredAt` is set; the PVC and the CR still exist (the grace period of 24 h holds); the object does not disappear. The overview marks it (LAND-14).
Cleanup: `ft_cleanup` (or continue with WS-08).

### WS-06 Expiry stage 2: deletion after the grace period
Safety: test-only, disruptive (restarts the operator with a changed config); destructive if any real workspace is already `Expired`
Needs: no `Expired` workspace other than fixtures (`k get ideworkspaces | grep Expired`); otherwise approval of the environment owner in chat.
Steps:
1. Record the ConfigMap and set `workspaces.grace` to `2m` in `config.yaml` (`k get cm $FULL-config -o yaml > /tmp/cfg.bak` outside the repo; edit with `k edit cm $FULL-config`), `k rollout restart deploy/$FULL-operator`, wait for it.
2. `ft_workspace ft-ws-g "$T_STD" "" 1m`.
3. Follow phase and objects: after about 1 min `Expired`, after another 2 min plus requeue the CR and its PVC are gone.
Expect: stage 2 deletes the workspace CR and the PVC (`k get pvc | grep ft-ws-g` is empty), the operator log names the workspace, the operator does not restart, no other workspace changed.
Cleanup: restore the recorded ConfigMap (`k apply -f /tmp/cfg.bak` after removing the server fields, or revert the edit), restart the operator, check WS-01 again. If the chart owns the ConfigMap, record that the next deploy would restore it anyway.

### WS-07 Config parsing fails loudly, without touching the shared operator
Safety: test-only
Needs: rights to create pods and ConfigMaps in the namespace.
Steps: for each case create a ConfigMap `ft-cfg-<case>` holding a `config.yaml` (take the live file from PLAT-08 and change one thing) and a pod `ft-op-<case>` with the operator image (same tag as the Deployment), the ConfigMap mounted at `/etc/eduide`, `serviceAccountName: default`, `restartPolicy: Never`, labelled `eduide.dev/functional-test=$FT_RUN`. Cases: `workspaces.retention: "14"` (no unit), `workspaces.retention: 14d` (days are not a Go duration), `sessionsPerUser: -1`, an unknown key (`bogus: 1`), `hosts.instance` removed. Read `k logs` and the exit code.
Expect: every case exits non-zero within seconds with a message that names the field (`config: ...`, `oidc.issuerURL is required`, unknown field); no case joins leader election (the shared operator keeps its lease, `k get lease eduide-operator`); the old trap of a unit-less value meaning seconds is not possible. Config values are never printed.
Cleanup: `k delete pod,cm -l eduide.dev/functional-test=$FT_RUN`.

### WS-08 Retain annotation cancels expiry
Safety: test-only
Steps: continue with an `Expired` workspace from WS-05 (create a new one with retention `1m` if needed): `k annotate ideworkspace ft-ws-r eduide.github.io/retain=true`; wait two minutes; read the phase and `expiredAt`; then remove the annotation (`k annotate ideworkspace ft-ws-r eduide.github.io/retain-`).
Expect: with the annotation the workspace leaves `Expired` (phase `Ready`, `expiredAt` cleared) or stays untouched and is never deleted, also after the grace period would have passed (record which); without the annotation the normal clock applies again from `lastUsed`. The PVC is never touched while the annotation is set.
Cleanup: `ft_cleanup`.

### WS-09 lastUsed at start and end; a running session blocks expiry
Safety: test-only
Needs: browser pane optional.
Steps: `ft_workspace ft-ws-u "$T_STD" "$ME" 3m`; note `lastUsed`; `ft_session ft-ws-us "$T_STD" ft-ws-u "$ME"`, `ft_wait`; read `lastUsed` (set at session start); keep the session running for 5 minutes (longer than the retention) and read phase and `expiresAt` every minute; then `k delete idesession ft-ws-us` and read `lastUsed` and `expiresAt`.
Expect: `lastUsed` moves at the start and again at the end of the session; during the session the phase stays `Ready` although `lastUsed + 3m` has passed (never during a running session); after the end `expiresAt` is `end + 3m`. The same applies for sessions ended by the idle timeout.
Cleanup: `ft_cleanup`.

### WS-10 Starting an expired workspace
Safety: test-only
Needs: browser token or `ME`; an `Expired` workspace of the user from WS-05 (retention 1m), still within grace.
Steps: launch a session on it (`await api('POST','/sessions',{template:'<T>',workspace:'<name>'})`, or "Starten" in the overview).
Expect: the launch is allowed (starting extends the retention, G19): the session reaches Ready on the same PVC, the workspace returns to `Ready` with `expiredAt` cleared and `lastUsed` set to the start. Record if the launch is refused instead.
Cleanup: `ft_cleanup`.

### WS-11 Overview warning before expiry
Safety: test-only
Needs: logged in as `ME`.
Steps: `ft_workspace ft-ws-w "$T_STD" "$ME" 48h` (expires in under 3 days; `2d` is not a Go duration and is rejected) and `ft_workspace ft-ws-n "$T_STD" "$ME"` (default retention); `await api('GET','/me/overview')` and the overview page.
Expect: the item for `ft-ws-w` has `expiresAt` within 3 days and the page shows a warning that names the date; `ft-ws-n` has none; "Starten" on `ft-ws-w` pushes `expiresAt` out again (WS-09).
Cleanup: `ft_cleanup`.

### WS-12 Import of an existing volume
Safety: test-only
Needs: a spare PVC created by the test: `k apply` a PVC `ft-ws-import` (1Gi, the cluster's storage class, label `eduide.dev/functional-test=$FT_RUN`), written once by a throwaway pod if you want to see the data survive.
Steps: create an IDEWorkspace with `spec.persistence.existingClaimName: ft-ws-import` (copy `ft_workspace` and add the field), read `status.claimName`, `lastUsed`, start a session on it and `ls /home/project` in the `ide` container.
Expect: `status.claimName` equals `ft-ws-import`, no second PVC is created, `lastUsed` is the import time, the session mounts the imported volume with its data intact. Record whether deleting the workspace also deletes the imported PVC (the design does not say; the test PVC is expendable).
Cleanup: `ft_cleanup` (PVC carries the label).

## Explore

- A workspace whose PVC was deleted by hand: phase and message; does a session on it fail with `workspace-not-found` or `start-failed`?
- A workspace stuck in deletion (finalizer on the PVC): does the operator retry without error floods?
- Retention shorter than the template's idle timeout: does a long-idle session on a workspace block expiry as intended?
- Clock behaviour: `expiresAt` after daylight saving changes (UTC only?).
- Change the retention in config while workspaces exist: are `expiresAt` values recomputed, and when?
- Does `GET /me/overview` hide `Expired` workspaces or show them with a warning?
