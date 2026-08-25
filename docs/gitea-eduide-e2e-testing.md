# Gitea + EduIDE integration - end-to-end test plan

This plan validates launching EduIDE sessions from a Gitea repo with Gitea as the OIDC provider (no Keycloak), auto-cloning private repos.

## Components changed (must be built/deployed together)

| Repo | Change | Build artifact |
| --- | --- | --- |
| `scorpio` | Bearer-header (`http.extraHeader`) clone when `GIT_TOKEN` is set | Rebuild the **Theia session image** that bundles scorpio (e.g. `java-17`) |
| `EduIDE-Landing-Page` | Gitea OIDC (PKCE) login, `GIT_TOKEN` env, identity = Gitea email | Landing-page container image |
| `EduIDE-Cloud` | `--gitea` operator flag -> injects oauth2-proxy for Gitea | Operator image |
| `EduIDE-Helm` | `gitea.*` values + oauth2-proxy `oidc` provider branch | Chart |
| `EduIDE-deployment/charts/gitea-eduide` | Deploy + configure Gitea for testing | Chart |

CRITICAL: scorpio is compiled into the Theia session image. The updated `java-17` (or equivalent) image MUST be rebuilt/pushed, or the clone will still be the old verbatim clone.

## Phase 0 - probe the git-auth assumption (gates everything)

The whole design assumes Gitea accepts a raw OIDC access token as an HTTP Bearer git credential. Verify FIRST:

```bash
# obtain a Gitea OIDC access token for a user (or use the token from a landing-page login)
git clone -c "http.extraHeader=Authorization: Bearer <ACCESS_TOKEN>" \
  https://<gitea-host>/<owner>/<private-repo>.git /tmp/probe
```

- Success -> proceed.
- `401`/`403` -> the raw OIDC token is not accepted on this Gitea version; the Bearer approach needs the PAT-mint fallback (NOT built - would be a follow-up). Stop and report.

## Phase 1 - deploy

1. **Deploy Gitea** (test): `helm dependency build` then `helm install gitea-eduide EduIDE-deployment/charts/gitea-eduide` with `domain`, `gitea.gitea.config.server.ROOT_URL`+`.DOMAIN`, `gitea.gitea.admin.password`, `eduide.landingPageUrl`, `eduide.redirectUris` (include the landing-page origin AND, for session guarding, each session oauth2-proxy callback - Gitea has no wildcard redirect URIs), and `eduide.createTestRepo=true`.
2. **Read the OAuth secret** the configure-Job created: `kubectl get secret gitea-eduide-oauth -o yaml` -> `client_id`, `client_secret`, `issuer`.
3. **Manual (one-time): add the "Open with" button** in Gitea Site Administration (there is no API/CLI for this in Gitea 1.22+). Entry URL:
   `https://<landing-host>/?gitUri={url}&appDef=java-17-latest`
4. **Deploy EduIDE** via `EduIDE-Helm` with: `keycloak.enable=false`, `gitea.enable=true`, `gitea.issuerUrl=<issuer>`, `gitea.clientId=<client_id>`, `gitea.clientSecret=<client_secret>`, `gitea.cookieSecret=<32-byte base64>`, the rebuilt operator + landing-page + session images.
5. Confirm the landing-page config (`/config.js`) now shows `useGiteaOidc: true`, `giteaIssuerUrl`, `giteaClientId`.

## Phase 2 - functional tests

### T1 - private-repo happy path (core)
- In Gitea, open the private test repo -> Clone dropdown -> "Open in EduIDE".
- Expect: landing page opens with `gitUri`+`appDef` -> redirect to Gitea OIDC -> login -> redirect back -> auto-start fires (no `artemisToken`) -> session opens.
- In the IDE: the private repo is cloned at the workspace root. Open a terminal: `git remote -v` and `git fetch` succeed (proves the persisted Bearer credential works, not an anonymous cache).

### T2 - identity / workspace persistence
- Launch T1 twice as the same user -> same persistent workspace (`ws-...-<email hash>`), files persist.
- Launch as a different Gitea user -> different workspace. Confirms `launchUser = Gitea email`.
- `kubectl get session <name> -o yaml` -> `spec.user` is the Gitea email; `spec.envVars` has `GIT_URI` and `GIT_TOKEN`.

### T3 - session access guard (oauth2-proxy -> Gitea)
- Owner opens the session URL -> allowed.
- A different Gitea user / unauthenticated -> denied by oauth2-proxy (redirect to Gitea / 403). Confirms the per-session `authenticated-emails-list` matches the Gitea email.
- `kubectl get pod <session> -o jsonpath=...` -> the `oauth2-proxy` sidecar container is present.

### T4 - in-IDE git operations
- `git fetch` in the session terminal succeeds: the `read:repository` scope the landing page requests (`openid email profile read:repository`) covers clone and fetch.
- `git push` needs the `write:repository` scope. With the current landing-page scope (`read:repository`), push is expected to be DENIED. To allow in-IDE push, widen the landing-page OIDC scope to `write:repository`.
- Requires Gitea >= 1.26.2 (earlier 1.26.x skipped repository-scoped token checks for Git Smart HTTP with `Authorization: Bearer`); the gitea-eduide chart pins Gitea 1.27.0.
- Note: Gitea OIDC access tokens are short-lived; after expiry, clone/fetch/push stop working (clone at startup is the primary path).

### T5 - public repo sanity
- Open the landing page with a public `gitUri` -> still clones (verbatim path unchanged).

## Phase 3 - regression (must not break existing)

### R1 - Keycloak path unchanged
- Deploy/keep a `keycloak.enable=true` instance -> Keycloak login + Artemis launch + clone still work exactly as before. (Operator: `--gitea` absent -> `isUseOAuth2Proxy() == isUseKeycloak`, byte-identical rendering.)

### R2 - Artemis auto-start unchanged
- An Artemis deep link (with `artemisToken`) still auto-starts and clones via the Artemis VCS-token path (scorpio: `ARTEMIS_TOKEN` present -> Gitea branch skipped).

### R3 - Helm guard
- `helm template ... --set keycloak.enable=true,gitea.enable=true` fails with the mutual-exclusion error.
- Default render (both disabled) is unchanged except 3 additive landing-page keys.

## Automated checks already run (pre-deploy)
- scorpio: `tsc --noEmit` clean, `eslint` 0 errors, webpack production + extension build succeed, unit tests compile. (Browser test runner blocked by a pre-existing `dist/web` path bug in `package.json` test script.)
- landing page: `typecheck`, `lint`, `build` pass.
- operator: `mvn clean install` + `mvn test` (19 tests) pass.
- EduIDE-Helm: `helm lint` + `helm template` diffs confirm keycloak/default byte-identical.
- gitea-eduide chart: `helm lint` + `helm template` render clean.

## Known risks / caveats to watch during testing
1. `GIT_TOKEN` lands in the `Session` CRD `spec.envVars` and the operator logs whole Session objects -> the token can appear in cluster logs/Sentry. Use short-lived tokens; redact `envVars` from operator logs before broad rollout.
2. Token expiry vs in-IDE push/fetch (T4).
3. Double login: the landing page logs in via Gitea and the session oauth2-proxy also authenticates via Gitea. With a live Gitea SSO cookie the second hop is usually transparent (redirect only).
4. The "Open with" entry is a manual admin-UI step (no Gitea API/CLI).
5. Gitea has no wildcard redirect URIs - each session host callback must be registered for T3 (or front sessions with a single host/path).
