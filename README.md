# EduIDE deployment

Where the EduIDE installations are described. **No application code and no
chart templates live here** - the charts are in
[EduIDE-Helm](https://github.com/EduIDE/EduIDE-Helm) and published to
`ghcr.io/eduide/charts`.

```
clusters/<name>.yaml             a cluster: storage, gateway class, runner
environments/<name>/env.yaml     how an installation is deployed
environments/<name>/values.yaml  how the chart is configured
environments/_base.yaml          chart settings identical on the java stack (2.x)
environments/_base-go.yaml       chart settings identical on the go stack (3.x)
schemas/                         JSON schemas the manifests are validated against
renovate.json                    who may bump the chart version, and when
```

An environment is one namespace on one cluster.

| Cluster | Environments |
|---|---|
| `tum-student` | `test1.eduide.student.k8s.aet.cit.tum.de`<br>`test2.…`<br>`test3.…`<br>`e2e.…`<br>`staging.…` |
| `tum-production` | `eduide.artemis.cit.tum.de` |
| `eduide` | `bonn.eduide.aet.cit.tum.de`<br>`mannheim.eduide.aet.cit.tum.de` |

**Two stacks run side by side**, chosen per environment by
`spec.platform.stack` in `env.yaml` (`java` when omitted):

| Stack | Chart | Environments |
|---|---|---|
| `java` | `eduide` 2.x (Theia Cloud), values on `_base.yaml` | `mannheim` |
| `go` | `eduide` 3.x (EduIDE 3.0, Go control plane), values on `_base-go.yaml` | `bonn`, `test1`, `test2`, `test3`, `e2e`, `staging`, `eduide.artemis.cit.tum.de` |

`eduide.artemis.cit.tum.de` moved to `go` on 2026-11-21 by
[its rollout plan](docs/rollout-3.0-tum-production.md) (option B, in place).

**An environment is named after the hostname it serves.** The directory under
`environments/`, the GitHub Environment and the landing host are the same
string, so there is nothing to map and nothing to keep in sync.

The `eduide` cluster is `parma.aet.cit.tum.de` (131.159.88.106), a single
node k3s serving Bonn and Mannheim since 2026-08-28. It has **no load
balancer** - the Envoy data plane binds the node's own `:80` and `:443` with
`hostPort`. `clusters/eduide.yaml` records why, and why the obvious
alternative does not work.

Namespaces stay short - `eduide-test1`, `eduide-tum-production` - because a
Kubernetes namespace cannot contain dots. `spec.namespace` in each `env.yaml`
states it.

## Installing

New cluster? Start at [Preparing a cluster](docs/cluster-setup.md) - it covers
what the workflows do and what has to be set up by hand first.

Two charts, always at the same version. The cluster one first. (On the `go`
stack the cluster half is only the CRD chart `eduide-control-plane-crds`,
which `Bootstrap cluster` installs as release `eduide-crds`; a `go`
environment renders its own Gateway.)

```bash
# once per cluster - CRDs, conversion webhook, ClusterRoles, issuers,
# the shared Gateway, PodMonitors and dashboards
helm install eduide-cluster oci://ghcr.io/eduide/charts/eduide-cluster \
  --version <chart version> -n eduide-system --create-namespace -f cluster-values.yaml

# once per environment
helm install eduide oci://ghcr.io/eduide/charts/eduide \
  --version <chart version> -n eduide-test1 \
  -f environments/_base.yaml -f environments/test1/values.yaml
```

In practice neither is run by hand. `Bootstrap cluster` does the first and
derives its Gateway listeners and monitored namespaces from the environments
that claim the cluster, so adding an environment never means editing a second
file. `Deploy` does the second.

## Deploying

| I want to | Do this |
|---|---|
| Put a PR's images on a test environment | Actions → **Deploy environment** with `ide_tag`, `control_plane_tag` or `landing_page_tag` set to `pr-<number>`. A `/deploy <environment>` comment on the PR needs a sender workflow in the component repo (see `deploy-comment.yml`); none has one yet |
| Deploy any environment by hand | Actions → **Deploy environment** |
| Move staging | Actions → **Deploy staging** |
| Move production | Tick the production bump on Renovate's Dependency Dashboard, or bump `chartVersion` in `environments/eduide.artemis.cit.tum.de/env.yaml` by hand, open a PR, merge it, then Actions → **Deploy environment**. Merging alone deploys nothing |
| Undo a bad deploy | Actions → **Rollback** |
| Check that an environment works | [Functional test plan](docs/testing/README.md), or the `functional-check` skill |
| Bring up a new cluster | Actions → **Bootstrap cluster** |

`e2e.eduide.student.k8s.aet.cit.tum.de` deploys from `main` automatically, and
every deploy of it, however it was started, ends with the functional tests from
[theia-scale-tests](https://github.com/EduIDE/theia-scale-tests) (the
`e2e-tests` job of `deploy.yml`). Do not point manual work at it - use the
`staging.` one. To test another environment, see
[docs/environments.md](docs/environments.md#testing-an-environment).

Every deploy asserts which cluster it reached before touching anything, shows a
`helm diff` before applying, runs `--wait --atomic`, and prints a summary read
back from the cluster rather than echoed from its inputs.

## What an environment does and does not configure

An environment file carries **hosts, gateway routing, Keycloak and branding**.
That is all. Everything else is derived or shared:

| | Where it comes from |
|---|---|
| Image tags | `versions.ide` / `versions.cloud` / `versions.landingPage` in the chart |
| App definitions | `appDefinitions.catalog` in the chart; the environment picks with `appDefinitions.enabled` |
| Images to preload | derived from the enabled apps |
| The landing page's app list | derived from the enabled apps |
| Storage class, node pool | `clusters/<name>.yaml` |
| Gateway listeners | derived from each environment's `parentRefs` |
| Monitored namespaces | derived from the environments on the cluster |
| Everything identical everywhere | `environments/_base.yaml` |

Adding a language is one entry in the chart, not three edits across two
repositories.

## Secrets

In GitHub Environments, never in a file here. There are two kinds of
environment and they hold different secrets:

| | Named | Holds |
|---|---|---|
| Per environment, for `Deploy` | the directory under `environments/` | `KUBECONFIG`; `THEIA_KEYCLOAK_COOKIE_SECRET` (java) or `OIDC_CLIENT_SECRET` (go) |
| Per cluster, for `Bootstrap cluster` | `spec.bootstrapEnvironment`, by convention `cluster-<name>` | `KUBECONFIG`, `THEIA_WILDCARD_CERTIFICATE_CERT`, `THEIA_WILDCARD_CERTIFICATE_KEY` |

`OIDC_CLIENT_SECRET` is the client secret of the confidential gateway client in
Keycloak. The deploy writes it into the Secret `eduide-oidc` (key
`client-secret`) in the namespace before `helm` runs.

`THEIA_ADMIN_API_TOKEN` (java only) is a repository secret today, so every environment
shares one token. The token alone does not enable the admin scaling endpoints:
from Cloud 3.0.x (chart 3.0.0) they also need `service.adminApiEnabled: true`,
which is off by default.

Anything `tier: production` or `staging` should have required reviewers set, so
GitHub holds the run until someone approves and records the approval.

See [GitHub Environments](docs/github-environments.md) for what each secret is,
how to produce it, and what each environment holds today.

## Checking a change

```bash
./scripts/test-deploy-logic.sh            # overrides, tags, listeners, storage, cache

helm template eduide oci://ghcr.io/eduide/charts/eduide --version <chart version> \
  -f environments/_base.yaml -f environments/test1/values.yaml
```

`go` environments render in the same script once their chart is published
(the 3.0.0 release candidates are not yet; the script then prints SKIP). To
render them now, build the chart's dependencies in a local EduIDE-Helm checkout
and point `EDUIDE_CHART_GO` at it.

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
| [Preparing a cluster](docs/cluster-setup.md) | what to install and configure before bootstrapping, manual vs automated |
| [GitHub Environments](docs/github-environments.md) | every secret, how to produce it, protection rules |
| [Environments](docs/environments.md) | the model, adding one, what is derived |
| [Keycloak](docs/keycloak-setup.md) | clients, scopes, redirect URIs |
| [Envoy Gateway](docs/envoy-gateway-setup.md) | the Gateway API layer |
| [Rollout of 3.0 on tum-production](docs/rollout-3.0-tum-production.md) | prerequisites, parallel run, rollback, checklist |
| [Monitoring](docs/monitoring-setup.md) | PodMonitors and dashboards |
| [TUM certificates](docs/tum-certificates.md) | the wildcard certificate |
| [AGENTS.md](AGENTS.md) | conventions, and the traps worth knowing |

## Related

- [EduIDE-Helm](https://github.com/EduIDE/EduIDE-Helm) - the charts
- [EduIDE](https://github.com/EduIDE/EduIDE) - the IDE and its images
- [EduIDE-Cloud](https://github.com/EduIDE/EduIDE-Cloud) - operator and REST service
- [EduIDE-Landing-Page](https://github.com/EduIDE/EduIDE-Landing-Page)
- [theia-scale-tests](https://github.com/EduIDE/theia-scale-tests) - the test suite
