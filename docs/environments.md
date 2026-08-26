# Environments

An environment is one EduIDE installation: a namespace on a cluster, with its
own hostnames, branding and Keycloak client.

```
clusters/<name>.yaml             where things run, and what is true of the whole cluster
environments/<name>/env.yaml     how this installation is DEPLOYED
environments/<name>/values.yaml  how the CHART is configured - a plain Helm values file
environments/_base.yaml          chart settings identical in every environment
schemas/                         JSON schemas env.yaml and clusters/*.yaml are validated against
```

The split is the whole point. `env.yaml` is read by the deploy workflow and
never by Helm; `values.yaml` is read by Helm and never by the workflow. If you
are looking for a chart setting it is in `values.yaml`, always.

The deploy runs, in this order:

```bash
helm upgrade --install eduide ./charts/theia-cloud-combined \
  -f cluster-defaults.yaml \                     # generated from clusters/<name>.yaml
  -f environments/_base.yaml \                   # identical everywhere
  -f environments/<name>/values.yaml \           # this installation
  -f secrets.yaml                                # from the GitHub Environment
```

Later files win, so an environment can override anything its cluster or the
base sets.

## The three clusters

| Cluster | Environments | Notes |
|---|---|---|
| `tum-student` | `test1`, `test2`, `test3`, `e2e-test`, `staging` | everything non-production |
| `tum-production` | `tum-production` | TUM's own installation |
| `eduide` | `bonn`, `mannheim` | other universities. **Not provisioned yet.** |

`bonn` and `mannheim` exist as reviewable configuration before the cluster does.
Deploying one stops at the cluster identity check until that cluster has been
bootstrapped and the GitHub Environment holds a `KUBECONFIG`.

## Hostnames

Test installations sit under `eduide.student.k8s.aet.cit.tum.de`, production
installations under `eduide.aet.cit.tum.de`.

| Environment | Landing host |
|---|---|
| `test1` | `test1.eduide.student.k8s.aet.cit.tum.de` |
| `test2` | `test2.eduide.student.k8s.aet.cit.tum.de` |
| `test3` | `test3.eduide.student.k8s.aet.cit.tum.de` |
| `e2e-test` | `e2e.eduide.student.k8s.aet.cit.tum.de` |
| `staging` | `staging.eduide.student.k8s.aet.cit.tum.de` |
| `tum-production` | `eduide.artemis.aet.cit.tum.de` |
| `bonn` | `bonn.eduide.aet.cit.tum.de` |
| `mannheim` | `mannheim.eduide.aet.cit.tum.de` |

Each landing host implies three more, all derived from the same block:

```
<landing>                            the landing page
service.<landing>                    the REST service
instance.<landing>                   session ingress
*.webview.instance.<landing>         per-session webviews
```

That last one is why listeners are per environment rather than one wildcard per
cluster: a wildcard certificate covers exactly one label, and the webview hosts
are three levels below the base.

## Identity provider

Keycloak is configured per environment, `authUrl` included. Nothing about it is
in `_base.yaml`: TUM installations share a server and differ by realm,
installations elsewhere may bring their own entirely.

| Environment | authUrl | realm | clientId |
|---|---|---|---|
| test1, test2, test3, e2e-test, staging | `keycloak-test.aet.cit.tum.de` | `tum` | `eduide` |
| tum-production | `keycloak.aet.cit.tum.de` | `tum` | `eduide` |
| bonn | `keycloak.aet.cit.tum.de` | **TBD** | `eduide` |
| mannheim | `keycloak.aet.cit.tum.de` | **TBD** | `eduide` |

Bonn's and Mannheim's realms are placeholders (`REALM-TBD-*`). A wrong
`authUrl`, `realm` or `clientId` fails at login, not at deploy, so nothing in CI
catches it. Confirm both with the university before the first deploy.

**Secrets are not here.** `clientSecret` and `cookieSecret` come from the
environment's GitHub Environment secrets, never from a file in this repo.

### A different provider entirely

The chart also supports a generic OIDC provider, added for Gitea and mutually
exclusive with Keycloak:

```yaml
theia-cloud:
  keycloak:
    enable: false
  gitea:
    enable: true
    issuerUrl: https://git.example.edu
    clientId: eduide
```

The chart refuses to render if both are enabled at once.

## Adding an environment

### 1. `environments/<name>/env.yaml`

Deploy metadata only. Sixteen lines:

```yaml
apiVersion: eduide.dev/v1
kind: Environment
metadata:
  name: bonn
  displayName: EduIDE Bonn
  tier: production           # test | staging | production
spec:
  cluster: eduide            # must match a file in clusters/
  namespace: bonn
  platform:
    chartVersion: 1.0.0-rc0
    channel: release         # release | main
```

`channel: main` makes the deploy resolve an immutable `latest-<sha>` tag and
restart the deployments afterwards. `release` pins whatever the values file
says. Production is always `release`.

### 2. `environments/<name>/values.yaml`

A plain Helm values file. Copy a neighbour and change the hosts, the Gateway
`parentRefs`, the Keycloak block and the branding. Everything else should come
from `_base.yaml`; if you find yourself repeating something across two
environments, move it there instead.

The four `parentRefs` are what the shared Gateway listeners are derived from,
so their `sectionName`s are load-bearing:

```yaml
theia-cloud:
  gateway:
    parentRefs:
      - { name: theia-shared-gateway, namespace: gateway-system, sectionName: bonn-landing }
      - { name: theia-shared-gateway, namespace: gateway-system, sectionName: bonn-service }
      - { name: theia-shared-gateway, namespace: gateway-system, sectionName: bonn-instances }
      - { name: theia-shared-gateway, namespace: gateway-system, sectionName: bonn-webview }
```

The prefix (`bonn-`) must be unique on the cluster; CI rejects a collision.

### 3. The GitHub Environment

Create one named exactly as the manifest, under **Settings → Environments**.

| Secret | What |
|---|---|
| `KUBECONFIG` | the whole kubeconfig file, pasted in |
| `THEIA_KEYCLOAK_COOKIE_SECRET` | `dd if=/dev/urandom bs=32 count=1 \| base64 \| tr -d -- '\n' \| tr -- '+/' '-_'` |
| `THEIA_ADMIN_API_TOKEN` | bearer token for the admin scaling API |

**Protection:** add required reviewers for anything `tier: production` or
`staging`. The deploy job names the environment, so GitHub holds the run until
someone approves, and the approval is recorded on the run. Test environments
generally do not need approvers - the point of a test environment is that
deploying to it is cheap.

### 4. Bootstrap the cluster

```
Actions -> Bootstrap cluster -> cluster: eduide, dry_run: true
```

The shared Gateway's listeners are derived from every environment that claims
the cluster, so a new environment needs no second file edited. Run it with
`dry_run: false` once the diff looks right.

### 5. DNS, certificates and Keycloak

Four DNS records per environment, matching the hosts above. Certificates for
each listener. Redirect URIs in Keycloak for every one of the four hosts, on a
client matching `clientId`. See `docs/keycloak-setup.md`.

## The dependency cache

`theia-shared-cache` deploys a Gradle build cache, a Redis and a reposilite
Maven proxy with a 20Gi PVC. It is **off in all three production
installations** and on in test and staging.

Switching it off needs two keys, not one:

```yaml
theia-shared-cache:
  enabled: false
  reposilite:
    enabled: false
```

The umbrella declares `theia-shared-cache` without a `condition:`, so `enabled`
only silences that chart's own templates; the vendored reposilite subchart is
gated separately by `reposilite.enabled` and would otherwise still bring a
Deployment and the PVC. `test-deploy-logic.sh` asserts both are false for every
`tier: production` environment.

Note that nothing consumes the cache today either way: the operator's
`enableBuildCaching` and `enableDependencyCaching` both default to `false` and
no environment overrides them, so sessions are not configured to reach it.
Turning it back on for an environment means setting those two and the matching
URLs as well, not just re-enabling the chart.

## What belongs in the cluster manifest

`clusters/<name>.yaml` carries what is true of the whole cluster:

```yaml
spec:
  storageClassName: local          # applied to every environment on this cluster
  gatewayClassName: envoy          # used when the shared Gateway is installed
  sharedGateway: { namespace: gateway-system, name: theia-shared-gateway }
  runner: ubuntu-latest            # deploying needs to reach the API server
  bootstrapEnvironment: cluster-eduide
```

`storageClassName` is rendered into a values file the deploy `-f`'s before
`_base.yaml`, and it covers **both** subcharts that claim storage: the
operator's session PVCs and `theia-shared-cache`'s vendored reposilite chart,
which has its own key and its own `csi-rbd-sc` default.

An environment must not set it. It is a property of the cluster - `eduide` runs
on local disks, both TUM clusters on Ceph - and a copy in an environment file is
how `test3` ended up asking for `longhorn` on a cluster that only offers
`csi-rbd-sc`: no error, just a PVC that never binds and a session that never
starts. `test-deploy-logic.sh` renders every environment against a sentinel and
fails if any storage key escapes the cluster default, so a new subchart with its
own key cannot slip through either.

`runner` is per cluster because deploying is not building. Builds all run on
GitHub-hosted runners; a deploy has to reach the cluster's API server, and the
three clusters may differ in how they are reachable.

## How a deploy knows it reached the right cluster

The cluster tells it. `Bootstrap cluster` writes the cluster's name into a
ConfigMap:

```
eduide-system/eduide-cluster-identity   clusterName: tum-student
```

Every deploy reads that back and compares it with the environment's
`spec.cluster`. A mismatch stops the deploy and says which cluster it actually
reached. Nobody transcribes anything and there is nothing to keep in sync - the
bootstrap workflow already knows which cluster it was told to bootstrap, so it
writes what it knows.

**Why not compare the API server URL?** Every cluster sits behind the same
Rancher endpoint, so that URL is identical for all of them. Comparing it would
pass whichever cluster the kubeconfig reached, which is worse than no check: it
looks like protection and provides none.

If a deploy reports the cluster carries no identity, it has not been
bootstrapped - run `Bootstrap cluster` for it. Bootstrapping refuses to rename a
cluster that already carries a different name, since that almost always means
the `KUBECONFIG` for that GitHub Environment points somewhere unexpected. Delete
the ConfigMap first if the rename is genuinely intended.

## Things that are not what they look like

**The Gateway section prefix is not the landing host.** Production's landing
host is `eduide` but its Gateway sections are `prod-*`; `e2e-test`'s are `e2e-*`.
Getting this wrong attaches routes to sections that do not exist, and nothing
fails until traffic does.

**`e2e-test` is not for people.** It follows `main` and the functional tests run
against it automatically. Point manual work at `staging` instead, or a red build
there stops meaning anything.

**A top-level `hosts:` key in a values file does nothing.** The umbrella chart
has one, but only as a YAML anchor feeding its own two subcharts, and anchors
resolve within a single file. An override file has to set
`theia-cloud.hosts.configuration` and `theia-certificates.hosts.configuration`
explicitly. Both are set in every environment; do not add a third copy at the
top level, it will be silently ignored.

## Checking a change

```bash
helm template eduide ./charts/theia-cloud-combined \
  -f environments/_base.yaml -f environments/test1/values.yaml
./scripts/test-deploy-logic.sh            # overrides, tags, listener collisions
./scripts/legacy-diff.sh                  # what the cutover changes on a live env
```

`legacy-diff.sh` is a report, not a gate. Hostnames, realms and client ids were
changed deliberately, so it is expected to differ - read it before cutting an
environment over rather than expecting it to be empty.

CI runs schema validation, checks every environment points at a real cluster,
checks no two environments on a cluster share a listener prefix, renders every
environment, and posts the legacy diff to the run summary.
