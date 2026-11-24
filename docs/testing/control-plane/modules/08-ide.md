# 08 IDE per language and template (IDE)

Browser module, test environments only. Each test launches a template from the landing page (module 02) or through the API with data (module 03 helper `api`), and works inside the IDE in the browser pane. Keep the IDE tab visible: in a hidden or background tab the IDE can take minutes to connect, and the template is only applied once it does.

Sources: EduIDE `images/<lang>/templates/<id>/{template.json,.vscode/tasks.json}`, `images/base-ide/package.json.patch` (pinned scorpio and `eduide-session`), EduIDE-c-makefile experimental pull request (decision U8: `eduide-session` replaces the data bridge and the monitor, fixed webview host per G3, `THEIA_WEBVIEW_EXTERNAL_ENDPOINT` and `THEIA_MINI_BROWSER_HOST_PATTERN` in the images, `scripts/smoke-test-image.sh`); scorpio `src/theia/{theia,env-strategy,progress}.ts`, `src/participation/gradle.service.ts`; control plane `extensions/eduide-session`.

Differences from the old stack that matter here: the launch data reaches the IDE through the agent (long-poll on `127.0.0.1:8082`), not through a data bridge server; the IDE sits behind the gateway (OIDC cookie plus authz) and the agent proxy, not behind oauth2-proxy; webviews and the mini browser use the one host `$WEBVIEW_HOST`, path-routed under `/<instance>/`.
Test images come from the PR tags of the image repository: record the tag per template (`k get idetemplates -o custom-columns=NAME:.metadata.name,IMAGE:.spec.image`).

## Template matrix

Run IDE-01 for each template the deployment offers (record which rows ran). Task names are from each template's `.vscode/tasks.json`; run them with Terminal > Run Task. When running a task's command outside the IDE, apply its `options.env` too.
In a hidden browser pane the IDE needs about two minutes to become ready: keep the tab in the foreground, and poll the pod (`k exec $POD -c ide -- ls -A /home/project`) rather than the UI.

| Template (build system `TEMPLATE`) | Tasks and the command they run | Expected result |
|---|---|---|
| java 17/25: `maven` | Run `mvn compile exec:java ...`, Build `mvn compile`, Test `mvn test` | program output, BUILD SUCCESS, tests pass |
| java 17/25: `gradle` | Run `./gradlew run`, Build `./gradlew build`, Test `./gradlew test` | as above |
| python: `python` | Run `python -m example.main`, Test `pytest`, Lint `ruff check` | output, `1 passed`, ruff clean; `import numpy, pandas, matplotlib` works |
| javascript: `node` | Run `tsx src/index.ts`, Build `tsc`, Test `tsx --test "test/**/*.test.ts"` | output, no tsc errors, tests pass |
| javascript: `web` | Start `tsc --watch` (default), Build `tsc` | compiles; preview in IDE-04 |
| c: `make` | Run `make run`, Build `make build`, Valgrind | greeting printed, no leaks reported |
| c: `bazel` | Run `bazel run //:app`, Build, Valgrind | as above (needs network) |
| rust: `cargo` | Run, Build, Test, Clippy | output, tests pass, clippy clean |
| go: `go` | Run `go run .`, Build, Test `go test ./...`, Vet | output, tests pass, vet clean |

### IDE-01 Template applied and tasks work (one run per matrix row)
Safety: test-only
Steps:
1. Launch the template from the landing page, choose the build system if a picker appears (the picker sends `data.TEMPLATE`).
2. Wait for the IDE; check the Explorer shows the template files and the status bar shows "Saved workspace" or "Temporary workspace" matching the badge.
3. Run every task of the template from Terminal > Run Task.
4. `k exec $POD -c ide -- sh -c 'git config user.name; git config user.email'` (name only, mail is the test user's).
Expect: the template is in the workspace within a minute of the IDE opening (the extension fetched the data from the agent, the `Data injected` wait of the old stack does not exist); every task ends with the expected result and exit code 0; EduIDE branding in the title and About dialog; the About dialog version matches the image tag of the template; git user and email come from the token (`UserName` and `UserEmail` sources, G18), not from the request.
Cleanup: stop the session (API-05 or `k delete idesession`).

### IDE-02 Experience levels
Safety: test-only
Steps: in one session open the top-level "Experience Levels" menu (the status bar shows the level name) and switch Beginner, Advanced, Expert.
Expect:
- Expert is the default for a new session.
- Beginner: menu bar File, Edit, View, Experience Levels, Help; only Explorer, Search and (Artemis) the Artemis view; one Run button in the editor title bar (shown only with a file open; it runs the default task); no terminal, no "Open new Terminal" or "Open Version Control" links on any start page.
- Advanced: adds the Selection, Go and Terminal menus, Source Control, Testing, build tool views, Output; no Run menu, no debugger.
- Expert: stock IDE with the Run menu, debugger and Debug Console, Outline, all tasks, Welcome page.
- The switch applies immediately, without reload.

### IDE-03 Persistence across stop and start
Safety: test-only
Steps: in a Saved session create `ft-persist.txt` with some text and change a template file; stop the session ("Beenden" or API-05); in the overview click "Starten" on the workspace.
Expect: the same IDEWorkspace and PVC are used (`status.claimName` unchanged), the new session is `cold`; both changes are there; the template is not applied again over them (a non-empty workspace is left alone). For a Temporary template the files are gone after a new launch, as the badge promised (`emptyDir`).

### IDE-04 Web preview on the fixed webview host
Safety: test-only
Steps: javascript template with `web`; run Start; open `index.html`; "Open Preview to the Side"; change the text, save, reload the preview. Then open a Markdown preview, an extension webview (for example the Settings editor or an extension's welcome page) and a second webview at the same time; read the origin of each webview frame from the browser (`document.querySelectorAll('iframe')` `src` host names, host names only).
Expect: all webviews load from `https://$WEBVIEW_HOST/<instance>/...` (decision G3: one host, no `<uuid>.webview` name), with a valid certificate that names exactly that host; the workbench (`$INSTANCE_HOST`) and the webviews are different origins; the preview shows the page and, after a manual reload, the change; several webviews at once do not break each other (service workers). The OIDC cookie covers the webview host (no extra login). The mini browser works with the same host pattern.

### IDE-05 Clone from GIT_URI into an empty workspace
Safety: test-only
Needs: browser token (README); a small public repository on the deployment's `allowedHosts` (record which); a template whose `injectableKeys` contains `GIT_URI`.
Steps: `await api('POST','/sessions',{template:'<T>',data:{GIT_URI:'<public repo .git URL>'},display:{source:'<same URL>'}})`, open the returned URL.
Expect: the repository is cloned into the workspace; git user and email are set from the token. With scorpio 3.1.0 or later in the image: a "Preparing your workspace" notification shows its steps; with 3.0.0 no progress notification (record the version in the image, Extensions view). The overview title is derived from the repository (LAND-14). A URL outside `allowedHosts` or `http://` is refused with 400 before any pod starts (API-10).

### IDE-06 Non-empty workspace warning
Safety: test-only
Needs: browser token.
Steps: launch a persistent session (no `GIT_URI`), add a file, stop it; launch again on the same `workspace` with `GIT_URI` set (a different launch key only if the key includes the data: for a workspace the key is template plus workspace, so the second launch returns the same session if it still runs, stop it first).
Expect: no clone; a warning "The exercise was not cloned because this workspace already contains files. Empty the workspace or start a new one to get the exercise."; no Gradle prewarm runs; existing files untouched.

### IDE-07 Gradle prewarm prompt (standalone)
Safety: test-only
Needs: browser token; a small public repository with a Gradle wrapper (record which); a template that allows `GIT_URI` and does not set `GRADLE_PREWARM_AUTO_CONFIRM`.
Steps: launch a standalone Java template with that repository as `GIT_URI`.
Expect: after the clone a prompt "Scorpio can pre-build this exercise with its Gradle wrapper ... Only continue for exercises you trust." with one button "Pre-build now"; dismissing it runs nothing; clicking it shows "Preparing Gradle in the background". A template session without `GIT_URI` never shows the prompt.

### IDE-08 Gradle prewarm in the Artemis edition
Safety: test-only
Steps: as IDE-07 with the Artemis edition template (its image sets `GRADLE_PREWARM_AUTO_CONFIRM=true`; check `k get idetemplate <name> -o jsonpath='{.spec.env}'` and the image env, never data from the request).
Expect: no prompt; prewarm starts by itself. The key `GRADLE_PREWARM_AUTO_CONFIRM` is not accepted as launch data (400 `unknown-key`).

### IDE-09 Help and extensions
Safety: test-only
Steps: Help > Report Issue; Extensions view; the command palette entries of the extension (`dataBridge.getEnv` and `dataBridge.getEnvState` are commands for other extensions and may not be listed: check that Scorpio's template application works, which uses them).
Expect: Report Issue opens `https://github.com/eduide/eduide/issues`; images have scorpio and `eduide-session`; the old `data-bridge` and `theia-cloud-monitor` extensions are absent (G7); the Artemis edition also has the Artemis extension. `k exec $POD -c ide -- ss -ltn` (or `netstat`) shows no listener on 16281 or 8081 inside the IDE: the extension opens no server, it only calls `127.0.0.1:8082`.

### IDE-10 Image without the extension
Safety: test-only
Needs: a template that still uses an IDE image from before `eduide-session` (an old release tag); the design has no compatibility mode (U8).
Steps: `ft_template "$T_STD" ft-ide-old '.spec.image="<old image>"'`, `FT_DATA='{...}'` launch as `ME`, open the IDE.
Expect: the session reaches Ready (the agent is ready, the IDE answers), but the IDE never reads the data: no template, no git identity, no idle notice, and the monitor heartbeat never arrives, so the session ends by the no-activity rule (OPR-04). Record exactly what the student sees. This documents why every template needs an image with `eduide-session` before it is switched.
Cleanup: `ft_cleanup`.

### IDE-11 Idle warning in the IDE
Safety: test-only
Needs: OPR-04's `ft-opr-idle` template (idle 4m, warning 2m).
Steps: open a session of that template, leave it idle, watch for the notification; then type in the editor.
Expect: a notification appears about `warning` after the last input ("your session will end at ..."); typing sends a heartbeat (at most one per minute) and moves the end time; no notification repeats in a loop.
Cleanup: `ft_cleanup`.

## Explore

- Run a task at Beginner level that needs a terminal: what does the student see?
- Large output (a test that prints 100k lines), an infinite loop in Run: can the student stop it, does the session stay responsive through the agent proxy?
- Disk full in the workspace (`fallocate` a large file in a Temporary session): which message, does the IDE survive?
- Two browser tabs on the same session: do both work (two WebSocket connections through the agent), does the clone run once?
- Download and upload of large files through the proxy; copy and paste in the Explorer; download of the whole workspace.
- Offline-sensitive templates: `bazel`, `maven` and `gradle` need network (the egress policy); do the others work without it?
- Close the laptop lid for 10 minutes and reopen the tab: the OIDC cookie may have expired (AUTHZ-08); does the IDE recover without losing the editor state?
