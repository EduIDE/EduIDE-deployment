# GitHub Environments

Every workflow that touches a cluster runs inside a GitHub Environment. The
Environment holds the `KUBECONFIG` and the secrets for that target, and it is
what makes an approval gate possible.

There are **two kinds**, and they are not interchangeable.

| Kind | Named | Used by | Holds |
|---|---|---|---|
| Per environment | the installation's landing hostname, which is also its directory under `environments/` | `Deploy`, `Rollback` | `KUBECONFIG`, `THEIA_KEYCLOAK_COOKIE_SECRET` |
| Per cluster | `spec.bootstrapEnvironment` in `clusters/<name>.yaml`, by convention `cluster-<name>` | `Bootstrap cluster` | `KUBECONFIG`, `THEIA_WILDCARD_CERTIFICATE_CERT`, `THEIA_WILDCARD_CERTIFICATE_KEY` |

A deploy never installs anything cluster-scoped, and a bootstrap never installs
a tenant. So the wildcard certificate belongs on the **cluster** environment,
even though it used to live on the per-environment ones.

## The secrets

### `KUBECONFIG` - both kinds

The entire kubeconfig file, pasted in verbatim. Not base64, not a path. The
workflow writes it to a file with mode 600 and points `KUBECONFIG` at it.

It is stored in clear text as a GitHub secret by deliberate choice.

Two things matter more than the format:

- **It must reach the cluster the target claims.** Both workflows read
  `eduide-system/eduide-cluster-identity` back from the cluster and compare it
  with `spec.cluster`, so a kubeconfig for the wrong cluster fails the job
  instead of installing EduIDE somewhere unexpected. That check is the reason
  nobody transcribes an API server URL: every TUM cluster sits behind the same
  Rancher endpoint, so that URL is identical for all of them and comparing it
  would pass whichever cluster the kubeconfig happened to reach.
- **It should be scoped.** A deploy needs write access in one namespace plus
  read on the identity ConfigMap. A bootstrap genuinely needs cluster-admin: it
  installs CRDs, ClusterRoles and a ClusterIssuer.

Take care that the file does not carry more contexts than intended; the
workflows use whatever `current-context` it names.

### `THEIA_KEYCLOAK_COOKIE_SECRET` - per environment

The cookie encryption key for the oauth2-proxy sidecar in every session pod.

```bash
dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64 | tr -d -- '\n' | tr -- '+/' '-_'
```

Per environment, not shared. Rotating it logs everyone out of that
installation and nothing else.

### `THEIA_ADMIN_API_TOKEN` - currently repository-wide

The bearer token for the admin scaling API.

It is **a repository secret today, not an environment secret**, so every
environment deploys the same token and production shares it with every test
installation. Moving it to per-environment secrets is a one-line change to
nothing at all - `deploy.yml` reads `secrets.THEIA_ADMIN_API_TOKEN`, which
resolves from the environment first and falls back to the repository - so
setting it on an environment overrides it there with no workflow change.

### `THEIA_WILDCARD_CERTIFICATE_CERT` and `_KEY` - per cluster

The webview wildcard certificate and its **decrypted** private key, both as
plain PEM. The workflow base64-encodes them itself, so do not pre-encode.

ACME cannot issue a wildcard over HTTP-01, so this certificate is obtained from
Harica through RBG and renewed by hand. See
[tum-certificates.md](tum-certificates.md).

They live on the **cluster** environments (`cluster-tum-student`,
`cluster-tum-production`, `cluster-eduide`), which is where
`bootstrap-cluster.yml` reads them. A deploy never uses them.

### `E2E_KEYCLOAK_USER` and `E2E_KEYCLOAK_PWD` - the `e2e.` environment only

Credentials for the account the functional tests log in as. Only
`deploy-e2e.yml` reads them.

## Creating one

**In the UI:** Settings -> Environments -> New environment. The name must match
the directory exactly - `environments/test1.eduide.student.k8s.aet.cit.tum.de/` needs an environment of the same
name. Names are the landing hostname, so they are long; that is deliberate,
since it removes any mapping that could drift.

**With the CLI:**

```bash
REPO=EduIDE/EduIDE-deployment
gh api -X PUT "repos/$REPO/environments/test1"

gh secret set KUBECONFIG --repo "$REPO" --env test1 < ~/.kube/test1.yaml
gh secret set THEIA_KEYCLOAK_COOKIE_SECRET --repo "$REPO" --env test1 \
  --body "$(dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64 | tr -d -- '\n' | tr -- '+/' '-_')"
```

For a cluster environment:

```bash
gh api -X PUT "repos/$REPO/environments/cluster-tum-student"
gh secret set KUBECONFIG --repo "$REPO" --env cluster-tum-student < ~/.kube/stud-cp.yaml
gh secret set THEIA_WILDCARD_CERTIFICATE_CERT --repo "$REPO" --env cluster-tum-student < wildcard.crt
gh secret set THEIA_WILDCARD_CERTIFICATE_KEY  --repo "$REPO" --env cluster-tum-student < wildcard.key
```

Check what an environment holds - names only, values are never readable:

```bash
gh api "repos/$REPO/environments/test1/secrets" --jq '.secrets[].name'
```

## Protection rules

Add **required reviewers** to anything `tier: production` or `staging`, and to
every `cluster-*` environment. The job names the environment, so GitHub holds
the run until someone approves and records who approved it on the run.

```bash
gh api -X PUT "repos/$REPO/environments/tum-production" \
  -F 'reviewers[][type]=Team' -F 'reviewers[][id]=<team-id>'
```

The `e2e.` environment deliberately has none: it deploys from `main`
automatically and a gate there would just leave runs waiting. Test environments generally do not
need approvers either - the point of a test environment is that deploying to it
is cheap.

## What is configured today

`THEIA_ADMIN_API_TOKEN` is a repository secret, so every environment inherits it.

| Environment | `KUBECONFIG` | Cookie secret | Wildcard cert | Reviewers |
|---|---|---|---|---|
| `cluster-tum-student` | yes | n/a | yes | yes |
| `cluster-tum-production` | yes | n/a | yes | yes |
| `cluster-eduide` | **missing** | n/a | yes | yes |
| `test1.eduide.student.k8s.aet.cit.tum.de` and the other two `test` ones | yes | yes | n/a | yes |
| `staging.eduide.student.k8s.aet.cit.tum.de` | yes | yes | n/a | yes |
| `e2e.eduide.student.k8s.aet.cit.tum.de` | yes | yes | n/a | none, by design |
| `eduide.artemis.cit.tum.de` | yes | yes | n/a | yes |
| `bonn.…`, `mannheim.…` | **missing** | **missing** | n/a | yes |

Outstanding: `cluster-eduide` has no `KUBECONFIG`, so the cluster hosting Bonn
and Mannheim cannot be bootstrapped, and the `e2e.` environment still needs
`E2E_KEYCLOAK_USER` and `E2E_KEYCLOAK_PWD`.

`theia-prod` and `theia-staging` are pre-2.0.0 environments. No workflow
references either name any more, and both still hold live secrets. They should
be deleted once nothing is left running from them.

## Order of operations for a new environment

1. `environments/<name>/env.yaml` and `values.yaml`. See
   [environments.md](environments.md).
2. Create the GitHub Environment with the same name, add `KUBECONFIG` and
   `THEIA_KEYCLOAK_COOKIE_SECRET`, and add reviewers if it is staging or
   production.
3. Re-run `Bootstrap cluster` for its cluster. The new environment's four
   Gateway listeners, its certificate names and its monitored namespace are all
   derived from the files in step 1, so there is no second file to edit - but
   they do not exist until bootstrap runs again.
4. DNS, certificates and the Keycloak client. See
   [cluster-setup.md](cluster-setup.md) and [keycloak-setup.md](keycloak-setup.md).
5. `Deploy (dispatch)` with `dry_run: true`, read the diff, then run it for real.
