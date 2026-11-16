# Functional test plan

A manual, agent-executable check of a deployed EduIDE installation. It complements the automated tests on `e2e.` (which follow `main`) and is meant for release candidates, upgrades, and "is this environment healthy" questions.

The plan is split into modules. A run selects all modules or any subset, writes one report, and proposes plan updates in that report. The `functional-check` skill (`.claude/skills/functional-check/SKILL.md`) walks an agent through a run.

## Modules

| # | Module | File | Prefix | Kind | Prod-safe tests |
|---|---|---|---|---|---|
| 01 | Platform health and versions | [modules/01-platform.md](modules/01-platform.md) | PLAT | server | all |
| 02 | Landing page | [modules/02-landing-page.md](modules/02-landing-page.md) | LAND | browser | some |
| 03 | Service API | [modules/03-service-api.md](modules/03-service-api.md) | API | server + browser token | some |
| 04 | Operator and session lifecycle | [modules/04-operator.md](modules/04-operator.md) | OPR | server | some |
| 05 | Warm pool (prewarming) | [modules/05-warm-pool.md](modules/05-warm-pool.md) | POOL | server | some |
| 06 | Data bridge | [modules/06-data-bridge.md](modules/06-data-bridge.md) | DB | server | some |
| 07 | Workspace garbage collector | [modules/07-garbage-collector.md](modules/07-garbage-collector.md) | GC | server | some |
| 08 | IDE per language and template | [modules/08-ide.md](modules/08-ide.md) | IDE | browser | none |
| 09 | Security regressions (2026-11-16 audit) | [modules/09-security.md](modules/09-security.md) | SEC | server | most |
| 10 | Monitoring and alerting | [modules/10-monitoring.md](modules/10-monitoring.md) | MON | server | all |
| 11 | Upgrade and rollback smoke | [modules/11-upgrade-rollback.md](modules/11-upgrade-rollback.md) | UPG | server + workflows | none |
| 12 | Artemis integration | [modules/12-artemis.md](modules/12-artemis.md) | ART | browser | none, **skipped for now** |

Module 01 always runs first: it pins the versions every other result refers to.
Module 12 needs a login on the Artemis test server and is skipped until one is available; record its tests as `skipped`.

## Selecting a run

A run is described by three things, recorded at the top of the report:

- **Environment**: one directory name under `environments/` (the landing hostname).
- **Modules**: `all`, or a list such as `01,03,05,06,09`.
- **Mode**: `prod-safe` (only tests marked prod-safe) or `full`.

Production installations (`eduide.artemis.cit.tum.de`, `bonn.eduide.aet.cit.tum.de`, `mannheim.eduide.aet.cit.tum.de`) always run in `prod-safe` mode.
`e2e.` belongs to the automated pipeline: do not run `full` there (see AGENTS.md).
`staging.`, `test1.` and `test2.` are the places for `full` runs; tell the people using that environment before disruptive tests.

## Safety labels

Every test carries one label:

| Label | Meaning |
|---|---|
| `prod-safe` | Read-only. Allowed on every environment, production included. |
| `test-only` | Creates and removes its own `ft-` objects. Never on production. |
| `test-only, disruptive` | Restarts or reconfigures a shared component (operator, service) for a short time, or changes live config and restores it. Never on production; announce on shared test environments. |
| `test-only, destructive` | Can delete data that is not the run's own (other users' workspaces). Needs explicit approval of the person who owns the environment for this run, in chat. |

Rules that hold in every mode:

- Never print, log, or put into the report a token, cookie, password, Secret value, or the content of an env var that holds one. Read secrets into shell variables, use them, and print only status codes, counts, or hashes.
- Never enter a password. When a browser login is needed, ask the user to log in in the browser pane.
- Never obtain a user token on production.
- Objects a run creates are named `ft-...` and labelled `eduide.dev/functional-test=<run id>` where the API allows a label. Cleanup removes exactly those.
- Never change a production environment's Helm release, AppDefinitions, or deployments. Never use `clean_install`.
- Do not copy exploit payloads or audit PoCs into this repository or into reports. The security module describes what to check, not how to break it.

## Setup

Run from a checkout of this repository. Set these once per run; every module uses them.

```bash
export ENV=test2.eduide.student.k8s.aet.cit.tum.de   # directory under environments/
export CTX="<kube context that reaches the cluster>"  # never the current context by accident
export RUN_ID=$(date +%Y-%m-%d)-1                       # also used in the report file name
export NS=$(yq -r .spec.namespace environments/$ENV/env.yaml)
export CLUSTER=$(yq -r .spec.cluster environments/$ENV/env.yaml)
export LANDING=https://$ENV SERVICE=https://service.$ENV INSTANCE=https://instance.$ENV
k() { kubectl --context "$CTX" -n "$NS" "$@"; }

# The service auth token is public (it is shipped to every browser in config.js), not a secret.
export APPID=$(curl -fsS "$LANDING/config.js" | sed -n 's/.*serviceAuthToken: "\([^"]*\)".*/\1/p')

# Sanity: the context reaches the right cluster (bootstrap writes this ConfigMap).
test "$(kubectl --context "$CTX" -n eduide-system get cm eduide-cluster-identity -o jsonpath='{.data.clusterName}')" = "$CLUSTER" && echo "cluster ok"
```

Every hostname follows the same pattern on every environment: `service.$ENV`, `instance.$ENV`, `*.webview.instance.$ENV` (see `hosts.configuration` in each `values.yaml`).

Useful read-only listings:

```bash
k get appdefinitions -o custom-columns=NAME:.metadata.name,IMAGE:.spec.image,MIN:.spec.minInstances,MAX:.spec.maxInstances,TIMEOUT:.spec.timeout,NOTIFY:.spec.monitor.activityTracker.notifyAfter,IDLE:.spec.monitor.activityTracker.timeoutAfter
k get sessions -o custom-columns=NAME:.metadata.name,APP:.spec.appDefinition,WS:.spec.workspace,STATUS:.status.operatorStatus,AGE:.metadata.creationTimestamp
k get workspaces -o custom-columns=NAME:.metadata.name,APP:.spec.appDefinition,AGE:.metadata.creationTimestamp
k get deploy,pods -o wide
```

Do not hard-code app names: the catalog differs per environment and chart version. Pick them from the listing and record them in the report:

- `APP_POOL`: an app with `minInstances > 0` (warm pool, e.g. `java-17` with chart 3.x).
- `APP_STD`: a standalone app shown on the landing page (e.g. `java-17-standalone`).

### Fixtures (test-only)

Server modules create their own objects instead of touching students' sessions. Sessions and workspaces created directly as custom resources need no user token.

```bash
FT_USER=ft-bot@functional-test.invalid

# Clone an existing AppDefinition under a new name (not managed by Helm, not on the landing page).
ft_appdef() { # $1 source app, $2 new name, $3 minInstances
  k get appdefinition "$1" -o json | jq --arg n "$2" --argjson m "$3" --arg r "$RUN_ID" '
    del(.metadata.uid,.metadata.resourceVersion,.metadata.creationTimestamp,.metadata.generation,
        .metadata.managedFields,.metadata.annotations,.metadata.ownerReferences,.status)
    | .metadata.name=$n | .spec.name=$n | .spec.minInstances=$m
    | .metadata.labels={"eduide.dev/functional-test":$r}' | k apply -f -
}

ft_workspace() { # $1 name, $2 app definition, [$3 user]
  k apply -f - <<EOF
apiVersion: theia.cloud/v1beta5
kind: Workspace
metadata: {name: $1, labels: {eduide.dev/functional-test: "$RUN_ID"}}
spec: {name: $1, appDefinition: $2, user: ${3:-$FT_USER}, label: functional-test}
EOF
}

ft_session() { # $1 name, $2 app definition, [$3 workspace, empty = ephemeral], [$4 user]
  # Session env goes in FT_ENV as a YAML map, e.g. FT_ENV='{THEIA: "1", TEMPLATE: maven}' ft_session ...
  local env=${FT_ENV:-"{}"}
  k apply -f - <<EOF
apiVersion: theia.cloud/v1beta8
kind: Session
metadata: {name: $1, labels: {eduide.dev/functional-test: "$RUN_ID"}}
spec: {name: $1, appDefinition: $2, workspace: "${3:-}", user: ${4:-$FT_USER}, envVars: $env}
EOF
}

ft_wait() { # $1 session: waits for HANDLED and a URL
  for _ in $(seq 1 90); do
    s=$(k get session "$1" -o jsonpath='{.status.operatorStatus} {.status.url}' 2>/dev/null)
    case "$s" in HANDLED\ ?*) echo "$s"; return 0;; ERROR*) echo "$s"; return 1;; esac
    sleep 10
  done; echo "timeout: $s"; return 1
}

ft_cleanup() {
  k delete sessions -l eduide.dev/functional-test=$RUN_ID --wait=true
  k delete workspaces -l eduide.dev/functional-test=$RUN_ID --wait=true
  k delete appdefinitions -l eduide.dev/functional-test=$RUN_ID --wait=true
}
```

Session pods carry `app.kubernetes.io/component=session`, `theia-cloud.io/session=<session>` and `theia-cloud.io/app-definition=<app>`. Find a session's pod and its IDE container like this:

```bash
POD=$(k get pod -l theia-cloud.io/session=ft-s1 -o name | head -1)
k get $POD -o jsonpath='{.spec.containers[*].name}'   # the IDE container is the one that is not oauth2-proxy
```

### A user token for service API tests (test environments only)

Most service endpoints need a Keycloak token. The landing page keeps it in memory inside its bundle (keycloak-js, module scope, not on `window`) and sends the **ID token** as `Authorization: Bearer ...` on its XHR calls. To use it without ever printing it:

1. Never on production. Ask the user to log in on `$LANDING` in the browser pane (the agent never types a password).
2. On the landing page, before clicking anything, install a hook in the page context (javascript tool):

   ```js
   (() => {
     const o = XMLHttpRequest.prototype.setRequestHeader;
     XMLHttpRequest.prototype.setRequestHeader = function (k, v) {
       if (k === 'Authorization') sessionStorage.setItem('ft.tok', v.slice(7));
       return o.apply(this, arguments);
     };
     return 'hook installed';
   })()
   ```

3. Trigger an authenticated request: launch any app from a tile (the page refreshes the token first). The page then navigates to the session; navigate back to `$LANDING`. The token stays in the tab's `sessionStorage` for the landing origin. Record the launched session for cleanup.
4. Call the service from the landing page context, so the token never leaves the browser and CORS allows the call. Return only status and a short body:

   ```js
   window.api = async (method, path, body) => {
     const tok = sessionStorage.getItem('ft.tok');
     const r = await fetch(window.theiaCloudConfig.serviceUrl.replace(/\/service$/, '') + path, {
       method, headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + tok },
       body: body ? JSON.stringify(body) : undefined });
     return { status: r.status, body: (await r.text()).slice(0, 400) };
   };
   ```

   Example: `await api('GET', '/service/session/' + window.theiaCloudConfig.serviceAuthToken + '/' + '<user>')`.
5. ID tokens are short-lived (minutes). On a 401 that the test does not expect, repeat steps 2 and 3.
6. At the end: `sessionStorage.removeItem('ft.tok')`.

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

Each module ends with an **Explore** section: open-ended ideas for the agent to try beyond the scripted tests.

## Running

1. Load the setup above and run module 01. Stop if the versions are not what the run is meant to test.
2. Run the selected modules. Server modules (01, 03 server part, 04, 05, 06, 07, 09, 10) are independent of each other and can run in parallel, each with its own `ft-<module>-` name prefix and its own subagent. Browser modules (02, 08, 12, and the token part of 03) share one browser and one login: run them one after the other.
3. Per test record `pass`, `fail`, `blocked` (could not run: missing access, precondition false), or `skipped` (deliberately not run: mode, selection, Artemis). Evidence is the command plus the relevant output lines, or a screenshot path, never secret values.
4. Explore beyond the plan (next section).
5. Run cleanup (`ft_cleanup`, restore anything a disruptive test changed) and check that no `ft-` object is left: `k get sessions,workspaces,appdefinitions | grep ft-`.
6. Write the report (below) and propose plan updates.

## Beyond the plan

The scripted tests check what we already know can break. Every run also spends time on what nobody wrote down yet:

- Use each module's Explore section as a starting point, not as a list to tick off.
- Heuristics that find bugs here: boundaries (0, 1, max, one over max), concurrency (two tabs, two sessions, two launches in the same second), interruption (restart a component in the middle of a flow), stale state (old sessions, removed apps, rotated tokens), wrong identity (another user's names), and "the error path nobody looks at" (what does the student see?).
- Stay inside the safety label of the environment. Exploration on production is read-only.
- Record every exploration in the report, including the ones that found nothing: what was tried, how, and what happened. A finding without steps to reproduce is not a finding.
- If an exploration should become a scripted test, write it as a proposal in the report ("Plan updates" section) with the full test fields.

## Reports

- One file per run: `docs/testing/reports/<YYYY-MM-DD>-<environment>-<n>.md`, for example `2026-11-17-test2.eduide.student.k8s.aet.cit.tum.de-1.md`. Copy [report-template.md](report-template.md).
- Reports may name environments, versions, pod and session names of `ft-` objects, and error messages. They never contain tokens, cookies, Secret values, env values of sessions, or personal data (students' names or email addresses, real users' session names). Write `<redacted>` instead.
- Commit the report in a pull request of its own (or together with the plan update it proposes).

## Changing the plan

The plan changes through pull requests to this directory, never silently during a run.

- A run proposes changes in its report: new tests, tests whose expectation turned out wrong (after checking that the code is not the thing that is wrong), retired tests, new Explore ideas.
- A follow-up PR applies them: edit the module, keep IDs stable, mark retired tests `Retired: <date>, <reason>` instead of deleting their ID, and add a line to the changelog below.
- When a component changes behaviour (new release, new chart value), the PR that moves the version into an environment should also update the affected tests, or name the gap in its description.
- Every concrete detail in a test must be checkable in the code or config of the repository it comes from. Add the source (`repo:path`) when it is not obvious.

## Changelog

| Date | Change |
|---|---|
| 2026-11-16 | First version: modules 01 to 12, report template, `functional-check` skill. Grounded in EduIDE-Cloud 3.0.1, EduIDE-Helm 3.0.0 (main), EduIDE 2.0.0-rc.3, scorpio 3.1.0, EduIDE-data-bridge 2.0.0, Landing 1.4.1, workspace-garbage-collector 1.0.0. |
