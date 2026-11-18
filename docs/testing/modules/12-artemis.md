# 12 Artemis integration (ART)

Browser module. **Skipped for now**: every test needs a login on the Artemis test server connected to the environment (test2: `artemis-test2.artemis.cit.tum.de`, from `landingPage.trustedArtemisHosts`). Record all tests as `skipped` with the reason "no Artemis login" until a test account is available; then remove this note in a plan update.

The agent never types Artemis credentials; the user logs in in the browser pane.

Sources: EduIDE-Landing-Page `src/App.tsx` (URL parameters `appDef`, `gitUri`, `artemisToken`, `artemisUrl`, `gitUser`, `gitMail`; auto start only for trusted hosts), scorpio `src/theia/theia.ts`, EduIDE `images/base-artemis/Dockerfile` (Artemis extension, `GRADLE_PREWARM_AUTO_CONFIRM=true`).

### ART-01 Start from Artemis auto-starts
Safety: test-only
Needs: Artemis login, a programming exercise configured for the online IDE.
Steps: in Artemis open the exercise and click the online IDE button.
Expect: the landing page starts the session without a Launch click (both hosts trusted); the repository is cloned (IDE-05 expectations); the Artemis extension is logged in (also in lazy sessions: needs the data bridge in lazy sessions, Cloud 3.0.1).

### ART-02 Submit from the IDE
Safety: test-only
Steps: change a file, submit with the Artemis extension.
Expect: the push succeeds; Artemis shows a new submission and a build result.

### ART-03 Resume the same exercise
Safety: test-only
Steps: end the session, start again from Artemis.
Expect: same workspace, earlier changes kept, no clone over them (IDE-06 warning only if the content differs from the repository).

### ART-04 Gradle prewarm auto-confirm
Safety: test-only
Steps: start a Gradle exercise.
Expect: prewarm runs without a prompt (IDE-08).

### ART-05 Token handling
Safety: test-only
Steps: in the session, check (names only) where the Artemis token lives: `git remote -v | sed 's#//[^@]*@#//<redacted>@#'`; process list of the clone (`ps -ef | grep -c git-credential`).
Expect: the clone used a credential helper (token not in process arguments); the origin URL still carries the token (known decision SC-03, follow-up in the Artemis extension). Never record the token.

## Explore

- Two exercises from Artemis in parallel (session limit, 553 text).
- An expired Artemis token in the link; an exercise from a host that is not trusted.
- Artemis start on a phone-sized viewport.
