# Derive the control plane board version

## Problem
The per-cluster board version key was hand-maintained in each cluster manifest (PR #187).
It drifts from the control plane the environments run, so boards lag behind new metrics.

## Change
- `bootstrap-cluster.yml`: the "Control plane dashboards (go)" step derives the version.
  For every go environment on the cluster it reads the `eduide-control-plane` dependency of the pinned `eduide` chart with `helm show chart` and takes the highest.
  It fails with `::error::` when the chart cannot be read or has no such dependency, and prints a `::notice::` naming the version and the environment.
- That key is gone from the three cluster manifests and the schema.
- `deploy.yml`: after a go deploy, a step compares the `eduide.github.io/source` annotation of the board ConfigMap with the deployed control plane version.
  A missing or older board gives a `::warning::` to run `Bootstrap cluster`; an unreadable one gives a `::notice::`.
  The step never fails the deploy.
- `test-deploy-logic.sh`: checks that every go environment's chart has the dependency.
- Docs updated: `AGENTS.md`, `docs/cluster-setup.md`, `docs/monitoring-setup.md`, values comments.

## Verification
- Derivation run locally per cluster against the real charts.
- `actionlint`, `shellcheck -S error`, `test-deploy-logic.sh`, schema validation of every cluster manifest.
