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

## Why not just Helm values files?

Every environment used to be a ~170-line `values.yaml`, and they were 90%
copies of each other. Adding an environment meant copying one and search and
replacing host names, which is how they drifted: production stopped offering the
C templates image, `test3` offered an app that had no AppDefinition, and every
environment pre-pulled four images that none of them used.

A manifest carries only what is genuinely different. Everything shared lives in
`_base.yaml`; everything derivable (host names, Gateway `parentRefs`, the
preload list) is computed. The five manifests together are **190 lines,
replacing 830**.

## Adding an environment

Create `environments/<name>/env.yaml`:

```yaml
apiVersion: eduide.dev/v1
kind: Environment
metadata:
  name: test4
  displayName: EduIDE Test 4
  tier: test
spec:
  cluster: aet-stud          # must match a file in clusters/
  namespace: test4
  platform:
    chartVersion: 1.0.0-rc0
    channel: main
  hosts:
    baseHost: theia-test.artemis.cit.tum.de
    landing: test4           # service/instance default to service.test4 / instance.test4
    wildcardPrefixes: ["*.webview."]
  gateway:
    mode: shared
    listenerPrefix: test4
  keycloak:
    realm: Test
    clientId: theia-test
  branding:
    appName: Artemis Online IDE (Test4)
    infoTitle: Welcome to EduIDE Cloud (Test4)
```

Then add the four Gateway listeners on the cluster, and create the GitHub
Environment holding its `KUBECONFIG`.

That is the whole file. Compare it with `docs/adding-environments.md`, which
describes the old process.

## Things that are not what they look like

**`gateway.listenerPrefix` is not the landing host.** Staging's landing host is
`theia-staging` but its Gateway sections are `staging-*`; production's are
`prod-*`, not `theia-*`. Getting this wrong attaches the routes to sections that
do not exist, so it is a separate field rather than derived.

**`spec.values` is an escape hatch, not a config section.** Anything that shows
up there for more than one environment belongs in `_base.yaml` or as a
first-class field. Today it holds four things: test1's raised `sessionsPerUser`
(load testing), test3's loading text, staging's floating image tag, and
production's replica count and disabled landing-page Sentry.

**`preloadApps` defaults to the standard set.** Production overrides it because
it deliberately does not ship the C templates image.

## Checking a change

```bash
./scripts/render-values.sh test1          # see the compiled values
./scripts/verify-migration.sh             # compare against the legacy values files
```

`verify-migration.sh` renders the umbrella chart from both the old values file
and the compiled manifest and diffs the result. It must report `IDENTICAL` for
every environment; that is the gate for cutting an environment over. It can be
deleted once `deployments/` is gone.

CI runs schema validation, checks that every environment points at a real
cluster, checks that no two environments on one cluster claim the same Gateway
listener prefix, compiles every manifest, and runs the equivalence check.
