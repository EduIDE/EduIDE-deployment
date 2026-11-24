# Mapping from the old test plan to the control plane plan

Every test ID of the old plan ([../modules/](../modules/), 123 tests for EduIDE-Cloud 3.x with the Java operator and service) and what became of it in this plan.
IDs keep their prefix and number where the intent survives. Statuses:

| Status | Meaning |
|---|---|
| `kept` | same intent and same steps up to naming; only trivial wording changed |
| `changed` | same intent, different mechanics, objects or expectations (the column says what differs) |
| `replaced by <id>` | the intent is covered by another test, usually in another module |
| `retired` | the intent has no counterpart in the new design (reason given) |

IDs of retired and replaced tests are not reused. The new plan has gaps in the numbering where a test was retired.

## Naming translation

| Old stack | New stack |
|---|---|
| `AppDefinition` (`theia.cloud`) | `IDETemplate` (`idetemplates.eduide.github.io`), pool part in `IDEPool` |
| `Session` (`operatorStatus` HANDLING, HANDLED, ERROR) | `IDESession` (`status.phase` Pending, Starting, Ready, Failed, `errorCode`) |
| `Workspace` | `IDEWorkspace` (`status.phase` Pending, Ready, Expired, `lastUsed`, `expiresAt`) |
| Service `/service/...` with `appId`, error 47x, 55x | `/api/v1/...`, OIDC bearer token only, Problem Details with stable `code` |
| eager (pool) / lazy session | start strategy `warm-ready`, `warm-starting`, `cold` in `status.startStrategy` |
| oauth2-proxy per pod plus e-mail ConfigMap | SecurityPolicy (OIDC) plus ext_authz service `authz`, instance token at the agent, NetworkPolicy |
| Data bridge (operator polls, token Secret per instance) | agent sidecar (operator pushes once per claim, extension long-polls on loopback) |
| `workspace-garbage-collector` | workspace retention in the operator (`lastUsed`, two stages) |
| Deployment, ReplicaSet and ConfigMap per instance | bare pod, Service, HTTPRoute, token Secret per instance |
| Conversion webhook pod | none (CEL rules in the CRDs) |

## Table

### Module 01 Platform (PLAT)

| Old ID | New ID | Status | What differs |
|---|---|---|---|
| PLAT-01 | PLAT-01 | changed | two charts (CRDs per cluster, control plane per deployment), images of operator, service, authz, agent, pool scaler; CRD versions instead of Helm `eduide`/`eduide-cluster` equality and AppDefinition images |
| PLAT-02 | PLAT-02 | changed | operator 1 replica with leader lease, service and authz 2 replicas, PodDisruptionBudgets; no garbage collector deployment |
| PLAT-03 | PLAT-03 | changed | landing `/config.json` instead of `config.js`, API answers 401 instead of the ping, webview host is one exact name (no wildcard certificate), own Gateway and certificates in `eduide-test3` |
| PLAT-04 | PLAT-04 | changed | routes per instance (`ide-<instance>`), `$FULL-api`, `$FULL-oauth2`, SecurityPolicy status; test3 has its own Gateway |
| PLAT-05 | PLAT-05 | changed | IDETemplates and IDEPools against the landing page and `GET /templates`, Helm label instead of managed-by |
| PLAT-06 | PLAT-06 | changed | per-template prepull DaemonSets on the template's node pool |
| PLAT-07 | PLAT-07 | changed | orphans are claimed pods without session, sessions without pod or template, stuck workspaces |
| (new) | PLAT-08 | new | config ConfigMap is sane, no secrets, hosts as designed |
| (new) | PLAT-09 | new | CEL rules active, no webhook pod |

### Module 02 Landing page (LAND)

| Old ID | New ID | Status | What differs |
|---|---|---|---|
| LAND-01 | LAND-01 | changed | runtime config is `/config.json` (`legacy`, `apiBaseUrl`, `keycloak`) |
| LAND-02 | LAND-02 | changed | tiles come from `GET /templates`, badge from the template's persistence |
| LAND-03 | LAND-03 | changed | build system is the `TEMPLATE` key of the launch data (Enum), checked in the data Secret instead of `spec.envVars` |
| LAND-04 | LAND-04 | changed | `POST /sessions` plus SSE instead of polling; session name `s-<10>`, workspace `w-<hash>` |
| LAND-05 | LAND-05 | changed | resume is "Starten" in the overview (G15), not the `/session-ended` page |
| LAND-06 | (none) | retired | there is no end-reason annotation in `v1alpha1`; add a test when the design adds one |
| LAND-07 | LAND-07 | changed | no redirect to a session-ended page; a released URL answers 403 (see AUTHZ-06) |
| LAND-08 | LAND-08 | changed | error 553 becomes `session-limit-reached` with the list of sessions; 555 becomes `capacity-exhausted`; invalid app becomes `template-not-found` |
| LAND-09 | LAND-09 | changed | 2 service replicas: losing one is invisible; scaling to 0 is the maintenance case |
| LAND-10 | LAND-10 | changed | Artemis token in the URL fragment (G16), removed before login; legacy query form deprecated |
| LAND-11 | LAND-11 | kept | adds the check that an open session tab is signed out as well (record) |
| LAND-12 | LAND-12 | kept | |
| LAND-13 | LAND-13 | changed | launch idempotency (G14): key is template plus workspace, or template plus hash of the data; double click and reload give one session |
| (new) | LAND-14 | new | overview content and actions (G15) |
| (new) | LAND-15 | new | overview updates live over SSE |
| (new) | LAND-16 | new | launch sends `traceparent` |

### Module 03 Service API (API)

| Old ID | New ID | Status | What differs |
|---|---|---|---|
| API-01 | API-01 | changed | no public ping with `appId`; anonymous call gives a Problem Details 401 |
| API-02 | API-02 | changed | all 11 operations, malformed tokens; no PATCH endpoint |
| API-03 | API-03 | changed | `POST /sessions`, data Secret with ownerReference, owner from the token |
| API-04 | API-04 | changed | `persistence: volume` creates a deterministic workspace; relaunch is idempotent (200); persistent sessions are always `cold` |
| API-05 | API-05 | changed | `DELETE /sessions/{name}` returns 204; second call 204 or 404 (record) |
| API-06 | API-06 | changed | deleting a workspace in use is 409 `workspace-in-use` |
| API-07 | API-07 | changed | 403 or 404 must be identical for foreign and non-existing names; no performance or config endpoints |
| API-08 | API-08 | changed | `session-limit-reached` (default limit 3) with `sessions`, no service restart needed; failed sessions do not count |
| API-09 | API-09 | changed | `template-not-found`, `unknown-key`, `invalid-input`, `persistence-not-allowed`, `payload-too-large` (8 KiB), no stack traces |
| API-10 | API-10 | changed | reserved env key dropping becomes the injectable key allowlist with formats (HTTPSURL, Token, Enum, Pattern); no `fromSecrets`/`fromConfigMaps`/`env` |
| API-11 | API-11 | changed | admin API does not exist in v1 (no toggle); all admin paths 401 or 404 |
| API-12 | (none) | retired | no admin API in v1 (admin tasks go through Helm and the CRDs) |
| API-13 | API-13 | changed | landing page and API share a host, so no CORS rule is needed; foreign origins get none |
| API-14 | API-14 | changed | management port is 9090 (`/metrics`, `/healthz`, `/readyz`), not routed |
| API-15 | API-15 | changed | config from `--config` file and `POD_NAMESPACE`, no service auth token |
| API-16 | API-16 | changed | foreign workspace gives 403 or 404, same as unknown |
| API-17 | OPR-11 | replaced | a launch that never becomes ready is a session problem: `start-failed` after a bad image; there is no client `timeout` field |
| API-18 | API-18 | changed | two replicas, SSE stream reopens with the current state, one session per launch |
| (new) | API-19 | new | SSE events of a session |
| (new) | API-20 | new | idempotent launch, also under concurrency |
| (new) | API-21 | new | `GET /me/overview` and its SSE stream |
| (new) | API-22 | new | per-user launch rate limit (`rate-limited`) |
| (new) | API-23 | new | `GET /templates` matches the CRDs (`warm` flag, key names only) |
| (new) | API-24 | new | `traceparent` stored as annotation |

### Module 04 Operator (OPR)

| Old ID | New ID | Status | What differs |
|---|---|---|---|
| OPR-01 | OPR-01 | changed | typed `config.yaml` and leader election instead of 30 CLI flags |
| OPR-02 | OPR-02 | changed | cold session with a volume: bare pod, Service, HTTPRoute, token Secret owned by the pod; no Deployment |
| OPR-03 | OPR-03 | changed | `Failed` with `template-not-found` or `workspace-not-found` instead of `ERROR` |
| OPR-04 | OPR-04 | changed | timeouts per template (`idle`, `warning`), activity from the agent, a session without a browser counts as inactive (G7) |
| OPR-05 | OPR-05 | changed | `timeouts.max` counted from creation |
| OPR-06 | OPR-06 | changed | defaults 60m, 50m, 24h are unset template fields |
| OPR-07 | OPR-07 | changed | template removed under a running session: behaviour is open in the design, the test records it |
| OPR-08 | OPR-08 | changed | policies `session-default-deny`, `-from-envoy`, `-from-operator`, `-egress`; negative tests moved to SEC-13 |
| OPR-09 | (none) | retired | `IDETemplate` has no sidecars in v1alpha1 |
| OPR-10 | OPR-10 | changed | bare pods survive, claims are not repeated, no data re-injection |
| OPR-11 | OPR-11 | changed | expects `Failed` with `start-failed` instead of `HANDLED` for the whole lifetime |
| OPR-12 | OPR-12 | changed | second session on one workspace is refused instead of Multi-Attach |
| OPR-13 | OPR-13 | changed | state lives in the agent, so the restart cannot lose it |
| OPR-14 | OPR-14 | changed | single operator replica; exactly one claim per session |
| (new) | OPR-15 | new | capacity pressure per node pool, `capacity-exhausted` after 45 s (G8, U7); replaces the implicit 555 and eviction of the old stack |
| (new) | OPR-16 | new | pressure does not cross node pools |
| (new) | OPR-17 | new | quota-forbidden pod counts as pressure |
| (new) | OPR-18 | new | status written only on real change |
| (new) | OPR-19 | new | session pod contract (`ide` plus `agent`) |
| (new) | OPR-20 | new | per-instance Service, HTTPRoute (header, rewrite, labels), token Secret |
| (new) | OPR-21 | new | pod lost under a running session |

### Module 05 Warm pool (POOL)

| Old ID | New ID | Status | What differs |
|---|---|---|---|
| POOL-01 | POOL-01 | changed | `IDEPool` with bare pods; readiness is real (agent `/readyz`); Service and route exist from warm-up |
| POOL-02 | POOL-02 | changed | `idleReady`, `idleStarting` status instead of counting pods |
| POOL-03 | POOL-03 | changed | label patch with `resourceVersion`, `startStrategy: warm-ready`, route unchanged at claim |
| POOL-04 | POOL-04 | changed | release discards the pod (no token rotation or reset) |
| POOL-05 | POOL-05 | changed | NO_CAPACITY fallback: running out of idle pods is a `warm-starting` or `cold` start; running out of cluster room is G8 (OPR-15) |
| POOL-06 | POOL-06 | changed | idle pods are replaced after a template change; claimed pods run on (design intent, record) |
| POOL-07 | POOL-07 | changed | `minIdle`, `targetIdle`, `maxInstances` and the clamp formula |
| POOL-08 | POOL-08 | changed | orphaned claimed pod is discarded, never reset |
| POOL-09 | POOL-09 | changed | same intent, no reset path |
| POOL-10 | POOL-10 | changed | pod contract instead of Deployment args and token reference |
| POOL-11 | (none) | retired | no sidecars |
| POOL-12 | POOL-08 | replaced | the orphan-after-release timer does not exist; orphans are handled by the claim logic |
| POOL-13 | POOL-13 | changed | a not-ready idle pod is skipped by the claim (breaking the IDE image of a bare pod) |
| (new) | POOL-14 | new | start strategy matrix: `none`/`volume` against pool/no pool |
| (new) | POOL-15 | new | `warm-starting` |
| (new) | POOL-16 | new | concurrent claims never double-assign |
| (new) | POOL-17 | new | `/scale` subresource |
| (new) | POOL-18 | new | pool scaler integration (annotations, status instead of counting) |
| (new) | POOL-19 | new | prepull and placement |

### Module 06 Data bridge becomes Agent (AGENT)

| Old ID | New ID | Status | What differs |
|---|---|---|---|
| DB-01 | AGENT-01 | changed | agent container config instead of `DATA_BRIDGE_*` env |
| DB-02 | AGENT-02 | changed | warm claim pushes the data (`/v1/claim`), no opening of the IDE needed for delivery |
| DB-03 | AGENT-03 | changed | cold session; the operator waits for the late data Secret |
| DB-04 | AGENT-04 | changed | control port 8081 refuses missing or wrong tokens, health endpoints open |
| DB-05 | AGENT-05 | changed | claim validation: 16 KiB, idempotent for the same session, 409 for another |
| DB-06 | (none) | retired | no `DATA_BRIDGE_EXTRA_KEYS`; the allowlist is `injectableKeys` in the template (API-10) |
| DB-07 | AGENT-07 | changed | claim after operator restart; nothing polls |
| DB-08 | (none) | retired | no sidecars |
| DB-09 | SEC-13 | replaced | control port reachability is part of the NetworkPolicy negative test |
| DB-10 | AGENT-10 | changed | `THEIA` is static template env, not launch data |
| DB-11 | POOL-04 | replaced | no token rotation: the pod and its token Secret are discarded on release (also SEC-06) |
| DB-12 | AGENT-12 | changed | IDE container restart keeps the data in the agent; whole pod restart is not a case (pods are discarded) |
| DB-13 | AGENT-07 | replaced | no re-injection on operator start; AGENT-13 is a new test and not the successor of DB-13 |
| (new) | AGENT-13 | new | local long-poll semantics, loopback only |
| (new) | AGENT-14 | new | heartbeat, activity and connection count |
| (new) | AGENT-15 | new | notify reaches the IDE |
| (new) | AGENT-16 | new | proxy forwards HTTP, large uploads and WebSocket |

### Module 07 Garbage collector becomes Workspace retention (WS)

| Old ID | New ID | Status | What differs |
|---|---|---|---|
| GC-01 | WS-01 | changed | retention and grace in the config, no collector deployment, operator RBAC |
| GC-02 | WS-02 | changed | no ticker log; every workspace has `lastUsed` and `expiresAt` (counted from last use, not creation) |
| GC-03 | WS-03 | changed | nothing past `expiresAt` stays `Ready`, nothing lingers past the grace |
| GC-04 | WS-04 | changed | deleting an `IDEWorkspace` removes the PVC by ownerReference |
| GC-05 | WS-05 | changed | per-workspace retention instead of a deployment-wide short TTL (not destructive); stage 2 is WS-06 |
| GC-06 | WS-07 | replaced | a bad config fails at parse time in the operator, checked without touching the shared operator |
| GC-07 | WS-07 | changed | config parsing in throwaway pods; duration without unit and `14d` are invalid |
| (new) | WS-06 | new | stage 2: deletion after the grace period |
| (new) | WS-08 | new | `retain` annotation cancels expiry |
| (new) | WS-09 | new | `lastUsed` at start and end, running session blocks expiry |
| (new) | WS-10 | new | starting an expired workspace |
| (new) | WS-11 | new | overview warning 3 days before expiry |
| (new) | WS-12 | new | import of an existing PVC |

### Module 08 IDE (IDE)

| Old ID | New ID | Status | What differs |
|---|---|---|---|
| IDE-01 | IDE-01 | changed | data arrives through the agent and `eduide-session`; git user and email from the token |
| IDE-02 | IDE-02 | kept | |
| IDE-03 | IDE-03 | changed | restart through "Starten" in the overview, new session is `cold` |
| IDE-04 | IDE-04 | changed | one fixed webview host `webview.instance...` (G3), path-routed, no `<uuid>.webview` wildcard |
| IDE-05 | IDE-05 | changed | `GIT_URI` goes through the allowlist (`allowedHosts`, https only) |
| IDE-06 | IDE-06 | changed | launch key rules for relaunching on a workspace |
| IDE-07 | IDE-07 | changed | only for templates that allow the key |
| IDE-08 | IDE-08 | changed | `GRADLE_PREWARM_AUTO_CONFIRM` is not accepted as launch data |
| IDE-09 | IDE-09 | changed | `eduide-session` replaces data bridge and monitor, no listener in the IDE |
| (new) | IDE-10 | new | IDE image without the extension (no compatibility mode, U8) |
| (new) | IDE-11 | new | idle warning shown in the IDE |

### Module 09 Security (SEC)

| Old ID | New ID | Status | What differs |
|---|---|---|---|
| SEC-01 | AUTHZ-11 | replaced | oauth2-proxy skip rules do not exist; the SecurityPolicy and route wiring are checked instead |
| SEC-02 | SEC-02 | changed | anonymous requests get the OIDC redirect at the gateway on both hosts, with path variants; the decision table is module 13 |
| SEC-03 | SEC-03 | changed | `s-<10>` session names and 20 character instance ids |
| SEC-04 | SEC-04 | changed | distroless, non-root, read-only root filesystem for four binaries |
| SEC-05 | SEC-05 | changed | counts for four components, JSON logs; the full check with a real launch is SEC-14 |
| SEC-06 | SEC-06 | changed | per-instance token Secrets owned by the pod, hashed comparison with the route header |
| SEC-07 | SEC-07 | changed | policy set of the new chart, agent ports instead of data bridge and monitor ports |
| SEC-08 | API-11 | replaced | no admin API to switch on |
| SEC-09 | SEC-09 | changed | no anonymous setting exists in the config schema |
| SEC-10 | SEC-10 | changed | the CRDs have no `valueFrom`, `envFrom`, `fromSecrets` or `fromConfigMaps` at all |
| SEC-11 | SEC-11 | changed | four hosts including the webview host |
| (new) | SEC-12 | new | instance token: direct pod access needs the header |
| (new) | SEC-13 | new | NetworkPolicy negative test with a foreign pod |
| (new) | SEC-14 | new | launch data never in logs, status, specs, traces, metrics |
| (new) | SEC-15 | new | telemetry holds no personal data (pseudonymous user id) |
| (new) | SEC-16 | new | session pod hardening |
| (new) | SEC-17 | new | minimal RBAC per component |

### Module 10 Monitoring (MON)

| Old ID | New ID | Status | What differs |
|---|---|---|---|
| MON-01 | MON-01 | changed | one PodMonitor for all components; operator metrics are scraped |
| MON-02 | MON-02 | changed | operator, service, authz, pool scaler targets; no duplicate PodMonitor case |
| MON-03 | MON-03 | changed | alerts are the chart's own PrometheusRule, no fixed count |
| MON-04 | MON-04 | changed | selectors on the `eduide_*` metrics |
| MON-05 | MON-05 | changed | label is `namespace` of the deployment |
| MON-06 | MON-06 | changed | checks labels against the cluster's routing |
| MON-07 | MON-07 | changed | one dashboard ConfigMap of the chart |
| MON-08 | MON-08 | changed | certificates of the deployment's own Gateway |
| (new) | MON-09 | new | every name of the metrics contract is exposed, no personal labels |
| (new) | MON-10 | new | a launch trace with all phases in Jaeger (warm and cold) |
| (new) | MON-11 | new | logs carry the trace id |
| (new) | MON-12 | new | Jaeger is internal and keeps traces |

### Module 11 Upgrade (UPG)

| Old ID | New ID | Status | What differs |
|---|---|---|---|
| UPG-01 | UPG-01 | changed | blocked until test3 has an environment manifest; CRD chart diff additive |
| UPG-02 | UPG-02 | changed | sessions are bare pods; authz rollout must not block owners |
| UPG-03 | UPG-03 | changed | CRD chart stays; operator minimum CRD version check |
| UPG-04 | UPG-04 | kept | |
| UPG-05 | UPG-05 | changed | five components |
| (new) | UPG-06 | new | CRD chart ahead of the operator (version skew, G10) |
| (new) | UPG-07 | new | parallel run with the old stack leaves it untouched |

### Module 12 Artemis (ART), skipped

| Old ID | New ID | Status | What differs |
|---|---|---|---|
| ART-01 | ART-01 | changed | token in the URL fragment, no existing login needed, token reaches the IDE through the agent |
| ART-02 | ART-02 | kept | skipped |
| ART-03 | ART-03 | changed | deterministic workspace name, idempotent launch; skipped |
| ART-04 | ART-04 | kept | skipped |
| ART-05 | ART-05 | changed | adds the SEC-14 style count for the token; skipped |
| (new) | ART-06 | new | legacy query token is deprecated; skipped |

### Modules 13 and 14 (new)

| Old ID | New ID | Status | What differs |
|---|---|---|---|
| (new) | AUTHZ-01 to AUTHZ-13 | new | decision table: anonymous redirect, owner, foreign, free instance, unknown (no oracle), after release, invalid cookie, expired token re-login, authz down, not Ready or deleting, SecurityPolicy wiring, decision metrics, replica loss |
| (new) | PERF-01 to PERF-07 | new | control plane memory, agent memory, warm start, cold start, phase budgets, authz latency, launch burst |

## Behaviour of the old stack that was decided on purpose (design, "Implizites Verhalten")

| Old behaviour | New behaviour | Tests |
|---|---|---|
| error 553 per-user session limit | `session-limit-reached` with the running sessions | API-08, LAND-08 |
| error 555 no capacity; eviction under pressure | operator evicts the oldest idle pod in the same node pool, pools held at 0 idle, `capacity-exhausted` after 45 s | OPR-15 to OPR-17, LAND-08 |
| NO_CAPACITY fallback of the eager handler to a lazy start | a claim without an idle pod is a normal `warm-starting` or `cold` start | POOL-05, POOL-14, POOL-15 |
| workspace removal by creation date | removal after last use, two stages, retain annotation | WS-05 to WS-11 |
| session end after idle or lifetime via the IDE monitor, only if the monitor ever answered | agent activity, no browser after claim counts as idle | OPR-04, OPR-05, AGENT-14 |
| data bridge injection polling | one push per claim, extension long-poll | AGENT-02, AGENT-03, PERF-03 |
| oauth2-proxy skip routes and e-mail file | gateway OIDC plus authz plus instance token plus NetworkPolicy | AUTHZ-01 to AUTHZ-13, SEC-12, SEC-13 |
| admin API, `performance`, `setConfigValue` | none in v1 | API-11 |

## Counts

Old plan: 123 tests (PLAT 7, LAND 13, API 18, OPR 14, POOL 13, DB 13, GC 7, IDE 9, SEC 11, MON 8, UPG 5, ART 5).
Fate of the old tests is in the table below.

| Status | Count | IDs |
|---|---|---|
| retired | 6 | LAND-06, API-12, OPR-09, POOL-11, DB-06, DB-08 |
| replaced | 8 | API-17, POOL-12, DB-09, DB-11, DB-13, GC-06, SEC-01, SEC-08 |
| kept | 6 | LAND-11, LAND-12, IDE-02, UPG-04, ART-02, ART-04 |
| changed | 103 | all others |

The module files hold the active tests: PLAT 11, LAND 15, API 24, OPR 20, POOL 18, AGENT 15, WS 12, IDE 11, SEC 15, MON 12, UPG 7, ART 6 (skipped), AUTHZ 13, PERF 7, in total 186 (eight tests were added after the first run: PLAT-10, PLAT-11, API-25, API-26, POOL-20, AGENT-17 to AGENT-19).
