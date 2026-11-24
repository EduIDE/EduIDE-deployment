# 11 Upgrade and rollback smoke (UPG)

Server module with GitHub workflows. Test environments only (test3 first); never production, never `e2e.`, never `clean_install`. Each deploy affects everyone on that environment: announce it. The new stack has two charts: `eduide-control-plane-crds` (per cluster, additive only, installed first) and `eduide-control-plane` (per deployment), both published as OCI charts (decision G10, ADR 0018). `EduIDE-Helm` embeds them and adds the landing page, the Gateway and the issuer.

Workflows (repository EduIDE-deployment): `.github/workflows/deploy-dispatch.yml` ("Deploy environment"), `rollback.yml` ("Rollback"), `bootstrap-cluster.yml`. They need an environment directory for test3 (`environments/test3.eduide.student.k8s.aet.cit.tum.de`) that does not exist yet; until the migration work package for the umbrella chart lands it, record UPG-01 to UPG-05 as `blocked: no environment manifest for test3`. The manifest alone does not unblock them: the `environment` choice lists of `deploy-dispatch.yml` and `rollback.yml` must also contain test3 and the GitHub Environment must exist. Never run `helm` against the cluster by hand.

Variables: `FROM` = the chart version currently deployed (PLAT-01), `TO` = the version under test.

### UPG-01 Dry run shows the expected change
Safety: test-only (applies nothing)
Steps:
```bash
gh workflow run deploy-dispatch.yml -R EduIDE/EduIDE-deployment -f environment=$ENV -f chart_version=$TO -f dry_run=true
gh run watch -R EduIDE/EduIDE-deployment $(gh run list -R EduIDE/EduIDE-deployment -w deploy-dispatch.yml -L1 --json databaseId -q '.[0].databaseId')
```
Expect: the run is green; its job summary (web UI) shows a non-empty diff for a version change (images of operator, service, authz, agent, pool scaler, landing page) that matches the release notes of `TO`; the cluster identity check passes; the CRD chart diff (if any) is additive only.

### UPG-02 Upgrade with sessions running
Safety: test-only, disruptive
Steps:
1. Before: start a cold session with a volume (`ft-upg-ws`, `ft-upg-s1`, a file in its workspace), a warm session, and keep one idle pool pod; record pod UIDs, `status.url`, owners; run PLAT-01. In a shell loop, as the owner in the browser or with a token, open a session URL every 2 seconds and count non-200 answers during the rollout (AUTHZ-02 method).
2. `gh workflow run deploy-dispatch.yml -R EduIDE/EduIDE-deployment -f environment=$ENV -f chart_version=$TO` and watch it.
3. After: PLAT-01, PLAT-02, PLAT-06, API-01, and a fresh warm and cold launch from the landing page.
Expect: the deploy is green (`--wait --atomic`); new component versions as expected; running sessions keep their pods and URLs (sessions are bare pods, the operator restart does not touch them, OPR-10); no non-200 answers for the owner during the authz rollout (2 replicas and the PodDisruptionBudget keep it up, AUTHZ-13); the workspace and its file survive; idle pool pods are replaced only when the template spec or the agent image changed (POOL-06); a new launch works after prepull finished.

### UPG-03 Rollback
Safety: test-only, disruptive
Steps: `gh workflow run rollback.yml -R EduIDE/EduIDE-deployment -f environment=$ENV` (blank revision = one back), watch it, then PLAT-01, PLAT-02, API-01 and a launch.
Expect: green; versions back to `FROM`; IDESession, IDEWorkspace objects and PVCs untouched (the workflow does not touch them); the persistent fixture workspace still has its file. The CRD chart is not rolled back with the deployment chart (CRDs are additive, an older operator tolerates unknown fields via server-side apply with its own field manager); record `FROM` and `TO` of the CRD chart. The operator checks the minimum CRD version at start: a rollback to an operator that needs newer CRDs must refuse to start with a clear message, not crash-loop silently. `rollback.yml` has no cluster identity check: confirm the environment before approving.

### UPG-04 Upgrade again
Safety: test-only, disruptive
Steps: repeat UPG-02 step 2 to return to `TO`.
Expect: green; the environment ends on the version it should be on. Record the final versions.

### UPG-05 Redeploy without changes restarts nothing
Safety: test-only, disruptive
Steps: record the pod UIDs of operator, service, authz, pool scaler and landing page; run the deploy dispatch with the versions already deployed; compare UIDs; `helm --kube-context "$CTX" -n "$NS" get manifest eduide-control-plane --revision <before>` against `<after>` (read-only).
Expect: the manifests of the two revisions are identical, no `helm.sh/revision`-style annotations in pod templates, so no pod restarts; session pods and idle pool pods keep their UIDs. The deploy workflow's forced rollout restart for floating tags (`deploy.yml`) restarts components only for floating channels: record which of them restarted, and what it did to open WebSockets and the operator's leader lease.

### UPG-06 CRD chart ahead of the operator (version skew)
Safety: test-only, disruptive
Needs: two released versions `N-1` and `N` of the control plane where `N` adds an optional CRD field.
Steps: with the CRD chart at `N` and the deployment chart at `N-1`: create a template, pool, workspace and session with the new field set (`k apply` of a resource that uses it; the API server accepts it, the old operator ignores it), start and stop a session; check the operator log for errors; update the objects (`k annotate`) and see that the old operator does not wipe the unknown field (server-side apply with its own field manager).
Expect: sessions start and end normally; the unknown field survives an operator write; no reconcile error flood. Removing a field from the CRD is refused by the CI schema diff, so the reverse skew is not tested.
Cleanup: `ft_cleanup`.

### UPG-07 Parallel run with the old stack
Safety: prod-safe (read-only on other namespaces)
Steps: before and after installing the control plane in `eduide-test3`: `kubectl --context $CTX get crd | grep theia.cloud`; `kubectl --context $CTX get crd -o json | jq -r '.items[] | select(.spec.group=="theia.cloud") | .metadata.name + " " + .metadata.resourceVersion'`; `kubectl --context $CTX -n eduide-test2 get sessions.theia.cloud --no-headers | wc -l` (read only); the shared Gateway's listeners and its address (`kubectl --context $CTX -n eduide-system get gateway`); `k get gateway` for the own Gateway of `eduide-test3`.
Expect: the CRDs of the old group `theia.cloud` are unchanged (same resourceVersions), the old namespaces and the shared Gateway untouched (decision U9: nothing in them is modified), both stacks answer at the same time (`curl` the landing pages of test2 and test3 and a session of each); the new Gateway in `eduide-test3` has the same IP through `mergeGateways: true` and its own certificates; the control plane's RBAC cannot see the old namespaces (SEC-17).

## Explore

- Upgrade while a launch is in flight (click a tile, then start the deploy): what does the student see, does the SSE stream reconnect?
- Upgrade while the pool is being refilled; how long until the pool is full again after the upgrade (time to first fast launch)?
- Roll the authz Deployment only, with a session open in the browser: any 403 flash or re-login?
- Does the rollback summary read back from the cluster the same versions PLAT-01 sees?
- Uninstall and reinstall the deployment chart: do sessions, workspaces and PVCs survive (CRs have no Helm owner)? What happens to PVCs of workspaces when the CRD chart is removed (never do this on a shared cluster; read the chart's policy only)?
