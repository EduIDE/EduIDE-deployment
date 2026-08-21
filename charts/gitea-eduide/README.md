# gitea-eduide

A deployable Helm chart that stands up a [Gitea](https://gitea.com) instance
(>= 1.22) pre-configured for **EduIDE** integration, for end-to-end testing.

It **wraps the official Gitea chart** (`https://dl.gitea.com/charts/`, chart
`12.6.0` / Gitea `1.26.1`) and adds a post-install/post-upgrade Job that performs
the EduIDE-specific setup that the Gitea chart does not do.

After `helm install` you get a Gitea that is:

- an **OIDC / OAuth2 provider** (on by default; pinned on here),
- with an **EduIDE OAuth2 application** registered as a confidential client, and
  its `client_id` / `client_secret` / `issuer` exported to a Kubernetes Secret,
- optionally seeded with a **private test org + repo** for e2e clone tests.

## Automated vs. manual

| Step | How | Automated? |
| --- | --- | --- |
| Deploy Gitea >= 1.22 | official Gitea subchart | yes |
| Enable OAuth2 provider + OpenID sign-in | `gitea.gitea.config` (app.ini) | yes |
| Admin user / password | `gitea.gitea.admin.*` | yes |
| Stable `ROOT_URL` (OIDC issuer) | `gitea.gitea.config.server.ROOT_URL` | yes |
| Register EduIDE OAuth2 app + capture client id/secret | configure Job -> Gitea API | yes |
| Export credentials to a K8s Secret | configure Job -> `kubectl apply` | yes |
| Private test org + repo | configure Job (guarded by `eduide.createTestRepo`) | yes (opt-in) |
| **Repo "Open with" launch button** | **Site Administration UI** | **NO - manual, see below** |

### Why "Open with" is manual

Gitea's customizable "Open with" clone applications were added in **Gitea 1.22**
([PR #29320](https://github.com/go-gitea/gitea/pull/29320)). They are stored as
**JSON in the database `system_setting` table** and are configurable **only via
the Site Administration web UI**. As of current Gitea there is **no REST API and
no CLI command** to add an "Open with" entry (the PR author explicitly deferred
an API/CLI to a possible future change). This chart therefore does **not** try to
hack the database; it documents the exact one-time manual step instead (below).

## Prerequisites

- A Kubernetes cluster and Helm 3+.
- DNS / ingress so that `gitea.<domain>` resolves to the Gitea Service and matches
  `gitea.gitea.config.server.ROOT_URL`. OIDC discovery relies on a correct `ROOT_URL`.
  (This chart does not create an Ingress; enable `gitea.ingress` in values or
  route via your existing gateway, e.g. the repo's `theia-shared-gateway`.)
- Network access to `https://dl.gitea.com/charts/` to fetch the dependency once.
- The configure Job image (`alpine/k8s`, bundles `kubectl` + `curl` + `jq`) must
  be pullable from the cluster.

## Install

```bash
# 1. Fetch the Gitea dependency (writes charts/gitea-*.tgz + Chart.lock).
helm dependency build ./charts/gitea-eduide     # or: helm dependency update

# NOTE (Helm 4): Helm v4 currently refuses to use a packaged .tgz dependency for
# `template`/`install` ("missing in charts/ directory: gitea"). If you hit this,
# unpack the fetched dependency once:
#   tar -xzf charts/gitea-eduide/charts/gitea-*.tgz -C charts/gitea-eduide/charts/
# Helm 3 consumes the .tgz directly and needs no unpack step.

# 2. Install. Override at least domain, ROOT_URL, landing page URL, admin password.
helm upgrade --install gitea-eduide ./charts/gitea-eduide \
  --namespace gitea-eduide --create-namespace \
  --set domain=eduide.example.com \
  --set gitea.gitea.config.server.ROOT_URL=https://gitea.eduide.example.com \
  --set gitea.gitea.config.server.DOMAIN=gitea.eduide.example.com \
  --set gitea.gitea.admin.password='a-strong-test-password' \
  --set eduide.landingPageUrl=https://eduide.example.com \
  --set-json 'eduide.redirectUris=["https://eduide.example.com","https://eduide.example.com/"]' \
  --set eduide.createTestRepo=true
```

For anything beyond a couple of flags, use a values file (see the values table
below). `values.yaml` is **not** templated, so keep `domain`, `ROOT_URL`,
`landingPageUrl` and `redirectUris` consistent by hand.

## How the OAuth2 client Secret is produced

The configure Job (Helm hook `post-install,post-upgrade`):

1. polls `<gitea>/api/v1/version` until Gitea is ready,
2. authenticates to the Gitea API with **HTTP basic auth** using
   `gitea.gitea.admin.username` / `gitea.gitea.admin.password` (no pod exec required),
3. looks up an OAuth2 app named `eduide.oauthAppName`; if a valid one already
   exists and its secret is stored, it reuses it (idempotent). Otherwise it
   creates one via `POST /api/v1/user/applications/oauth2` with
   `redirect_uris = eduide.redirectUris` and `confidential_client: true`, and
   captures the returned `client_id` / `client_secret` (Gitea only returns the
   secret at creation time),
4. writes them to the Secret named `eduide.oauthSecretName` (default
   `gitea-eduide-oauth`).

The Job is **safe to re-run**: it looks up the app by name and reconciles against
the existing Secret before creating anything.

### Secret contents

`kubectl -n <ns> get secret gitea-eduide-oauth -o yaml`, keys (base64):

| Key | Meaning |
| --- | --- |
| `client_id` | OAuth2 client id |
| `client_secret` | OAuth2 client secret |
| `issuer` | Gitea OIDC issuer = `ROOT_URL` (discovery at `issuer/.well-known/openid-configuration`) |
| `redirect_uris` | JSON array registered for the app |

Read one value:

```bash
kubectl -n gitea-eduide get secret gitea-eduide-oauth \
  -o jsonpath='{.data.client_secret}' | base64 -d ; echo
```

## Wiring into EduIDE-Helm

EduIDE-Helm consumes `gitea.issuerUrl` / `gitea.clientId` / `gitea.clientSecret`.
Point them at this Secret. Either reference the Secret directly (preferred) or
copy the values.

Direct reference (in the EduIDE-Helm release, same namespace or copy the Secret):

```yaml
gitea:
  issuerUrl: https://gitea.eduide.example.com   # = issuer key in the Secret
  clientId:
    valueFrom:
      secretKeyRef: { name: gitea-eduide-oauth, key: client_id }
  clientSecret:
    valueFrom:
      secretKeyRef: { name: gitea-eduide-oauth, key: client_secret }
```

Or copy explicit values from the Secret:

```bash
NS=gitea-eduide
ISSUER=$(kubectl -n $NS get secret gitea-eduide-oauth -o jsonpath='{.data.issuer}' | base64 -d)
CID=$(kubectl -n $NS get secret gitea-eduide-oauth -o jsonpath='{.data.client_id}' | base64 -d)
CSECRET=$(kubectl -n $NS get secret gitea-eduide-oauth -o jsonpath='{.data.client_secret}' | base64 -d)
# then: --set gitea.issuerUrl=$ISSUER --set gitea.clientId=$CID --set gitea.clientSecret=$CSECRET
```

The landing page uses `scope: openid email profile read:repository` and a
redirect_uri of `origin + pathname` (no query string) - which is why
`eduide.redirectUris` must contain both the bare origin and the trailing-slash
form of the landing page URL. Gitea does **not** support wildcard redirect URIs,
so if you guard workspace sessions with a per-session oauth2-proxy, add each
concrete `https://<session-host>/oauth2/callback` to `eduide.redirectUris`.

## "Open with" launch button (manual)

This is the only manual step. Do it once per Gitea instance.

1. Log in as the admin user (`gitea.gitea.admin.username`).
2. Go to **Site Administration** -> **Settings** -> **Repositories**
   (the "Open with" applications block; on some versions it is under
   Site Administration -> **Repositories** configuration).
3. Under **"Open with" applications**, add a new entry. Paste this exact URL
   template (Gitea substitutes `{url}` with the repo clone URL):

   ```
   https://eduide.example.com/?gitUri={url}&appDef=java-17-latest
   ```

   Generalized (substitute your `eduide.landingPageUrl` and `eduide.appDef`):

   ```
   {landingPageUrl}/?gitUri={url}&appDef={appDef}
   ```

   Give it a display name such as `Open in EduIDE`.
4. Save. The button now appears in every repo's clone dropdown and deep-links to
   the EduIDE landing page, which reads `gitUri` and `appDef` from the query
   string (see `EduIDE-Landing-Page/src/App.tsx`).

## Private test repo + user

Set `eduide.createTestRepo=true` and the configure Job creates a **private** org
(`eduide.testOrg`) and repo (`eduide.testRepo`, auto-initialized) owned by the
admin user - enough for an e2e clone test. To add a dedicated test **user**
instead, either set it via values on the Gitea subchart or create it manually:

```bash
# Manual test user (exec into the Gitea pod):
kubectl -n gitea-eduide exec deploy/gitea-eduide -- \
  gitea admin user create --username e2e --password 'e2e-pass' \
  --email e2e@example.com --must-change-password=false
```

## Values

| Key | Default | Description |
| --- | --- | --- |
| `domain` | `eduide.example.com` | Base domain; drives defaults / docs (not templated). |
| `eduide.landingPageUrl` | `https://eduide.example.com` | EduIDE landing page origin; OAuth2 redirect + "Open with" base. |
| `eduide.appDef` | `java-17-latest` | App definition for the "Open with" launch URL. |
| `eduide.oauthAppName` | `EduIDE` | Name of the registered OAuth2 application. |
| `eduide.confidentialClient` | `true` | Register as confidential client. |
| `eduide.redirectUris` | `[origin, origin/]` | OAuth2 redirect URIs (list). Add session oauth2-proxy callbacks here. |
| `eduide.oauthSecretName` | `gitea-eduide-oauth` | Secret that receives client id/secret/issuer. |
| `eduide.createTestRepo` | `false` | Create a private test org + repo. |
| `eduide.testOrg` / `eduide.testRepo` | `eduide-test` / `sample-assignment` | Test org / repo names. |
| `configure.enabled` | `true` | Enable the configuration Job + RBAC. |
| `configure.image` | `alpine/k8s:1.30.13` | Image with `kubectl`, `curl`, `jq`. |
| `configure.readinessTimeoutSeconds` | `300` | How long to wait for Gitea readiness. |
| `configure.rbac.create` | `true` | Create ServiceAccount/Role/RoleBinding for Secret writes. |
| `gitea.gitea.admin.username` / `gitea.gitea.admin.password` | `gitea_admin` / `changeme-admin-pw` | Admin creds (also used by the Job for API auth). |
| `gitea.gitea.config.server.ROOT_URL` | `https://gitea.eduide.example.com` | External URL = OIDC issuer. |
| `gitea.gitea.config.server.DOMAIN` | `gitea.eduide.example.com` | Gitea host. |
| `gitea.gitea.config.oauth2.ENABLE` | `true` | OAuth2 provider on. |
| `gitea.gitea.config.openid.ENABLE_OPENID_SIGNIN` | `true` | OpenID sign-in on. |
| `gitea.gitea.config.database.DB_TYPE` | `sqlite3` | Lightweight DB for testing. |
| `postgresql-ha.enabled` / `postgresql.enabled` | `false` | Bundled DBs disabled (sqlite used). |

All `gitea.*` keys are passed to the official Gitea subchart; see its
[values](https://gitea.com/gitea/helm-gitea) for the full set (ingress, TLS,
resources, persistence, SSH, etc.).

## Verify / render

```bash
helm dependency build ./charts/gitea-eduide
helm lint ./charts/gitea-eduide
helm template gitea-eduide ./charts/gitea-eduide \
  --set eduide.createTestRepo=true | less   # inspect Job, Secret RBAC, Gitea release
```
