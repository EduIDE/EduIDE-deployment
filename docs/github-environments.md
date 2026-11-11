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
- **It should be scoped.** A deploy needs write access in one namespace, read
  on the identity ConfigMap, and a few cluster-scoped rights: the tenant chart
  renders one ClusterRole and its binding for the operator, and the workflow
  reads nodes and CRDs. A bootstrap genuinely needs cluster-admin: it installs
  CRDs, ClusterRoles and a ClusterIssuer. See
  [Creating the kubeconfigs](#creating-the-kubeconfigs).

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

### `E2E_KEYCLOAK_USER` and `E2E_KEYCLOAK_PWD` - `e2e.eduide.student.k8s.aet.cit.tum.de` only

Credentials for the account the functional tests log in as. Only
`deploy-e2e.yml` reads them.

## Creating the kubeconfigs

Both are kubeconfigs for a Kubernetes ServiceAccount with a long-lived token,
pointed straight at the cluster's API server. A personal kubeconfig, such as one
downloaded from Rancher, is the wrong thing to store: it carries your identity,
often several contexts, and dies with your account.

**Check reachability first.** The workflows run on `spec.runner` from
`clusters/<name>.yaml`, by default a GitHub-hosted `ubuntu-latest`. A token is
only useful if that runner reaches the API server. A ServiceAccount token does
not work through the Rancher proxy URL (`https://<rancher>/k8s/clusters/<id>`),
only against the cluster's own endpoint.

Run the commands in `bash`, not fish (heredocs), with a cluster-admin context
for the target cluster. The example is `tum-production` on AET.

```bash
CTX=aet-cp                                        # your admin context
SERVER=https://k8s-aet-cp.aet.cit.tum.de:6443     # the cluster's API server
REPO=EduIDE/EduIDE-deployment
```

### Bootstrap: cluster-admin, per cluster

```bash
kubectl --context "$CTX" create namespace eduide-system --dry-run=client -o yaml \
  | kubectl --context "$CTX" apply -f -
kubectl --context "$CTX" apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: eduide-bootstrap
  namespace: eduide-system
---
apiVersion: v1
kind: Secret
metadata:
  name: eduide-bootstrap-token
  namespace: eduide-system
  annotations:
    kubernetes.io/service-account.name: eduide-bootstrap
type: kubernetes.io/service-account-token
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: eduide-bootstrap
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: eduide-bootstrap
    namespace: eduide-system
EOF
```

### Deploy: one namespace, per environment

Exactly what the deploy and rollback workflows do and nothing more, verified on
a throwaway cluster with helm v3.16.3 and chart 2.8.0: install, `helm diff`,
upgrade, `--wait --atomic`, rollback, uninstall, the live summary and
`rollout restart`. No `pods/exec`, no PVCs or Jobs, nothing in any other
namespace except reading the identity ConfigMap.

Three rules look broader than they are:

- **Pods, workspaces, HTTPRoutes.** The chart creates Roles for the operator
  and the garbage collector, and Kubernetes only lets a ServiceAccount grant
  rights it holds itself. Remove `deletecollection` on pods and the install
  fails on `operator-sidecar-pod-restart`.
- **`bind` on two ClusterRoles.** The chart's RoleBindings reference
  `operator-api-access` and `service-api-access` from bootstrap. `bind` lets
  the deployer reference them in its own namespace without holding them.
- **`create` on ClusterRoles and ClusterRoleBindings.** The chart renders one
  of each for the operator, and Kubernetes cannot limit `create` to a name.
  The same escalation check applies: binding `cluster-admin`, or creating a
  ClusterRole with rights the deployer lacks, is refused (tested).

The namespace must exist beforehand: `create namespaces` is cluster-wide, so
the deployer does not get it. Bootstrap creates a missing one and leaves an
existing one untouched, and the deploy workflow does the same.

`clean_install` additionally deletes Sessions, StatefulSets and PVCs. It is
refused for production, so this ServiceAccount cannot run it; a test
environment that needs it uses a broader kubeconfig.

**Bootstrap creates it.** Set `spec.deployers: true` in `clusters/<name>.yaml`
and run `Bootstrap cluster` with `eduide-cluster` 2.9.0 or later. It renders
the ServiceAccount, its token Secret and the rules above for every
environment on the cluster. The rules live in the chart, next to the templates
whose objects they deploy, and EduIDE-Helm's `test-deployers.sh` fails when the
`eduide` chart renders something the deployer may not touch. Then build the
kubeconfig and store it without writing it to a file:

```bash
ENV=eduide.artemis.cit.tum.de
scripts/deployer-kubeconfig.sh "$ENV" "$CTX" \
  | gh secret set KUBECONFIG --repo "$REPO" --env "$ENV"
```

**Taking over objects created by hand.** `tum-production` got its deployer from
an earlier version of this page, before the chart had one. Helm refuses to
install over objects it does not own, so label them once before the first
bootstrap with 2.9.0:

```bash
NS=eduide-tum-production REL=eduide-cluster RELNS=eduide-system
adopt() {
  kubectl --context "$CTX" label "$@" app.kubernetes.io/managed-by=Helm --overwrite
  kubectl --context "$CTX" annotate "$@" meta.helm.sh/release-name="$REL" meta.helm.sh/release-namespace="$RELNS" --overwrite
}
adopt -n "$NS" serviceaccount/eduide-deployer secret/eduide-deployer-token role/eduide-deployer rolebinding/eduide-deployer
adopt -n "$RELNS" role/eduide-deployer-identity-"$NS" rolebinding/eduide-deployer-identity-"$NS"
adopt clusterrole/eduide-deployer-"$NS" clusterrolebinding/eduide-deployer-"$NS"
```

### Storing and checking them

The bootstrap kubeconfig, with a single context so the workflow cannot pick
the wrong one:

```bash
token=$(kubectl --context "$CTX" -n eduide-system get secret eduide-bootstrap-token -o jsonpath='{.data.token}' | base64 -d)
ca=$(kubectl --context "$CTX" -n eduide-system get secret eduide-bootstrap-token -o jsonpath='{.data.ca\.crt}')
cat <<EOF | gh secret set KUBECONFIG --repo "$REPO" --env cluster-tum-production
apiVersion: v1
kind: Config
clusters:
  - name: cluster
    cluster:
      server: $SERVER
      certificate-authority-data: $ca
users:
  - name: eduide
    user:
      token: $token
contexts:
  - name: eduide
    context:
      cluster: cluster
      user: eduide
current-context: eduide
EOF
```

The deploy one comes from `scripts/deployer-kubeconfig.sh`, above. Check what
it may do before relying on it; everything outside its namespace must be
refused:

```bash
D() { kubectl --kubeconfig <(scripts/deployer-kubeconfig.sh "$ENV" "$CTX") "$@"; }
NS=$(yq -r .spec.namespace environments/$ENV/env.yaml)
D -n "$NS" auth can-i create deployments                                   # yes
D -n "$NS" auth can-i create appdefinitions.theia.cloud                    # yes, once the CRD exists
D -n eduide-system auth can-i get configmap/eduide-cluster-identity        # yes
D -n default auth can-i create deployments                                 # no
D -n "$NS" auth can-i create pods --subresource=exec                       # no
D auth can-i create customresourcedefinitions                              # no
D auth can-i create namespaces                                             # no
```

**Rotating a token:** delete its Secret. For the deployer, run `Bootstrap
cluster` again, which recreates it; for the bootstrap ServiceAccount, apply the
manifest above again. Kubernetes invalidates the old token with the Secret.
Then store the new kubeconfig.

**Revoking access:** for the deployer, drop the environment from the cluster
(or set `spec.deployers: false`, which revokes every deployer on it) and
bootstrap again. For the bootstrap ServiceAccount, delete it and its
ClusterRoleBinding.

## Creating one

**In the UI:** Settings -> Environments -> New environment. The name must match
the directory exactly - `environments/test1.eduide.student.k8s.aet.cit.tum.de/`
needs an environment of the same name. Names are the landing hostname, so they are long; that is deliberate,
since it removes any mapping that could drift.

**With the CLI:**

```bash
REPO=EduIDE/EduIDE-deployment
ENV=test1.eduide.student.k8s.aet.cit.tum.de
gh api -X PUT "repos/$REPO/environments/$ENV"

gh secret set KUBECONFIG --repo "$REPO" --env "$ENV" < ~/.kube/stud-cp.yaml
gh secret set THEIA_KEYCLOAK_COOKIE_SECRET --repo "$REPO" --env "$ENV" \
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
gh api "repos/$REPO/environments/test1.eduide.student.k8s.aet.cit.tum.de/secrets" --jq '.secrets[].name'
```

## Protection rules

Add **required reviewers** to anything `tier: production` or `staging`, and to
every `cluster-*` environment. The job names the environment, so GitHub holds
the run until someone approves and records who approved it on the run.

```bash
gh api -X PUT "repos/$REPO/environments/tum-production" \
  -F 'reviewers[][type]=Team' -F 'reviewers[][id]=<team-id>'
```

`e2e.eduide.student.k8s.aet.cit.tum.de` deliberately has none: it deploys
from `main` automatically and a gate there would just leave runs waiting. Test environments generally do not
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
and Mannheim cannot be bootstrapped, and `e2e.eduide.student.k8s.aet.cit.tum.de`
still needs
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
