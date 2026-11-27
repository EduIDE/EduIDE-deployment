# 12 Artemis integration (ART)

Browser module. **Skipped for now**: every test needs a login on the Artemis test server connected to the environment (test2: `artemis-test2.artemis.cit.tum.de`, listed in `allowedHosts` of `environments/test2.../values.yaml`). Record all tests as `skipped` with the reason "no Artemis login" until a test account is available; then remove this note in a plan update.

The agent never types Artemis credentials; the user logs in in the browser pane.

Sources: control plane `landing-page/src/{App,launch,artemisToken}.ts(x)`, `landing-page/README.md` ("Link parameters"), ADR 0012 (amendment 2026-11-19, repository URLs with credentials), `internal/httpapi/validate.go`; EduIDE-Helm `charts/eduide/templates/ide-templates.yaml` (`gitUriAllowCredentials`); EduIDE `images/base-artemis/Dockerfile` (Artemis extension, `GRADLE_PREWARM_AUTO_CONFIRM=true`).

Facts:
- Artemis opens `$LANDING/?appDef=<template>&gitUri=...&artemisUrl=...` with `#artemisToken=...` (and, with a VCS token in the repository URL, `#gitUri=https://<user>:<vcs-token>@<artemis-host>/git/...`) in the fragment. The landing page moves both fragment values into `sessionStorage` before Keycloak starts, removes them from the address bar and deletes them after the launch. The query forms still work with a deprecation warning.
- The link starts at once when the template exists and is known (`appDef` is the template name; Artemis editions are `listed: false`, so they have no tile). There is no list of trusted Artemis hosts on the landing page: the service accepts `GIT_URI` and `ARTEMIS_URL` only over `https` and only for hosts in `allowedHosts`, and user info in `GIT_URI` only where the template key has `allowCredentials` (test2 and production Artemis editions: `gitUriAllowCredentials: true`).
- The launch data (`GIT_URI`, `ARTEMIS_URL`, `ARTEMIS_TOKEN`, `TEMPLATE`, and `GIT_USER` and `GIT_MAIL` from the token) goes to the launch data Secret and the agent only; `display.source` is the repository URL without user info.

### ART-01 Start from Artemis auto-starts
Safety: test-only
Needs: Artemis login, a programming exercise configured for the online IDE.
Steps: in Artemis open the exercise and click the online IDE button.
Expect: the landing page logs in (silent through Keycloak SSO where possible), starts the session without a click, shows the launch view and opens the IDE; the repository is cloned (IDE-05 expectations); the Artemis extension is logged in (the token arrived through launch data, AGT-02); `k get idesession -o json | jq '.items[-1].spec'` shows `display.source` without user info.

### ART-02 Submit from the IDE
Safety: test-only
Steps: change a file, submit with the Artemis extension.
Expect: the push succeeds; Artemis shows a new submission and a build result.

### ART-03 Resume the same exercise
Safety: test-only
Needs: a link with `persistence=volume` (or an Artemis edition whose default is `volume`); the default of the chart templates is `none`, so without it the exercise starts in a temporary workspace.
Steps: end the session (`k delete idesession <name>`), start again from Artemis with a fresh VCS token in the link.
Expect: the same IDEWorkspace (its name derives from owner, template and the repository URL without credentials, so a new token reattaches the same one), earlier changes kept, no clone over them (IDE-06 warning only if the content differs from the repository). With persistence `none` the files are gone, as the tag said.

### ART-04 Gradle prewarm auto-confirm
Safety: test-only
Steps: start a Gradle exercise.
Expect: prewarm runs without a prompt (IDE-08).

### ART-05 Token handling
Safety: test-only
Steps: after the launch: (a) the address bar and `history.length` entries hold no `artemisToken` or credentials; (b) `Object.keys(sessionStorage)` no longer lists `eduide.artemisToken` and `eduide.gitUri` (names only); (c) `k get secret <session>-data -o json | jq -r '.data|keys[]'` (key names only); (d) in the IDE terminal `git remote -v | sed 's#//[^@]*@#//<redacted>@#'` and `ps -ef | grep -c git-credential`; (e) counts of the token in the operator, service and agent logs (AGT-08 method, with the session's own marker, never print it).
Expect: (a) and (b) clean; (c) holds `ARTEMIS_TOKEN` and `GIT_URI` among the keys; (d) the clone used a credential helper (token not in process arguments); the origin URL may still carry the token (known decision SC-03 of the Java stack, follow-up in the Artemis extension: record what it does now); (e) 0. Never record the token.

### ART-06 Hosts are allowlisted
Safety: test-only
Needs: Artemis login for the positive case; the negative case needs none.
Steps: start from Artemis (host in `allowedHosts`); then open a link with `gitUri` and `artemisUrl` on a host outside the list (LAND-10).
Expect: the Artemis host works; a foreign host is refused with 400 `invalid-input` and the page names it ("Repositories from <host> cannot be opened here."); nothing is created. Record the `allowedHosts` of the environment (PLAT-10).

### ART-07 Artemis editions have no tile
Safety: test-only
Steps: open `$LANDING/` and look for the Artemis editions (`java-17`, `java-25`: `listed: false`); then open `$LANDING/?appDef=java-17`.
Expect: no tile for them (LAND-02) and no entry in the public status as a start tile (it lists all templates with names; the landing page uses `listed`); the link starts the edition by name.

## Unverified, check in the first run

- Everything in this module: no Artemis account was available when the tests were written for the Go stack; the flow is read from the landing page source and ADR 0012.
- ART-05 (d): what the Artemis extension does with the token now (SC-03 on the Java stack).
- ART-03: whether Artemis sends `persistence` in its link; the workspace reattachment rule is from `launch.go` (`workspaceName`).
- ART-01: whether a silent login happens when the Artemis tab and the landing page share the Keycloak realm.

## Explore

- Two exercises from Artemis in parallel: the session limit (`session-limit-reached`, the landing page lists the running environments).
- An expired Artemis token in the link; a token with characters the `Token` format refuses (400 `invalid-input`).
- An exercise from a host that is not allowed; a `gitUri` with a query or fragment in it (`display.source` refuses both).
- Artemis start on a phone-sized viewport.
- The deprecated query forms (`?artemisToken=`, `?gitUri=` with credentials): are they moved out of the address bar too?
