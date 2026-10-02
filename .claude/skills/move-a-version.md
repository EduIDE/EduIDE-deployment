---
name: move-a-version
description: Move an environment to a new EduIDE version, including production. Use when asked to deploy a version, update production, bump the chart version, roll out a release, or pin an image tag for one installation.
---

# Moving a version into an environment

**This repository chooses which chart version an environment installs. It does
not choose image tags.** Image tags come from the chart: `appVersion` renders
every IDE image, `versions.cloud` the operator and service, `versions.landingPage`
the landing page. So "move production to EduIDE 1.3.0" is a chart version bump
here, and a chart release in EduIDE-Helm before it.

```
EduIDE            release v1.3.0        images published as 1.3.0
EduIDE-Helm       chart 2.3.0           appVersion 1.3.0
EduIDE-deployment chartVersion: 2.3.0   merging this IS the deploy
```

Getting this backwards - trying to move the IDE version from here alone - leads
to setting `versions.ide`, which is an override for unreleased images and not
how a release reaches an environment.

## The change

One line per environment, in `environments/<name>/env.yaml`:

```yaml
spec:
  platform:
    chartVersion: 2.3.0
```

**Production and staging go in separate pull requests.** Not a style
preference: bundling them means production cannot be reverted without also
reverting the environment that proved it. `renovate.json` enforces the same
split for automated bumps, and production bumps never arrive unasked - somebody
ticks the box on the Dependency Dashboard, because bumping `chartVersion` in a
production environment *is* the release procedure.

The three production installations:

| Environment | Cluster |
|---|---|
| `eduide.artemis.cit.tum.de` | tum-production |
| `bonn.eduide.aet.cit.tum.de` | eduide |
| `mannheim.eduide.aet.cit.tum.de` | eduide |

## Check these before opening the PR

**The chart version exists.** Merging a manifest that names an unpublished
chart fails at chart resolution, in the deploy, against production.

```bash
helm show chart oci://ghcr.io/eduide/charts/eduide --version 2.3.0
```

**The images that chart pins exist.** A published chart is not proof - the
component build runs after its release is created and takes the better part of
an hour.

```bash
gh run list --repo EduIDE/EduIDE --event release --limit 1
docker manifest inspect ghcr.io/eduide/eduide/java-17:1.3.0
```

**It renders.** Point the tests at the version the environment will actually
install:

```bash
./scripts/test-deploy-logic.sh
EDUIDE_CHART=../EduIDE-Helm/charts/eduide ./scripts/test-deploy-logic.sh   # unpublished chart

CHART=oci://ghcr.io/eduide/charts/eduide
helm template eduide $CHART --version 2.3.0 \
  -f environments/_base.yaml -f environments/eduide.artemis.cit.tum.de/values.yaml \
  --set service.adminApiToken=x \
  | grep -oE "ghcr\.io/eduide/eduide/[a-z0-9-]+:[^ \"',]+" | sort -u
```

That last one is the check worth doing by hand: it prints the image tags the
environment will pull. `--set service.adminApiToken=x` is only to get past the
deliberate render failure on placeholder secrets; never put a real one there.

## versions.ide is an override, and every use of it is temporary

`versions.ide` in an environment's `values.yaml` replaces `appVersion` for that
installation. It exists for one case: an image that no numbered release
publishes yet, typically a `pr-NNN` tag while a pull request is open.

Mannheim carried `versions.ide: pr-170` for exactly that reason, with a comment
naming the condition for removing it - "once #170 merges and a release publishes
a numbered tag". **Check those comments whenever a release moves past them.** A
pin left behind silently holds an installation on an old image while every other
environment moves, and the chart version bump beside it looks like it did
something.

Never set a blanket tag. A pull request only builds the images of the repo it
came from, so one tag for everything puts the rest of the namespace into
`ImagePullBackOff`. One knob, one repository.

## What CI does and does not prove

`validate.yml` renders every environment and checks that every chart version any
environment selects is published. It does **not** check the images inside that
chart, and it cannot tell you whether the new version behaves. That is what
staging is for.

The `e2e.` environment follows `main` automatically and is not somewhere to
point manual work; `staging.` is the manual one.

## After merging

The deploy asserts which cluster it reached before touching anything, shows a
`helm diff`, and runs `--wait --atomic`. A failed upgrade rolls back on its own.

If something is wrong after a successful deploy, that is Actions → **Rollback**,
not a revert commit - the revert would be a second deploy taking the same time
as the first.

`eduide-cluster` is a `Bootstrap cluster` workflow input rather than a value in
a file, so nothing here bumps it. It is kept at the same version as `eduide` by
hand; pass the new version the next time that workflow runs.
