# EduIDE deployment

Where the EduIDE installations are described. **No application code and no
chart templates live here** — the charts are in
[EduIDE-Helm](https://github.com/EduIDE/EduIDE-Helm) and published to
`ghcr.io/eduide/charts`.

```
clusters/<name>.yaml             a cluster: storage, gateway class, runner
environments/<name>/env.yaml     how an installation is deployed
environments/<name>/values.yaml  how the chart is configured
environments/_base.yaml          chart settings identical everywhere
schemas/                         JSON schemas the manifests are validated against
```

An environment is one namespace on one cluster.

| Cluster | Environments |
|---|---|
| `tum-student` | `test1`, `test2`, `test3`, `e2e-test`, `staging` |
| `tum-production` | `tum-production` |
| `eduide` | `bonn`, `mannheim` — **cluster not provisioned yet** |

Every namespace is `eduide-<environment>`.

## Installing

Two charts, always at the same version. The cluster one first.

```bash
# once per cluster — CRDs, conversion webhook, ClusterRoles, issuers,
# the shared Gateway, PodMonitors and dashboards
helm install eduide-cluster oci://ghcr.io/eduide/charts/eduide-cluster \
  --version 2.0.0 -n eduide-system --create-namespace -f cluster-values.yaml

# once per environment
helm install eduide oci://ghcr.io/eduide/charts/eduide \
  --version 2.0.0 -n eduide-test1 \
  -f environments/_base.yaml -f environments/test1/values.yaml
```

In practice neither is run by hand. `Bootstrap cluster` does the first and
derives its Gateway listeners and monitored namespaces from the environments
that claim the cluster, so adding an environment never means editing a second
file. `Deploy` does the second.

## Deploying

| I want to | Do this |
|---|---|
| Put a PR's images on a test environment | Comment `/deploy test2` on the PR |
| Deploy any environment by hand | Actions → **Deploy (dispatch)** |
| Move staging | Actions → **Deploy staging** |
| Move production | Bump `chartVersion` in `environments/tum-production/env.yaml`, open a PR |
| Undo a bad deploy | Actions → **Rollback** |
| Bring up a new cluster | Actions → **Bootstrap cluster** |

`e2e-test` deploys from `main` automatically and the functional tests run
against it. Do not point manual work at it — use `staging`.

Every deploy asserts which cluster it reached before touching anything, shows a
`helm diff` before applying, runs `--wait --atomic`, and prints a summary read
back from the cluster rather than echoed from its inputs.

## What an environment does and does not configure

An environment file carries **hosts, gateway routing, Keycloak and branding**.
That is all. Everything else is derived or shared:

| | Where it comes from |
|---|---|
| Image tags | `versions.ide` / `versions.cloud` / `versions.landingPage` in the chart |
| App definitions | `appDefinitions.apps` in the chart |
| Images to preload | derived from `appDefinitions.apps` |
| The landing page's app list | derived from `appDefinitions.apps` |
| Storage class | `clusters/<name>.yaml` |
| Gateway listeners | derived from each environment's `parentRefs` |
| Monitored namespaces | derived from the environments on the cluster |
| Everything identical everywhere | `environments/_base.yaml` |

Adding a language is one entry in the chart, not three edits across two
repositories.

## Secrets

Per environment, in its GitHub Environment. Never in a file here.

| Environment | Secret | What |
|---|---|---|
| each installation | `KUBECONFIG` | the whole kubeconfig, pasted in |
| each installation | `THEIA_KEYCLOAK_COOKIE_SECRET` | `dd if=/dev/urandom bs=32 count=1 \| base64 \| tr -d -- '\n' \| tr -- '+/' '-_'` |
| `cluster-<name>` | `KUBECONFIG` | that cluster's kubeconfig |
| `cluster-<name>` | `THEIA_WILDCARD_CERTIFICATE_CERT` / `_KEY` | the webview wildcard, which HTTP-01 cannot issue |

`THEIA_ADMIN_API_TOKEN` is a **repository** secret and is inherited by every
environment, so there is nothing to set per environment.

Anything `tier: production` or `staging` should have required reviewers set, so
GitHub holds the run until someone approves and records the approval.

## Checking a change

```bash
./scripts/test-deploy-logic.sh            # overrides, tags, listeners, storage, cache

helm template eduide oci://ghcr.io/eduide/charts/eduide --version 2.0.0 \
  -f environments/_base.yaml -f environments/test1/values.yaml
```

To test against a chart that is not published yet:

```bash
EDUIDE_CHART=../EduIDE-Helm/charts/eduide ./scripts/test-deploy-logic.sh
```

CI validates both schemas, checks every environment points at a real cluster,
rejects two environments on one cluster sharing a Gateway listener prefix, and
renders every environment.

## Documentation

| | |
|---|---|
| [Environments](docs/environments.md) | the model, adding one, what is derived |
| [Keycloak](docs/keycloak-setup.md) | clients, scopes, redirect URIs |
| [Envoy Gateway](docs/envoy-gateway-setup.md) | the Gateway API layer |
| [Monitoring](docs/monitoring-setup.md) | PodMonitors and dashboards |
| [TUM certificates](docs/tum-certificates.md) | the wildcard certificate |
| [AGENTS.md](AGENTS.md) | conventions, and the traps worth knowing |

## Related

- [EduIDE-Helm](https://github.com/EduIDE/EduIDE-Helm) — the charts
- [EduIDE](https://github.com/EduIDE/EduIDE) — the IDE and its images
- [EduIDE-Cloud](https://github.com/EduIDE/EduIDE-Cloud) — operator and REST service
- [EduIDE-Landing-Page](https://github.com/EduIDE/EduIDE-Landing-Page)
- [theia-scale-tests](https://github.com/EduIDE/theia-scale-tests) — the test suite
