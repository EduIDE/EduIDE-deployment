# Bootstrap ships the Go control plane boards

Date: 2026-11-22

## Problem

The `eduide-control-plane` chart renders its Grafana boards ("EduIDE control plane", "EduIDE usage") as a ConfigMap in `cattle-dashboards`.
The deploy credentials of an environment cannot write there, so every go environment sets `monitoring.dashboard.enabled: false`.
On stud the boards were applied by hand on 2026-11-21; tum-production and parma had none.

## Change

- `bootstrap-cluster.yml`: new step "Control plane dashboards (go)" for clusters with go environments.
  It pulls the `eduide-control-plane` chart at `spec.controlPlaneDashboards`, takes `files/dashboard.json` and `files/usage-dashboard.json`, sets the preselected namespace to the first go environment of the cluster and applies ConfigMap `cattle-dashboards/eduide-go-control-plane-dashboards` (label `grafana_dashboard=1`).
  `dry_run` writes a `kubectl diff` to the step summary and applies nothing.
  The chart is not rendered, because its schema needs a whole installation's values.
- `clusters/{tum-student,tum-production,eduide}.yaml`: `controlPlaneDashboards: 0.2.3`.
- `schemas/cluster.schema.json`: the new key.
- `scripts/test-deploy-logic.sh`: a cluster with go environments must set it.
- Docs: `AGENTS.md`, `docs/cluster-setup.md`, `docs/monitoring-setup.md`, the comments in the three go values files.

## Verified

- Local run of the step's commands against chart 0.2.3; `kubectl diff` against stud shows only the annotation and label change, the boards are byte-identical to the hand-applied ones.
- `actionlint`, `shellcheck -S error`, schema check of all cluster manifests, `test-deploy-logic.sh` all pass.

## Rollout

Run `Bootstrap cluster` per cluster with `dry_run: true`, read the diff, then `dry_run: false`.
tum-production only by whoever owns the production rollout.
