# AGENTS.md — EduIDE-deployment

Deploys EduIDE to TUM's Kubernetes clusters. **No application code lives here.**

`CLAUDE.md` is a symlink to this file, so every agent reads the same thing.

## The model

```
clusters/<name>.yaml            where things run (identity, storage, runner)
environments/<name>/env.yaml    what runs there (hosts, branding, versions)
environments/_base.yaml         settings identical in every environment
environments/<name>/values.yaml  plain Helm values, -f'd directly
```

An environment is one namespace on one cluster.

| Cluster | Environments |
|---|---|
| `tum-student` | `test1`, `test2`, `test3`, `e2e-test`, `staging` |
| `tum-production` | `tum-production` |
| `eduide` | `bonn`, `mannheim` (cluster not provisioned yet) |

The charts live in **EduIDE-Helm** and are pulled from
`oci://ghcr.io/eduide/charts`. Chart templates are not edited here.

Since chart 2.0.0 there is **one tenant chart**, `eduide`, replacing the
`theia-cloud-combined` umbrella and its five subcharts. Values files are keyed
at the top level (`hosts:`, `keycloak:`, `operator:`), not under
`theia-cloud:`. `charts/` and `deployments/` in this repo are the superseded
setup, kept only until the fresh installations are up.

## Before you change anything

```bash
CHART=oci://ghcr.io/eduide/charts/eduide
helm template eduide $CHART --version 2.0.0 \
  -f environments/_base.yaml -f environments/test1/values.yaml
./scripts/test-deploy-logic.sh          # override, tag, listener and storage logic
```

Point `EDUIDE_CHART` at a local `EduIDE-Helm/charts/eduide` to test against an
unpublished chart:

```bash
EDUIDE_CHART=../EduIDE-Helm/charts/eduide ./scripts/test-deploy-logic.sh
```

## Things that will catch you out

**The cluster identifies itself; nothing is transcribed.** `Bootstrap cluster`
writes the cluster name into `eduide-system/eduide-cluster-identity`, and every
deploy reads it back and compares with the environment's `spec.cluster`. Do not
add an API server URL to the cluster manifests: every cluster sits behind the
same Rancher endpoint, so that URL is identical for all of them and comparing
it would pass whichever cluster the kubeconfig reached.

**Keycloak is per environment, including `authUrl`.** TUM installations share a
server and differ only by realm; Bonn and Mannheim bring their own. Nothing
about the identity provider belongs in `_base.yaml`, and secrets never go in a
manifest.

**`e2e-test` follows main and is tested automatically.** Do not point manual
work at it; a red build there should mean the code is broken, not that somebody
was mid-experiment. `staging` is the manual one.

**The Gateway section prefix is not the landing host.** Production's landing
host is `eduide` but its Gateway sections are `prod-*`; `e2e-test`'s are `e2e-*`.
The shared Gateway's listeners are derived from the `sectionName`s an
environment declares, so those strings are load-bearing. Getting one wrong
attaches a route to a section that does not exist, and nothing fails until
traffic does.

**Storage class is a cluster property; an environment must not set it.**
`clusters/<name>.yaml` states it once and the deploy renders it into a values
file `-f`'d before `_base.yaml`. A copy in an environment file is how `test3`
ended up asking for `longhorn` on a cluster that only offers `csi-rbd-sc` - no
error, just a PVC that never binds. Two things claim storage independently (the
operator, and the shared cache's vendored reposilite chart with its own key), so
the deploy sets both; `test-deploy-logic.sh` renders every environment against a
sentinel and fails if any storage key escapes the cluster default.

**The dependency cache is off in production.** `sharedCache.enabled: false` in
all three production installations, asserted by `test-deploy-logic.sh`. Nothing
consumes it anywhere today regardless: the operator's `enableBuildCaching` and
`enableDependencyCaching` default to false and no environment overrides them,
so enabling the chart alone deploys a cache with no clients.

**Never set a blanket image tag.** A pull request only builds the images of the
repo it came from. One tag for everything puts the whole namespace into
`ImagePullBackOff` because `java-17:pr-451` does not exist. The chart carries
one version knob per source repository — `versions.ide` (EduIDE),
`versions.cloud` (EduIDE-Cloud), `versions.landingPage` — and a deploy override
names exactly one of them. `versions.ide` empty means the chart's `appVersion`,
so a plain install pins every IDE image to the released tag.

**Do not list images to preload, and do not list app definitions.** Both derive
from `appDefinitions.apps` in the chart, along with the landing page's app
list. They used to be three hand-maintained lists — that is how production
ended up offering `c-templates` while preloading everything except
`c-templates`. Adding a language is one entry in the chart.

**Staging resolves an immutable `latest-<sha>` tag, never a floating one.** With
a floating tag the pod template does not change between upgrades, so
`helm --wait` returns immediately without pulling and `--atomic` has nothing to
roll back.

**Secrets go in a values file, never `--set`.** `--set` puts them in the process
list and in Actions debug logs.

**Nothing cluster-scoped is installed by a tenant deploy.** CRDs, the conversion
webhook and the shared Gateway belong to `bootstrap-cluster.yml`. Reinstalling
them from every tenant deploy is what the old six-attempt retry loop was
working around.

**Preloading is a separate Helm release.** It pulls ~10 multi-GB images on every
node; under `--wait` it would time out and `--atomic` would then roll back a
healthy deploy.

## Two `lookup` calls make rendering nondeterministic

The `eduide` chart preserves live `minInstances`/`maxInstances` on
AppDefinitions, and the shared cache generates a Redis password when its lookup
finds no existing Secret. Both are correct — they stop Helm resetting live state
— but `lookup` returns empty under `helm template`, so both must be masked
wherever rendered output is diffed. **If you add a `lookup`, add it to the mask
list too**, or the render diff becomes noise and stops being read.

## Adding an environment

One file under `environments/`, then the GitHub Environment holding its
`KUBECONFIG`. The shared Gateway listeners are derived from the manifests, so
there is no second file to edit. See `docs/environments.md`.

## Conventions

- Bash: `set -euo pipefail`. Prefer `if` blocks over `A && B` — `set -e` has
  subtle rules there and this is code that touches production.
- Workflows must pass `actionlint` and scripts `shellcheck -S error`.
- Every environment renders through the same code path. If something is true of
  one environment only, it belongs in that manifest's `values:` block, not in a
  conditional.
