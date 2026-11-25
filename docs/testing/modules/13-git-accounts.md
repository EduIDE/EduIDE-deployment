# 13 Git accounts (GIT)

Server and browser module. A student connects a GitHub or GitLab account once on the landing page. The token stays in the control plane. Git in the session pod reaches a provider host through the agent (loopback) and the `git-proxy` Deployment, which adds the token. Design: `EduIDE-control-plane` ADR 0023 (`docs/adr/0023-git-accounts-and-git-proxy.md`).

Sources (EduIDE-control-plane, state of branch `git-accounts`, commit `b8f306b`): ADR 0023, `docs/development/git-accounts.md`, `docs/operations/git-proxy.md`, `docs/operations/install.md`, `docs/api/README.md`, chart README of `eduide-control-plane`, `internal/gitapi/gitapi.go` (messages), `internal/gitaccount`, `internal/gitpolicy`, `internal/gitproxy`, `internal/agent/git.go`, `landing-page/src/git.ts`, `extensions/eduide-session/src/git.ts`, `test/e2e/git_test.go`, `test/e2e/auth_test.go`, `test/e2e/browser/git-accounts.spec.ts`.

## Facts

- The feature is on only when `config.gitAccounts.providers` has at least one entry. Without providers the chart renders no `git-proxy`, no key Secret, no internal service port and no Git NetworkPolicy, and every test in "Feature off" must pass. `GET /api/v1/git/providers` then answers an empty list, every other Git endpoint answers 404 (`not-found`).
- Providers: `{name, type (github|gitlab), host, displayName, clientID, clientSecretRef, caConfigMapRef?, inactivityExpiry (default 2160h)}`. The OAuth redirect URI is exactly `https://<hosts.service>/git/callback`. Provider hosts count as allowed hosts for the launch key `GIT_URI` only.
- Token store: one Secret per user and provider, `git-account-<first 32 hex of sha256(owner, newline, provider)>`, labels `eduide.github.io/component=git-account`, `eduide.github.io/git-provider`, `eduide.github.io/owner-hash`, no `managed-by` label. The value is one AES-256-GCM blob. Only the service reads it. The key is in the Secret `<release>-git-accounts-key` (or `gitAccounts.encryptionKey.secretName`), key name `key`.
- Approvals: one Secret per session, `<session>-git-repos`, owned by the session, label `eduide.github.io/component=git-approvals`, no credential in it.
- The IDE container holds no Git token and no instance token. Its global Git config maps `https://<provider host>/` to `http://127.0.0.1:8082/git/<provider host>/` (`insteadOf`), written by the `eduide-session` extension from `GET /v1/git/hosts`. The agent adds the instance name and token and forwards to the `git-proxy` Service (ports 8080 Git, 9090 metrics and health). The agent serves `/git/` only for a claimed instance (idle warm pod: 403) and only when the operator set `AGENT_GIT_PROXY_URL`, `AGENT_GIT_HOSTS` and `AGENT_GIT_LANDING_URL` (otherwise 404).
- The credential rule: the user's token is used only for the repository the session was started with (`GIT_URI`) and for repositories the user approved for this session. Every other repository of a provider host is read anonymously (public repositories keep working) and never pushed to.
- Repository approval: `gitAccounts.approval.mode` is `off`, `read` or `write` (default `write`), `maxPerSession` default 20. The git-proxy message for a refused repository is "This session may not use <host>/<repo> yet. Approve it here: <link>" (a push: "may not push to"). The link is `https://<hosts.service>/?session=<session>&approveRepo=<url-encoded https URL>&access=<read|write>`. With mode `off`, with a push in mode `read`, or without a connected account the old messages stay ("EduIDE uses your <displayName> account only for the repository this session was started with (<repo or none>). Start a session from <host>/<repo> to open it." and "Connect your <displayName> account to open this repository: <landing URL>"). Approving needs the EduIDE bearer token of the session owner, on the landing page, with a click.
- Timing: a connect takes effect within 3 seconds, a disconnect or a removed or lowered approval within 5 seconds (the git-proxy reuses an allowed answer for at most 5 seconds, a denial for 3).
- Connect flow: no cookie. The provider redirects the browser to the landing page route `/git/callback`. The page reads `code` and `state` (or `error` and `state`), removes them from the address bar, logs in, and posts them with its bearer token to `POST /api/v1/git/callback`. The state is sealed (10 minute lifetime), PKCE S256 is used. The callback requires that the state owner equals the bearer owner. Problem codes: `git-invalid-state`, `git-state-expired`, `git-denied`, `git-provider-error`. A state is not single use. Two flows at once both succeed.
- Preflight: `POST /api/v1/git/preflight` `{gitUri}` answers `ok`, `connect`, `no-access`, `not-a-provider` or `unknown`. One `GET info/refs` to the provider with a 3 second timeout, never follows a redirect. Any failure of the request never blocks a launch. A URL with credentials (Artemis) is not sent.
- Template picker: a link with `gitUri` and a missing or unknown `appDef` shows the repository and the listed templates whose `injectableKeys` contain `GIT_URI`. It never forwards `artemisUrl` or an Artemis token.
- Commit identity: for a launch with a `GIT_URI` on a provider host where the user has an account with a stored no-reply address, `GIT_USER` is the display name (login when empty) and `GIT_MAIL` the no-reply address, only for keys the template takes from the token. GitHub Enterprise Server stores no address, so the identity provider values stay. Otherwise the launch data stays as before.
- Limits: connect, callback, preflight and approval calls are rate limited per user (the launch rate, own buckets). The git-proxy allows 100 requests per second per client IP (burst 400, then 429), 16 requests at the same time per instance (an `ERR` line says so) and cancels a request that moves no byte for 5 minutes (idle deadline, not total time). The authorize call allows 10 per second per instance (burst 30), and the token is checked before the limiter is charged.
- Repository path rule (`gitapi.CanonicalRepo`): 2 to 10 segments of letters, digits and `._~-`; no segment starts with a dot (so no `.git` directory, no `..`); `.git` only as the suffix of the last segment; no name that still ends in `.git` after one suffix is cut. The upstream path is built from the authorised repository, never from the request path.
- The git-proxy serves `info/refs`, `git-upload-pack` and `git-receive-pack` only. Git LFS paths answer 501 with "Git LFS is not supported through EduIDE.". Everything else is 404. It follows no redirect and talks only to provider hosts over HTTPS.
- Network (NetworkPolicies of the release): `session-to-git-proxy` (session pods to `git-proxy` :8080, a pod selector rule of its own), `git-proxy` (ingress from session pods and the metrics scrape; egress DNS, the service :8083, HTTPS to the internet without private ranges), `service-internal` (the service port 8083 accepts only `git-proxy`). The `git-proxy` pod has no service account token and mounts no Secret. The service Role gets `list`, `update`, `patch` on Secrets only with providers.
- The idle warm instances are replaced after a change of the Git settings: they are part of the pod hash. Without providers the hash is unchanged, so an upgrade replaces nothing.
- Two Keycloak clients (install guide): the landing page client is public with PKCE S256 and has redirect URIs on the service host only. The gateway client is confidential with exact redirect URIs for the instance and webview host. `oidc.gatewayClientID` is never in `oidc.clientIDs`.
- Scorpio (the IDE's Git integration) shows the remote message of a refused Git command with an "Open" button, offers "Retry" after connecting, and a restarted session reuses the workspace from Scorpio 3.5.0 (EduIDE/scorpio PR 239).

Each test has one more field than the README names: **Automated** says whether the control plane e2e suite (`make e2e`, `E2E_RUN=TestGitAccounts`) covers it. `go` names the subtest of `TestGitAccounts` in `test/e2e/git_test.go`, `pw` the Playwright spec `test/e2e/browser/git-accounts.spec.ts`, `unit` that only unit tests cover it, `none` that nothing automated does. The e2e suite runs against a fake provider, a fake IDE and a kind cluster. A run on a real installation should spend its time on what only a real environment shows: real GitHub and GitLab, the real IDE with Scorpio, NetworkPolicy enforcement by the cluster's CNI, the real Keycloak clients and the real landing page host. Tests marked `go` or `pw` are still worth a smoke run (GIT-20, GIT-30, GIT-32) and are otherwise skipped when time is short.

Preconditions for the "real provider" tests: OAuth apps registered for this installation, a test account on each provider with one private repository `ft-private`, one public repository `ft-public`, and a second private repository `ft-other`. The user logs in to the provider in the browser pane; the agent never types a password. Every object a test creates is named `ft-`. The user logs in on the landing page in the browser pane, and the agent never types a password there either.

Never print or record a token, a code, the `state`, a cookie, or the decrypted content of a `git-account-` Secret. Evidence is status codes, key names, counts and hashes. Do not record the callback URL or an approval link with a real session name.

## Feature off (regression)

### GIT-01 No providers: nothing changes
Safety: prod-safe
Automated: none (the e2e suite runs the whole suite with the feature off first)
Steps: on an installation without `gitAccounts.providers`: `k get deploy,svc,networkpolicy,pdb -l app.kubernetes.io/component=git-proxy`; `k get secret -l eduide.github.io/component=git-account`; `k get cm $P-config -o json | jq -r '.data["config.yaml"]' | yq -o json | jq 'has("gitAccounts")'`; the service start log line with `git_providers`; `GET /api/v1/status`; with a user token `GET /api/v1/git/providers` and `POST /api/v1/git/preflight`.
Expect: no `git-proxy` objects, no git-account Secret, no `gitAccounts` key in the config, `git_providers: 0` in the log; `status` has no `gitProviders`; the provider list is an empty array; the preflight answers 404 `not-found` and the landing page still launches a link with a `GIT_URI`; the landing page shows no "Git accounts" section.

### GIT-02 Start link to a public repository still works
Safety: test-only
Automated: none
Steps: open `/?appDef=<standalone template>&gitUri=https://github.com/<public repo>.git` as a logged-in user.
Expect: the session starts and Scorpio clones into the workspace root, exactly as before the feature (module 08 result for the same template is the reference).

### GIT-03 Artemis launch still works
Safety: test-only
Automated: none
Steps: module 12 ART tests.
Expect: unchanged. A `GIT_URI` with the Artemis VCS token as user info does not match the `insteadOf` entry (it only matches URLs that start with `https://<host>/`), so the clone goes straight to the host as before, even when the Artemis host is also a provider.

### GIT-04 Session pod without the feature
Safety: prod-safe
Automated: none
Steps: in a running session pod (IDE container): `git config --global --get-regexp '^url\.'`; `git config --list --show-origin | grep -ci insteadof`; env names of both containers.
Expect: exit code 1 and no output for the first command, 0 for the second, no `AGENT_GIT_*` env name in the agent container.

## Configuration and deployment

### GIT-10 Objects of the feature
Safety: prod-safe
Automated: go `feature is on`
Steps: with one provider configured: `k get deploy,svc,pdb,networkpolicy -l app.kubernetes.io/component=git-proxy`; `k get networkpolicy` (names); `k get secret -l eduide.github.io/component=git-account` (names and count only); `k get secret <release>-git-accounts-key` (existence only, never the data); `k get svc $P-service -o jsonpath='{.spec.ports[*].name}'`; `k get role $P-service -o json | jq '[.rules[] | select(.resources | index("secrets")) | .verbs]'`.
Expect: `git-proxy` Deployment with 2 ready replicas and a PodDisruptionBudget (`maxUnavailable 1`); a ClusterIP Service; no HTTPRoute or Ingress for it; NetworkPolicies `session-to-git-proxy`, `git-proxy` and `service-internal` exist; the key Secret exists; the service has the internal port (8083); the service Role has `list`, `update` and `patch` on Secrets; the `git-proxy` pod spec has `automountServiceAccountToken: false` and no Secret volume.

### GIT-11 Proxy is not reachable from outside or from foreign pods
Safety: test-only
Automated: go `foreign pods cannot reach git-proxy or the internal port of the service`
Steps: from outside the cluster request `https://<service host>/git/github.com/` and `https://<service host>/api/v1/git/callback` without a token; from an `ft-` pod without session labels in the namespace, `curl -m 5` the `git-proxy` Service on 8080 and the service's internal port 8083. Needs a CNI that enforces NetworkPolicies.
Expect: outside: the landing page's HTML for the first (a route of the SPA), 401 for the second, never a Git answer. Foreign pod: timeout (exit code 28) on both. A control from a pod that is allowed (a session pod to 8080) shows the path works.

### GIT-12 Invalid provider config is refused
Safety: test-only, disruptive
Automated: unit (config validation)
Steps: `helm template` (dry run, no install) with a duplicate provider name, a duplicate host, an unknown `type`, and a host with a path.
Expect: schema or config validation fails with a message that names the field. Nothing is installed.

## Connect and disconnect

### GIT-20 Connect (real provider)
Safety: test-only
Automated: pw `connect through the page`, go `session with a connected account` (fake provider only)
Steps: landing page, "Connect" on each provider. The user consents at the provider in the browser pane.
Expect: the page returns to where it was, the address bar has no `code` or `state`, the provider row shows "Connected as <login>"; one new `git-account-` Secret with the three labels; the service log has no code, state or token; `GET /git/providers` has no token field.

### GIT-21 Connect resumes a pending launch
Safety: test-only
Automated: pw `a start link to the private repository asks to connect, then launches`
Steps: disconnected, open a start link to `ft-private`.
Expect: the page says "This repository needs your <name> account" (the repository may also not exist), offers "Connect" and no "Start anyway". After the consent the same launch continues without opening the link again, and the repository is cloned in the IDE.

### GIT-22 Callback needs the owner of the flow
Safety: test-only
Automated: go `another user cannot complete my flow`
Steps: start a connect as user A. Take the `code` and `state` from the provider's redirect (do not record them). As user B, post them to `POST /api/v1/git/callback` from the landing page context. Then post them as user A.
Expect: B gets 400 `git-invalid-state`, no Secret is created for either user, the provider is not called for B (service log). A completes the flow (200, the provider and login). There is no cookie anywhere in the flow: `Set-Cookie` does not appear on the callback exchange.

### GIT-23 Callback rejects a tampered, expired or denied state
Safety: test-only
Automated: go `denied at the provider` (denied only); unit (state, expiry)
Steps: post a callback with a changed `state`; with a valid state after its 10 minute lifetime; with `error=access_denied` and a valid state.
Expect: 400 with `git-invalid-state`, `git-state-expired` and `git-denied`. No Secret, no provider call (service log). The page shows a message for each code and returns to the home page.

### GIT-24 Disconnect
Safety: test-only
Automated: go `disconnect`, pw `connect through the page`
Steps: with a running session of `ft-private`, "Disconnect" on the landing page (the page asks first). Fetch in the session every second.
Expect: the Secret is gone; the provider's settings page no longer lists the EduIDE authorization (user checks in the browser pane); the session's next private fetch fails with the connect message within 5 seconds; a new session fetch fails the same way.

### GIT-25 Revocation at the provider
Safety: test-only
Automated: go `refresh after the access token expired` (refresh only), unit (`invalid_grant`)
Steps: connected, revoke the authorization in the provider's settings, then fetch a private repository in a session (GitLab: after the access token expired, or at once for GitHub).
Expect: the fetch fails with the connect message; the Secret is deleted on that use; the landing page shows "Connect" again. The effect comes within 5 seconds of the next request after a cached answer ends.

### GIT-26 Inactivity expiry
Safety: test-only, disruptive
Automated: unit (sweep)
Steps: set `inactivityExpiry` of one provider to a short value on the test environment, connect, wait, wait for the hourly sweep (it has jitter), restore the value.
Expect: the account is revoked and deleted; an account used within the window stays. The annotation `eduide.github.io/git-last-used` is written at most once per 24 hours.

### GIT-27 Switch account keeps the working account
Safety: test-only
Automated: unit
Steps: connected as account 1. On the gate ("This repository needs your ... account" or "Connect another account"), choose "Switch account" and cancel at the provider; then do it again and finish with account 2 (sign out at the provider first, it remembers its login).
Expect: after the cancel the Secret still holds account 1 and `GET /git/providers` still shows its login. After the finish the account is account 2 and the old token is revoked at the provider (user checks the authorized applications). The page tells the user to sign out at the provider to really switch.

## Clone, fetch and push in a session

### GIT-30 Private clone by start link
Safety: test-only
Automated: pw `a start link to the private repository asks to connect, then launches`, go `session with a connected account` (fake IDE)
Steps: connected, open a start link to `ft-private`.
Expect: Scorpio clones into the workspace root without any prompt.

### GIT-31 Clone of another private repository in the terminal
Safety: test-only
Automated: go `second private repository is refused with an approval link`
Steps: connected, session of `ft-private`. In the terminal: `git clone https://<host>/<user>/ft-other.git /tmp/o`.
Expect: the clone is refused (the credential is not used for another repository, the anonymous read of a private repository fails). With approval mode `read` or `write`: `remote error: This session may not use <host>/<user>/ft-other yet. Approve it here: <link>`. With mode `off`: `EduIDE uses your <displayName> account only for the repository this session was started with (...)`. Without an account: the connect message. `/tmp/o` does not exist or is empty. One log line in the git-proxy (`anonymous-other`, only if the request failed).

### GIT-32 Push to the session repository
Safety: test-only
Automated: go `clone, commit and push the session repository` (fake IDE)
Steps: in the session of GIT-30 commit a file and `git push`; also push with the Git view of the IDE.
Expect: both succeed; the commit shows on the provider under the student's account; the `git-proxy` log has one push line (salted user, session, provider, repository, result `ok`) and no token.

### GIT-33 Push to another repository is refused
Safety: test-only
Automated: go `push elsewhere is denied`
Steps: in a public clone of another repository (or an approved one with access `read`) commit and `git push`.
Expect: refused. Mode `write` and a connected account: the message "This session may not push to ... yet. Approve it here: ..." with `access=write`. Mode `read` or `off`: "EduIDE only pushes to the repository ...". The repository on the provider is unchanged. One deny line in the log (`push-rule`).

### GIT-34 Session without a repository cannot use the account
Safety: test-only
Automated: go `push elsewhere is denied` (push only)
Steps: connected, start a session without `gitUri` (a tile). In the terminal clone `ft-private`, clone `ft-public`, and push a commit made in `ft-public`.
Expect: the clone of `ft-private` is refused with the approval message (the session has no repository, so the credential is not used), the clone of `ft-public` works anonymously, the push is refused with the approval or push-rule message.

### GIT-35 Connect inside a running session
Safety: test-only
Automated: go `session without an account` (public only)
Steps: connected, start a session from `ft-private`, then disconnect on the landing page. In the terminal `git fetch` fails with the connect message. Connect again in another tab and repeat `git fetch`.
Expect: the first fetch fails with "Connect your <displayName> account to open this repository: <landing URL>". The second works without a restart, within 3 seconds of the connect.

### GIT-36 Public repositories without an account
Safety: test-only
Automated: go `session without an account`
Steps: disconnected, clone `ft-public` and any public repository of another owner in the terminal.
Expect: works (anonymous pass-through).

### GIT-37 Workspace reattach
Safety: test-only
Automated: none
Steps: session with a saved workspace on `ft-private`, stop it, start it again from the landing page (no link), `git pull` and `git push`.
Expect: both work; `.git/config` still has `https://<host>/...` as the remote URL (never the proxy address). Needs Scorpio 3.5.0 or later for the IDE to reuse the workspace (see GIT-95).

### GIT-38 Commit identity
Safety: test-only
Automated: go `identity` (service side)
Steps: connected on a provider with a no-reply address. Start from a link to `ft-private`: in the IDE terminal `git config user.name` and `git config user.email`. Repeat in an Artemis session, in a session of a public repository without an account, in a session started from a tile, and (if available) with a GitHub Enterprise Server provider.
Expect: provider session with account: the account's display name (login when empty) and the platform's no-reply address (`<id>+<login>@users.noreply.github.com`, `<id>-<login>@users.noreply.<host>`). A GitHub Enterprise Server host, Artemis, a tile, a repository without an account: the name and e-mail of the EduIDE login, as before. The launch data has no control characters in the name.

### GIT-39 Large repository
Safety: test-only
Automated: unit (streaming test with a throttled provider)
Steps: clone a repository of several hundred MB through the proxy; watch `git-proxy` memory (`k top pod`).
Expect: the clone finishes; memory stays below its 64Mi limit and flat (streaming, no buffering); a slow but moving transfer is never cut.

### GIT-40 Token refresh during a long session (GitLab)
Safety: test-only
Automated: go `refresh after the access token expired` (fake provider)
Steps: connected to a GitLab provider, keep a session open past the access token lifetime (2 hours), then fetch and push `ft-private`.
Expect: both work without a new consent. Two parallel fetches right after the expiry both succeed (refresh lock).

## Repository approval

The approvals of these tests need approval mode `write` (the default) unless a test says otherwise. Do not record the link with a real session name; the page may be opened by copying it into the browser pane.

### GIT-70 A refused repository prints an approval link
Safety: test-only
Automated: go `second private repository is refused with an approval link`
Steps: connected, session of `ft-private`. `git clone` of `ft-other`; then in a clone of a public repository `git push`.
Expect: the first message ends in a link `https://<hosts.service>/?session=<session>&approveRepo=<url-encoded https URL of ft-other>&access=read`, the push message has `access=write`. The link holds no token, code or state.

### GIT-71 Approve read, then clone
Safety: test-only
Automated: go `approve read, then write`, pw `the approval page approves only after a click`
Steps: open the read link of GIT-70 in the browser pane as the session owner. Check the page, click "Allow". Repeat the `git clone` of `ft-other` in the terminal. Then `git push` in that clone.
Expect: the page says "Repeat the Git command in your IDE."; the clone works within 5 seconds; the push is refused with a new link (`access=write`). `GET /sessions/<name>/git/repositories` lists the repository with access `read`. One audit line `git repository approved` in the service log.

### GIT-72 Approve write, then push
Safety: test-only
Automated: go `approve read, then write`
Steps: open the write link of GIT-71, click "Allow", `git push` in the clone of `ft-other`.
Expect: the push works within 5 seconds, the commit shows on the provider, one push line in the git-proxy log. The approval is raised, not duplicated (approving again is idempotent).

### GIT-73 Remove an approval
Safety: test-only
Automated: go `delete the approval`, `repositories of the session`, pw `the approval page approves only after a click`
Steps: "Remove" next to the repository on the approval page (or `DELETE /sessions/<name>/git/repositories`). Fetch in the clone every second.
Expect: the fetch fails with the approval message within 5 seconds. The list is empty. One audit line `git repository approval removed`. The Secret `<session>-git-repos` has no credential (only repository, access and time).

### GIT-74 Approval modes `read` and `off`
Safety: test-only, disruptive
Automated: unit (`mayUseCredential` per mode)
Steps: on a test installation set `gitAccounts.approval.mode: read`, wait for the service rollout. Repeat GIT-70. Set `off`, repeat. Restore the value.
Expect: mode `read`: the clone message has a link (`access=read`), `PUT` with `access: write` answers `git-access-not-allowed`, the push message has no link ("EduIDE only pushes to ..."). Mode `off`: no link at all, `PUT` answers `git-approval-disabled`, stored approvals stop counting at once. Both cases: the session repository works as before.

### GIT-75 Limit per session
Safety: test-only
Automated: unit
Steps: set `maxPerSession` to 2 on a test installation (or approve 20 distinct public repositories in a loop with `PUT` from the page context, 20 is the default limit). Approve one more.
Expect: the extra `PUT` answers `git-approval-limit`. Approving an existing repository again still works.

### GIT-76 Another user's session
Safety: test-only
Automated: go `another user and bad requests`
Steps: user B calls `GET`, `PUT` and `DELETE /sessions/<A's session>/git/repositories` from the page context, also for a session that does not exist and one that is being deleted.
Expect: B gets a problem (`not-found`), never the approvals of A. A `PUT` for a host that is not a provider answers `git-not-a-provider`, without an account `git-not-connected`. Nothing is approved.

### GIT-77 The approval page names session and repository and approves nothing without a click
Safety: test-only
Automated: pw `the approval page approves only after a click`
Steps: open the link as the owner. Read the page. Reload it. Close it without a click.
Expect: the page shows the environment (title or template, start time), the repository, "Read (clone and fetch)" or "Read and push", the sentence that the student should allow only a request just made themselves, and "Allow" and "Decline". Opening the link approved nothing (the list is empty). An approval link never starts a launch.

### GIT-78 Malformed links are refused
Safety: test-only
Automated: pw (`access=root` only), unit (parser)
Steps: open the home route with `approveRepo` values: a path with a percent-encoded character (`%2e%2e`, `%2F` inside a segment), a `.git` segment, 11 segments, a URL with user info, with a port, with a query, `http://`; a session name that is not a DNS label; `access=root`.
Expect: each shows "This link is not valid. Nothing was approved." and makes no call to the service (browser network log). A repository is shown the way the service compares it (lower case host, no `.git`).

### GIT-79 Code in the pod cannot approve
Safety: test-only
Automated: go `pod cannot approve`
Steps: in the IDE container: `curl -m 5 -X PUT` the public route of the service for the session's repositories with no token, and with a made-up bearer; `curl` the git-proxy with the loopback agent path (`http://127.0.0.1:8082/git/<host>/...`) for the refused repository.
Expect: no connection (the egress deny list) or 401, never 2xx. Afterwards the approval list is still empty. The authorize call is not reachable from the pod (GIT-53).

## Preflight and template picker

### GIT-80 Preflight results
Safety: test-only
Automated: go `preflight before connect`, `preflight after connect`, pw `a start link to the private repository asks to connect, then launches`
Steps: from the page context `POST /git/preflight` for `ft-private` disconnected (`connect`), connected (`ok`), `ft-private-does-not-exist` connected (`no-access`), `ft-public` (`ok`), and a non-provider repository (`not-a-provider`, nothing checked).
Expect: the results above. For `no-access` the page names the connected account and offers "Connect another account" or "Back". The service log does not carry the URL or a credential.

### GIT-81 Provider down does not block the launch
Safety: test-only, disruptive
Automated: unit (`preflight` returns undefined on failure)
Steps: add a provider with an unreachable host (a name that does not resolve) on a test installation, open a start link to a repository on it; and a start link while the service answers 404 or 429 for the preflight if one can be provoked.
Expect: the preflight answers `unknown` within about 3 seconds (or fails), and the launch goes ahead with the clone failing later with the provider message. Never a blocked page. Remove the provider again.

### GIT-82 Artemis launch skips the preflight
Safety: test-only
Automated: none
Steps: open an Artemis launch link (module 12) with the browser network log open.
Expect: no call to `/git/preflight` for a URL with credentials; the launch runs as before.

### GIT-83 Template picker for a link without a usable `appDef`
Safety: test-only
Automated: none
Steps: open `/?gitUri=<ft-private URL>` (no `appDef`), `/?appDef=does-not-exist&gitUri=<URL>` and `/?appDef=<name>&gitUri=<URL>&artemisUrl=<URL>`; and `/` plus a made-up `appDef` without `gitUri`.
Expect: the first two show the repository and the listed templates whose `injectableKeys` contain `GIT_URI` (check with `GET /templates`); the pick launches with the repository (after the login, and the preflight). The Artemis token is never forwarded. A link without `gitUri` and without `appDef` does nothing, and no launch starts before the login.

## Limits and errors

### GIT-41 LFS is refused with a clear message
Safety: test-only
Automated: unit
Steps: clone a repository that uses Git LFS.
Expect: the Git objects clone; the LFS download fails with "Git LFS is not supported through EduIDE." (HTTP 501). No credential appears in the pod.

### GIT-42 Platform API is not proxied
Safety: test-only
Automated: unit (path allowlist)
Steps: in the IDE container: `curl -s -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:8082/git/<host>/api/v4/user` (GitLab) or `/git/api.github.com/user`.
Expect: 404 (or 403 for `api.github.com`, which is no provider host), never account data.

### GIT-43 Unknown host is not proxied
Safety: test-only
Automated: unit
Steps: `curl -m 5 -i http://127.0.0.1:8082/git/example.org/x.git/info/refs?service=git-upload-pack` in the IDE container.
Expect: refused (403 or 404, not a Git answer). The git-proxy opens no connection to a host that is not a provider (proxy log has no line, or `unknown-host`).

### GIT-44 Proxy outage
Safety: test-only, disruptive
Automated: none
Steps: scale `git-proxy` to 0, try a public and a private clone in a session, scale back.
Expect: both fail with a clear message (agent: 502 `git proxy unavailable`, `git proxy unreachable` in the agent log); sessions, the IDE and Artemis clones keep working; after the scale-up Git works again without a session restart.

### GIT-45 Service internal port unavailable
Safety: test-only, disruptive
Automated: none
Steps: scale the service to 0 (or break the policy `service-internal` on a test installation), `git fetch` in a session, restore.
Expect: "EduIDE cannot check your access right now"; git-proxy metric `unavailable` rises; recovery without a restart of the session.

### GIT-46 A wrong token for another instance does not block my session
Safety: test-only
Automated: unit (limiter, token-first order)
Steps: two sessions, user A and user B, both fetching every second. From the IDE container of B, send 60 `curl -m 5` requests to the `git-proxy` Service with the instance name of A (it is in A's IDE URL) and a made-up bearer. Stay below 100 requests per second.
Expect: all 60 answer 401. A's fetches keep working without a failure or delay. The service log shows no rate limit for A's instance.

### GIT-47 Parallel Git requests of one session are capped
Safety: test-only
Automated: unit
Steps: in one session start 30 parallel `git clone` of a large repository (or `curl` with `--limit-rate` on `info/refs`); in another session fetch at the same time.
Expect: some of the 30 fail with "Too many Git requests of this session run at the same time"; the others complete. The other session is not affected. A 429 from the proxy is not reached by Git commands (100 per second per IP).

### GIT-48 Idle transfer is cut, a slow transfer is not
Safety: test-only
Automated: unit
Steps: `curl --limit-rate 10k` an upload-pack of a mid size repository (must keep moving), and a request that sends headers and then nothing for more than 5 minutes.
Expect: the first finishes; the second is cancelled with "The transfer stalled and EduIDE cancelled it".

### GIT-49 Repository path rules
Safety: test-only
Automated: unit (`CanonicalRepo`)
Steps: in the IDE container `curl -s -m 5 -o /dev/null -w '%{http_code}'` the loopback agent path for `info/refs?service=git-upload-pack` of: `<owner>/ft-private.git` (reference), `<owner>/.git/ft-private.git`, `<owner>/../ft-other.git`, `<owner>/ft-private.git.git`, a path with 11 segments, a path with a space or `%2e`.
Expect: the reference gives a Git answer (the credential is used for the session repository). The others give 404 or a Git `ERR` message and never a response with the credential. The git-proxy log has no `ok` line for them.

## Security

### GIT-50 No token in the pod
Safety: test-only
Automated: go `no token, code or state outside the provider and the service`
Steps: in a session with a connected account, in the IDE container: list env names; `git config --list --show-origin`; `cat ~/.git-credentials` if present; `grep -r` the home directory and `/tmp` for the token prefix patterns (`gho_`, `glpat-`, `oauth2:`, `x-access-token`) and print only a count. Repeat in the agent container's env names (`k get pod -o json | jq`).
Expect: count 0; no credential helper that returns a token; only the `insteadOf` entries. The agent container has `AGENT_GIT_PROXY_URL`, `AGENT_GIT_HOSTS`, `AGENT_GIT_LANDING_URL` (URLs and hosts, no token).

### GIT-51 Instance token is not readable in the IDE container
Safety: test-only
Automated: go `no token, code or state outside the provider and the service`
Steps: `k get pod <pod> -o json | jq '[.spec.containers[] | {name, mounts: [.volumeMounts[].mountPath], env: [.env[]?.name]}]'`; in the IDE container list env names and the file system for the token file named in `AGENT_TOKEN_FILE` of the agent.
Expect: only the `agent` container mounts the token Secret; no env name of `ide` holds a token; the token file path does not exist in `ide`.

### GIT-52 Direct call of the proxy without the agent
Safety: test-only
Automated: go (foreign pods) for the network part; unit for the 401
Steps: from the IDE container `curl -m 5 -i` the `git-proxy` Service on 8080 without headers and with a made-up `X-EduIDE-Instance` and bearer.
Expect: 401, no upstream request (no line in the provider's access, the proxy log has `unauthorized`).

### GIT-53 Service internal port from a session pod
Safety: test-only
Automated: go `foreign pods cannot reach git-proxy or the internal port of the service`
Steps: from the IDE container `curl -m 5` the service's internal port 8083 (`/internal/v1/git/authorize`), with the CNI enforcing policies.
Expect: timeout (exit code 28). If it answers, 401 is the second line of defence: record the missing enforcement as a finding.

### GIT-54 Token store content
Safety: prod-safe
Automated: unit (store), go `no token, code or state outside the provider and the service` (leaks)
Steps: `k get secret -l eduide.github.io/component=git-account -o json | jq '[.items[] | {keys: (.data|keys), labels: .metadata.labels, bytes: (.data|map(length)|add)}]'`.
Expect: one opaque blob per Secret; decoding it does not start with `{` (print only that boolean); labels are exactly the component, the provider name and a user hash, never a login or an e-mail address; no `managed-by` label.

### GIT-55 Nothing secret in logs, CRs and traces
Safety: prod-safe
Automated: go `no token, code or state outside the provider and the service`
Steps: grep the logs of service, `git-proxy`, operator and one agent, the `IDESession` objects, the `<session>-git-repos` Secret keys and the session's launch data key names for token prefixes and for the `state` parameter; print counts only.
Expect: 0 everywhere. The launch data Secret has no Git token key.

### GIT-56 Other user's session cannot use my account
Safety: test-only
Automated: go `session without an account`
Steps: user B's session fetches user A's `ft-private`.
Expect: refused with the connect or no-access message. The proxy picks the account by the session owner only.

### GIT-57 Released session loses access at once
Safety: test-only
Automated: go `idle instance cannot use the proxy`
Steps: note the instance of a session, release the session, replay a fetch through a pod that still runs, and from an idle warm pod `curl -m 5 http://127.0.0.1:8082/git/<host>/<repo>/info/refs?service=git-upload-pack`.
Expect: refused (the authorize answer says `not-ready`; the idle pod answers 403 on `/git/`). An idle warm instance has no access to any account.

### GIT-58 Login cookies are HttpOnly and never reach the IDE
Safety: test-only
Automated: go `TestGatewayAuth` (`login cookies are HttpOnly and never reach the IDE`)
Steps: as a logged-in user open a session in the browser pane. In the page context `document.cookie` (names only). `curl -sI https://instance.<env>/<instance>/` without a login and note the `Set-Cookie` attributes of the flow cookies (`OauthNonce`, `CodeVerifier`). In the IDE terminal `env | cut -d= -f1`.
Expect: `document.cookie` lists none of `eduide-id` (or the configured `oidc.idTokenCookie`), `eduide-authz`, `IdToken`, `AccessToken`, `BearerToken`, `RefreshToken`, `OauthHMAC`, `OauthExpires`; the flow cookies carry `HttpOnly` and `Secure`; the IDE sees no `Authorization` header and no login cookie (the agent strips them; check with the `eduide-session` extension's request log, or record `none` as unverified on a real IDE).

### GIT-59 Two OIDC clients
Safety: prod-safe
Automated: none
Steps: `k get cm $P-config -o json | jq -r '.data["config.yaml"]' | yq -o json | jq '. as $c | {clientIDs: $c.oidc.clientIDs, gateway: $c.oidc.gatewayClientID, overlap: (($c.oidc.clientIDs // []) | index($c.oidc.gatewayClientID) != null)}'`; `k get cm eduide-landing-page -o json | jq -r '.data["config.json"]' | jq '.keycloak'` (client id only); `k get securitypolicy $P-session -o json | jq '.spec.oidc.clientID'`. Ask the realm owner (the agent has no Keycloak admin access) to check the Keycloak settings of the install guide: gateway client confidential, standard flow only, exact redirect URIs for the instance and webview callback with no wildcard; landing page client public with PKCE `S256` required and redirect URIs on the service host only; no direct access grants, implicit flow or service accounts; web origins limited to each client's own hosts.
Expect: `overlap` is `false`, the gateway client id differs from the landing page client id and from every entry of `clientIDs`, the SecurityPolicy names the gateway client. Record each Keycloak setting as confirmed by the realm owner or `blocked`. An installation with one client for both is a finding: script in the IDE origin can then obtain an API token.

## Browser extension

### GIT-60 Provider hosts from the installation
Safety: prod-safe
Automated: none
Steps: load the extension, set the EduIDE host, open the options page.
Expect: it lists the providers of `GET /api/v1/status` (`gitProviders`) with the refresh time.

### GIT-61 One click from a provider page
Safety: test-only
Automated: none
Steps: on `ft-private` on each provider host, click the toolbar button. Once disconnected, once connected.
Expect: disconnected: the landing page asks to connect, then starts the session and clones. Connected: the session starts and clones without another step.

## Scorpio in a real IDE

These tests need an IDE image with Scorpio 3.5.0 or later and the `eduide-session` extension that writes the `insteadOf` entries (check `status.image.version` of the template and the extension version in the IDE). The e2e suite uses a fake IDE and covers none of them. If the IDE is older, record `blocked` with the version.

### GIT-90 Insteadof entries come from the extension
Safety: test-only
Automated: go (fake IDE does the same), none for the real extension
Steps: start a session on a provider installation. In the IDE terminal: `git config --global --get-regexp '^url\.'`, and (with the session claimed) `curl -s -m 5 http://127.0.0.1:8082/v1/git/hosts | jq 'keys'`.
Expect: one `insteadOf` entry per configured provider host (`url.http://127.0.0.1:8082/git/<host>/.insteadof https://<host>/`); the host list names the provider hosts and the landing page URL; no token.

### GIT-91 Scorpio shows the remote message with an "Open" button
Safety: test-only
Automated: none
Steps: disconnected, open a start link to `ft-private` with the preflight bypassed (start from a tile and use the Git view to clone the URL), or revoke the account in a running session and fetch in the Git view.
Expect: the refusal message of the provider ("Connect your ... account ...: <landing URL>" or the approval message) is shown in the IDE as a message, and the URL has an "Open" button that opens the landing page (or the approval link). No generic "authentication failed" prompt, no credential dialog.

### GIT-92 "Retry" works after connecting
Safety: test-only
Automated: none
Steps: continue GIT-91: connect (or approve) in another tab, then click "Retry" in the IDE message.
Expect: the clone or fetch succeeds without a restart of the session, within 5 seconds of the connect or approval.

### GIT-93 A restarted session reuses the workspace
Safety: test-only
Automated: none
Steps: session with a persistent workspace from `ft-private`, commit locally, stop the session (release), start it again from the landing page without a link.
Expect: the IDE opens the existing workspace (no second clone, no clone error, local commit still there), `git pull` and `git push` work, `.git/config` shows `https://<host>/...`.

## Exploration

- Branches and tags as `gitRef` once the templates accept `GIT_REF`.
- Submodules that point to another provider host or to a non-provider host (the submodule is read anonymously unless approved).
- A repository renamed or transferred at the provider while a workspace exists (the rule compares against the old URL).
- Two sessions of the same user pushing at the same time.
- Shallow clone, partial clone, `git fetch --unshallow` through the proxy.
- HTTP/2 between proxy and provider, very slow clients, aborted pushes.
- A rotated client secret: restart of the service needed (`kubectl rollout restart`), the connect fails with `git-provider-error` until then.
- A changed encryption key: stored accounts are treated as not connected and deleted on the next use.
- A provider removed from the config: its Secrets stay (the sweep skips them), the tokens stay valid at the host.
- Two providers connected at once in two tabs.

## Unverified, check in the first run

- The exact problem code and status for a foreign session in GIT-76 (`not-found` is listed for the approval endpoints; the e2e subtest `another user and bad requests` checks it, the source was read only for its name).
- Whether the chart rolls the service by itself after a change of `gitAccounts.approval.mode` (GIT-74).
- What the agent answers for an unknown host (GIT-43): the ADR says only provider hosts, the exact status is not stated.
- What Scorpio does with the credentials in an Artemis `GIT_URI` in a real IDE (ADR: not verified).
- The Scorpio behaviour of GIT-91 to GIT-93 (message with "Open", "Retry", workspace reuse): taken from the brief for Scorpio 3.5.0 and EduIDE/scorpio PR 239, not from the control plane sources.
- The rate of the per-user limits (it is the launch rate, `rateLimit.launchesPerMinute`).
- Whether the real extension strips the login cookies as GIT-58 expects in a real IDE (the e2e test checks the fake IDE).
