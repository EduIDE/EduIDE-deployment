# 02 Landing page (LAND)

Browser module. Run in one browser tab with the user logged in (the agent never types a password; ask the user to log in when the page shows the Keycloak login). On production only the read-only tests run, with no launch.

Sources: control plane `landing-page/` (`README.md`, `src/{main,App,launch,templates,routes,artemisToken,i18n}.ts(x)`, `src/components/{Home,TemplateTile,TemplateDialogs,EnvironmentRows,Launch,Footer,Shell}.tsx`, `src/status/`, `src/admin/`, `server/main.go`), `charts/eduide-landing-page/templates/landing-page.yaml`; ADR 0020.

Facts:
- One page at `/` and `/me/overview`: "Your environments" (running sessions and saved workspaces, live over SSE) on top, "Start new" tiles below. The page asks Keycloak for a login at once (`login-required`); only `/imprint`, `/privacy` and `/status` work without one. `/admin` needs the admin role.
- No `data-testid` hooks exist. Use accessible names: tile button `Start <display name>`, info button `What <display name> includes`, row buttons `Start` and `Delete`, avatar menu with `Sign out` and `Admin`.
- Texts below are the English ones (the page follows the browser language; German is in `src/i18n.ts`).
- Tiles show only templates with `listed: true`. The persistence badge follows the template's default: `Temporary workspace` for `none`, `Saved workspace` for `volume`. Chart templates default to `none` (test2 shows `Temporary workspace`). A saved workspace starts only through a link with `persistence=volume`, through a template whose default is `volume`, or from a row of "Your environments".
- Start times: `Ready instantly` for a template with a warm pool (temporary) or an estimate below 2 s, `Ready in about N s` from the public status estimates, nothing without data.
- The page reads `/config.json` (no-store). Its CSP allows only `'self'` and the Keycloak origin.

### LAND-02 Tiles and badges
Safety: prod-safe
Needs: logged in.
Steps: read the page (accessibility tree) after login; compare with `curl -s $LANDING/api/v1/status | jq -r '.templates[].name'` and `k get idetemplates -o custom-columns=NAME:.metadata.name,LISTED:.spec.listed`.
Expect:
- Greeting "Welcome, <first name>" (or "Welcome back" with environments), the lead text, the section "Your environments" and the section "Start new".
- One tile per IDETemplate with `listed` not false. Unlisted templates (the Artemis editions) show no tile.
- Each tile shows its display name, exactly one persistence tag ("Saved workspace" or "Temporary workspace", tooltip "Your files are kept after the environment stops, so you can continue later." or "Your files are deleted when the environment stops.") and, where known, "Ready instantly" or "Ready in about N s".
- Tiles of a template with a pool and persistence `none` read "Ready instantly".

### LAND-03 Project template picker
Safety: test-only (starting launches a session)
Needs: logged in; a listed template whose image metadata has `variants` and whose `injectableKeys` include `TEMPLATE` (for example `java-17-standalone`).
Steps:
1. Click the tile. Check the dialog "New <name> environment", "Pick a project template": one radio per variant plus "Empty project".
2. Press "What <name> includes", check the chips, close with "Back"/"Close".
3. Pick a variant and press "Start".
4. Click a tile of a template without variants (if any).
Expect: step 1 lists the variants of `k get idetemplate <n> -o jsonpath='{.status.image.variants[*].id}'`; step 3 starts a session whose `spec.display.title` is the variant name (`k get idesession <name> -o jsonpath='{.spec.display.title}'`) and whose data Secret `<session>-data` holds the key `TEMPLATE` (`k get secret <session>-data -o json | jq -r '.data|keys[]'`, key names only); step 4 starts directly, without the dialog.
Cleanup: delete the session (`k delete idesession <name>` or the API in API-05).

### LAND-04 Launch progress
Safety: test-only
Steps: start a tile with a temporary workspace (and, with `?appDef=<TPL_STD>&persistence=volume`, a saved one). Watch the launch view until the IDE opens.
Expect: the view shows the steps "Sending request", "Request accepted", "Starting your environment", "Opening the IDE" and, for a cold start, "Usually ready in about N seconds."; the browser ends up on `https://instance.$ENV/<instance>/` and the IDE loads. A temporary start creates an IDESession without `workspaceRef`; a saved start creates an IDEWorkspace named `w-<16 hex>` and a session on it (`status.startStrategy: cold`). The first path segment is the session's `status.instance`.
Cleanup: delete the sessions; the saved workspace stays until LAND-16 or RET-02.

### LAND-05 Resume a saved workspace
Safety: test-only
Needs: LAND-04 with a saved workspace; the test user may start sessions.
Steps:
1. Create a file in the IDE, then end the session without deleting the workspace: `k delete idesession <name>` (the row button "Delete" would delete the files).
2. Reload `$LANDING`.
3. Press "Start" on the row of the saved workspace.
Expect: step 2 shows the workspace in "Your environments" as "saved workspace", "last used <time>" and "Deleted on <date> unless you start it" (the deletion date is `expiresAt` plus the grace period). Step 3 starts a session on the same workspace; the file from step 1 is there.

### LAND-08 Error texts
Safety: test-only
Steps:
1. Open `$LANDING/?appDef=does-not-exist`.
2. Open `$LANDING/?appDef=<TPL_STD>&gitUri=https://untrusted.example.org/x.git`.
3. With the session limit reached (3 by default on test environments; `config.yaml` `sessionsPerUser`), start one more tile. Reach the limit with fixture sessions owned by the test user (`ft_session ft-land-1 <TPL_STD> "" "$ME"`, `ME` as in the README token section) or with real starts.
4. Launch more than the rate limit allows in a minute (default 10 launches per minute and user) with a script of rejected launches (API-21), then start a tile.
Expect: step 1 "Unknown environment: does-not-exist". Step 2 no session starts and the page says "Repositories from untrusted.example.org cannot be opened here. Ask your course team for a link to an approved repository.". Step 3 "You already have N environments running" with the list of running environments (open or delete them) and the text "Delete one to start a new one, or continue in one of these.". Step 4 "Too many requests. Please wait a moment and try again.".
Cleanup: delete the fixture sessions.

### LAND-09 Service down
Safety: test-only, disruptive
Steps: record the replicas (`k get deploy $P-service -o jsonpath='{.spec.replicas}'`), `k scale deploy/$P-service --replicas=0`, reload `$LANDING` and click a tile, scale back after 30 s, `k rollout status deploy/$P-service`.
Expect: the page does not hang. With the service down the templates cannot load: "Could not load the environments." or "The service could not be reached."; an open page shows "Lost the connection to the service, retrying." and recovers by itself after the scale-up (the overview stream reconnects; the templates are asked again). Record exactly what the student sees. `/status` (LAND-17) shows the page without a login while sign-in works; with the service down it says "Status is not available right now".
Cleanup: replicas restored.

### LAND-10 Artemis link with a host that is not allowed
Safety: test-only
Steps: as LAND-08 step 2, with `artemisUrl` and `gitUri` hosts outside `allowedHosts` (`yq .allowedHosts` of the config, PLAT-10).
Expect: nothing starts, the page names the host. A link whose hosts are allowed starts at once without a click (ART-01). There is no `trustedArtemisHosts` list on the Go stack: the service's `allowedHosts` is the only host rule (ADR 0012).

### LAND-11 Logout
Safety: prod-safe
Steps: open the avatar menu, press "Sign out".
Expect: redirect through the Keycloak logout; a reload asks for the login again.

### LAND-12 Imprint and privacy
Safety: prod-safe
Steps: open `/imprint` and `/privacy` from the footer, without a login (fresh tab). Compare with `curl -s $LANDING/config.json | jq .legal`.
Expect: each page is either an external page (`url`, the footer link opens it in a new tab) or a Markdown page served from `/legal/imprint.md` and `/legal/privacy.md` and rendered at `/imprint`, `/privacy`. Production and Bonn name the real controller, never the placeholder `https://example.org/...` (test environments may still use it: record it).

### LAND-13 Second variant while a session runs
Safety: test-only
Needs: logged in; a template with two project templates, temporary persistence.
Steps: start `java-17-standalone` with variant Maven; go back to `$LANDING`; start the same template with variant Gradle; compare the two sessions.
Expect: two sessions with different launch keys (the key is template plus a hash of the launch data), each with its own `TEMPLATE` key in its data Secret; the second start does not return the Maven session silently. Both count against the session limit. Repeating the Gradle start returns the same session (idempotent launch, API-04).
Cleanup: delete both sessions.

### LAND-14 Anonymous visit starts the login
Safety: prod-safe
Steps: open `$LANDING/` in a fresh tab; also `curl -s -o /dev/null -w '%{http_code}\n' $LANDING/` and `curl -s $LANDING/healthz`.
Expect: the page redirects to the Keycloak login of the environment's realm (`/config.json` `keycloak`) and shows no environments before login; curl gets the static app with 200 (the login happens in the browser) and `/healthz` answers `ok`.

### LAND-15 Link parameters and the Artemis token
Safety: test-only
Steps: open `$LANDING/?appDef=<TPL_STD>&title=ft-link&persistence=none#artemisToken=dummy-token` after the login.
Expect: the fragment is gone from the address bar at once and the value is in `sessionStorage` (key names only: `Object.keys(sessionStorage)` shows `eduide.artemisToken`; never print the value); the launch starts and the environment is titled `ft-link`; the data Secret holds the key `ARTEMIS_TOKEN` (key names only); after the launch `sessionStorage` no longer holds the key. A `persistence` value the template does not allow is ignored.
Cleanup: delete the session.

### LAND-16 Delete an environment
Safety: test-only
Needs: a saved workspace and optionally a running session on it, owned by the test user.
Steps: press the row's "Delete" button, read the dialog, press "Delete".
Expect: the dialog "Delete <title>?" says "All files of this environment are deleted permanently and cannot be restored." and, for a running one, "The open IDE stops."; afterwards the row, the session and the IDEWorkspace and its PVC are gone (`k get ideworkspace,pvc`); "Cancel" changes nothing.

### LAND-17 Status page
Safety: prod-safe
Steps: open `$LANDING/status` in a fresh tab without a login; compare with `curl -s $LANDING/api/v1/status | jq .`.
Expect: "Everything is working" when `overall` is `ok` ("Starting takes longer right now" for `slow`, "New environments cannot start" for a down `starting`); the parts "Sign in", "Starting environments" and "Saved workspaces" with "Working"; the start time per template split into "Temporary" and "Saved" and "Ready environments available" for warm templates; "Updated <time>, refreshes on its own" (every 30 s); with the API unreachable "Status is not available right now". The footer has a "Status" link.

### LAND-18 Admin entry and panel
Safety: prod-safe (read-only)
Needs: logged in; a user with the admin role (`oidc.admin` in the config) and one without.
Steps: open the avatar menu, then `/admin`, `/admin/pools`, `/admin/sessions`, `/admin/workspaces`, `/admin/problems`, `/admin/templates`, `/admin/limits`.
Expect: with the role the menu shows "Admin" and every page loads (Status with live updates, Pools with scaler decisions, Sessions with detail, Workspaces, Problems, Templates, Limits); users appear only as a hash; figures that need Prometheus are hidden when none is configured. Without the role there is no menu entry and `/admin` shows "No access". Nothing in the panel changes state.

### LAND-19 Language and information dialog
Safety: prod-safe
Steps: switch the language in the avatar menu to German and back; press the info button of a tile.
Expect: texts switch without a reload and the choice stays (`localStorage` key `lang`); the dialog "What this environment includes" shows groups and chips from `status.image.includes` of the template and the image version.

### LAND-20 Stop time of a running environment
Safety: test-only
Needs: a running session of the test user.
Steps: read the row of the running environment.
Expect: "Stops at <time> if inactive" (the idle timeout from the last activity, else the ready time) or "Stops at <time> (time limit)" when the maximum lifetime comes first; red text only when files would be deleted ("..., files are deleted then", temporary workspace). The time matches `stopsAt` of `GET /api/v1/sessions` (API-03) and the template timeouts (60 m idle, 24 h max by default).

## Unverified, check in the first run

- The exact text of the persistence tooltip and of the row lines (`life.*`) was read from `src/i18n.ts` at control plane 0.2.3; check them on the deployed landing page.
- Whether the picker appears for `java-17-standalone` on test2 (needs `variants` in the image metadata and the `TEMPLATE` key; the Artemis edition `java-17` shows both).
- The route `/admin/limits` name and the admin page set (from the README of the landing page).
- LAND-08 step 4: the rate limit message appears on the launch view only when `rate-limited` comes back on a tile start.
- LAND-15: whether the `sessionStorage` key is removed right after the launch or after the session is Ready.

## Retired

- LAND-01 Logged-out page: 2026-11-24, the Go landing page redirects to the login at once; replaced by LAND-14.
- LAND-07 Session-ended redirect from the gateway: 2026-11-24, no `/session-ended` page and no redirect route exist; a released instance gives 403 to its owner (SEC-13).
- LAND-06 Session-ended reasons: 2026-11-24, the page `/session-ended` and the Workspace annotation `last-session-end-reason` no longer exist; the end reason is the Event `Ended` (`idle` or `max`, OPR-04, OPR-05) and the stop time is shown in the rows (LAND-20).

## Explore

- Double click on a tile, or two tabs launching at the same time: one session or two (the launch key makes it idempotent), any `session-limit-reached`?
- Browser back button during the launch view; reload during the launch view (the link launches again and returns to the same session).
- Very long or unusual display titles and usernames (umlauts, plus signs): do names and rows stay valid?
- Narrow viewport (375 px) and keyboard-only navigation: can every tile, dialog and row button be reached?
- Dark mode contrast; `prefers-color-scheme` switch while the page is open.
- Open `/config.json` and `/legal/imprint.md` caching and CSP headers (`curl -sI`).
- A deep link whose `gitRef`, `title` or `artemisUrl` is empty, very long, or contains markup: how does the page show it?
