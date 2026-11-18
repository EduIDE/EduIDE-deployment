# 02 Landing page (LAND)

Browser module. Run in one browser tab with the user logged in (the agent never types a password; ask the user to log in when the page shows "Login to use EduIDE"). On production only the read-only tests run, with no launch.

Sources: EduIDE-Landing-Page `src/App.tsx`, `src/launch.ts`, `src/components/{SelectApp,SelectBuildSystem,PersistenceBadge,SessionEnded,Footer,Header}.tsx`, `src/lastLaunch.ts`; EduIDE-Helm `charts/eduide/templates/landing-page-config-map.yaml`.

Element hooks: tiles `[data-testid="launch-app-<id>"]`, build systems `[data-testid="build-system-<id>"]`, badge `[data-persistence="saved|temporary"]`, logout `[data-testid="logoutButton"]`.

### LAND-01 Logged-out page
Safety: prod-safe
Steps: open `$LANDING` in a fresh (logged-out) tab.
Expect: heading "Login to use EduIDE", a Login button in the header, no tiles; footer with Imprint and Privacy links and the version text.

### LAND-02 Tiles and badges
Safety: prod-safe
Needs: logged in.
Steps: read the page (accessibility tree) after login.
Expect:
- Heading "Choose your programming language".
- One tile per entry in `config.js` `additionalApps` with a landing page entry; apps with `visible: false` (the Artemis editions) are not shown.
- Each tile has exactly one badge: "Saved" (`data-persistence="saved"`, tooltip "Files are kept between sessions.") or "Temporary" ("Files are lost when the session ends."). The badge follows the app's own `ephemeral` flag, otherwise `useEphemeralStorage` from `config.js`.
- Labels are spelled as in the catalog (for example "JavaScript", rc.1 finding 4).

### LAND-03 Build system picker
Safety: test-only (selecting a build system launches a session)
Needs: logged in.
Steps:
1. Click a tile of an app with two or more build systems (chart 3.x: Java 17/25 Maven and Gradle, C Make and Bazel, JavaScript Node.js and Web).
2. Check the picker, click "← Back", check that the language list returns.
3. Click the tile again and pick one build system.
4. Click a tile of an app with one build system (Python, Rust, Go).
Expect: step 1 shows "Choose your build system" with one `build-system-<id>` tile per build system; step 3 launches with env `TEMPLATE=<id>` (visible in the Session CR: `k get session <name> -o jsonpath='{.spec.envVars.TEMPLATE}'`); step 4 launches directly, without the picker.
Cleanup: stop the sessions (API-05 or `k delete session <name>` for the run's own sessions).

### LAND-04 Launch and loading page
Safety: test-only
Steps: launch one Saved and one Temporary app. Watch the loading page until the IDE opens.
Expect: loading page shows the loading text and the same badge as the tile; the browser ends up on `https://instance.$ENV/...` and the IDE loads. A Saved app creates a Workspace `ws-<app>-playground-<user>-<hash>` (segments cut to 12 characters); a Temporary app creates a session named `eph-...-session` and no Workspace.

### LAND-05 Resume after the session ended
Safety: test-only
Steps:
1. Launch a Saved app, create a file in the IDE, then end the session (`k delete session <name>` or API-05).
2. Open `$LANDING/session-ended`.
3. Click "Resume my session".
Expect: step 2 shows "Your session has ended", does not start anything by itself (no Session CR appears for 60 s), and offers "Resume my session" and "Start something else". Step 3 starts the same workspace; the file from step 1 is there. "Start something else" clears the stored launch (`sessionStorage['eduide.lastLaunch.v1']`) and returns to `/`.
After a Temporary session the page says "This session ran without a persistent workspace, so its files could not be kept." and offers only "Start a new session". Resume needs an app that is Saved in `config.js`; on an environment with `useEphemeralStorage: true` and no Saved app, run only the Temporary variant and record the rest as `blocked`.

### LAND-06 Session-ended reasons
Safety: test-only
Needs: OPR-04 or OPR-05 ended a session of the logged-in user with reason `inactivity` or `lifetime` (Workspace annotation `theia-cloud.io/last-session-end-reason`).
Steps: open `$LANDING/session-ended` after that.
Expect: "Your session closed after a period without activity." for inactivity, "Your session reached the maximum time a session may run and was closed." for lifetime, the generic text otherwise.

### LAND-07 Session-ended redirect from the gateway
Safety: test-only
Steps: open the URL of a session that was just deleted.
Expect: the gateway answers 302 to `$LANDING/session-ended` (chart `gateway.routes.sessionEndedRedirect`, enabled by default) and the page from LAND-05 shows.

### LAND-08 Error texts
Safety: test-only (553 part) / prod-safe (invalid appDef part)
Steps:
1. Open `$LANDING/?appDef=does-not-exist`.
2. With SESSIONS_PER_USER lowered (run together with API-08, one service restart for both; the user's own running session counts), launch a second app.
Expect: step 1 shows "Invalid default selection value: does-not-exist"; step 2 shows "Your previous session is still shutting down. Please try again in a few seconds." (error 553; the text does not fit the cause, see the 2026-11-17 report).

### LAND-09 Retry behaviour
Safety: test-only, disruptive
Steps: scale the service to 0 for one launch (`k scale deploy/service-deployment --replicas=0`), click a tile, scale back to the recorded replica count after 20 s.
Expect: the ping fails first: the page shows the maintenance text ("Sorry, we are performing some maintenance at the moment..."), it does not hang. Record exactly what the student sees. (The launch itself retries at most 4 more times on 502/503/504 and network errors, 3 to 10 s apart.)
Cleanup: replicas restored, `k rollout status deploy/service-deployment`.

### LAND-10 Artemis deep link from an untrusted host
Safety: prod-safe (nothing is clicked)
Steps: open `$LANDING/?appDef=<an artemis app>&gitUri=https://untrusted.example.org/x.git&artemisToken=dummy`.
Expect: no auto start; the page shows "Launch your Online IDE", "This link opens a repository from untrusted.example.org." and a "Launch <app name> →" button. Do not click it. Auto start happens only when both hosts are in `trustedArtemisHosts` (module 12).

### LAND-11 Logout
Safety: prod-safe
Steps: click `logoutButton`.
Expect: redirect through Keycloak logout back to the landing page in the logged-out state of LAND-01; a reload does not log in again silently.

### LAND-12 Imprint and privacy
Safety: prod-safe
Steps: open `/imprint` and `/privacy` from the footer.
Expect: both render; privacy names the controller from `environments/_base.yaml` (`landingPage.privacy`), not the chart placeholder "Example University".

### LAND-13 Build system switch while a session runs
Safety: test-only
Needs: logged in; an app with two build systems shown as Temporary.
Steps: launch Java 17 > Maven; go back to `$LANDING`; launch Java 17 > Gradle; check the Session CR's `TEMPLATE` and the workspace.
Expect (target): the student gets a Gradle workspace or a clear message ("You already have a Java 17 session with Maven..."); never the Maven workspace silently. Cloud 3.0.1 with Landing 1.4.1: the running Maven session is returned; record `fail`.
Cleanup: stop the session.

## Explore

- Double click on a tile, or two tabs launching at the same time: one session or two? Any 553?
- Browser back button during the loading page; reload during the loading page.
- Very long or unusual user names (umlauts, plus signs in the email): workspace and session names stay valid?
- Narrow viewport (375 px) and keyboard-only navigation: can every tile and button be reached?
- `config.js` caching: is it really served with no-cache after a deploy (`curl -sI $LANDING/config.js`)?
- Dark mode contrast (Landing 1.4.1 contrast fix).
- Deep links: does stray app id text show under the welcome title, and do query parameters (`gitUri`, `artemisToken`) stay in the URL across routes?
