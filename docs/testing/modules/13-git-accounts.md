# 13 Git accounts (GIT)

Server and browser module. A student connects a GitHub or GitLab account once on the landing page. The token stays in the control plane. Git in the session pod reaches a provider host through the agent (loopback) and the `git-proxy` Deployment, which adds the token. Design: `EduIDE-control-plane` ADR 0023.

Sources: EduIDE-control-plane `internal/gitaccount`, `cmd/git-proxy`, `internal/agent`, `landing-page`, `extensions/eduide-session`, chart `eduide-control-plane` (`gitAccounts`, NetworkPolicies), `test/e2e/gitaccounts_test.go`.

Facts:
- The feature is on only when `config.gitAccounts.providers` has at least one entry. Without providers the chart renders no `git-proxy` and every test in "Feature off" must pass.
- One Secret per user and provider, name `git-account-<hash>`, value encrypted. Only the service reads it.
- The IDE container holds no Git token and no instance token. Its global Git config maps `https://<provider host>/` to `http://127.0.0.1:8082/git/<provider host>/`.
- Push rule: fetch and clone for every repository the user can read; push only to the repository the session was started with.
- The proxy serves Git smart HTTP only: `info/refs`, `git-upload-pack`, `git-receive-pack`. No LFS, no platform API.
- A provider host counts as an allowed `GIT_URI` host.
- The automated e2e suite (`make e2e` in EduIDE-control-plane) covers GIT-10 to GIT-45 against a fake provider. This module repeats the important ones on a deployed installation with real providers, and adds what only a real environment shows.

Preconditions for the "real provider" tests: OAuth apps registered for this installation (admin guide in the Docs), a test account on each provider with one private repository `ft-private`, one public repository `ft-public`, and a second private repository `ft-other`. The user logs in to the provider in the browser pane; the agent never types a password.

Never print or record a token, the `state`, a cookie, or the decrypted content of a `git-account-` Secret. Evidence is status codes, key names, counts and hashes.

## Feature off (regression)

### GIT-01 No providers: nothing changes
Safety: prod-safe
Steps: on an installation without `gitAccounts.providers`: `k get deploy,svc,networkpolicy -l app.kubernetes.io/component=git-proxy`; `GET /api/v1/git/providers` with a user token; `GET /api/v1/status`.
Expect: no `git-proxy` objects; the provider list is empty; `status` has no `gitProviders` or an empty list; the landing page shows no "Connect" entry.

### GIT-02 Start link to a public repository still works
Safety: test-only
Steps: open `/?appDef=<standalone template>&gitUri=https://github.com/<public repo>.git` as a logged-in user.
Expect: the session starts and Scorpio clones into the workspace root, exactly as before the feature (module 08 result for the same template is the reference).

### GIT-03 Artemis launch still works
Safety: test-only
Steps: module 12 ART tests, or the Playwright `artemis-launch` spec of the control plane e2e suite against this installation.
Expect: unchanged. The Artemis host is not a provider, so its clone does not pass the proxy.

### GIT-04 Session pod without the feature
Safety: prod-safe
Steps: in a running session pod (IDE container): `git config --global --get-regexp '^url\.'`.
Expect: no `insteadOf` entry for a provider host when no provider is configured.

## Configuration and deployment

### GIT-10 Objects of the feature
Safety: prod-safe
Steps: with one provider configured: `k get deploy,svc,pdb,networkpolicy -l app.kubernetes.io/component=git-proxy`; `k get secret -l eduide.github.io/git-account` (names and count only).
Expect: `git-proxy` Deployment with 2 ready replicas and a PodDisruptionBudget; a ClusterIP Service; no HTTPRoute or Ingress for it; the encryption key Secret exists.

### GIT-11 Proxy is not reachable from outside or from foreign pods
Safety: test-only
Steps: from outside the cluster request `https://<service host>/git/github.com/`; from an `ft-` pod without session labels in the namespace, `curl` the `git-proxy` Service and the service's internal port.
Expect: outside: 404 from the landing page or API, never a Git answer. Foreign pod: connection refused or timeout on both.

### GIT-12 Invalid provider config is refused
Safety: test-only, disruptive
Steps: `helm template` (dry run, no install) with a duplicate provider name, an unknown `type`, and a host with a path.
Expect: schema or config validation fails with a message that names the field. Nothing is installed.

## Connect and disconnect

### GIT-20 Connect (real provider)
Safety: test-only
Steps: landing page, "Connect GitHub" (and each GitLab provider). The user consents at the provider.
Expect: back on the landing page the provider shows as connected with the account login; one new `git-account-` Secret; the service log has one line for the connect without code, state or token.

### GIT-21 Connect resumes a pending launch
Safety: test-only
Steps: disconnected, open a start link to `ft-private`.
Expect: the landing page says the repository needs a connected account (it names both "not found" and "no access"), offers "Connect", and after the consent starts the session without opening the link again. The repository is cloned.

### GIT-22 Callback rejects a foreign flow
Safety: test-only
Steps: start a connect in browser profile A, copy the provider's redirect back (callback URL with `code` and `state`) into profile B that is logged in as another user.
Expect: the callback redirects to the landing page with an error; no Secret is created for either user. Do not record the URL.

### GIT-23 Callback rejects a tampered or expired state
Safety: test-only
Steps: call the callback with a changed `state`, and again with a valid one after its 10 minute lifetime.
Expect: redirect to the landing page with an error, no Secret, no provider call (service log).

### GIT-24 Disconnect
Safety: test-only
Steps: "Disconnect" on the landing page.
Expect: the Secret is gone; the provider's settings page no longer lists the EduIDE authorization (user checks in the browser pane); a running session's next private fetch fails with the connect message.

### GIT-25 Revocation at the provider
Safety: test-only
Steps: connected, revoke the authorization in the provider's settings, then fetch a private repository in a session.
Expect: the fetch fails with the connect message; the Secret is deleted; the landing page shows "Connect" again.

### GIT-26 Inactivity expiry
Safety: test-only, disruptive
Steps: set `inactivityExpiry` of one provider to a short value on the test environment, connect, wait, trigger or wait for the sweep, restore the value.
Expect: the account is revoked and deleted; an account used within the window stays.

## Clone, fetch and push in a session

### GIT-30 Private clone by start link
Safety: test-only
Steps: connected, open a start link to `ft-private`.
Expect: Scorpio clones into the workspace root without any prompt.

### GIT-31 Clone in the terminal
Safety: test-only
Steps: in the session terminal: `git clone https://<host>/<user>/ft-other.git /tmp/o`.
Expect: works without a prompt (fetch is allowed for every repository the user can read).

### GIT-32 Push to the session repository
Safety: test-only
Steps: in the session of GIT-30 commit a file and `git push`; also push with the Git view of the IDE.
Expect: both succeed; the commit shows on the provider under the student's account; the `git-proxy` log has one push line (user hash, session, provider, repository, result) and no token.

### GIT-33 Push to another repository is refused
Safety: test-only
Steps: in `/tmp/o` of GIT-31 commit and `git push`.
Expect: refused with a message that states the rule and what to do; `ft-other` is unchanged on the provider; one deny line in the log.

### GIT-34 Session without a repository cannot push
Safety: test-only
Steps: start a session without `gitUri`, clone `ft-private` in the terminal, commit, push.
Expect: clone works, push is refused with the rule message.

### GIT-35 Connect inside a running session
Safety: test-only
Steps: disconnected, start a session without `gitUri`; `git clone` of `ft-private` fails with the connect message; connect on the landing page in another tab; repeat the clone.
Expect: the second clone works without a restart.

### GIT-36 Public repositories without an account
Safety: test-only
Steps: disconnected, clone `ft-public` and any public repository of another owner in the terminal.
Expect: works (anonymous pass-through).

### GIT-37 Workspace reattach
Safety: test-only
Steps: session with a saved workspace on `ft-private`, stop it, start it again from the landing page (no link), `git pull` and `git push`.
Expect: both work; `.git/config` still has `https://<host>/...` as the remote URL.

### GIT-38 Commit identity
Safety: test-only
Steps: in the session of GIT-30: `git config user.name`, `git config user.email`. In an Artemis session and in a session with a public repository and no account: the same.
Expect: provider session with account: account name and the platform's no-reply address. Otherwise: name and e-mail of the EduIDE login, as before.

### GIT-39 Large repository
Safety: test-only
Steps: clone a repository of several hundred MB through the proxy; watch `git-proxy` memory (`k top pod`).
Expect: the clone finishes; memory stays flat (streaming, no buffering).

### GIT-40 Token refresh during a long session (GitLab)
Safety: test-only
Steps: connected to a GitLab provider, keep a session open past the access token lifetime (2 hours), then fetch and push.
Expect: both work without a new consent. Two parallel fetches right after the expiry both succeed (refresh lock).

## Limits and errors

### GIT-41 LFS is refused with a clear message
Safety: test-only
Steps: clone a repository that uses Git LFS.
Expect: the Git objects clone; the LFS download fails with a message that names the limitation. No credential appears in the pod.

### GIT-42 Platform API is not proxied
Safety: test-only
Steps: in the IDE container: `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8082/git/<host>/api/v4/user` (GitLab) or `/git/api.github.com/user`.
Expect: 403 or 404, never account data.

### GIT-43 Unknown host is not proxied
Safety: test-only
Steps: `curl` `http://127.0.0.1:8082/git/example.org/x.git/info/refs?service=git-upload-pack` in the IDE container.
Expect: refused. The proxy opens no connection to a host that is not a provider (proxy log).

### GIT-44 Proxy outage
Safety: test-only, disruptive
Steps: scale `git-proxy` to 0, try a public and a private clone in a session, scale back.
Expect: both fail with a clear message; sessions, the IDE and Artemis clones keep working; after the scale-up Git works again without a session restart.

## Security

### GIT-50 No token in the pod
Safety: test-only
Steps: in a session with a connected account, in the IDE container: list env names; `git config --list --show-origin`; `cat ~/.git-credentials` if present; `grep -r` the home directory and `/tmp` for the account login's token prefix patterns (`gho_`, `glpat-`, `oauth2:`) and print only a count.
Expect: count 0; no credential helper that returns a token; only the `insteadOf` entries.

### GIT-51 Instance token is not readable in the IDE container
Safety: test-only
Steps: in the IDE container try to read `/var/run/eduide/token` and list the env names.
Expect: the file does not exist in that container; no env name holds the token.

### GIT-52 Direct call of the proxy without the agent
Safety: test-only
Steps: from the IDE container `curl` the `git-proxy` Service directly, without and with a made-up bearer.
Expect: 401, no upstream request.

### GIT-53 Service internal port from a session pod
Safety: test-only
Steps: from the IDE container `curl` the service's internal port.
Expect: timeout or refused (NetworkPolicy).

### GIT-54 Token store content
Safety: prod-safe
Steps: `k get secret -l eduide.github.io/git-account -o json | jq '[.items[] | {keys: (.data|keys), labels: .metadata.labels, bytes: (.data|map(length)|add)}]'`.
Expect: one opaque blob per Secret; decoding it does not start with `{` (print only that boolean); labels carry the provider name and a user hash, never a login or an e-mail address.

### GIT-55 Nothing secret in logs, CRs and traces
Safety: prod-safe
Steps: grep the logs of service, `git-proxy`, operator and one agent, the `IDESession` objects and the session's launch data key names for token prefixes and for the `state` parameter; print counts only.
Expect: 0 everywhere. The launch data Secret has no Git token key.

### GIT-56 Other user's session cannot use my account
Safety: test-only
Steps: user B's session fetches user A's `ft-private`.
Expect: refused with the connect or no-access message. The proxy picks the account by the session owner only.

### GIT-57 Released session loses access at once
Safety: test-only
Steps: note the instance of a session, release the session, replay a fetch through a pod that still runs (or the agent of a warm pod claimed by nobody).
Expect: refused. An idle warm instance has no access to any account.

## Browser extension

### GIT-60 Provider hosts from the installation
Safety: prod-safe
Steps: load the extension, set the EduIDE host, open the options page.
Expect: it lists the providers of `GET /api/v1/status` with the refresh time.

### GIT-61 One click from a provider page
Safety: test-only
Steps: on `ft-private` on each provider host, click the toolbar button. Once disconnected, once connected.
Expect: disconnected: the landing page asks to connect, then starts the session and clones. Connected: the session starts and clones without another step.

## Exploration

- Branches and tags as `gitRef` once the templates accept `GIT_REF`.
- Submodules that point to another provider host or to a non-provider host.
- A repository renamed or transferred at the provider while a workspace exists (push rule compares against the old URL).
- Two sessions of the same user pushing at the same time.
- Shallow clone, partial clone, `git fetch --unshallow` through the proxy.
- HTTP/2 between proxy and provider, very slow clients, aborted pushes.
