# Functional test plan for the Go control plane

A manual, agent-executable check of a deployed EduIDE control plane (repository `EduIDE-control-plane`: `operator`, `service`, `authz`, `agent`, pool scaler, landing page).
It adapts the plan for the old Java stack ([../README.md](../README.md)) to the new CRDs (`*.eduide.github.io/v1alpha1`), the REST API (`/api/v1`), gateway auth with ext_authz and the agent sidecar.
[mapping.md](mapping.md) lists every old test ID and what became of it.

The first environment is **test3** (namespace `eduide-test3`, context `stud`).
The design is [plans/2026-11-18-eduide-control-plane-go.md](../../../../plans/2026-11-18-eduide-control-plane-go.md) (decisions G1 to G19, U1 to U10), the contracts are in the control plane repository (`api/v1alpha1`, `api/openapi/v1.yaml`, `api/agent/v1.yaml`, `internal/config/config.go`, `docs/contracts/metrics.md`, ADR 0005 and 0006).
When code and this plan disagree, check the code first: the plan is wrong only if the code matches the design.

## Modules

| # | Module | File | Prefix | Kind | Prod-safe tests |
|---|---|---|---|---|---|
| 01 | Platform health and versions | [modules/01-platform.md](modules/01-platform.md) | PLAT | server | all |
| 02 | Landing page | [modules/02-landing-page.md](modules/02-landing-page.md) | LAND | browser | some |
| 03 | Service API | [modules/03-service-api.md](modules/03-service-api.md) | API | server + browser token | some |
| 04 | Operator and session lifecycle | [modules/04-operator.md](modules/04-operator.md) | OPR | server | some |
| 05 | Warm pool and start strategies | [modules/05-warm-pool.md](modules/05-warm-pool.md) | POOL | server | some |
| 06 | Agent and data path | [modules/06-agent.md](modules/06-agent.md) | AGENT | server | none |
| 07 | Workspace retention | [modules/07-workspace-ttl.md](modules/07-workspace-ttl.md) | WS | server | some |
| 08 | IDE per language and template | [modules/08-ide.md](modules/08-ide.md) | IDE | browser | none |
| 09 | Security regressions and isolation | [modules/09-security.md](modules/09-security.md) | SEC | server | most |
| 10 | Monitoring, metrics contract and traces | [modules/10-monitoring.md](modules/10-monitoring.md) | MON | server | most |
| 11 | Upgrade and rollback smoke | [modules/11-upgrade-rollback.md](modules/11-upgrade-rollback.md) | UPG | server + workflows | none |
| 12 | Artemis integration | [modules/12-artemis.md](modules/12-artemis.md) | ART | browser | none, **skipped for now** |
| 13 | Session access (authz decision table) | [modules/13-authz.md](modules/13-authz.md) | AUTHZ | browser + server | some |
| 14 | Startup time and footprint | [modules/14-performance.md](modules/14-performance.md) | PERF | server + browser | some |

Module 01 always runs first: it pins the versions every other result refers to.
Module 12 needs a login on the Artemis test server and is skipped until one is available; record its tests as `skipped`.

## Selecting a run

A run is described by three things, recorded at the top of the report:

- **Environment**: `test3` for now (`test3.eduide.student.k8s.aet.cit.tum.de`).
- **Modules**: `all`, or a list such as `01,03,05,13`.
- **Mode**: `prod-safe` (only tests marked prod-safe) or `full`.

The new stack runs only on test3 (decision U9).
Later deployments (staging, Bonn, Mannheim, production) follow the migration plan; a production deployment always runs in `prod-safe` mode.
Never touch: existing namespaces (`eduide-test1`, `eduide-test2`, `eduide-e2e`, ...), `eduide-cluster`, the shared Gateway, and the context `eduide` (production).
Tell the people using test3 before disruptive tests.

## Safety labels

Every test carries one label:

| Label | Meaning |
|---|---|
| `prod-safe` | Read-only. Allowed on every deployment, production included. |
| `test-only` | Creates and removes its own `ft-` objects. Never on production. |
| `test-only, disruptive` | Restarts, scales or reconfigures a shared component (operator, service, authz, pool), starves a node pool, or changes live config and restores it. Never on production; announce on shared test environments. |
| `test-only, destructive` | Can delete data that is not the run's own (other users' workspaces). Needs explicit approval of the person who owns the environment for this run, in chat. |

Rules that hold in every mode:

- Never print, log, or put into the report a token, cookie, password, Secret value, or the content of an env var that holds one. Read secrets into shell variables, use them, and print only status codes, counts, or hashes. Pass tokens to curl with `-H @-` (header from stdin), not on the command line.
- Never enter a password. When a browser login is needed, ask the user to log in in the browser pane.
- Never obtain a user token on production.
- Objects a run creates are named `ft-...` and labelled `eduide.dev/functional-test=$FT_RUN` (run id plus module, so parallel agents never delete each other's fixtures). Cleanup removes exactly those.
- Every kubectl call goes through `k` (context `stud`, namespace `eduide-test3`). Cluster-scoped reads (`k get crd`, `kubectl get nodes`) are read-only.
- Never run `helm` against the cluster. Deployments go through the workflows (module 11).
- Test data is dummy data (`ft-...` strings, `https://github.com/...` on the allowlist). Never put a real Artemis token or a real user's data into a fixture.
- Do not copy exploit payloads into this repository or into reports. The security modules describe what to check, not how to break it.

## Setup

Run from a checkout of this repository. Background port-forwards use the plain `kubectl` binary, not the `k` function (its PID cannot be killed). The snippets are bash: when the agent's shell is zsh or fish, run them through `bash -c` or take care with quoting.

```bash
export ENV=test3.eduide.student.k8s.aet.cit.tum.de
export CTX=stud                                           # always explicit, never the current context by accident
export NS=eduide-test3
export RUN_ID=$(date +%Y-%m-%d)-1                         # also used in the report file name
export FT_RUN=$RUN_ID-${MODULE:-main}                      # label value of every fixture; set MODULE=05 per agent, never share one value
export LANDING=https://$ENV API=https://$ENV/api/v1
export INSTANCE_HOST=instance.$ENV WEBVIEW_HOST=webview.instance.$ENV
export PF_CTRL=${PF_CTRL:-18081} PF_PROXY=${PF_PROXY:-18080}      # local ports of agent_pf; give every parallel agent its own pair
k() { kubectl --context "$CTX" -n "$NS" "$@"; }

# Sanity: the context reaches the right cluster and the namespace exists.
kubectl config get-contexts "$CTX" >/dev/null && k get ns "$NS" -o name

# Component names come from the chart (charts/eduide-control-plane, helper ecp.fullname = <release>-<chart>).
# Discover the prefix instead of hard-coding the release name; PLAT-01 records it.
export FULL=$(k get deploy -l app.kubernetes.io/component=operator -o jsonpath='{.items[0].metadata.name}' | sed 's/-operator$//')
export CP_SEL=app.kubernetes.io/name=eduide-control-plane          # all control plane pods
# Deployments: $FULL-operator (1 replica, leader election lease eduide-operator), $FULL-service (2), $FULL-authz (2), $FULL-pool-scaler (only when `poolScaler.enabled`; not deployed on test3).
```

Names assumed from the chart at the time of writing (`$FULL-operator`, `$FULL-service`, `$FULL-authz`, `$FULL-config`, NetworkPolicies `$FULL-session-*`, SecurityPolicy `$FULL-session`, HTTPRoutes `$FULL-api` and `$FULL-oauth2`).
If the chart renames something, fix the name in the module and note it in the report.

Hosts on test3:

| Host | Purpose |
|---|---|
| `test3.eduide.student.k8s.aet.cit.tum.de` (`$LANDING`) | landing page (`/`, `/config.json`) and the API (`/api/`) |
| `instance.test3...` (`$INSTANCE_HOST`) | all sessions, as paths: `https://$INSTANCE_HOST/<instance>/`; the OIDC callback (`/oauth2/`) lives here too |
| `webview.instance.test3...` (`$WEBVIEW_HOST`) | the one fixed webview host (decision G3); there is no wildcard name |

Useful read-only listings (custom resources have short names `idet`, `idep`, `idew`, `ides`):

```bash
k get idetemplates -o custom-columns=NAME:.metadata.name,IMAGE:.spec.image,PERSIST:.spec.persistence.allowed,DEFAULT:.spec.persistence.default
k get idepools                                                     # printer columns: template, target, ready, starting, claimed
k get ideworkspaces                                                # owner, template, phase, last used
k get idesessions -o custom-columns=NAME:.metadata.name,OWNER:.spec.owner,TEMPLATE:.spec.templateRef,PHASE:.status.phase,STRATEGY:.status.startStrategy,AGE:.metadata.creationTimestamp
k get pods -l eduide.github.io/component=session -L eduide.github.io/state,eduide.github.io/pool,eduide.github.io/session
k get deploy,pods,svc,httproute,networkpolicy,securitypolicy
```

The session owner is the value of the token claim `oidc.userClaim` (`preferred_username` by default), not an e-mail address.
Reports show owners only as `owner-hash` (`k get idesession <n> -o jsonpath='{.metadata.labels.eduide\.github\.io/owner-hash}'`).

Do not hard-code template names: the catalog differs per deployment. Pick from the listing and record them in the report:

- `T_STD`: any template without pool that allows `none` and `volume` (the fixtures clone it).
- `T_POOL`: a template that has an IDEPool (a warm template; only `none` sessions use the pool).

### Fixtures (test-only)

Server modules create their own objects instead of touching students' sessions.
Sessions and workspaces created directly as custom resources need no user token; they are not visible to the service as that user's own unless their owner is that user (`ME`, see below).

```bash
# One fixture owner per agent: parallel agents sharing one owner hit the per-user session limit of each other.
FT_USER=ft-${MODULE:-bot}          # owner name (a preferred_username value, not an e-mail), set MODULE=05 per agent
OWNER_HASH() { printf %s "$1" | shasum -a 256 | cut -c1-40; }     # api/v1alpha1 OwnerHash: first 40 hex of sha256(owner)

# Clone an IDETemplate under a new name (not managed by Helm). $3 is an optional jq filter applied to the clone, for example
#   ft_template "$T_STD" ft-t1 '.spec.timeouts={"idle":"4m","warning":"2m"}'
#   ft_template "$T_STD" ft-t2 '.spec.injectableKeys += [{"name":"FT_PROBE","source":"Request","format":"Token","maxLength":64}]'
ft_template() {
  k get idetemplate "$1" -o json | jq --arg n "$2" --arg r "$FT_RUN" "
    del(.metadata.uid,.metadata.resourceVersion,.metadata.creationTimestamp,.metadata.generation,
        .metadata.managedFields,.metadata.annotations,.metadata.ownerReferences,.status)
    | .metadata.name=\$n | .metadata.labels={\"eduide.dev/functional-test\":\$r}
    | ${3:-.}" | k apply -f -
}

ft_pool() { # $1 name (also the pool's identity), $2 template, $3 minIdle, [$4 maxInstances, default minIdle+5]
  k apply -f - <<EOF
apiVersion: eduide.github.io/v1alpha1
kind: IDEPool
metadata: {name: $1, labels: {eduide.dev/functional-test: "$FT_RUN"}}
spec: {templateRef: $2, minIdle: $3, targetIdle: $3, maxInstances: ${4:-$(($3 + 5))}}
EOF
}

ft_workspace() { # $1 name, $2 template, [$3 owner], [$4 retention such as 2m]; optional FT_TITLE (default: the name) and FT_SOURCE (display.source)
  local o=${3:-$FT_USER}
  k apply -f - <<EOF
apiVersion: eduide.github.io/v1alpha1
kind: IDEWorkspace
metadata:
  name: $1
  labels: {app.kubernetes.io/managed-by: eduide, eduide.dev/functional-test: "$FT_RUN", eduide.github.io/owner-hash: $(OWNER_HASH "$o")}
spec:
  owner: $o
  templateRef: $2
  persistence: {mode: volume}
  display: {title: "${FT_TITLE-$1}"${FT_SOURCE:+, source: "$FT_SOURCE"}}
  ${4:+retention: $4}
EOF
}

# IDESession plus its data Secret. spec.dataSecretRef is set at creation (the spec is immutable); the Secret follows with an
# ownerReference to the session, like the service does. The operator waits for the Secret if it is not there yet.
# Launch data goes in FT_DATA as a JSON object of strings, e.g. FT_DATA='{"FT_PROBE":"dummy"}'. Use dummy values only.
# Assumption: the Secret keys are the launch data keys (check internal/ once the service writes them; adapt this function if not).
ft_session() { # $1 name, $2 template, [$3 workspace, empty = no persistence], [$4 owner]
  local o=${4:-$FT_USER} d=${FT_DATA:-'{}'} uid t=
  [ -n "$FT_SESSION_TITLE" ] && t="display: {title: \"$FT_SESSION_TITLE\"}"   # not ${..:+display: {..}}, the first } would end the expansion
  k apply -f - <<EOF
apiVersion: eduide.github.io/v1alpha1
kind: IDESession
metadata:
  name: $1
  labels: {app.kubernetes.io/managed-by: eduide, eduide.dev/functional-test: "$FT_RUN", eduide.github.io/owner-hash: $(OWNER_HASH "$o")}
spec:
  owner: $o
  templateRef: $2
  dataSecretRef: $1-data
  ${3:+workspaceRef: $3}
  $t
EOF
  uid=$(k get idesession "$1" -o jsonpath='{.metadata.uid}')
  jq -n --arg s "$1" --arg uid "$uid" --arg r "$FT_RUN" --argjson d "$d" '{apiVersion:"v1",kind:"Secret",
    metadata:{name:($s+"-data"),labels:{"app.kubernetes.io/managed-by":"eduide","eduide.dev/functional-test":$r},
      ownerReferences:[{apiVersion:"eduide.github.io/v1alpha1",kind:"IDESession",name:$s,uid:$uid}]},stringData:$d}' | k apply -f -
}

ft_wait() { # $1 session, [$2 timeout in seconds, default 120]: waits for phase Ready or Failed, prints "<phase> <strategy> <url> <errorCode>"
  local s
  for _ in $(seq 1 $((${2:-120} / 2))); do
    s=$(k get idesession "$1" -o jsonpath='{.status.phase} {.status.startStrategy} {.status.url} {.status.errorCode}' 2>/dev/null) || { echo "no session $1"; return 1; }
    case "$s" in Ready\ *) echo "$s"; return 0;; Failed*) echo "$s"; return 1;; esac
    sleep 2
  done; echo "timeout: $s"; return 1
}

ft_times() { # $1 session: seconds from creation to each recorded timestamp (the start path, PERF-03)
  k get idesession "$1" -o json | jq -r '(.metadata.creationTimestamp|fromdate) as $c | .status.timestamps | to_entries[]
    | "\(.key) +\((.value|fromdate) - $c)s"'
}

ft_cleanup() {
  k delete idesessions -l eduide.dev/functional-test=$FT_RUN --wait=true
  k delete ideworkspaces -l eduide.dev/functional-test=$FT_RUN --wait=true
  k delete idepools -l eduide.dev/functional-test=$FT_RUN --wait=true
  k delete idetemplates -l eduide.dev/functional-test=$FT_RUN --wait=true
  k delete pod,secret,configmap,pvc,resourcequota -l eduide.dev/functional-test=$FT_RUN --wait=true
}
```

A session pod has the containers `ide` and `agent`.
Find the pod, its instance id and its token Secret by label and name pattern (warm, claimed and cold pods all look the same):

```bash
POD=$(k get pod -l eduide.github.io/session=ft-s1 -o name | head -1)           # claimed pool pods keep the pool label and get the session label
INST=$(k get idesession ft-s1 -o jsonpath='{.status.instance}')                 # 20 characters, also label eduide.github.io/instance and the URL path segment
k get $POD -o jsonpath='{.spec.containers[*].name}'                             # ide agent
# Per instance: Pod ide-<instance>, Service ide-<instance>, HTTPRoute ide-<instance>, Secret ide-<instance>-token (key token).
# Service, HTTPRoute and Secret are owned by the Pod.
```

Idle pool pods have no session label; list them by pool:

```bash
pool_pods() { # $1 pool name: pod, state, session, phase, all containers ready
  k get pods -l "eduide.github.io/pool=$1" -o json | jq -r '.items[] | [.metadata.name,
    .metadata.labels["eduide.github.io/state"], (.metadata.labels["eduide.github.io/session"] // "-"), .status.phase,
    ([.status.containerStatuses[]?.ready] | all | tostring)] | @tsv'
  k get idepool "$1" -o jsonpath='ready={.status.idleReady} starting={.status.idleStarting} claimed={.status.claimed} target={.spec.targetIdle}{"\n"}'
}
```

### Reaching an agent (test-only)

The agent has three listeners (`api/agent/v1.yaml`): proxy `:8080` (Envoy only, needs `X-EduIDE-Instance-Token`), control `:8081` (operator, `Authorization: Bearer <instance token>`; `/healthz` and `/readyz` without auth) and local `127.0.0.1:8082` (extension, no auth).
The control port is closed to everything except the operator, but `kubectl port-forward` goes through the kubelet and works.
The token is read into a shell variable inside the function and handed to curl on stdin; it is never printed.

```bash
agent_pf() { # $1 instance id: forwards $PF_CTRL (control) and $PF_PROXY (proxy) of ide-<instance>; plain kubectl, so $AGENT_PF is the real PID
  kubectl --context "$CTX" -n "$NS" port-forward "pod/ide-$1" $PF_CTRL:8081 $PF_PROXY:8080 >/dev/null 2>&1 & AGENT_PF=$!; sleep 2
}
agent() { # $1 instance, $2 method, $3 path, [$4 JSON body]; prints "<body> <http code>"
  local tok; tok=$(k get secret "ide-$1-token" -o jsonpath='{.data.token}' | base64 -d)
  printf 'Authorization: Bearer %s\n' "$tok" | curl -s -m 10 -w ' %{http_code}\n' -X "$2" -H @- \
    ${4:+-H 'Content-Type: application/json' -d "$4"} "http://127.0.0.1:$PF_CTRL$3"
}
proxy() { # $1 instance, $2 token mode none|wrong|right, $3 path: request through the agent proxy
  local h=()
  case "$2" in wrong) h=(-H 'X-EduIDE-Instance-Token: wrong');; right) h=(-H @-);; esac
  if [ "$2" = right ]; then k get secret "ide-$1-token" -o jsonpath='{.data.token}' | base64 -d | sed 's/^/X-EduIDE-Instance-Token: /;$a\' |
    curl -s -m 10 -o /dev/null -w '%{http_code}\n' -H @- "http://127.0.0.1:$PF_PROXY$3"
  else curl -s -m 10 -o /dev/null -w '%{http_code}\n' "${h[@]}" "http://127.0.0.1:$PF_PROXY$3"; fi
}
# Stop with: kill $AGENT_PF
```

Local agent API from inside the pod (the IDE container has curl; data keys only, never values):

```bash
k exec "$POD" -c ide -- curl -s "http://127.0.0.1:8082/v1/session?after=0&timeout=0" | jq '{version, claimed, keys: (.data // {} | keys)}'
```

### Opening a session in the browser (test-only)

A session URL opens only for its owner (module 13).
For browser tests, create the fixture session with the logged-in user as owner, so the real path (gateway, OIDC cookie, authz, agent proxy) is tested end to end:

```bash
ME=<preferred_username of the logged-in test user>     # ask the user, or read it from the owner of a session launched through the API
ft_session ft-b1 "$T_STD" "" "$ME"; ft_wait ft-b1
# open the URL from .status.url in the browser pane
```

Sessions of `ME` count against `sessionsPerUser` (default 3, `config.sessionsPerUser`).
Keep at most two browser sessions per user running, or lower the count of the others.
Keep the IDE tab visible: in a hidden browser pane the IDE can take minutes to connect.

### A user token for API tests (test environments only)

Most API operations need a Keycloak token of the deployment's realm.
The landing page uses keycloak-js and sends the **access token** as `Authorization: Bearer ...` on its `fetch` calls (the generated client; module scope, not on `window`).
To use it without ever printing it:

1. Never on production. Ask the user to log in on `$LANDING` in the browser pane (the agent never types a password).
2. On the landing page, before triggering anything, install a hook in the page context (javascript tool):

   ```js
   (() => {
     const o = window.fetch;
     window.fetch = function (input, init) {
       try {
         const h = new Headers((init && init.headers) || (input && input.headers) || {});
         const a = h.get('Authorization');
         if (a && a.startsWith('Bearer ')) sessionStorage.setItem('ft.tok', a.slice(7));
       } catch (e) {}
       return o.apply(this, arguments);
     };
     return 'hook installed';
   })()
   ```

3. Trigger one authenticated call from the page: open an item of the overview, or click a tile (this launches a session; record it for cleanup). The overview stream (`/me/overview/events`) is also a `fetch` with the header, so a reconnect works too. If the client captured `window.fetch` before the hook, no token arrives: install the same hook for `XMLHttpRequest.prototype.setRequestHeader` as the old plan did, and if that fails too, mark the dependent tests `blocked` and describe what happened.
4. Call the API from the landing page context, so the token never leaves the browser and no CORS rule applies. Return only status, the Problem `code`, and a short body:

   ```js
   window.api = async (method, path, body, headers = {}) => {
     const base = (await (await fetch('/config.json')).json()).apiBaseUrl;     // "/api/v1"
     const r = await fetch(base + path, { method,
       headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + sessionStorage.getItem('ft.tok'), ...headers },
       body: body ? JSON.stringify(body) : undefined });
     const t = await r.text(); let code; try { code = JSON.parse(t).code; } catch (e) {}
     return { status: r.status, code, body: t.slice(0, 400) };
   };
   ```

   Example: `await api('POST', '/sessions', {template: '<T_STD>'})`.
5. Server-Sent Events need the same header, so read them with `fetch` and a stream reader, not `EventSource`:

   ```js
   window.sse = async (path, seconds = 20) => {
     const base = (await (await fetch('/config.json')).json()).apiBaseUrl, out = [];
     const ac = new AbortController(); setTimeout(() => ac.abort(), seconds * 1000);
     try {
       const r = await fetch(base + path, { signal: ac.signal, headers: { Authorization: 'Bearer ' + sessionStorage.getItem('ft.tok') } });
       out.push('HTTP ' + r.status + ' ' + r.headers.get('content-type'));
       const rd = r.body.getReader(), dec = new TextDecoder();
       for (;;) { const { done, value } = await rd.read(); if (done) { out.push('closed by server'); break; }
         dec.decode(value).split('\n').filter(l => l.startsWith('event:') || l.startsWith(':')).forEach(l => out.push(Math.round(performance.now()) + ' ' + l)); }
     } catch (e) { out.push('end: ' + e.name); }
     return out;
   };
   ```

6. Access tokens are short lived (Keycloak default 300 s). On a 401 that the test does not expect, re-capture (step 3).
7. At the end: `sessionStorage.removeItem('ft.tok')`.

This procedure is not covered by an automated test. If it fails, mark the dependent tests `blocked`.

### Status of a session URL in the browser

The browser holds the OIDC cookie, which the agent must never read.
To learn what the gateway answered for a session URL, navigate the logged-in tab to it and read the status of that navigation:

```js
performance.getEntriesByType('navigation')[0].responseStatus     // 200, 403, ...
```

Anonymous checks use curl without any cookie (module 13).

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
2. Run the selected modules. Server modules (01, 03 server part, 04, 05, 06, 07, 09, 10) are independent of each other and can run in parallel, each with its own `ft-<module>-` name prefix, its own `FT_USER` and its own subagent. Disruptive tests (operator, authz, service restarts, capacity pressure) run alone and last. Browser modules (02, 08, 12, 13 browser part, 14 browser part, and the token part of 03) share one browser and one login: run them one after the other.
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

- One file per run: `docs/testing/control-plane/reports/<YYYY-MM-DD>-<environment>-<n>.md`, for example `2026-11-25-test3-1.md`. Copy [../report-template.md](../report-template.md) and replace the old stack rows (operator/service image, IDE images) with: chart `eduide-control-plane` and `eduide-control-plane-crds` versions, tag of operator, service, authz, agent, pool scaler and landing page, IDE image tags (with `eduide-session` version), Gateway API and Envoy Gateway versions.
- Reports may name environments, versions, pod and session names of `ft-` objects, and error messages. They never contain tokens, cookies, Secret values, launch data, or personal data (names or e-mail addresses, real users' session names). Write `<redacted>` instead.
- Commit the report in a pull request of its own (or together with the plan update it proposes).

## Changing the plan

The plan changes through pull requests to this directory, never silently during a run.

- A run proposes changes in its report: new tests, tests whose expectation turned out wrong (after checking that the code is not the thing that is wrong), retired tests, new Explore ideas.
- A follow-up PR applies them: edit the module, keep IDs stable, mark retired tests `Retired: <date>, <reason>` instead of deleting their ID, and add a line to the changelog below.
- When a component changes behaviour (new release, new chart value, an open question of the design is decided), the PR that moves the version into an environment should also update the affected tests, or name the gap in its description.
- Every concrete detail in a test must be checkable in the code or config of the repository it comes from. Add the source (`repo:path`) when it is not obvious. Statements the design leaves open are marked "record" in the test: the run writes down what it saw, and the plan changes once the design decides.

## Changelog

| Date | Change |
|---|---|
| 2026-11-19 | First run on test3 ([reports/2026-11-19-test3-1.md](reports/2026-11-19-test3-1.md)): fixture label per module (`FT_RUN`), `ft_session` brace fix, per-agent forward ports, bodies from files with `-H @-`, pool scaler optional; new tests PLAT-10, PLAT-11, API-25, API-26, POOL-20, AGENT-17 to AGENT-19; corrected expectations PLAT-01, 05, 09, SEC-02, 04, 17, MON intro, 08, 10, 12, API-13, 14, WS-11, POOL-01, 07, 18, AGENT-02, 05, 14, 16, OPR-10, 17, 19, AUTHZ-01, 07, 09, 13, LAND-12, PERF-03. |
| 2026-11-18 | First version for the Go control plane: 14 modules adapted from the old plan ([mapping.md](mapping.md)), new modules AUTHZ and PERF, new tests for strategies, instance token, NetworkPolicies, capacity pressure, workspace retention, SSE, overview, traces and the metrics contract. Not yet run. |
