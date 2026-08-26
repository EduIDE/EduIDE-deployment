# Environments

An environment is one EduIDE installation: a namespace on a cluster, with its
own hostnames, branding and Keycloak client. Each is described by a single file.

```
clusters/<name>.yaml            where things run
environments/<name>/env.yaml    what runs there
environments/_base.yaml         settings identical in every environment
schemas/                        JSON schemas both are validated against
scripts/render-values.sh        compiles a manifest into Helm values
```

## The three clusters

| Cluster | Environments | Notes |
|---|---|---|
| `tum-student` | `test1`, `test2`, `test3`, `e2e-test`, `staging` | everything non-production |
| `tum-production` | `tum-production` | TUM's own installation |
| `eduide` | `bonn`, `mannheim` | other universities. **Not provisioned yet.** |

`bonn` and `mannheim` exist as reviewable configuration before the cluster does.
Deploying one stops at the cluster identity check until `clusters/eduide.yaml`
has an `apiServerUrl` and the GitHub Environment holds a `KUBECONFIG`.

## Why not just Helm values files?

Every environment used to be a ~170-line `values.yaml`, and they were 90%
copies of each other. Adding one meant copying another and search-replacing
hostnames, which is how they drifted: production stopped offering the C
templates image, `test3` offered an app with no AppDefinition, and every
environment pre-pulled four images none of them used.

A manifest carries only what is genuinely different. Everything shared lives in
`_base.yaml`; everything derivable (hostnames, Gateway `parentRefs`, the preload
list) is computed.

## Adding an environment

### 1. The manifest

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
    channel: release
  hosts:
    baseHost: eduide.uni-bonn.de
    landing: eduide          # service/instance default to service.<landing>, instance.<landing>
    wildcardPrefixes: ["*.webview."]
  gateway:
    mode: shared
    listenerPrefix: bonn
  keycloak:
    realm: EduIDE
    clientId: eduide-bonn
  branding:
    appName: EduIDE Bonn
    infoTitle: Welcome to EduIDE (Bonn)
  imageTag: "1.0.0-rc0"

  # Anything genuinely specific to this installation. Keep it small: whatever
  # appears here for more than one environment belongs in _base.yaml or as a
  # first-class field.
  values:
    theia-cloud:
      operator:
        sessionsPerUser: 10
```

### 2. The GitHub Environment

Create one named exactly as the manifest, under
**Settings → Environments**.

**Secrets:**

| Secret | What |
|---|---|
| `KUBECONFIG` | the whole kubeconfig file, pasted in |
| `THEIA_KEYCLOAK_COOKIE_SECRET` | `dd if=/dev/urandom bs=32 count=1 \| base64 \| tr -d -- '\n' \| tr -- '+/' '-_'` |
| `THEIA_ADMIN_API_TOKEN` | bearer token for the admin scaling API |

**Protection:** add required reviewers for anything `tier: production` or
`staging`. The deploy job names the environment, so GitHub holds the run until
someone approves it, and the approval is recorded on the run.

Test environments generally do not need approvers — the point of a test
environment is that deploying to it is cheap.

### 3. Bootstrap the cluster

```
Actions -> Bootstrap cluster -> cluster: eduide, dry_run: true
```

The shared Gateway's listeners are derived from every environment that claims
the cluster, so a new environment needs no second file edited. Run it with
`dry_run: false` once the diff looks right.

### 4. Keycloak

Redirect URIs for the new hostnames, and a client matching `keycloak.clientId`.
See `docs/keycloak-setup.md`.

## `apiServerUrl`, and why it is not redundant

It is the `server:` field out of the cluster's kubeconfig:

```bash
./scripts/cluster-url.sh ~/.kube/tum-student.yaml
```

It is not a credential and not extra information — it is one line copied out of
the `KUBECONFIG` secret into git.

The point is that the two must **agree**. The kubeconfig lives in a GitHub
Environment secret that nobody reviews; the manifest lives in git where a pull
request shows it. If the wrong kubeconfig is ever pasted into an environment's
secret, the deploy compares it against the reviewed file and stops instead of
quietly deploying to the wrong cluster. Reading the cluster's identity out of
the same secret you are trying to check would prove nothing.

Leaving it empty is allowed. The check then degrades to a **warning that prints
what the kubeconfig actually points at** — which is also how you discover the
value without having the file locally: run a deploy with `dry_run: true` and
read the log.

## Things that are not what they look like

**`gateway.listenerPrefix` is not the landing host.** Staging's landing host is
`theia-staging` but its Gateway sections are `staging-*`; production's are
`prod-*`. Getting this wrong attaches routes to sections that do not exist, and
nothing fails until traffic does. CI rejects two environments on one cluster
sharing a prefix.

**`e2e-test` is not for people.** It follows `main` and the functional tests run
against it automatically. Point manual work somewhere else, or a red build stops
meaning anything.

**`spec.values` is an escape hatch, not a config section.**

## Checking a change

```bash
./scripts/render-values.sh test1          # what it compiles to
./scripts/test-deploy-logic.sh            # overrides, tags, listener collisions
./scripts/verify-migration.sh             # compiled == legacy values
```

CI runs schema validation, checks every environment points at a real cluster,
checks no two environments on a cluster share a listener prefix, compiles every
manifest, and runs the equivalence check.
