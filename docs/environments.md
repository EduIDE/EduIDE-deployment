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
helm upgrade --install eduide oci://ghcr.io/eduide/charts/eduide --version 2.0.0 \
  -f cluster-defaults.yaml \                     # generated from clusters/<name>.yaml
  -f environments/_base.yaml \                   # identical everywhere
  -f environments/<name>/values.yaml \           # this installation
  -f secrets.yaml                                # from the GitHub Environment
```

Since 2.0.0 that is **one chart**, not an umbrella over five subcharts, so
values files are keyed at the top level: `hosts:`, `keycloak:`, `operator:`,
not `theia-cloud.hosts:`.

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
| `tum-production` | `eduide.artemis.aet.cit.tum.de` — see below |
| `bonn` | `bonn.eduide.aet.cit.tum.de` |
| `mannheim` | `mannheim.eduide.aet.cit.tum.de` |

**TUM production is deliberately not under `eduide.aet.cit.tum.de`.** It runs
behind a different load balancer, so it keeps `eduide.artemis.aet.cit.tum.de`.
Bonn and Mannheim do sit under the shared base. This is recorded in the values
file too, because it reads like a typo and is not one.

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
| mannheim | `keycloak.aet.cit.tum.de` | `external_register` | `eduide` |
| bonn | **not configured** | — | — |

**Bonn has no authentication.** Its realm has not been decided, so the block is
commented out and it sets `keycloak.allowUnauthenticated: true`. Do not expose
that installation until the block is filled in and the flag removed.

That flag exists because the oauth2-proxy ConfigMaps are rendered regardless of
`keycloak.enable` — the operator mounts them into every session pod by literal
name, so they cannot be gated. Left at the chart's defaults they carry
`https://keycloak.url/auth/realms/TheiaCloud`, a host that does not exist, so
sessions fail at the proxy instead of running unauthenticated. The chart now
refuses to render on the placeholder values unless the flag says otherwise.

A wrong `authUrl`, `realm` or `clientId` still fails at login rather than at
deploy, so confirm them with the university before the first deploy.

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
  namespace: eduide-bonn     # every namespace carries the eduide- prefix
  platform:
    chartVersion: 2.0.0
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
      - { name: theia-shared-gateway, namespace: eduide-system, sectionName: bonn-landing }
      - { name: theia-shared-gateway, namespace: eduide-system, sectionName: bonn-service }
      - { name: theia-shared-gateway, namespace: eduide-system, sectionName: bonn-instances }
      - { name: theia-shared-gateway, namespace: eduide-system, sectionName: bonn-webview }
```

The prefix (`bonn-`) must be unique on the cluster; CI rejects a collision.

### 3. The GitHub Environment

Create one named exactly as the manifest, under **Settings → Environments**.

| Secret | What |
|---|---|
| `KUBECONFIG` | the whole kubeconfig file, pasted in |
| `THEIA_KEYCLOAK_COOKIE_SECRET` | `dd if=/dev/urandom bs=32 count=1 \| base64 \| tr -d -- '\n' \| tr -- '+/' '-_'` |

`THEIA_ADMIN_API_TOKEN` is a **repository** secret, not an environment one, so
every environment inherits it and there is nothing to set per environment.

A cluster's bootstrap environment (`cluster-<name>`) holds a different set:
`KUBECONFIG` for that cluster, plus `THEIA_WILDCARD_CERTIFICATE_CERT` and
`THEIA_WILDCARD_CERTIFICATE_KEY` for the webview wildcard, which cert-manager
cannot issue over HTTP-01.

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

## Versions

One number per source repository, and one chart version over the lot:

| Value | Repository | Default |
|---|---|---|
| `versions.ide` | EduIDE (the IDE images) | empty → the chart's `appVersion` |
| `versions.cloud` | EduIDE-Cloud (operator, service) | `1.2.0` |
| `versions.landingPage` | EduIDE-Landing-Page | `1.2.0` |

`helm install --version 2.0.0` with no overrides therefore pins every image to
a tag that release published. Nothing floats, and no environment repeats an
image string.

A deploy override names one repository, never all of them: a pull request only
builds the images of the repo it came from, so a blanket tag would put the rest
of the namespace into `ImagePullBackOff`.

```
Actions -> Deploy -> image_overrides: {"controlPlane": "pr-451"}
```

## Applications and preloading

`appDefinitions.apps` in the chart is the single source of truth for three
things: the AppDefinition custom resources, the app list the landing page
offers, and the images preloaded onto every node. **No environment lists any of
them.** Adding a language is one entry in the chart.

They used to be three hand-maintained lists across two repositories, the
preload one addressed by array index. Production offered `c-templates` while
preloading everything except `c-templates`, so students picking it waited for a
cold multi-gigabyte pull. `test-app-consistency.sh` in EduIDE-Helm asserts the
three agree.

## Monitoring

On by default. An environment opts out with:

```yaml
monitoring:
  enabled: false
```

The PodMonitor objects are in `eduide-cluster`, not the tenant chart: they have
to be created in Rancher's own namespace to be discovered, and one per tenant
writing into a shared namespace would collide on names. So the cluster chart
owns them and this flag decides whether the environment's namespace appears in
the list they watch — `Bootstrap cluster` reads it when deriving that list. A
cluster where everything has opted out gets monitoring switched off rather than
PodMonitors watching nothing.

Not to be confused with `monitor.enable`, which is the operator's own session
activity tracker and unrelated.

## The dependency cache

`eduide-shared-cache` deploys a Gradle build cache, a Redis and a reposilite
Maven proxy with a 20Gi PVC. It is **off in all three production
installations** and on in test and staging.

```yaml
eduide-shared-cache:
  enabled: false
```

`test-deploy-logic.sh` asserts this for every `tier: production` environment.

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
  tls:                             # the Secret each listener role terminates with
    landing: shared-theia-cert
    service: shared-theia-cert
    instances: shared-theia-cert
    webview: static-theia-cert     # always its own - see below
    acmeHttp: false                # true adds :80 listeners for HTTP-01
  sharedGateway: { namespace: eduide-system, name: theia-shared-gateway }
  runner: ubuntu-latest            # deploying needs to reach the API server
  bootstrapEnvironment: cluster-eduide
```

`tls` names the Kubernetes Secret each listener role terminates with. It is per
cluster because the clusters issue certificates differently: `tum-student`
terminates everything with one pre-issued wildcard, `tum-production` has
cert-manager issue one certificate per role and therefore also needs
`acmeHttp: true`, which adds a plain `:80` listener per host for HTTP-01
challenges. The webview secret is always separate — those hosts are two labels
below the instance host, so no certificate covering the others covers them.

`Bootstrap cluster` also derives the certificate's `dnsNames` from the same
pass, so an environment gets its certificate names when it gets its listeners.
Only the landing, service and instance hosts go on it: cert-manager solves
HTTP-01 by serving a token on port 80 per name, so a name with no listener stays
pending and blocks the certificate for every other name on it. The webview host
is a wildcard, which HTTP-01 cannot do at all, and keeps its own long-lived
certificate.

Nothing detects a certificate that omits a host. The Gateway reports the
listener healthy either way - Gateway API never compares the certificate's names
against the listener's hostname - so the first symptom is a browser warning, and
the second is the landing page silently failing to reach its own REST service.

A listener with no secret renders an empty `certificateRefs` entry. Nothing
rejects it: the Gateway is accepted and simply never programs TLS for that
hostname, so the first symptom is a browser connection failure. The chart fails
the render instead, and `test-deploy-logic.sh` checks the policy is complete
before it gets that far.

`storageClassName` is rendered into a values file the deploy `-f`'s before
`_base.yaml`, and it covers **both** things that claim storage: the operator's
session PVCs and the shared cache's vendored reposilite chart, which has its own
key and its own `csi-rbd-sc` default.

An environment must not set it. It is a property of the cluster - `eduide` runs
on local disks, the TUM clusters on Ceph.

Worth knowing about the test cluster: **both `csi-rbd-sc` and `longhorn` exist
there and both are marked default**, so a PVC that omits the class gets an
arbitrary one. test3 ran on `longhorn` and the others on `csi-rbd-sc`, for no
reason anyone recorded; they are standardised on `csi-rbd-sc` now. Two default
StorageClasses is a cluster misconfiguration worth raising with whoever owns the
cluster - nothing in this repo can fix it.

`test-deploy-logic.sh` renders every environment against a sentinel and fails if
any storage key escapes the cluster default, so a new subchart with its own key
cannot slip through either.

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

## Checking a change

```bash
helm template eduide oci://ghcr.io/eduide/charts/eduide --version 2.0.0 \
  -f environments/_base.yaml -f environments/test1/values.yaml
./scripts/test-deploy-logic.sh            # overrides, tags, listeners, storage, cache
```

To test against a chart that is not published yet, point at a local checkout:

```bash
EDUIDE_CHART=../EduIDE-Helm/charts/eduide ./scripts/test-deploy-logic.sh
```

CI runs schema validation, checks every environment points at a real cluster,
checks no two environments on a cluster share a listener prefix, and renders
every environment.
