# Functional test plan

A manual, agent-executable check of a deployed EduIDE installation on the Go control plane (EduIDE 3.x). It complements the automated tests on `e2e.` (which follow `main`) and is meant for release candidates, upgrades, and "is this environment healthy" questions.

The plan is split into modules. A run selects all modules or any subset, writes one report, and proposes plan updates in that report. The `functional-check` skill (`.claude/skills/functional-check/SKILL.md`) walks an agent through a run.

The plan describes the Go stack: the CRDs `IDETemplate`, `IDEPool`, `IDESession` and `IDEWorkspace` (group `eduide.github.io`), the operator, service and authz, the agent sidecar in every session pod, the gateway with OIDC and ext_authz, and the landing page. Sources of truth: `EduIDE-control-plane` (`docs/architecture/`, `docs/adr/`, `docs/contracts/metrics.md`, `api/`), the `eduide` chart in `EduIDE-Helm`, and the environment files of this repository.

## Modules

| # | Module | File | Prefix | Kind | Prod-safe tests |
|---|---|---|---|---|---|
| 01 | Platform health and versions | [modules/01-platform.md](modules/01-platform.md) | PLAT | server | all |
| 02 | Landing page | [modules/02-landing-page.md](modules/02-landing-page.md) | LAND | browser | some |
| 03 | Service API | [modules/03-service-api.md](modules/03-service-api.md) | API | server + browser token | some |
| 04 | Operator and session lifecycle | [modules/04-operator.md](modules/04-operator.md) | OPR | server | some |
| 05 | Warm pool and pool scaler | [modules/05-warm-pool.md](modules/05-warm-pool.md) | POOL | server | some |
| 06 | Agent and launch data | [modules/06-agent-launch-data.md](modules/06-agent-launch-data.md) | AGT | server | some |
| 07 | Workspace retention | [modules/07-workspace-retention.md](modules/07-workspace-retention.md) | RET | server | some |
| 08 | IDE per language and template | [modules/08-ide.md](modules/08-ide.md) | IDE | browser | none |
| 09 | Security: access, isolation, data | [modules/09-security.md](modules/09-security.md) | SEC | server | most |
| 10 | Monitoring and alerting | [modules/10-monitoring.md](modules/10-monitoring.md) | MON | server | all |
| 11 | Upgrade and rollback smoke | [modules/11-upgrade-rollback.md](modules/11-upgrade-rollback.md) | UPG | server + workflows | none |
| 12 | Artemis integration | [modules/12-artemis.md](modules/12-artemis.md) | ART | browser | none, **skipped for now** |

Module 01 always runs first: it pins the versions every other result refers to.
Module 12 needs a login on the Artemis test server and is skipped until one is available; record its tests as `skipped`.
Number 13 is reserved for a module that another branch adds (Git accounts, PR 199).

Modules 06 and 07 replace the data bridge and the workspace garbage collector of the Java stack. Their old test IDs (`DB-*`, `GC-*`) are retired; each module lists them with the successor.

## Java stack: Mannheim only

Every environment except `mannheim.eduide.aet.cit.tum.de` is on the Go stack (`spec.platform.stack: go` in `environments/*/env.yaml`; check the files before a run, the stack is chosen per environment). Mannheim has no `stack` key and runs the Java stack (chart `eduide` 2.x, Theia Cloud, `theia.cloud` CRDs, AppDefinitions, data bridge, workspace garbage collector, namespace `eduide-mannheim` on the cluster `eduide`).

This plan does not apply there. What a run on Mannheim does instead:

- Only `prod-safe` checks, never a fixture, never a token.
- Use the Java plan as it stood before this rewrite: `git show 13a6ef3:docs/testing/README.md` and `git show 13a6ef3:docs/testing/modules/<file>`. Run only its `prod-safe` tests of modules 01, 02 (read-only part), 03 (unauthenticated part) and 10.
- Do not use the setup, fixtures or IDs of this file on Mannheim: they name objects that do not exist there.

When Mannheim moves to the Go stack, delete this section.

## Selecting a run

A run is described by three things, recorded at the top of the report:

- **Environment**: one directory name under `environments/` (the landing hostname).
- **Modules**: `all`, or a list such as `01,03,05,06,09`.
- **Mode**: `prod-safe` (only tests marked prod-safe) or `full`.

Production installations (`eduide.artemis.cit.tum.de`, `bonn.eduide.aet.cit.tum.de`) always run in `prod-safe` mode.
`e2e.` belongs to the automated pipeline: do not run `full` there (see AGENTS.md).
`staging.`, `test1.`, `test2.` and `test3.` are the places for `full` runs; tell the people using that environment before disruptive tests. `test3` runs the pool scaler, prepull and the admin panel settings of production; use it for POOL-14 to POOL-17.

## Safety labels

Every test carries one label:

| Label | Meaning |
|---|---|
| `prod-safe` | Read-only. Allowed on every environment, production included. |
| `test-only` | Creates and removes its own `ft-` objects. Never on production. |
| `test-only, disruptive` | Restarts or reconfigures a shared component (operator, service, authz) for a short time, or changes live config and restores it. Never on production; announce on shared test environments. |
| `test-only, destructive` | Can delete data that is not the run's own (other users' workspaces). Needs explicit approval of the person who owns the environment for this run, in chat. |

Rules that hold in every mode:

- Never print, log, or put into the report a token, cookie, password, Secret value, launch data value, or the content of an env var that holds one. Read secrets into shell variables, use them, and print only status codes, counts, key names, or hashes.
- Never enter a password. When a browser login is needed, ask the user to log in in the browser pane.
- Never obtain a user token on production.
- Objects a run creates are named `ft-...` and labelled `eduide.dev/functional-test=<run id>`. Cleanup removes exactly those.
- Never change a production environment's Helm release, IDETemplates, IDEPools or deployments. Never use `clean_install`.
- Do not copy exploit payloads or audit PoCs into this repository or into reports. The security module describes what to check, not how to break it.
- Fixture sessions use a fixture owner (`ft-<module>`), never a real user's name.

## Setup

Run from a checkout of this repository. Set these once per run; every module uses them. The snippets are bash: when the agent's shell is zsh or fish, run them through `bash -c` or check quoting (`custom-columns` arguments with dots or brackets need quotes in zsh).

```bash
export ENV=test2.eduide.student.k8s.aet.cit.tum.de   # directory under environments/
export CTX="<kube context that reaches the cluster>"  # never the current context by accident
export RUN_ID=$(date +%Y-%m-%d)-1                       # also used in the report file name
export NS=$(yq -r .spec.namespace environments/$ENV/env.yaml)
export CLUSTER=$(yq -r .spec.cluster environments/$ENV/env.yaml)
test "$(yq -r .spec.platform.stack environments/$ENV/env.yaml)" = go || { echo "not a Go environment, see 'Java stack: Mannheim only'"; exit 1; }
# Public hosts: the landing page and the REST API share one host (API under /api/v1).
export LANDING=https://$ENV INSTANCE=https://instance.$ENV WEBVIEW=https://webview.instance.$ENV
# Every environment installs the release `eduide`, so the control plane objects are named like this:
export P=eduide-eduide-control-plane          # deployments: $P-operator, $P-service, $P-authz, $P-pool-scaler (test3)
k() { kubectl --context "$CTX" -n "$NS" "$@"; }

# Sanity: the context reaches the right cluster (bootstrap writes this ConfigMap).
test "$(kubectl --context "$CTX" -n eduide-system get cm eduide-cluster-identity -o jsonpath='{.data.clusterName}')" = "$CLUSTER" && echo "cluster ok"
```

Every hostname follows the same pattern on every environment: `$ENV` (landing page and API), `instance.$ENV` (session routes and the `/oauth2/` callback), `webview.instance.$ENV` (one fixed name, no wildcard). See `hosts` in each `values.yaml`.

Other objects of the release: ConfigMap `$P-config` (key `config.yaml`, the typed deployment config), ConfigMap `eduide-landing-page` (key `config.json`), Deployments `eduide-landing-page` and `eduide-oidc-bridge`, Gateway `eduide`, SecurityPolicy `$P-session`, Secret `eduide-oidc` (the gateway client secret; never read it) and `$P-user-salt` (never read it).

Useful read-only listings:

```bash
k get idetemplates -o custom-columns=NAME:.metadata.name,IMAGE:.spec.image,LISTED:.spec.listed,IDLE:.spec.timeouts.idle,WARN:.spec.timeouts.warning,MAX:.spec.timeouts.max
k get idepools
k get idesessions -o custom-columns=NAME:.metadata.name,TEMPLATE:.spec.templateRef,WS:.spec.workspaceRef,PHASE:.status.phase,STRATEGY:.status.startStrategy,AGE:.metadata.creationTimestamp
k get ideworkspaces -o custom-columns=NAME:.metadata.name,TEMPLATE:.spec.templateRef,PHASE:.status.phase,LASTUSED:.status.lastUsed,EXPIRES:.status.expiresAt
k get deploy,pods -o wide
k get pods -l eduide.github.io/component=session -L eduide.github.io/state,eduide.github.io/pool,eduide.github.io/template
```

Do not hard-code template names: the catalog differs per environment and chart version. Pick them from the listing and record them in the report:

- `TPL_POOL`: a template that has an `IDEPool` (for example `java-17` on test2 and test3).
- `TPL_STD`: a listed standalone template shown on the landing page (for example `java-17-standalone`).

### Fixtures (test-only)

Server modules create their own objects instead of touching students' sessions. Sessions, workspaces, templates and pools created directly as custom resources need no user token.

The service and authz only see objects with the label `app.kubernetes.io/managed-by=eduide`, and the service lists a user's sessions by the label `eduide.github.io/owner-hash` (first 40 hex characters of the SHA-256 of the owner name, `OwnerHash` in `api/v1alpha1/helpers.go`). The fixtures set both, so a fixture session shows up in the admin API and counts against its fixture owner's session limit, like a real one. The launch data Secret must carry the same managed-by label, or the operator waits for it.

```bash
# One fixture owner per agent: parallel agents sharing one owner hit the per-owner session limit of each other.
export FT_USER=ft-${MODULE:-bot}      # set MODULE=05 (or a run part) per agent; the owner claim is preferred_username
ft_hash() { printf %s "$1" | shasum -a 256 | cut -c1-40; }

# Clone an IDETemplate under a new name (not managed by Helm, not on the landing page).
# $3 is a JSON object merged into .spec, for example '{"timeouts":{"idle":"3m","warning":"1m","max":"10m"}}'.
ft_template() { # $1 source template, $2 new name, [$3 spec patch]
  local p=${3:-'{}'}
  k get idetemplate "$1" -o json | jq --arg n "$2" --arg r "$RUN_ID" --argjson p "$p" '
    {apiVersion, kind, metadata: {name: $n, labels: {"eduide.dev/functional-test": $r}},
     spec: ((.spec * {listed: false}) * $p)}' | k apply -f -
}

ft_pool() { # $1 template (the pool gets the same name), $2 minIdle, [$3 maxInstances]
  k apply -f - <<EOF
apiVersion: eduide.github.io/v1alpha1
kind: IDEPool
metadata: {name: $1, labels: {eduide.dev/functional-test: "$RUN_ID"}}
spec: {templateRef: $1, minIdle: $2, maxInstances: ${3:-3}}
EOF
}

ft_workspace() { # $1 name, $2 template, [$3 owner], [$4 retention such as 3m]
  local o=${3:-$FT_USER}
  k apply -f - <<EOF
apiVersion: eduide.github.io/v1alpha1
kind: IDEWorkspace
metadata:
  name: $1
  labels: {app.kubernetes.io/managed-by: eduide, eduide.github.io/owner-hash: "$(ft_hash "$o")", eduide.github.io/template: $2, eduide.dev/functional-test: "$RUN_ID"}
spec: {owner: $o, templateRef: $2, persistence: {mode: volume}${4:+, retention: $4}}
EOF
}

ft_session() { # $1 name, $2 template, [$3 workspace, empty = no persistence], [$4 owner]
  # Fake launch data goes in FT_DATA as a JSON object, e.g. FT_DATA='{"TEMPLATE":"maven"}'. The session spec is
  # immutable, so dataSecretRef is set at creation; the Secret follows, owned by the session, like the service does it.
  # kubectl create, not apply: apply copies the plain Secret value into the last-applied-configuration annotation (AGT-08).
  # With a workspace the session is owned by it, like the service does it (RET-02).
  local o=${4:-$FT_USER} h wo=""; h=$(ft_hash "$o")
  if [ -n "${3:-}" ]; then wo=$(k get ideworkspace "$3" -o jsonpath='{.metadata.uid}'); fi
  k create -f - <<EOF
apiVersion: eduide.github.io/v1alpha1
kind: IDESession
metadata:
  name: $1
  labels: {app.kubernetes.io/managed-by: eduide, eduide.github.io/owner-hash: "$h", eduide.dev/functional-test: "$RUN_ID"}${wo:+
  ownerReferences: [{apiVersion: eduide.github.io/v1alpha1, kind: IDEWorkspace, name: $3, uid: "$wo"}]}
spec: {owner: $o, templateRef: $2${3:+, workspaceRef: $3}${FT_DATA:+, dataSecretRef: $1-data}}
EOF
  if [ -n "${FT_DATA:-}" ]; then
    jq -n --arg n "$1-data" --arg s "$1" --arg u "$(k get idesession "$1" -o jsonpath='{.metadata.uid}')" --arg h "$h" --arg r "$RUN_ID" --argjson d "$FT_DATA" '
      {apiVersion: "v1", kind: "Secret",
       metadata: {name: $n, labels: {"app.kubernetes.io/managed-by": "eduide", "eduide.github.io/owner-hash": $h, "eduide.github.io/session": $s, "eduide.dev/functional-test": $r},
                  ownerReferences: [{apiVersion: "eduide.github.io/v1alpha1", kind: "IDESession", name: $s, uid: $u}]},
       stringData: $d}' | k create -f -
  fi
}

ft_wait() { # $1 session: waits for phase Ready (prints the URL) or Failed (prints code and message)
  for _ in $(seq 1 90); do
    s=$(k get idesession "$1" -o jsonpath='{.status.phase}|{.status.url}|{.status.errorCode}|{.status.message}' 2>/dev/null) || { echo "no session $1"; return 1; }
    case "$s" in Ready\|*) echo "$s"; return 0;; Failed\|*) echo "$s"; return 1;; esac
    sleep 5
  done; echo "timeout: $s"; return 1
}

ft_cleanup() {
  k delete idesessions -l eduide.dev/functional-test=$RUN_ID --wait=true
  k delete pods -l eduide.dev/functional-test=$RUN_ID --wait=true
  k delete idepools -l eduide.dev/functional-test=$RUN_ID --wait=true
  k delete ideworkspaces -l eduide.dev/functional-test=$RUN_ID --wait=true
  k delete idetemplates -l eduide.dev/functional-test=$RUN_ID --wait=true
}
```

Instance objects. A session pod is named `ide-<instance>`; the Service, HTTPRoute and token Secret carry the same name (`ide-<instance>-token`). A session with an instance names it in its status. Pool instances (idle) have no session label; claimed ones carry `eduide.github.io/session=<session>`.

```bash
POD=$(k get idesession ft-s1 -o jsonpath='{.status.podName}')
INST=$(k get idesession ft-s1 -o jsonpath='{.status.instance}')
k get pod $POD -o jsonpath='{.spec.containers[*].name}'   # ide agent
```

The `ide` container is the IDE (template image, listens on `127.0.0.1`, no launch data in its spec). The `agent` container is a minimal image with a read-only root filesystem: do not expect a shell in it; read its log with `k logs $POD -c agent`.

Session and pool events carry the story of a launch: `k get events --field-selector involvedObject.name=<session>` shows `Created` (cold start), `Claimed` (warm), `Ready`, `Ended` (timeout), `Failed`, `Reclaimed`. The operator's log is one JSON object per line (`docs/operations/logging.md` in the control plane): filter with `grep` on the session name.

### Opening a fixture session in the browser (test-only)

A fixture session belongs to a fixture owner, so the gateway (authz) refuses a real user who opens its URL; that is by design (SEC-13). To look at a fixture IDE, forward the IDE port of its pod. This bypasses the gateway and the agent proxy and is only for `ft-` fixtures:

```bash
k port-forward $POD 38302:3000 >/dev/null 2>&1 & PF=$!
# open http://127.0.0.1:38302/ in the browser pane; kill $PF when done
```

The IDE extension `eduide-session` inside the IDE long-polls the agent on `127.0.0.1:8082` of the pod and sends heartbeats on real input; that works through this tunnel. Keep the IDE tab in the foreground: in a hidden browser pane the IDE needs minutes to connect, and the template is only applied once it does. Closing the tab (or the port-forward) stops the heartbeats, which the inactivity tests use.

A session of the logged-in test user (started from the landing page) opens through the real URL and needs no port-forward.

### A user token for service API tests (test environments only)

Most API endpoints need an OIDC access token of the realm. The landing page keeps it in memory (keycloak-js, not on `window`) and sends it as `Authorization: Bearer ...` on every API call. The event streams (`/sessions/<name>/events`, `/me/overview/events`) call the global `fetch` at the moment they start, so a hook on `window.fetch` sees the token when a launch starts watching its session. To use it without ever printing it:

1. Never on production. Ask the user to log in on `$LANDING` in the browser pane (the agent never types a password).
2. On the landing page, before clicking anything, install a hook in the page context (javascript tool):

   ```js
   (() => {
     const o = window.fetch;
     window.fetch = function (input, init) {
       const h = init && init.headers;
       const v = h && (h.Authorization || (h.get && h.get('Authorization')));
       if (v && v.startsWith('Bearer ')) sessionStorage.setItem('ft.tok', v.slice(7));
       return o.apply(this, arguments);
     };
     return 'hook installed';
   })()
   ```

3. Start any template from a tile. The page opens the event stream of the new session, the hook stores the token, and the page then navigates to the session. Navigate back to `$LANDING`. The token stays in the tab's `sessionStorage` for the landing origin. Record the launched session for cleanup.
4. Call the API from the landing page context (same origin, so no CORS), so the token never leaves the browser. Return only status and a short body:

   ```js
   window.api = async (method, path, body) => {
     const tok = sessionStorage.getItem('ft.tok');
     const r = await fetch('/api/v1' + path, {
       method, headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + tok },
       body: body ? JSON.stringify(body) : undefined });
     return { status: r.status, body: (await r.text()).slice(0, 400) };
   };
   ```

   Example: `await api('GET', '/sessions')`.
5. Access tokens are short-lived (Keycloak default 5 minutes). On a 401 that the test does not expect, re-capture: install the hook again and start the same tile (a repeated launch returns the running session at once and opens its stream), then navigate back to `$LANDING`.
6. At the end: `sessionStorage.removeItem('ft.tok')`.

The claim `preferred_username` of that token is the owner of the user's sessions. Tests that need fixtures owned by that user read it in the page (`JSON.parse(atob(tok.split('.')[1])).preferred_username`), pass it to the shell as `ME`, and never write it into the report.

### What needs a login, and namespaces

In the first run (2026-11-24, [report](reports/2026-11-24-test2.eduide.student.k8s.aet.cit.tum.de-1.md)) 29 tests were `blocked` because nobody was logged in: LAND-02 to LAND-05, LAND-08, LAND-10, LAND-11, LAND-13, LAND-15, LAND-16, LAND-18 to LAND-20, API-03 to API-09, API-16, API-19 to API-22, SEC-10 (launch part), SEC-13 and GIT-02, GIT-03. Everything that needs a user token or the landing page UI is in this group. To unblock a run: the user logs in on `$LANDING` in the browser pane (the agent never types a password and never obtains a token on production), then the agent installs the token hook below and works from the landing page context.

Some tests read other namespaces: the setup block and PLAT-01 read `eduide-system` (cluster identity, release `eduide-crds`), MON reads `cattle-monitoring-system` and `cattle-dashboards`. A run restricted to one namespace cannot do them: record them as `blocked`.

### Unverified, check in the first run

These setup items come from the sources and from a read-only look at test2, not from a run (confirmed items are removed; the 2026-11-24 run confirmed the port-forward to 3000, 8081 and 8082 and `ft_template`):

- The `window.fetch` hook sees the token (step 3 above): not run on 2026-11-24 (no login). If the API client keeps its own reference to `fetch`, only the event streams call the hook; if the streams do too, record the procedure as `blocked` and describe what happened.
- `ft_session` with a workspace sets the owner reference now (changed after the first run); re-check that the CRD accepts it with `kubectl create`.
- `kubectl auth can-i <verb> pods/exec --as=system:serviceaccount:...` answered `yes` for the operator on test2 although its Role lists only `pods`, not `pods/exec` (checked 2026-11-24). Use the Role rules (SEC-07), not `can-i`, until this is understood.

This procedure is not covered by an automated test. If it fails, mark the dependent tests `blocked` and describe what happened.

## Writing a test into a module

Each test has a stable ID (`<PREFIX>-<NN>`, never reused) and these fields:

```
### API-07 Short title
Safety: prod-safe | test-only | test-only, disruptive | test-only, destructive
Needs: what must be true or available (token, exec rights, a second account, ...)
Steps: numbered, with concrete commands
Expect: observable results that decide pass or fail
Cleanup: what to remove or restore (omit when nothing)
```

Each module ends with an **Unverified, check in the first run** list (steps that could not be checked against the sources or a live environment when the test was written) and an **Explore** section: open-ended ideas for the agent to try beyond the scripted tests. A module that retired tests lists them in a **Retired** section.

## Running

1. Load the setup above and run module 01. Stop if the versions are not what the run is meant to test.
2. Run the selected modules. Server modules (01, 03 server part, 04, 05, 06, 07, 09, 10) are independent of each other and can run in parallel, each with its own `ft-<module>-` name prefix, its own `FT_USER` and its own subagent. Browser modules (02, 08, 12, and the token part of 03) share one browser and one login: run them one after the other.
3. Per test record `pass`, `fail`, `blocked` (could not run: missing access, precondition false), or `skipped` (deliberately not run: mode, selection, Artemis). Evidence is the command plus the relevant output lines, or a screenshot path, never secret values.
4. Explore beyond the plan (next section).
5. Run cleanup (`ft_cleanup`, restore anything a disruptive test changed) and check that no `ft-` object is left: `k get idesessions,ideworkspaces,idepools,idetemplates,pods,secrets | grep ft-`.
6. Write the report (below) and propose plan updates.

## Beyond the plan

The scripted tests check what we already know can break. Every run also spends time on what nobody wrote down yet:

- Use each module's Explore section as a starting point, not as a list to tick off.
- Heuristics that find bugs here: boundaries (0, 1, max, one over max), concurrency (two tabs, two sessions, two launches in the same second), interruption (restart a component in the middle of a flow), stale state (old sessions, removed templates, rotated tokens), wrong identity (another user's names), and "the error path nobody looks at" (what does the student see?).
- Stay inside the safety label of the environment. Exploration on production is read-only.
- Record every exploration in the report, including the ones that found nothing: what was tried, how, and what happened. A finding without steps to reproduce is not a finding.
- If an exploration should become a scripted test, write it as a proposal in the report ("Plan updates" section) with the full test fields.

## Reports

- One file per run: `docs/testing/reports/<YYYY-MM-DD>-<environment>-<n>.md`, for example `2026-11-17-test2.eduide.student.k8s.aet.cit.tum.de-1.md`. Copy [report-template.md](report-template.md).
- Reports may name environments, versions, pod and session names of `ft-` objects, and error messages. They never contain tokens, cookies, Secret values, launch data values, or personal data (students' names or email addresses, real users' session names). Write `<redacted>` instead.
- Commit the report in a pull request of its own (or together with the plan update it proposes).
- The three reports of 2026-11-17 describe the Java stack (Theia Cloud, EduIDE-Cloud 3.0.x). They stay as history; their test IDs refer to the plan before the Go rewrite (see the retired lists in the modules).

## Changing the plan

The plan changes through pull requests to this directory, never silently during a run.

- A run proposes changes in its report: new tests, tests whose expectation turned out wrong (after checking that the code is not the thing that is wrong), retired tests, new Explore ideas.
- A follow-up PR applies them: edit the module, keep IDs stable, mark retired tests in the module's Retired list (`<ID>: <date>, <reason>`) instead of deleting their ID, and add a line to the changelog below.
- When a component changes behaviour (new release, new chart value), the PR that moves the version into an environment should also update the affected tests, or name the gap in its description.
- Every concrete detail in a test must be checkable in the code or config of the repository it comes from. Add the source (`repo:path`) when it is not obvious. What cannot be checked goes into the module's "Unverified" list.

## Changelog

| Date | Change |
|---|---|
| 2026-11-16 | First version: modules 01 to 12, report template, `functional-check` skill. Grounded in EduIDE-Cloud 3.0.1, EduIDE-Helm 3.0.0 (main), EduIDE 2.0.0-rc.3, scorpio 3.1.0, EduIDE-data-bridge 2.0.0, Landing 1.4.1, workspace-garbage-collector 1.0.0. |
| 2026-11-17 | First full run on test2 ([report](reports/2026-11-17-test2-1.md)) applied: new tests SEC-10, SEC-11, MON-08, OPR-11 to OPR-14, POOL-11 to POOL-13, DB-11 to DB-13, GC-07, LAND-13, API-16 to API-18, UPG-05; corrected PLAT-04, PLAT-05, MON-02, MON-03 to MON-06 (alerting precondition), OPR-04, OPR-05, POOL-01, POOL-07, API-09, API-14, API-15, LAND-05, LAND-08, IDE-02, GC-06, DB-05, SEC-02, SEC-07, UPG-01, UPG-03; README: one `FT_USER` per agent, `sessionSecret` in `ft_session`, `ft_wait` exit on a missing Session, eager and sidecar pods, token Secrets by owner, port-forward browser step, token lifetime, `APPID` first match. |
| 2026-11-17 | Re-test of F1 to F5, F12, F19 on chart 3.0.0-rc.4 / Cloud 3.0.2 ([report](reports/2026-11-17-test2-2.md)): POOL-11 to POOL-13, OPR-13, DB-12, UPG-05, MON-08 expect the fixed behaviour; sidecar object names, dead-instance recipe, workflow restart noted. |
| 2026-11-24 | Rewrite for the Go control plane (EduIDE 3.x, control plane chart 0.2.3, chart `eduide` 3.0.x). Setup and fixtures create `IDETemplate`, `IDEPool`, `IDEWorkspace` and `IDESession` (group `eduide.github.io`); the API is `/api/v1` on the landing host and the token hook watches `fetch`. Modules 06 and 07 are renamed "Agent and launch data" (AGT) and "Workspace retention" (RET). Kept and rewritten: PLAT-01 to PLAT-07, LAND-02 to LAND-05, LAND-08 to LAND-13, API-01 to API-09, API-11, API-13 to API-16, API-18, OPR-01 to OPR-08, OPR-10 to OPR-14, POOL-01 to POOL-10, POOL-13, IDE-01 to IDE-09 (edited), SEC-02 to SEC-11, MON-01 to MON-08, UPG-01 to UPG-05, ART-01 to ART-05. Retired: LAND-01, LAND-06, LAND-07, API-10, API-12, API-17, OPR-09, POOL-11, POOL-12, SEC-01, DB-01 to DB-13, GC-01 to GC-07 (reasons in each module). New: PLAT-08 to PLAT-10, LAND-14 to LAND-20, API-19 to API-22, OPR-15, OPR-16, POOL-14 to POOL-17, AGT-01 to AGT-06, AGT-08 to AGT-10, AGT-12 (AGT-07 and AGT-11 are unused), RET-01 to RET-08, SEC-12 to SEC-15, MON-09 to MON-12, UPG-06, ART-06, ART-07. Every module has an "Unverified, check in the first run" list. Mannheim stays on Java and has its own section; reports of 2026-11-17 are history. Number 13 stays free. |
| 2026-11-24 | First run of the Go plan on test2 ([report](reports/2026-11-24-test2.eduide.student.k8s.aet.cit.tum.de-1.md): 63 pass, 0 fail, 29 blocked for lack of a login, 54 skipped) applied 9 plan corrections: PLAT-10, OPR-01 and RET-01 use `yq -o json \| jq`; SEC-06 forbids token values, not the names `AGENT_TOKEN_FILE` and `AGENT_ID_TOKEN_COOKIE`; `ft_session` uses `kubectl create` (AGT-08) and sets the workspace owner reference (RET-02); AGT-10 waits more than 2 minutes; MON-01 and MON-03 compare with the rendered chart; API-14 `/api/metrics` is a JSON 404; SEC-07 uses `curl` in the IDE container; API-01 `logoUrl` only where configured. Login-blocked tests and cross-namespace reads documented. |
