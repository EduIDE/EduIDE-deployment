# 02 Landing page (LAND)

Browser module. Run in one browser tab with the user logged in (the agent never types a password; ask the user to log in when the page shows the login prompt). Sources: `EduIDE-control-plane` landing page (`charts/eduide-landing-page`, generated TypeScript client), G14, G15, G16, `GET /config.json` (`{"apiBaseUrl":"/api/v1","keycloak":{...},"title":"EduIDE","legacy":false}`).

The landing page is a Go static server: `/` the app, `/config.json` its runtime config, `/api/` is routed to the service.
It now shows an **overview** per user (running sessions and workspaces that are not running), not only tiles.
Element hooks (`data-testid`) are those of the new page; read the accessibility tree and record the real ones in the report when they differ.

### LAND-01 Logged-out page
Safety: prod-safe
Steps: open `$LANDING` in a fresh (logged-out) tab; `curl -s $LANDING/config.json | jq 'keys, .legacy, .apiBaseUrl'`.
Expect: a login prompt and a Login button, no overview and no tiles, footer with Imprint and Privacy; `config.json` has `apiBaseUrl` `/api/v1`, `legacy` false, a `keycloak` block (url, realm, clientId; no secret).

### LAND-02 Tiles and badges from the template list
Safety: prod-safe
Needs: logged in.
Steps: read the page after login and compare with `k get idetemplates`.
Expect: one tile per template the API lists (`displayName`, logo from `logoUrl`); each tile shows a persistence badge following the template's `persistence.default` ("Saved" for `volume`, "Temporary" for `none`) and the tooltips of the old page; a template with a warm pool starts faster (no badge for that). Labels are spelled as in `displayName`.

### LAND-03 Build system picker
Safety: test-only (selecting a build system launches a session)
Needs: logged in; a template whose `injectableKeys` has `TEMPLATE` as `Enum`.
Steps:
1. Click a tile of a template with two or more build systems, check the picker, click Back, check that the list returns.
2. Click the tile again and pick one build system.
3. Click a tile with one build system.
Expect: step 1 shows one entry per value of the `TEMPLATE` enum; step 2 launches with `data.TEMPLATE=<id>`: `k get secret <session>-data -o json | jq -r '.data.TEMPLATE|@base64d'` prints that id (a non-secret enum value; check key names only for the rest: `jq '.data|keys'`); step 3 launches directly.
Cleanup: stop the sessions (API-05 or `k delete idesession <name>` for the run's own sessions).

### LAND-04 Launch, progress and redirect
Safety: test-only
Steps: launch one Saved and one Temporary tile. Watch the loading page until the IDE opens. In a second terminal: `k get idesession -w`.
Expect: the page calls `POST /sessions` and follows `GET /sessions/{name}/events` (SSE, no polling: check the browser's network log or hook `fetch`); the loading page shows the progress and the same badge; at phase Ready the browser goes to `https://$INSTANCE_HOST/<instance>/` and the IDE loads. A Saved tile creates an IDEWorkspace `w-<16 hex>` (get-or-create, deterministic) and the session has `workspaceRef`; a Temporary tile creates a session `s-<10 chars>` and no workspace.
Cleanup: stop the sessions.

### LAND-05 Resume from the overview
Safety: test-only
Steps:
1. Launch a Saved tile, create a file in the IDE, then stop the session from the overview ("Beenden", or API-05).
2. Look at the overview.
3. Click "Starten" on the workspace entry.
Expect: step 2 shows the workspace as "nicht laufend" (not running), with the title, template with logo and "zuletzt benutzt"; step 3 starts a cold session on the same workspace (`startStrategy cold`) and the file is there. The page never starts anything by itself while the overview is open (no IDESession appears for 60 s). After a Temporary session the overview lists nothing for it (no workspace); only "Öffnen" and "Beenden" exist for running sessions without a workspace (G15).

### LAND-07 Gone session ends in a visible state
Safety: test-only
Steps: open the URL of a session that was just stopped (it is `https://$INSTANCE_HOST/<instance>/`).
Expect: the gateway answers 403 (authz denies instances that are not Ready, AUTHZ-06) or the OIDC redirect for an anonymous tab; there is no redirect to a "session ended" page any more. Record exactly what the student sees and propose a friendlier page if it is a bare 403.

### LAND-08 Error texts
Safety: test-only
Steps:
1. Open `$LANDING/?appDef=does-not-exist` (and `?template=does-not-exist`, whichever parameter the page reads; record it).
2. With the user's running sessions at `sessionsPerUser` (API-08), launch one more.
3. Make capacity run out for a moment (OPR-15, test only) and launch a session of the starved template.
Expect: step 1 shows a message for `template-not-found`; step 2 shows the `session-limit-reached` message and the list of running sessions with "Öffnen" and "Beenden" (the Problem carries `sessions`); step 3 shows `capacity-exhausted` after about 45 s (`capacity.exhaustedAfter`), not an endless spinner. None of the texts shows a raw HTTP status like 553 or 555.

### LAND-09 Service pod lost, retry behaviour
Safety: test-only, disruptive
Steps:
1. With 2 service replicas, `k delete $(k get pod -l app.kubernetes.io/component=service -o name | head -1) --wait=false` (one pod only), and click a tile at the same time.
2. Scale the service to 0 for one launch (`k scale deploy/$FULL-service --replicas=0`), click a tile, scale back to 2 after 20 s.
Expect: step 1: no error shown (the other replica answers, API-18). Step 2: the page shows a maintenance or retry text, does not hang; record exactly what the student sees.
Cleanup: replicas restored (`k scale deploy/$FULL-service --replicas=2`, `k rollout status deploy/$FULL-service`).

### LAND-10 Artemis deep link keeps the token out of the URL (G16)
Safety: prod-safe (nothing is clicked)
Steps: open `$LANDING/?appDef=<a template>&gitUri=https://untrusted.example.org/x.git#artemisToken=dummy` in a logged-out tab, log in when asked, then read `location.href`, `sessionStorage.length` and the page.
Expect: the page reads the fragment first, keeps the token in `sessionStorage` only, removes the fragment (`history.replaceState`), and starts Keycloak only after that, so the token survives the login detour; after login the URL has no `artemisToken`. A host that is not trusted (`allowedHosts`) does not auto start: the page shows the repository host and a launch button, which the test does not click. The legacy form `?artemisToken=dummy` still works during the migration and logs a deprecation in the browser console. Never use a real token.

### LAND-11 Logout
Safety: prod-safe
Steps: click the logout button.
Expect: redirect through Keycloak logout back to the logged-out state of LAND-01; a reload does not log in again silently. A session tab opened earlier keeps working until its ID token cookie expires and then re-authenticates against Keycloak (AUTHZ-08): record whether the IDE tab is signed out as well.

### LAND-12 Imprint and privacy
Safety: prod-safe
Steps: open `/imprint` and `/privacy` from the footer.
Expect: since decision U6 the imprint and privacy pages are no longer built in: the footer links come from `config.legal` of the deployment. Record the configured links (or their absence) and check that they open; a built-in TUM text is a finding.

### LAND-13 Launch idempotency from the page (G14)
Safety: test-only
Needs: logged in; a template with two build systems.
Steps: (a) double click one tile, reload the page during the loading page, open the tile in a second tab; (b) launch Maven, go back to the overview, launch Gradle of the same template.
Expect: (a) exactly one IDESession (`k get idesessions -l eduide.github.io/owner-hash=$(OWNER_HASH "$ME")`; the launch key is label `eduide.github.io/launch-key`); all tabs end in the same IDE. (b) for a Temporary tile the launch key is template plus hash of the data, so Gradle is a second session (it counts towards the limit) with its own `TEMPLATE`; for a Saved tile the key is template plus workspace, so the second launch returns the running session: the page says so instead of silently opening the Maven IDE (record what the student sees).
Cleanup: stop the sessions.

### LAND-14 Overview content (G15)
Safety: test-only
Needs: logged in as `ME`; fixtures: `FT_TITLE= FT_SOURCE=https://github.com/example-org/ft-demo-ex01-solution.git ft_workspace ft-lw1 "$T_STD" "$ME"` (empty title, so the title is derived from the source; the host must be a plausible Git URL, it is only displayed); a running session without workspace, `FT_SESSION_TITLE="ft running" ft_session ft-ls1 "$T_STD" "" "$ME"`.
Steps: open the overview; compare with `GET /me/overview` (API-21).
Expect: the workspace item's title is derived from the Git URL (last path part without the user abbreviation), subtitle shows template with logo and "zuletzt benutzt", status "nicht laufend", actions "Starten" and "Löschen" (asks for confirmation); the session item titled "ft running", status "laufend", actions "Öffnen" and "Beenden"; technical names (`w-...`, `s-...`) are not the title. An empty overview points to Artemis.
Cleanup: `ft_cleanup`.

### LAND-15 Overview updates live
Safety: test-only
Needs: logged in; two tabs.
Steps: in tab 1 open the overview; in tab 2 launch a session through a tile (or `ft_session ft-ls2 "$T_STD" "" "$ME"` from the shell); then stop it from tab 2.
Expect: tab 1 shows the new session as "laufend" and later removes it without a reload (SSE `/me/overview/events`); the stream reconnects after `k delete pod` of one service replica without a visible error.
Cleanup: `ft_cleanup`.

### LAND-16 Launch sends a trace context
Safety: test-only
Needs: logged in.
Steps: hook `fetch` (README) to store only the name of the request headers of `POST /sessions`: `window.__h=[]; const o=fetch; window.fetch=function(i,n){ if(String(i).includes('/sessions')&&n&&n.method==='POST') window.__h.push([...new Headers(n.headers).keys()]); return o.apply(this,arguments)}`; click a tile; read `window.__h`.
Expect: the header list contains `traceparent` (and `authorization`, whose value is never read). The annotation `eduide.github.io/traceparent` on the new IDESession holds a W3C trace context (MON-10 follows the trace).
Cleanup: stop the session.

## Explore

- Browser back during the loading page; reload during the loading page; close the tab before Ready and reopen the overview.
- Very long or unusual user names (umlauts, plus signs): owner label (`owner-hash`) and workspace names stay valid; titles render.
- Narrow viewport (375 px) and keyboard-only navigation: can every tile, "Starten", "Beenden" and "Löschen" be reached?
- `config.json` caching: `curl -sI $LANDING/config.json` (no-cache after a deploy?).
- Dark mode contrast; very long `display.title` (200 characters) and a title with markup characters.
- A workspace with `expiresAt` in less than 3 days shows the warning (WS-11); what does "Starten" do on an Expired workspace (WS-10)?
- With `config.json` `legacy: true` the page should talk to the old stack: do both modes coexist during the migration (ADR 0017)?
