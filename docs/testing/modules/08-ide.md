# 08 IDE per language and template (IDE)

Browser module, test environments only. Each test launches a standalone template from the landing page (module 02) or through the REST API with a `GIT_URI` (module 03 helper `api`), and works inside the IDE in the browser pane. Keep the IDE tab visible: in a hidden or background tab the IDE can take minutes to connect, and the project template is only applied once it does (rc.1 finding 6, Java stack; the cause is the IDE, not the control plane). The control plane's part (launch data, agent) is module 06; this module checks what happens inside the IDE.

Sources: EduIDE `images/<lang>/templates/<id>/{template.json,.vscode/tasks.json}`, `images/base-ide/package.json.patch` (pinned scorpio and the `eduide-session` extension), `images/base-artemis/Dockerfile` (`GRADLE_PREWARM_AUTO_CONFIRM=true`), `theia-extensions/customization/` (levels), `theia-extensions/product/` (Help > Report Issue), `scripts/smoke-test-image.sh`; control plane `extensions/eduide-session/` (the extension that replaces the data bridge and the monitor, commands `dataBridge.getEnv` and `dataBridge.getEnvState` unchanged), `docs/architecture/data-model.md`; scorpio `src/theia/{theia,env-strategy,progress}.ts`, `src/participation/gradle.service.ts`, `src/theia/template.service.ts`.

## Template matrix

Run IDE-01 for each row the environment offers (the templates differ per environment; record which rows ran). Task names are from each template's `.vscode/tasks.json`; run them with Terminal > Run Task (or the Run button at Beginner level, which runs the default build task). When running a task's command outside the IDE, apply its `options.env` too (python Run needs `PYTHONPATH=src`).
In a hidden browser pane the IDE needs about two minutes to become ready and the template waits for it: keep the tab in the foreground, and poll the pod (`ls -A /home/project`) rather than the UI.

| Template | Project template id | Tasks and the command they run | Expected result |
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
1. Launch the template from its tile and pick the project template in the dialog ("Pick a project template"), or start it with `data.TEMPLATE=<id>` through the API.
2. Wait for the IDE; check the Explorer shows the template files and the status bar shows "Saved workspace" or "Temporary workspace" matching the tile's tag ("Saved workspace" or "Temporary workspace", LAND-02).
3. Run every task of the template from Terminal > Run Task.
Expect: the template is in the workspace within a minute of the IDE opening; every task ends with the expected result above and exit code 0; EduIDE branding in the title and About dialog; the About dialog version matches the image tag from PLAT-01.
Cleanup: stop the session (API-05 or `k delete idesession <name>`).

### IDE-02 Experience levels
Safety: test-only
Steps: in one session open the top-level "Experience Levels" menu (the status bar shows the level name) and switch Beginner, Advanced, Expert.
Expect:
- Expert is the default for a new session (known: the level resets on every new session, rc.1 finding 7).
- Beginner: menu bar File, Edit, View, Experience Levels, Help; only Explorer, Search and (Artemis) the Artemis view; one Run button in the editor title bar (shown only with a file open; it runs the default task); no terminal, no "Open new Terminal" or "Open Version Control" links on any start page (rc.1 finding 5).
- Advanced: adds the Selection, Go and Terminal menus, Source Control, Testing, build tool views, Output; no Run menu, no debugger.
- Expert: stock IDE with the Run menu, debugger and Debug Console, Outline, all tasks, Welcome page.
- The switch applies immediately, without reload.

### IDE-03 Persistence across restart (saved workspaces)
Safety: test-only
Steps: start a template with a saved workspace (`$LANDING/?appDef=<TPL_STD>&persistence=volume`, LAND-04); create `ft-persist.txt` with some text and change a template file; end the session without deleting the workspace (`k delete idesession <name>`; the row button "Delete" would delete the files); start the workspace again from its row in "Your environments" (LAND-05).
Expect: the same IDEWorkspace is used; both changes are there; the template is not applied again over them (a non-empty workspace is left alone). For a temporary session (persistence `none`) the files are gone after a new start, as the tag promised.

### IDE-04 Web preview
Safety: test-only
Steps: javascript-standalone with project template `web`; run Start; open `index.html`; "Open Preview to the Side" (or right click > Open With > Preview); change the text in `index.html`, save, reload the preview.
Expect: the preview loads from the fixed webview host `https://webview.instance.$ENV/...` (no wildcard and no per-preview subdomain on the Go stack; the gateway route matches the session's instance path) with a valid certificate; it shows the page; after a manual reload it shows the change (it does not refresh by itself).

### IDE-05 Clone from GIT_URI into an empty workspace
Safety: test-only
Needs: browser token (README); a small public repository on an allowed host (`allowedHosts`, PLAT-10; record which).
Steps: `await api('POST','/sessions',{template:'<TPL_STD>',persistence:'none',data:{GIT_URI:'<public repo .git URL>'}})`, wait for `Ready` (API-03) and open the returned URL; or open `$LANDING/?appDef=<TPL_STD>&gitUri=<URL>`.
Expect: the repository is cloned into the workspace; git user and email are set from the token (`GIT_USER`, `GIT_MAIL` are keys with source `UserName` and `UserEmail`; `git config user.email` in a terminal shows the account's address, never a made-up one). A "Preparing your workspace" notification shows the steps "Waiting for your exercise details", "Checking your workspace", "Cloning <repo>" (scorpio 3.1.0 or later; record the version from the Extensions view or `k get idetemplate <TPL_STD> -o jsonpath='{.status.image.includes}'`, test2 shows Scorpio 3.3.0). A host outside `allowedHosts` never starts (API-09).

### IDE-06 Non-empty workspace warning
Safety: test-only
Needs: browser token.
Steps: launch a session with a saved workspace (`persistence:'volume'`, no `GIT_URI`), add a file, end it (`k delete idesession <name>`); relaunch on the same workspace with `{template:'<TPL_STD>',workspace:'<w-...>',data:{GIT_URI:'<URL>'}}`.
Expect: no clone; a warning "The exercise was not cloned because this workspace already contains files. Empty the workspace or start a new one to get the exercise."; no Gradle prewarm runs; existing files untouched.

### IDE-07 Gradle prewarm prompt (standalone)
Safety: test-only
Needs: browser token; a small public repository with a Gradle wrapper (`gradlew`) on an allowed host (record which).
Steps: launch a standalone Java template (no project template) with that repository as `GIT_URI` (as IDE-05).
Expect: after the clone a prompt "Scorpio can pre-build this exercise with its Gradle wrapper ... Only continue for exercises you trust." with one button "Pre-build now"; dismissing it runs nothing; clicking it shows "Preparing Gradle in the background". A session started from a project template (no `GIT_URI`) never shows the prompt.

### IDE-08 Gradle prewarm in the Artemis edition
Safety: test-only
Steps: as IDE-07 with the Artemis edition template (`java-17`; `listed: false`, so launch it through the API or a link `?appDef=java-17`).
Expect: no prompt; prewarm starts by itself (`GRADLE_PREWARM_AUTO_CONFIRM=true` from the image env, never from launch data: it is not on any template's allowlist).

### IDE-09 Help and extensions
Safety: test-only
Steps: Help > Report Issue; Extensions view.
Expect: Report Issue opens `https://github.com/eduide/eduide/issues`; standalone images have scorpio and the `EduIDE Session` extension (no data bridge extension and no monitor extension any more), no Artemis extension; Artemis images also have the Artemis extension (test2: `Artemis - TUM`, `EduIDE Session`, `Scorpio` in `status.image.includes` of `java-17`).

## Unverified, check in the first run

- IDE-01 to IDE-09 were written for the Java stack and kept where the IDE behaviour does not depend on the control plane. Re-check each expectation once on the Go stack, especially: the status bar text for saved and temporary workspaces (the IDE derives it from the mounted workspace volume), the template being applied once launch data arrives through the extension, and the About dialog version against `status.image.version`.
- Whether the Run button, task names and EduIDE branding are unchanged in images 3.0.x (not read from the EduIDE repository for this rewrite).
- IDE-05: the exact git identity fallback when the token has no e-mail claim.
- IDE-04: how the webview URL is built on the fixed host and whether the preview loads (`hosts.webview`; cookie domain covers instance and webview host); written from `docs/architecture/overview.md`.
- Which version of the extension `eduide-session` the images carry (test2 shows 0.1.0).

## Explore

- Run a task at Beginner level that needs a terminal: what does the student see?
- Large output (a test that prints 100k lines), an infinite loop in Run: can the student stop it, does the session stay responsive?
- Disk full in the workspace (`fallocate` a large file in a Temporary session): which message, does the IDE survive?
- Two browser tabs on the same session: do both work, does the clone run once ("Another window is cloning the exercise")?
- Copy and paste, file upload and download in the Explorer; download of the whole workspace for a Temporary session.
- Offline-sensitive templates: `bazel`, `maven` and `gradle` need network; do the others really work without it?
