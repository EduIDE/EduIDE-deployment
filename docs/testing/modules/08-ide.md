# 08 IDE per language and template (IDE)

Browser module, test environments only. Each test launches a standalone app from the landing page (module 02) or through the service API with a `GIT_URI` (module 03 helper `api`), and works inside the IDE in the browser pane. Keep the IDE tab visible: in a hidden or background tab the IDE can take minutes to connect, and the template is only applied once it does (rc.1 finding 6).

Sources: EduIDE `images/<lang>/templates/<id>/{template.json,.vscode/tasks.json}`, `images/base-ide/package.json.patch` (pinned scorpio, data bridge, monitor), `images/base-artemis/Dockerfile` (`GRADLE_PREWARM_AUTO_CONFIRM=true`), `theia-extensions/customization/` (levels), `theia-extensions/product/` (Help > Report Issue), `scripts/smoke-test-image.sh`; scorpio `src/theia/{theia,env-strategy,progress}.ts`, `src/participation/gradle.service.ts`, `src/theia/template.service.ts`.

## Template matrix

Run IDE-01 for each row the environment offers (the catalog differs per environment; record which rows ran). Task names are from each template's `.vscode/tasks.json`; run them with Terminal > Run Task (or the Run button at Beginner level, which runs the default build task).

| App | Template id | Tasks and the command they run | Expected result |
|---|---|---|---|
| java-17/25-standalone | `maven` | Run `mvn compile exec:java ...`, Build `mvn compile`, Test `mvn test` | program output, BUILD SUCCESS, tests pass |
| java-17/25-standalone | `gradle` | Run `./gradlew run`, Build `./gradlew build`, Test `./gradlew test` | as above |
| python-standalone | `python` | Run `python -m example.main`, Test `pytest`, Lint `ruff check` | output, `1 passed`, ruff clean; `import numpy, pandas, matplotlib` works |
| javascript-standalone | `node` | Run `tsx src/index.ts`, Build `tsc`, Test `tsx --test "test/**/*.test.ts"` | output, no tsc errors, tests pass |
| javascript-standalone | `web` | Start `tsc --watch` (default), Build `tsc` | compiles; preview in IDE-04 |
| c-standalone | `make` | Run `make run`, Build `make build`, Valgrind | greeting printed, no leaks reported |
| c-standalone | `bazel` | Run `bazel run //:app`, Build, Valgrind | as above (needs network) |
| rust-standalone | `cargo` | Run, Build, Test, Clippy | output, tests pass, clippy clean |
| go-standalone | `go` | Run `go run .`, Build, Test `go test ./...`, Vet | output, tests pass, vet clean |

### IDE-01 Template applied and tasks work (one run per matrix row)
Safety: test-only
Steps:
1. Launch the app, choose the build system if a picker appears.
2. Wait for the IDE; check the Explorer shows the template files and the status bar shows "Saved workspace" or "Temporary workspace" matching the landing page badge.
3. Run every task of the template from Terminal > Run Task.
Expect: the template is in the workspace within a minute of the IDE opening; every task ends with the expected result above and exit code 0; EduIDE branding in the title and About dialog; the About dialog version matches the image tag from PLAT-01.
Cleanup: stop the session (API-05 or `k delete session`).

### IDE-02 Experience levels
Safety: test-only
Steps: in one session open the level menu (status bar `🎓 <level>`, or View > Experience Level...) and switch Beginner, Advanced, Expert.
Expect:
- Expert is the default for a new session (known: the level resets on every new session, rc.1 finding 7).
- Beginner: menu bar File, Edit, Help (plus the level menu); only Explorer, Search and (Artemis) the Artemis view; one Run button; no terminal, no "Open new Terminal" or "Open Version Control" links on any start page (rc.1 finding 5).
- Advanced: adds Source Control, Testing, build tool views, terminal, Output; no debugger.
- Expert: stock IDE with debugger, Outline, all tasks, Welcome page.
- The switch applies immediately, without reload.

### IDE-03 Persistence across restart (Saved apps)
Safety: test-only
Steps: in a Saved session create `ft-persist.txt` with some text and change a template file; end the session (`k delete session <name>`); relaunch the same app from the landing page (or "Resume my session").
Expect: the same Workspace is used; both changes are there; the template is not applied again over them (a non-empty workspace is left alone). For a Temporary app the files are gone after relaunch, as the badge promised.

### IDE-04 Web preview
Safety: test-only
Steps: javascript-standalone with `web`; run Start; open `index.html`; "Open Preview to the Side" (or right click > Open With > Preview); change the text in `index.html`, save, reload the preview.
Expect: the preview loads from `https://<uuid>.webview.instance.$ENV` with a valid certificate; it shows the page; after a manual reload it shows the change (it does not refresh by itself).

### IDE-05 Clone from GIT_URI into an empty workspace
Safety: test-only
Needs: browser token (README); a small public repository (record which).
Steps: `await api('POST','/service',{kind:'launchRequest',appId:theiaCloudConfig.serviceAuthToken,appDefinition:'<APP_STD>',ephemeral:true,env:{fromMap:{THEIA:'true',GIT_URI:'<public repo .git URL>'}}})`, open the returned URL.
Expect: the repository is cloned into the workspace; git user and email are set (`git config user.email` in a terminal: `GIT_MAIL` or `<user>@artemis-theia.de`). With scorpio 3.1.0 or later in the image: a "Preparing your workspace" notification shows the steps "Waiting for your exercise details", "Checking your workspace", "Cloning <repo>". With scorpio 3.0.0 (EduIDE 2.0.0-rc.3 pins 3.0.0): no progress notification; record which version the image has (`ls /home/theia/plugins` or the Extensions view).

### IDE-06 Non-empty workspace warning
Safety: test-only
Needs: browser token.
Steps: launch a persistent session (no `GIT_URI`), add a file, end it; relaunch the same workspace with `workspaceName` and `GIT_URI` set.
Expect: no clone; a warning "The exercise was not cloned because this workspace already contains files. Empty the workspace or start a new one to get the exercise."; no Gradle prewarm runs; existing files untouched.

### IDE-07 Gradle prewarm prompt (standalone)
Safety: test-only
Needs: browser token; a small public repository with a Gradle wrapper (`gradlew`) (record which).
Steps: launch a standalone Java app (not a template) with that repository as `GIT_URI`.
Expect: after the clone a prompt "Scorpio can pre-build this exercise with its Gradle wrapper ... Only continue for exercises you trust." with one button "Pre-build now"; dismissing it runs nothing; clicking it shows "Preparing Gradle in the background". A template session (no `GIT_URI`) never shows the prompt.

### IDE-08 Gradle prewarm in the Artemis edition
Safety: test-only
Steps: as IDE-07 with the Artemis edition app (`java-17` with chart 3.x; it is hidden from the landing page, launch via `api`).
Expect: no prompt; prewarm starts by itself (`GRADLE_PREWARM_AUTO_CONFIRM=true` from the image env, never from the bridge).

### IDE-09 Help and extensions
Safety: test-only
Steps: Help > Report Issue; Extensions view.
Expect: Report Issue opens `https://github.com/eduide/eduide/issues`; standalone images have scorpio, the data bridge and the monitor, no Artemis extension; Artemis images also have the Artemis extension.

## Explore

- Run a task at Beginner level that needs a terminal: what does the student see?
- Large output (a test that prints 100k lines), an infinite loop in Run: can the student stop it, does the session stay responsive?
- Disk full in the workspace (`fallocate` a large file in a Temporary session): which message, does the IDE survive?
- Two browser tabs on the same session: do both work, does the clone run once ("Another window is cloning the exercise")?
- Copy and paste, file upload and download in the Explorer; download of the whole workspace for a Temporary session.
- Offline-sensitive templates: `bazel`, `maven` and `gradle` need network; do the others really work without it?
