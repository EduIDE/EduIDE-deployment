# 11 Upgrade and rollback smoke (UPG)

Server module with GitHub workflows. Test environments only (`staging.`, `test1.`, `test2.`); never production, never `e2e.`, never `clean_install`. Each deploy affects everyone on that environment: announce it. Workflows: `.github/workflows/deploy-dispatch.yml` ("Deploy environment"), `rollback.yml` ("Rollback").

Variables: `FROM` = the chart version currently deployed (PLAT-01), `TO` = the version under test.

### UPG-01 Dry run shows the expected change
Safety: test-only (applies nothing)
Steps:
```bash
gh workflow run deploy-dispatch.yml -R EduIDE/EduIDE-deployment -f environment=$ENV -f chart_version=$TO -f dry_run=true
gh run watch -R EduIDE/EduIDE-deployment $(gh run list -R EduIDE/EduIDE-deployment -w deploy-dispatch.yml -L1 --json databaseId -q '.[0].databaseId')
```
Expect: the run is green; its summary (web UI job summary; `gh run view --log` does not contain it) shows a non-empty helm diff (helm-diff is pinned; an empty diff for a version change is a finding) that matches the release notes of `TO`; the cluster identity check passes.

### UPG-02 Upgrade with sessions running
Safety: test-only, disruptive
Steps:
1. Before: start a persistent fixture session with a file in its workspace (`ft-upg-ws`, `ft-upg-s1`) and an ephemeral one on a pool app; record pod UIDs; run PLAT-01.
2. `gh workflow run deploy-dispatch.yml -R EduIDE/EduIDE-deployment -f environment=$ENV -f chart_version=$TO` and watch it.
3. After: PLAT-01, PLAT-02, PLAT-06, API-01, and a fresh launch from the landing page.
Expect: the deploy is green (`--wait --atomic`); new component versions as expected; existing sessions keep running or end as the release notes say (sessions do not survive an app rename); the workspace and its file survive; outdated pool instances are recreated (POOL-06 behaviour); a new launch works after preloading finished.

### UPG-03 Rollback
Safety: test-only, disruptive
Steps: `gh workflow run rollback.yml -R EduIDE/EduIDE-deployment -f environment=$ENV` (blank revision = one back), watch it, then PLAT-01, PLAT-02, API-01 and a launch.
Expect: green; versions back to `FROM`; Session, Workspace CRs and PVCs untouched (the workflow does not touch them); the persistent fixture workspace still has its file. Across a CRD schema change the cluster release would have to be rolled back too: record if `FROM` and `TO` differ in the cluster chart. Rolling back from Cloud 3.0.1 to 3.0.0 re-enables the admin API endpoint (API-11 answers 401 instead of 404); record it. `rollback.yml` has no cluster identity check: confirm the environment before approving.

### UPG-04 Upgrade again
Safety: test-only, disruptive
Steps: repeat UPG-02 step 2 to return to `TO`.
Expect: green; the environment ends on the version it should be on. Record the final versions.

### UPG-05 Redeploy without changes restarts nothing
Safety: test-only, disruptive
Steps: record the pod UIDs of operator, service, landing page and preloading; run the deploy dispatch with the versions already deployed; compare UIDs; `helm get manifest --revision <before>` against `<after>`.
Expect (target): no pod restarted; the manifests are identical. Chart 3.0.0-rc.3: only `helm.sh/revision` differs, and operator, service, landing page and preloading restart (pod template annotation); record `fail`. Every operator restart also triggers OPR-13 and DB-12 effects.

Cleanup: `ft_cleanup`.

## Explore

- Upgrade while a launch is in flight (click a tile, then start the deploy): what does the student see?
- Upgrade while the pool is being refilled.
- How long until the warm pool is full again after the upgrade (time to first fast launch)?
- Does the rollback summary read back from the cluster the same versions PLAT-01 sees?
