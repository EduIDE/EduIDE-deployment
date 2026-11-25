# 11 Upgrade and rollback smoke (UPG)

Server module with GitHub workflows. Test environments only (`staging.`, `test1.`, `test2.`, `test3.`); never production, never `e2e.`, never `clean_install`. Each deploy affects everyone on that environment: announce it. Workflows: `.github/workflows/deploy-dispatch.yml` ("Deploy environment"; inputs `environment`, `chart_version`, `control_plane_tag`, `ide_tag`, `landing_page_tag`, `clean_install`, `dry_run`), `rollback.yml` ("Rollback"; inputs `environment`, `revision`), `bootstrap-cluster.yml` ("Bootstrap cluster"; installs the CRD chart `eduide-crds` and the Grafana boards on Go clusters; `dry_run` defaults to true).

Variables: `FROM` = the chart version currently deployed (PLAT-01), `TO` = the version under test.

Facts:
- The deploy runs `helm upgrade --install eduide oci://ghcr.io/eduide/charts/eduide --wait --atomic --timeout 15m` with `_base-go.yaml`, the environment's `values.yaml` and the overrides; the release is always `eduide`. The OIDC client Secret is applied from the GitHub Environment secret before helm runs. The health check is `GET $LANDING/api/v1/status` (200 within two minutes, a warning otherwise, the deploy still passes).
- The step "Force a pull when the tag is floating" (`rollout restart`) runs for the Java stack only. A Go deploy restarts a component only when its pod template changes.
- Session pods are bare pods and are not part of the release: a deploy never touches running sessions. Idle pool pods are replaced only when their spec hash changes (template spec, agent image string, placement, the Git settings when providers are set, the agent pull policy when set; POOL facts), claimed ones never. A deploy that leaves the hash alone keeps every idle pod, even when a mutable tag such as `pr-N` now points to newer images: check that with PLAT-11 after every deploy.
- CRDs are not in this release: `eduide-crds` is installed by Bootstrap cluster; rolling back across a CRD schema change needs that release rolled back too.

### UPG-01 Dry run shows the expected change
Safety: test-only (applies nothing)
Steps:
```bash
gh workflow run deploy-dispatch.yml -R EduIDE/EduIDE-deployment -f environment=$ENV -f chart_version=$TO -f dry_run=true
gh run watch -R EduIDE/EduIDE-deployment $(gh run list -R EduIDE/EduIDE-deployment -w deploy-dispatch.yml -L1 --json databaseId -q '.[0].databaseId')
```
Expect: the run is green; its summary (web UI job summary; `gh run view --log` does not contain it) shows a non-empty helm diff (an empty diff for a version change is a finding) that matches the release notes of `TO` (image tags, IDETemplate specs, `appVersion`); the cluster identity check passes.

### UPG-02 Upgrade with sessions running
Safety: test-only, disruptive
Steps:
1. Before: a saved fixture session with a file in its workspace (`ft-upg-ws`, `ft-upg-s1`, opened through a port-forward so the file can be written), a warm claimed fixture session (`<TPL_POOL>`), and the logged-in user's own session from a tile. Record pod UIDs of sessions and control plane pods and the spec hashes of idle pool pods; run PLAT-01.
2. `gh workflow run deploy-dispatch.yml -R EduIDE/EduIDE-deployment -f environment=$ENV -f chart_version=$TO` and watch it.
3. After: PLAT-01, PLAT-02, PLAT-04, PLAT-05, API-01 and a fresh launch from the landing page; compare UIDs.
Expect: the deploy is green (`--wait --atomic`) and ends with `/api/v1/status` 200; new component versions as expected; running session pods keep their UIDs and URLs (a deploy does not touch them; the operator picks them up again without re-claiming them, OPR-10); the saved workspace and its file survive; idle pool pods with a changed spec hash are replaced one by one while the pool keeps its ready count (POOL-06), idle pods with an unchanged hash stay (same UIDs, even if the deploy changed an image behind a mutable tag: then PLAT-11 fails, which is a finding about the tag, not about the pool); a new launch works afterwards (warm where a pool exists, after the new pods are ready). Anything that restarts the landing page or the service for a moment is recorded with the time the student could not launch.

### UPG-03 Rollback
Safety: test-only, disruptive
Steps: `gh workflow run rollback.yml -R EduIDE/EduIDE-deployment -f environment=$ENV` (blank revision = one back), watch it, then PLAT-01, PLAT-02, API-01 and a launch.
Expect: green; versions back to `FROM`; sessions, workspaces, pools and PVCs untouched (the workflow does not touch them), the saved fixture workspace still has its file. Across a CRD schema change (`spec.controlPlaneCRDs` of the cluster file differs between `FROM` and `TO`) the CRD release would have to be rolled back too: record it. `rollback.yml` has no cluster identity check: confirm the environment before approving. A rollback across the 2.x/3.x line is a stack switch, not a rollback (`docs/rollout-3.0-tum-production.md`).

### UPG-04 Upgrade again
Safety: test-only, disruptive
Steps: repeat UPG-02 step 2 to return to `TO`.
Expect: green; the environment ends on the version it should be on. Record the final versions.

### UPG-05 Redeploy without changes restarts nothing
Safety: test-only, disruptive
Steps: record the pod UIDs of operator, service, authz, landing page, OIDC bridge and the idle pool pods; run the deploy dispatch with the versions already deployed (blank overrides); compare UIDs; `helm --kube-context "$CTX" -n "$NS" get manifest eduide --revision <before>` against `<after>`.
Expect: the manifests of the two revisions are identical apart from the revision number, no `helm.sh/revision` or timestamp in pod templates, every pod keeps its UID, the idle pool pods included (their spec hash does not change when nothing that feeds it changed; no `rollout restart` runs for Go environments; a floating tag would not restart them either, so a `channel: main` environment on a mutable tag must be pinned to the chart `appVersion` to be tested). A restart of the operator, service or authz here is a finding.

### UPG-06 Bootstrap preview for the CRD release
Safety: test-only (applies nothing with `dry_run=true`)
Steps: `gh workflow run bootstrap-cluster.yml -R EduIDE/EduIDE-deployment -f cluster=$CLUSTER -f chart_version=<unused for Go-only clusters, see the workflow input text> -f dry_run=true` and read the job summary; compare with `yq .spec.controlPlaneCRDs clusters/$CLUSTER.yaml` and PLAT-01.
Expect: green; the preview shows the `eduide-crds` diff (none when the version matches) and the Grafana board ConfigMap diff (`spec.controlPlaneDashboards`); no step targets the Theia Cloud CRDs or the 3.x `eduide-cluster` chart on a cluster that still has them (it refuses). A CRD chart bump that changes a served version or removes a field needs an ADR in the control plane (CRD edits restart the operators; v1alpha1 changes are additive).

## Unverified, check in the first run

- UPG-02: that a deploy leaves session pods and idle pool pods alone unless their spec hash changes, and how long the landing page and service are unavailable.
- UPG-05: that no Go pod restarts on a no-change redeploy (the `rollout restart` step is Java-only, `deploy.yml`); `helm get manifest` diff noise from `lookup`-based values (AGENTS.md mentions masks for the old chart).
- UPG-06: the `chart_version` input is required by the workflow even for Go-only clusters; what value it accepts there.
- UPG-03: that `rollback.yml` works for a Go release with `--wait` and the OIDC secret untouched.
- All UPG tests: running a workflow needs permission that the agent may not have; ask the environment owner to start it and report the run URL.

## Retired

- The Java facts (preloading release, garbage collector pod UIDs, admin API re-enabled by a rollback, `helm.sh/revision` in pod templates, `--wait` over a DaemonSet) no longer apply. No UPG ID was retired.

## Explore

- Upgrade while a launch is in flight (click a tile, then start the deploy): what does the student see?
- Upgrade while the pool is being refilled; how long until the warm pool is full again (time to the first fast launch)?
- Roll the operator image alone (`control_plane_tag` override) with running sessions: any `Reclaimed` or `Failed`?
- An `ide_tag` override to a tag that does not exist: the pool's idle pods go `ImagePullBackOff` and are replaced in a loop (POOL-13); what happens to `--wait --atomic`, and do running sessions survive?
- Does the rollback summary read back from the cluster the same versions PLAT-01 sees?
