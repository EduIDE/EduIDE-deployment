# Deployment Workflows

This repository deploys Theia Cloud through three GitHub Actions entrypoints that all call the reusable [`deploy-theia.yml`](../.github/workflows/deploy-theia.yml) workflow.

## Workflow Overview

### Pull request deployments

- Workflow: [`deploy-pr.yml`](../.github/workflows/deploy-pr.yml)
- Trigger: pull requests (`opened`, `synchronize`, `reopened`) and manual `workflow_dispatch`
- Targets: `test1`, `test2`, `test3`
- Manual inputs:
  - `theia_cloud_tag`
  - `landing_page_tag`
  - `ide_images_tag`
  - `execution_mode`
  - `helm_chart_tag`
  - `clean_install`

`clean_install` now defaults to `true` for manual PR deployments.

### Staging deployments

- Workflow: [`deploy-staging.yml`](../.github/workflows/deploy-staging.yml)
- Trigger: push to `main` and manual `workflow_dispatch`
- Target: `theia-staging`
- Manual inputs:
  - `execution_mode`
  - `clean_install`

### Production deployments

- Workflow: [`deploy-production.yml`](../.github/workflows/deploy-production.yml)
- Trigger: manual `workflow_dispatch`
- Target: `theia-prod`
- Manual inputs:
  - `execution_mode`
  - `clean_install`

## Manual Deployment Inputs

### `execution_mode`

Selects which runner backend executes the deployment:

- `self-hosted-buildkit`
- `github-runners`

### `clean_install`

When enabled, the reusable deployment workflow performs a namespace-scoped cleanup before Helm install:

- deletes session and workspace resources
- deletes AppDefinitions
- deletes deployments, daemonsets, and statefulsets
- waits for pods to terminate
- deletes PVCs

Use this when you need a clean rollout and are prepared to remove the namespace-local runtime state.

## Release Process For Pinned Image Tags

Staging and production now intentionally pin several images to SHA-suffixed tags instead of floating on plain `latest`. A release therefore requires updating the short SHA suffix in the deployment values files.

### Which files to update

For staging:

- [`deployments/theia-staging.artemis.cit.tum.de/values.yaml`](../deployments/theia-staging.artemis.cit.tum.de/values.yaml)
- [`deployments/theia-staging.artemis.cit.tum.de/theia-crds-helm-values.yml`](../deployments/theia-staging.artemis.cit.tum.de/theia-crds-helm-values.yml)

For production:

- [`deployments/theia.artemis.cit.tum.de/values.yaml`](../deployments/theia.artemis.cit.tum.de/values.yaml)
- [`deployments/theia.artemis.cit.tum.de/theia-crds-helm-values.yml`](../deployments/theia.artemis.cit.tum.de/theia-crds-helm-values.yml)

### Tags that currently need to be bumped together

In each environment `values.yaml`:

- `theia-cloud.operator.image`
- `theia-cloud.service.image`
- `theia-cloud.preloading.images[0..10]`
- `theia-cloud.landingPage.image`

In each environment `theia-crds-helm-values.yml`:

- `conversion.image`

### Practical rule

There are currently three image families with separate tag suffixes:

- Theia Cloud control-plane images:
  - `operator`
  - `service`
  - `conversion-webhook`
- Landing page images:
  - `theia-cloud.landingPage.image`
  - `theia-cloud.preloading.images[0]`
- IDE and language-server images:
  - `theia-cloud.preloading.images[1..10]`

If a new release publishes a new short SHA for one of those families, update every field in that family in both staging and production before merging.

### Recommended release checklist

1. Confirm the published image tags in GHCR.
2. Update staging and production values files with the new short SHA suffixes.
3. Keep `theia-cloud.landingPage.image` and `theia-cloud.preloading.images[0]` in sync.
4. Keep `theia-cloud.preloading.images[1..10]` aligned with the intended IDE and language-server release.
5. Keep `operator`, `service`, and `conversion.image` in sync when rolling a new control-plane build.
6. If test environments should stop using a PR-specific conversion webhook, update their `theia-crds-helm-values.yml` files as well.
7. Validate the edited YAML files before opening the PR.

Example validation:

```bash
ruby -e 'require "yaml"; %w[
  .github/workflows/deploy-pr.yml
  .github/workflows/deploy-staging.yml
  .github/workflows/deploy-production.yml
  deployments/theia-staging.artemis.cit.tum.de/values.yaml
  deployments/theia-staging.artemis.cit.tum.de/theia-crds-helm-values.yml
  deployments/theia.artemis.cit.tum.de/values.yaml
  deployments/theia.artemis.cit.tum.de/theia-crds-helm-values.yml
].each { |f| YAML.load_file(f); puts "OK #{f}" }'
```

## Notes

- PR workflows can temporarily override image tags with workflow inputs, so you do not need to edit committed values files for preview deployments.
- Staging and production use committed values files as the source of truth, so release tag bumps must happen in git.
