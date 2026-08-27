# AGENTS.md - EduIDE-deployment

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
| `tum-student` | `test1.eduide.student.k8s.aet.cit.tum.de`<br>`test2.…`<br>`test3.…`<br>`e2e.…`<br>`staging.…` |
| `tum-production` | `eduide.artemis.cit.tum.de` |
| `eduide` | `bonn.eduide.aet.cit.tum.de`<br>`mannheim.eduide.aet.cit.tum.de` |

**An environment is named after the hostname it serves.** The directory under
`environments/`, the GitHub Environment and the landing host are the same
string, so there is nothing to map and nothing to keep in sync.

The `eduide` cluster is not provisioned yet.

The charts live in **EduIDE-Helm** and are pulled from
`oci://ghcr.io/eduide/charts`. Chart templates are not edited here.

Since 2.0.0 there are **two charts and no chart source in this repo**:

| Chart | Installed by | Owns |
|---|---|---|
| `eduide-cluster` | `bootstrap-cluster.yml`, once per cluster | CRDs, conversion webhook, ClusterRoles, issuers, the shared Gateway, PodMonitors, dashboards |
| `eduide` | `deploy.yml`, once per environment | operator, REST service, landing page, routes, app definitions, preloading |

Values files are keyed at the top level (`hosts:`, `keycloak:`, `operator:`).
The `theia-cloud-combined` umbrella, its five subcharts and the pre-restructure
workflows are gone - the installations are being brought up fresh, so there was
nothing to migrate.

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

**Placeholder Keycloak values fail the render, deliberately.** The oauth2-proxy
ConfigMaps are emitted regardless of `keycloak.enable`, because the operator
mounts them into every session pod by literal name. Left at the chart's
defaults they point the proxy at `https://keycloak.url/auth/realms/TheiaCloud`,
so sessions fail at the proxy rather than running unauthenticated - the worst of
both, with no clue why. An installation with no identity provider yet sets
`keycloak.allowUnauthenticated: true` and says so; Bonn does.

**Monitoring is on by default and opted out per environment** with
`monitoring.enabled: false`. The PodMonitors themselves are in the cluster
chart - they must be created in Rancher's namespace to be discovered, and one
per tenant would collide on names - so the flag decides whether the
environment's namespace is in the list they watch. Do not confuse it with
`monitor.enable`, the operator's session activity tracker.

**Keycloak is per environment, including `authUrl`.** TUM installations share a
server and differ only by realm; Bonn and Mannheim bring their own. Nothing
about the identity provider belongs in `_base.yaml`, and secrets never go in a
manifest.

**`e2e-test` follows main and is tested automatically.** Do not point manual
work at it; a red build there should mean the code is broken, not that somebody
was mid-experiment. `staging` is the manual one.

**TUM production is on a different domain on purpose.** Every other production
installation is under `eduide.aet.cit.tum.de`; `tum-production` is
`eduide.artemis.cit.tum.de` because it sits behind a different load
balancer. It reads like a typo. It is not.

**A certificate that does not name a host fails silently too, and worse.** The
Gateway reports `Programmed=True ResolvedRefs=True` for a listener whose secret
holds a certificate for entirely different hostnames - Gateway API never
compares the two. The only symptom is a browser warning, and then the landing
page cannot call its own REST service, because the browser blocks that
cross-origin XHR over an invalid certificate. test3 ran that way for 184 days.
`bootstrap-cluster.yml` derives the certificate's names from the same pass that
derives the listeners, so the two cannot disagree.

**Only put names with a listener on a certificate.** cert-manager solves
HTTP-01 by serving a token on port 80 for each name. A name with no listener
answers 404, its challenge stays pending, and the pending order blocks the
certificate for every other name on it. Adding `cache.test3` and `repo.test3`
by hand - which no listener serves, because test3 runs no shared cache - stalled
the whole reissue until they were removed.

**An HTTPS listener without a TLS secret fails silently.** It renders
`certificateRefs` with an empty name; the Gateway is accepted and just never
programs TLS for that hostname, so the first symptom is a browser connection
failure. The secrets are per cluster in `spec.tls` - the clusters issue
certificates differently, and `tum-production` also needs `acmeHttp: true` for
the plain `:80` listeners cert-manager's HTTP-01 challenges arrive on. The chart
fails the render on a missing secret and `test-deploy-logic.sh` checks the
policy is complete.

**The Gateway section prefix is not the landing host.** Production's landing
host is `eduide` but its Gateway sections are `prod-*`; `e2e-test`'s are `e2e-*`.
The shared Gateway's listeners are derived from the `sectionName`s an
environment declares, so those strings are load-bearing. Getting one wrong
attaches a route to a section that does not exist, and nothing fails until
traffic does.

**Storage class is a cluster property; an environment must not set it.**
`clusters/<name>.yaml` states it once and the deploy renders it into a values
file `-f`'d before `_base.yaml`.

On the test cluster **both** `csi-rbd-sc` and `longhorn` exist and **both are
marked default**, so a PVC that omits the class gets an arbitrary one. test3 ran
on `longhorn` and the others on `csi-rbd-sc` for no reason anyone recorded; they
are standardised on `csi-rbd-sc` now. Two default StorageClasses is a cluster
misconfiguration worth raising separately - nothing in this repo can fix it.

Two things claim storage independently (the operator, and the shared cache's
vendored reposilite chart with its own key), so the deploy sets both;
`test-deploy-logic.sh` renders every environment against a sentinel and fails if
any storage key escapes the cluster default.

**The dependency cache is off in production.** `eduide-shared-cache.enabled: false` in
all three production installations, asserted by `test-deploy-logic.sh`. Nothing
consumes it anywhere today regardless: the operator's `enableBuildCaching` and
`enableDependencyCaching` default to false and no environment overrides them,
so enabling the chart alone deploys a cache with no clients.

**Never set a blanket image tag.** A pull request only builds the images of the
repo it came from. One tag for everything puts the whole namespace into
`ImagePullBackOff` because `java-17:pr-451` does not exist. The chart carries
one version knob per source repository - `versions.ide` (EduIDE),
`versions.cloud` (EduIDE-Cloud), `versions.landingPage` - and a deploy override
names exactly one of them. `versions.ide` empty means the chart's `appVersion`,
so a plain install pins every IDE image to the released tag.

**Do not list images to preload, and do not list app definitions.** Both derive
from `appDefinitions.apps` in the chart, along with the landing page's app
list. They used to be three hand-maintained lists - that is how production
ended up offering `c-templates` while preloading everything except
`c-templates`. Adding a language is one entry in the chart.

**Staging resolves an immutable `latest-<sha>` tag, never a floating one.** With
a floating tag the pod template does not change between upgrades, so
`helm --wait` returns immediately without pulling and `--atomic` has nothing to
roll back.

**Secrets go in a values file, never `--set`.** `--set` puts them in the process
list and in Actions debug logs.

**Nothing cluster-scoped is installed by a tenant deploy.** CRDs, the conversion
webhook, the shared Gateway and the PodMonitors are all in `eduide-cluster`,
installed once per cluster by `bootstrap-cluster.yml`. Reinstalling them from
every tenant deploy is what the old six-attempt retry loop was working around.

**Three things are derived from the environments on a cluster, not written
down.** Gateway listeners come from each environment's `gateway.parentRefs`
plus its hosts; the PodMonitors' watched namespaces come from
`spec.namespace`. Both used to be hand-written lists in a second file, and both
had gone stale - the monitoring one still named `theia` and `theia-staging`,
so some environments were scraped and others silently were not. Adding an
environment is one directory; do not add a second edit anywhere.

**The shared Gateway is in `eduide-system`, not `gateway-system`.** All the
cluster-scoped EduIDE resources sit in one namespace. `envoy-gateway-system` is
a different thing entirely - Envoy Gateway's own operator namespace - and is
not ours to move.

**Preloading is a separate Helm release.** It pulls ~10 multi-GB images on every
node; under `--wait` it would time out and `--atomic` would then roll back a
healthy deploy.

## Two `lookup` calls make rendering nondeterministic

The `eduide` chart preserves live `minInstances`/`maxInstances` on
AppDefinitions, and the shared cache generates a Redis password when its lookup
finds no existing Secret. Both are correct - they stop Helm resetting live state
- but `lookup` returns empty under `helm template`, so both must be masked
wherever rendered output is diffed. **If you add a `lookup`, add it to the mask
list too**, or the render diff becomes noise and stops being read.

## Adding an environment

One directory under `environments/`, then the GitHub Environment holding its
`KUBECONFIG`. The shared Gateway listeners are derived from the manifests, so
there is no second file to edit. See `docs/environments.md`.

## Dependency updates

`renovate.json` extends the org-wide preset in EduIDE/.github. Only two things
here are versioned and both are managed: the actions in the workflows, and
`spec.platform.chartVersion` in each environment manifest. The chart version
needs a custom regex manager - `env.yaml` is an `eduide.dev/v1 Environment`, not
a `Chart.yaml` and not a values file, so no built-in manager can see it.

**Test and staging chart bumps arrive batched. Production ones do not arrive at
all** until somebody ticks the box on the Dependency Dashboard, because bumping
`chartVersion` in a production environment is the release procedure rather than
a chore, and grouping it with the test environments would mean neither could be
reverted without the other.

`eduide-cluster` is a `Bootstrap cluster` workflow input, not a value in a file,
so nothing bumps it. Keep it at the same version as `eduide` by hand.

## Preparing a cluster

`docs/cluster-setup.md` is the sequence, and says which parts
`bootstrap-cluster.yml` does and which are manual. Three things it needs that
the workflow does not supply: a GatewayClass whose load balancer address matches
DNS, a `ClusterIssuer` that can solve ACME over Gateway API, and the webview
wildcard certificate. `docs/github-environments.md` covers every secret and
which of the two kinds of GitHub Environment holds it.

## Conventions

- Bash: `set -euo pipefail`. Prefer `if` blocks over `A && B` - `set -e` has
  subtle rules there and this is code that touches production.
- Workflows must pass `actionlint` and scripts `shellcheck -S error`.
- Every environment renders through the same code path. If something is true of
  one environment only, it belongs in that manifest's `values:` block, not in a
  conditional.
