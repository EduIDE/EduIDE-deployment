# 14 Startup time and footprint (PERF)

Measures what the design promises: a start that feels immediate, a small control plane, a stable authz path. Budgets (design, "Schneller Startpfad", to be calibrated against the phase 0 baseline): **warm (`none` with pool) under 2 s p95 until the IDE is reachable; cold (`none` or `volume`) under 30 s p95, dominated by the IDE start.** Footprint: **control plane under 150 MiB per deployment** (decision G1), agent under 10 MiB per pod.

Sources: `docs/contracts/metrics.md` (`eduide_session_startup_seconds`, `eduide_session_phase_seconds`), `api/v1alpha1/idesession_types.go` (`status.timestamps`), ADR 0013, 0015.

Statistics: one launch proves nothing. Use at least 20 warm and 10 cold samples per case, sequentially (wait until the pool is full again between warm samples, `pool_pods`), report median, p95 and maximum, and the sample count. Say which node pool and whether the image was prepulled.

## How startup time is measured

Three views, always reported together; they answer different questions:

1. **Server view: timestamps in the status.** `status.timestamps` holds `claimed`, `podReady`, `agentReady`, `ready`; the session's `metadata.creationTimestamp` is the start. `ft_times <session>` (README) prints the seconds since creation. Resolution is one second (Kubernetes timestamps), so it is good for cold starts and for the order of phases, not for sub-second warm starts. Aggregate: `eduide_session_startup_seconds{template,strategy,result}` (creation until Ready or Failed) and `eduide_session_phase_seconds{phase,strategy}` (`claim`, `pod_ready`, `agent_ready`) in Prometheus:
   `histogram_quantile(0.95, sum by (le, strategy) (increase(eduide_session_startup_seconds_bucket{result="ready"}[1h])))`.
2. **Trace view: Jaeger spans.** Launch with a known `traceparent` (MON-10) and read the spans of the service, operator and agent with microsecond resolution; the root-to-last span duration is the control plane's share, with the phase spans showing where it goes (claim, pod ready, agent ready, ready). This is the only view with sub-second resolution inside the control plane.
3. **User view: what the browser perceives.** From the click until the IDE answers (and until the workbench is usable). It adds the SSE delivery, the redirect, the OIDC filter and authz, the route programming, the IDE page load and, for the cold case, the extension fetching the data. Method below; this is the number the design's budget is about, the first two explain it.

The user view method (test-only, needs a logged-in browser as `ME`; run with the IDE tab in the foreground):

```js
// 1. In the landing page tab, before clicking: record t0 at the POST and mark the redirect.
(() => {
  const o = window.fetch;
  window.fetch = function (i, n) {
    if (String(i).includes('/sessions') && n && n.method === 'POST') sessionStorage.setItem('ft.t0', String(Date.now()));
    return o.apply(this, arguments);
  };
  window.addEventListener('pagehide', () => sessionStorage.setItem('ft.tRedirect', String(Date.now())));
  return 'timing hook installed';
})()
```

2. Click a tile (a warm or a cold one). The page follows the SSE stream and navigates to the instance URL. 
3. In the IDE tab (same tab, after the navigation) measure the IDE side:

```js
(async () => {
  const nav = performance.getEntriesByType('navigation')[0];
  const t = { navStart: performance.timeOrigin, status: nav.responseStatus, firstByte: performance.timeOrigin + nav.responseStart };
  for (let i = 0; i < 600; i++) {                       // up to 60 s
    if (document.querySelector('.monaco-workbench, #theia-app-shell')) { t.workbench = Date.now(); break; }
    await new Promise(r => setTimeout(r, 100));
  }
  return t;
})()
```
   (Adapt the selector to what the IDE renders when usable; record the selector in the report.)
4. Navigate the tab back to the landing page (history back, the `sessionStorage` of that origin is restored) and read `ft.t0` and `ft.tRedirect`.
5. Compute, all in epoch milliseconds on the same machine clock: `click to redirect = tRedirect - t0` (API plus SSE, control plane view as the user gets it), `redirect to first byte = firstByte - tRedirect` (OIDC filter, authz, route, agent proxy), `first byte to usable = workbench - firstByte` (IDE load), `total = workbench - t0`. For a quick reachability number without the IDE load: from the landing page, after Ready, `performance.now()` around `await fetch(url, {mode:'no-cors', credentials:'include'})`.

The three views must agree: user total is at least the server view; `click to redirect` should be close to the `ready` timestamp minus creation (within the one-second resolution plus SSE latency). A large gap between them is the finding the baseline measurement is for.

### PERF-01 Control plane memory under 150 MiB
Safety: prod-safe
Steps: `k top pod -l $CP_SEL` (needs metrics-server) and, for working set, Prometheus: `sum by (pod) (container_memory_working_set_bytes{namespace="eduide-test3",pod=~"$FULL-(operator|service|authz|pool-scaler).*",container!=""})`; measure (a) idle, (b) with 20 running sessions (PERF-07), (c) after 100 open SSE streams (a loop of `sse` calls or curl) and (d) after an hour.
Expect: the sum of operator (1) + service (2 replicas) + authz (2 replicas) stays under 150 MiB at idle and with 20 sessions (record whether the pool scaler is counted; the design counts the control plane, record the total with and without it); each pod stays below its memory limit (OOM kills: `k get pods -l $CP_SEL -o jsonpath='{.items[*].status.containerStatuses[*].lastState.terminated.reason}'` is empty); no growth over the hour (leak). CPU at idle below 50m per pod. Compare with the old stack (about 2.5 to 4.9 GiB, design baseline).

### PERF-02 Agent memory per pod
Safety: prod-safe
Steps: `k top pod --containers -l eduide.github.io/component=session | grep agent`; Prometheus `container_memory_working_set_bytes{namespace="eduide-test3",container="agent"}`; with an open IDE tab, during a 50 MiB upload through the proxy (AGENT-16) and after 100 heartbeat and status calls.
Expect: below 10 MiB per agent at idle (design target) and below its limit (64 Mi in the chart) during the upload (the proxy streams, it does not buffer); no growth with long-poll connections (one per extension). Record the values; a few MiB over the target is a finding, not a failure of the limit.

### PERF-03 Warm start time
Safety: test-only
Needs: `ft-pool-t` with a pool of at least 3 idle (`ft_pool ft-perf-pool ft-pool-t 3`), logged in as `ME` for the user view.
Steps: 20 sequential samples. For each: wait until `pool_pods` shows all idle ready, launch (API for the server and trace views; the tile for the user view in all 20, so the user-view p95 rests on 20 samples), then `ft_wait`, `ft_times`, and for the traced ones MON-10's span listing with a `traceparent`. Collect `startStrategy` of every sample. Sessions made with `ft_session` carry about 0.5 s of extra `agent_ready` time because the helper writes the data Secret after the session while the service writes it first; use the API for the server view.
Expect: every sample `warm-ready`; server view: `ready - creation` is 0 to 2 s (budget: p95 under 2 s until reachable); trace view: spans `claim` and `agent_ready` in the low hundreds of milliseconds, no pod creation; user view: `click to redirect` about 1 s or less, `total` (to usable workbench) the number the design budget is judged against; report the three medians and p95s side by side, the largest phase, and any sample that was not warm-ready (pool empty, `warm-starting`). `eduide_session_startup_seconds{strategy="warm-ready"}` agrees (histogram buckets).
Cleanup: `ft_cleanup`.

### PERF-04 Cold start time (no persistence, and volume)
Safety: test-only
Needs: `ft-nopool-t` (clone without pool) and a volume workspace; the image prepulled on the node pool (PLAT-06); logged in as `ME` for the user view.
Steps: 10 sequential samples each for (a) `none` cold, (b) `volume` cold with an existing workspace, (c) `volume` cold with a new workspace (PVC creation), plus one sample with an image that is not on the node (record separately; `imagePullPolicy: Always` clone). Same three views as PERF-03.
Expect: strategy `cold` in all; server view: `podReady` dominates (IDE start), `agentReady` right after it; budget under 30 s p95 until reachable for (a) and (b); (c) adds PVC provisioning (record, the budget does not distinguish it); the pod, Service and HTTPRoute are created at the same time (compare their `creationTimestamp`: `k get pod,svc,httproute ide-<instance> -o custom-columns=KIND:.kind,CREATED:.metadata.creationTimestamp`), so the route is programmed while the container starts and `redirect to first byte` is not the bottleneck. The unprepulled sample shows the pull time as the extra cost.
Cleanup: `ft_cleanup`.

### PERF-05 Per-phase budget table
Safety: prod-safe
Steps: from Prometheus after PERF-03 and PERF-04: `histogram_quantile(0.5|0.95, sum by (le, phase, strategy) (increase(eduide_session_phase_seconds_bucket[2h])))`.
Expect: a table phase by strategy (`claim`, `pod_ready`, `agent_ready`) with p50 and p95; `claim` p95 under 100 ms for `warm-ready`; the sum of the phases of a strategy is close to the strategy's startup p50. The table goes into the report as the baseline for the CI time-budget gate.

### PERF-06 Authz and gateway latency per request
Safety: test-only
Steps: from outside, anonymous, 200 requests each: `for i in $(seq 200); do curl -s -o /dev/null -w '%{time_total}\n' https://$INSTANCE_HOST/<instance>/; done | sort -n | awk '{a[NR]=$1} END{print a[int(NR*0.5)], a[int(NR*0.95)], a[NR]}'` (the answer is the OIDC redirect: it includes ext_authz), and the same against a route outside the policy for comparison (`$LANDING/config.json`); from inside the cluster, authz's own histogram: `histogram_quantile(0.99, sum by (le) (rate(eduide_authz_check_seconds_bucket[5m])))` while the loop runs.
Expect: `eduide_authz_check_seconds` p99 in the low milliseconds (informer cache, no API call per request; record the number, the design sets no budget); the difference between the session route and the comparison route is small compared with the network round trip; no growth when the number of sessions grows (compare with 5 and with 50 sessions, PERF-07).

### PERF-07 Launch burst
Safety: test-only
Needs: a pool with `minIdle 5`, `maxInstances 40`, enough node capacity for 30 more pods; announce it.
Steps: create 30 sessions at once through the CRDs (`for i in $(seq 30); do ft_session ft-perf-b$i ft-pool-t & done; wait`), `ft_wait` each, collect strategies and times; watch `k top pod -l $CP_SEL`, operator log error count (`... | grep -c '"level":"ERROR"'`), `eduide_claim_total` (`conflict`, `empty`), the queue (`k get idesessions | grep -c Pending` over time), API server latency is not available, so record the wall time. Then the same through the API with 10 parallel launches from the browser (distinct data, within the user's limit after raising it, or from fixtures of different owners).
Expect: all 30 reach Ready (5 `warm-ready`, the rest `warm-starting` or `cold`) or fail with `capacity-exhausted` when the node pool is full (record); no stuck `Pending` session; no double claim (POOL-16 checks); operator memory stays inside PERF-01; claim conflicts are retried, not errors; no ERROR flood. Design target for scale (200 launches per minute, 1,000 sessions) is proven in the nightly kwok test of the repository, not here: record the rate achieved.
Cleanup: `ft_cleanup`; wait until the pool is at its target again and record the time.

## Explore

- Warm start with the browser's cache cold versus warm (first IDE load of the day): how much of the user view is the IDE bundle download?
- Start time against distance: the same measurement from the campus network and from outside.
- `redirect to first byte` with and without an existing OIDC cookie on the instance host (first session of the day against the fifth): what does the extra OIDC round trip cost (AUTHZ-02)?
- Time from `agentReady` to the extension applying the template (IDE-01): the data path adds how many milliseconds compared with the old polling (up to 2 s)?
- A warm claim while the operator is busy (launch burst, PERF-07): claim latency percentiles.
- Gateway: first request after route creation (cold case) and after pod claim (warm case): is any request answered 404 or 503 before the route is programmed?
