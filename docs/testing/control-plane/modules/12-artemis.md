# 12 Artemis integration (ART)

Browser module. **Skipped for now**: every test needs a login on the Artemis test server connected to the deployment (its host must be in `config.allowedHosts`, and Artemis must send the token in the URL fragment, G16). Record all tests as `skipped` with the reason "no Artemis login" until a test account is available; then remove this note in a plan update.

The agent never types Artemis credentials; the user logs in in the browser pane. Never record a token.

Sources: landing page URL handling (`appDef` or `template`, `gitUri`, `title`, fragment `#artemisToken=...`; decision G16), `IDETemplate.spec.injectableKeys` (`ARTEMIS_URL` HTTPSURL, `ARTEMIS_TOKEN` Token, `GIT_URI`), ADR 0012, scorpio `src/theia/theia.ts`, EduIDE `images/base-artemis/Dockerfile`.

### ART-01 Start from Artemis auto-starts without an existing login
Safety: test-only
Needs: Artemis login, a programming exercise configured for the online IDE, a browser without a Keycloak session.
Steps: in Artemis open the exercise and click the online IDE button (the link carries `gitUri`, optional `title`, and the token in the fragment).
Expect: the landing page reads the fragment first, stores the token in `sessionStorage`, removes it from the address bar, logs in through Keycloak, then starts the session without a launch click (host trusted); the repository is cloned (IDE-05 expectations); the Artemis extension is logged in (the token reached the IDE through the agent, not through env); the entry in `sessionStorage` is gone after the launch; the overview title is the `title` parameter or derived from `gitUri`.

### ART-02 Submit from the IDE
Safety: test-only
Steps: change a file, submit with the Artemis extension.
Expect: the push succeeds; Artemis shows a new submission and a build result.

### ART-03 Resume the same exercise
Safety: test-only
Steps: stop the session, start again from Artemis (same exercise, same user).
Expect: the same workspace is used (its name `w-<hash of owner, template, source>` is deterministic and get-or-create), earlier changes kept, no clone over them (IDE-06 warning only if the content differs), launch is idempotent while a session runs (the second click opens the running session).

### ART-04 Gradle prewarm auto-confirm
Safety: test-only
Steps: start a Gradle exercise.
Expect: prewarm runs without a prompt (IDE-08).

### ART-05 Token handling
Safety: test-only
Steps: in the session, check (names only) where the Artemis token lives: `git remote -v | sed 's#//[^@]*@#//<redacted>@#'`; process list of the clone (`ps -ef | grep -c git-credential`); then from the shell: SEC-14's checks with the exercise's token held in a shell variable (never printed): `k get pod <p> -o yaml | grep -c "$TOK"`, operator, service, authz and agent logs, Jaeger spans, the IDESession (all expected 0); the data Secret holds it and nothing else does.
Expect: the clone used a credential helper (token not in process arguments); the origin URL may still carry the token (known decision SC-03 of the old audit, follow-up in the Artemis extension); the control plane never logs it and never puts it into the session spec, status, pod spec, traces or metrics. Never record the token.

### ART-06 Legacy query token is deprecated
Safety: test-only
Steps: open the exercise link with `?artemisToken=...` instead of the fragment (while the migration allows it), with the browser console open.
Expect: it still works during the migration and the landing page logs a deprecation message (decision G16); the token is removed from the address bar the same way. Record when the legacy form is switched off.

## Explore

- Two exercises from Artemis in parallel: the session limit (`session-limit-reached` with the list) and what the student sees.
- An expired Artemis token in the link; an exercise from a host that is not in `allowedHosts` (the launch is refused with 400, API-10).
- A very long `title` (200 characters) and markup in it.
- Artemis start on a phone-sized viewport.
