# AGENTS.md — EduIDE-deployment

Deploys EduIDE to TUM's Kubernetes clusters. **No application code lives here.**

`CLAUDE.md` is a symlink to this file, so every agent reads the same thing.

## The model

```
clusters/<name>.yaml            where things run (identity, storage, runner)
environments/<name>/env.yaml    what runs there (hosts, branding, versions)
environments/_base.yaml         settings identical in every environment
scripts/render-values.sh        compiles a manifest into Helm values
```

An environment is one namespace on one cluster.

| Cluster | Environments |
|---|---|
| `tum-student` | `test1`, `test2`, `test3`, `e2e-test`, `staging` |
| `tum-production` | `tum-production` |
| `eduide` | `bonn`, `mannheim` (cluster not provisioned yet) |

The charts live in **EduIDE-Helm** and are pulled from
`oci://ghcr.io/eduide/charts`. Chart templates are not edited here.

## Before you change anything

```bash
./scripts/render-values.sh test1        # what the manifest compiles to
./scripts/test-deploy-logic.sh          # override, tag and listener logic
./scripts/verify-migration.sh           # compiled == legacy values (needs helm + GHCR)
```

`verify-migration.sh` must say `IDENTICAL` for every environment. It is the
gate for cutting an environment over, and it can be deleted once
`deployments/` is gone.

## Things that will catch you out

**`e2e-test` follows main and is tested automatically.** Do not point manual
work at it; a red build there should mean the code is broken, not that somebody
was mid-experiment. `staging` is the manual one.

**`gateway.listenerPrefix` is not the landing host.** Staging's landing host is
`theia-staging` but its Gateway sections are `staging-*`; production's are
`prod-*`, not `theia-*`. Getting this wrong attaches routes to sections that do
not exist, and nothing fails until traffic does.

**Never set a blanket image tag.** A pull request only builds the images of the
repo it came from. `--set global.imageTag=pr-451` puts the whole namespace into
`ImagePullBackOff` because `java-17:pr-451` does not exist. Overrides are per
component: `controlPlane`, `ide`, `landingPage`.

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

`theia-appdefinitions` preserves live `minInstances`/`maxInstances`, and
`theia-shared-cache` generates a Redis password when its lookup finds no
existing Secret. Both are correct — they stop Helm resetting live state — but
`lookup` returns empty under `helm template`, so both are masked in
`render-envs.sh` and `verify-migration.sh`. **If you add a `lookup`, add it to
the mask list too**, or the render diff becomes noise and stops being read.

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
