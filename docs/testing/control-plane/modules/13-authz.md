# 13 Session access, the authz decision table (AUTHZ)

Replaces the oauth2-proxy tests of the old plan. Who may open a session is decided at the gateway: a SecurityPolicy per deployment runs the OIDC login (cookie `eduide-id` holds the ID token) and calls the `authz` service through ext_authz on every request to a session route (for WebSockets at the upgrade). ext_authz runs before the OIDC filter in Envoy Gateway, so `authz` verifies the ID token cookie itself (go-oidc, issuer `oidc.issuerURL`, audience `oidc.gatewayClientID`). Design: ADR 0005, G4, G5; code `internal/authz`, chart `gateway.yaml`.

Decision table (per request on a session route; the first path segment is the instance id):

| Case | Cookies | Answer |
|---|---|---|
| (a) | no auth cookie at all (no `eduide-id`, no cookie starting `BearerToken`, `OauthHMAC`, `OauthExpires`, `IdToken`, `RefreshToken`) | allow here; the OIDC filter after it forces the login, so nothing reaches the IDE (a request without cookies gets a 302 to Keycloak) |
| (b) | ID token present but invalid or expired | 302 to the same URL with `Set-Cookie` expiring all those cookies (Domain = instance host, Path=/), so a fresh, silent login starts |
| (c) | valid ID token | allow only if the first path segment is `status.instance` of an IDESession in phase `Ready`, not being deleted, whose `spec.owner` equals the token claim `oidc.userClaim`; otherwise 403 |
| any | `/oauth2/` path prefix | allow (the OIDC callback; the route for it exists and the service answers 404) |
| any | internal error (informer not synced, parse error) | 403 (fail closed, `failOpen: false`) |

Unknown, free (idle pool), foreign, not yet Ready and released instances all give 403, with the same response, so the answer is no oracle for instance ids.

The tests use one logged-in test user `ME` (README) and fixture owners that are not `ME`:
- owner: a session launched by `ME` (API or `ft_session ... "$ME"`);
- foreign: a fixture session with owner `ft-other` (`ft_session ft-az-foreign "$T_STD" "" ft-other`);
- free: an idle pool pod's instance (`k get pod -l eduide.github.io/state=idle -o jsonpath='{.items[0].metadata.labels.eduide\.github\.io/instance}'`).
In the browser read the answer with `performance.getEntriesByType('navigation')[0].responseStatus` (README). Anonymous checks use curl without cookies. Never read or print cookies.

### AUTHZ-01 Anonymous requests redirect to login (case a)
Safety: prod-safe
Steps:
```bash
for h in $INSTANCE_HOST $WEBVIEW_HOST; do for i in <owner instance> <free instance> <foreign instance> nonexistentinstanceid0; do
  curl -s -o /dev/null -w "%{http_code} $h %{redirect_url}\n" "https://$h/$i/" | sed 's#\(https://[^/]*\).*#\1#'; done; done
curl -s -o /dev/null -w '%{http_code} oauth2\n' "https://$INSTANCE_HOST/oauth2/callback"
```
Expect: 302 to the Keycloak host for every instance on both hosts, the same for existing and non-existing ids (nothing leaks); never IDE content, never 200 from a session. `/oauth2/...` answers from the OIDC filter or the service (302, 400, 401 or 404), never from a session. This also holds right after the authz pods restarted (no cache-miss window), but anonymous probes cannot show that: the OIDC filter answers 302 before ext_authz is consulted, so that half needs the owner's cookie in the browser (AUTHZ-09).

### AUTHZ-02 Owner is allowed, silently (case c)
Safety: test-only
Needs: logged in on the landing page as `ME`; a session of `ME` that is Ready.
Steps: open the session URL in the logged-in tab; note whether a Keycloak login form appeared; read the navigation status; check the IDE loads and a terminal works. Repeat in a second tab and for the webview host path (open a preview, IDE-04).
Expect: the first visit passes through the OIDC filter via Keycloak without a login form (SSO: the landing page's Keycloak session exists), ends with status 200 and the IDE; later visits go straight through (200, no redirect); the cookie covers the instance and webview hosts. A WebSocket upgrade (the IDE's connection) is accepted. `eduide_authz_decisions_total{result="allow"}` rises (AUTHZ-12).

### AUTHZ-03 Another user's session is refused (case c, foreign)
Safety: test-only
Needs: logged in as `ME`; `ft_session ft-az-foreign "$T_STD" "" ft-other`, Ready.
Steps: navigate the logged-in tab to the foreign session's `status.url`; read the navigation status and the body text length; also `fetch(url,{credentials:'include'})` from the instance origin is not possible from the landing page (cross-origin): use the navigation only.
Expect: 403 with a short body that names nothing about the session or its owner; the same answer as for a free or unknown instance (AUTHZ-05). `eduide_authz_decisions_total{result="deny"}` rises with the reason for "not owner" (reason names are in the code; record them).
Cleanup: `ft_cleanup`.

### AUTHZ-04 A free (idle pool) instance is refused
Safety: test-only
Needs: logged in as `ME`; a pool with an idle pod (module 05).
Steps: navigate the tab to `https://$INSTANCE_HOST/<free instance>/` (the route exists since warm-up) and to the same on the webview host.
Expect: 403 on both hosts; the idle pod never serves anybody before a claim, although its route, service and token exist. After the pod is claimed by another user's session, still 403 for `ME`.

### AUTHZ-05 Unknown instance: no oracle
Safety: test-only
Needs: logged in as `ME`.
Steps: navigate to `https://$INSTANCE_HOST/<20 random base32 characters>/` and to the foreign, the free and a malformed id (`/x/`, `/../`); compare status codes, response headers (names) and body lengths: `[performance.getEntriesByType('navigation')[0].responseStatus, document.body.innerText.length]`.
Expect: identical status (403) and the same body for unknown, free and foreign instances; no timing or text difference that tells them apart (compare 5 samples each, record the spread). A path without an instance segment (`/`) answers 404 or the filter's own answer, never a session.

### AUTHZ-06 After release, access ends at once
Safety: test-only
Needs: logged in as `ME`; a Ready session of `ME` open in tab 1, its IDE connected.
Steps: in tab 2 stop the session (`await api('DELETE','/sessions/<name>')` on the landing page tab, or `k delete idesession <name>`); immediately (within 2 s, before the pod is gone: `k get pod ide-<instance> -w` in a shell) reload tab 1 and read the navigation status; in tab 1 evaluate `fetch(location.href,{credentials:'include'}).then(r=>r.status)` (same origin) every second for 20 s; watch the IDE's connection state in tab 1.
Expect: the session leaves `Ready` (or gets its deletion timestamp) before the pod terminates, so the status is 403 from the first request after the delete (not only after the pod is gone); the open IDE shows a lost-connection state when the pod is discarded (open WebSockets end with it); the URL never opens again. For a warm session the same applies to the pod that was claimed (never reused). Note the time from delete to the first 403.

### AUTHZ-07 Invalid ID token cookie is cleared (case b)
Safety: prod-safe (anonymous request with a made-up cookie)
Steps: `curl -s -o /dev/null -D - -H 'Cookie: eduide-id=not-a-jwt' "https://$INSTANCE_HOST/<any instance>/" | grep -i -E '^(HTTP|location|set-cookie)' | sed 's/=[^;]*/=<v>/'`; repeat with a syntactically valid but unsigned JWT-shaped value (three dot-separated base64url parts of dummy text), and with the cookie name taken from `oidc.idTokenCookie` of the config.
Expect: 302 to the same URL (`location` equals the request URL) with `Set-Cookie` lines that expire the auth cookies the request carried, only those (names such as `eduide-id`, `BearerToken`, `OauthHMAC`, `OauthExpires`, `IdToken`, `RefreshToken`; `Max-Age=0` or an expiry in the past), `Domain` equal to the instance host and `Path=/`; no 403 and no IDE content. `eduide_authz_decisions_total{result="login"}` rises.

### AUTHZ-08 Expired token leads to a transparent re-login
Safety: test-only
Needs: logged in as `ME`; a session of `ME` open; the ID token lifetime of the realm (Keycloak default 5 minutes; ask the owner or read the realm settings; the SecurityPolicy has `refreshToken` enabled).
Steps: open the session tab, then wait longer than the ID token lifetime plus a minute without using the tab (do not use it, the refresh must not happen from the page); reload the tab and watch the network log (browser) for the redirect chain; read the final status; repeat with the tab open and the IDE in use over 3 lifetimes.
Expect: the reload goes through at most one extra 302 round trip (case b clears the cookies, the OIDC filter logs in again against Keycloak with the existing SSO session, no login form) and ends with 200 and the IDE; during active use the IDE never shows an error: WebSockets stay open (authz checks only at upgrade), new HTTP requests are refreshed by the filter or re-authenticated. If the Keycloak SSO session is gone (logout, LAND-11), the reload shows the login form, never an error page or a loop. Record the number of redirects and any visible flicker. `login` decisions rise by the number of cases.

### AUTHZ-09 authz down: fail closed
Safety: test-only, disruptive (nobody opens a session while authz is down)
Needs: logged in as `ME`; a Ready session of `ME` with its IDE open in tab 1; announce it.
Steps: `k scale deploy/$FULL-authz --replicas=0`; wait 20 s; in tab 2 navigate to the session URL (new connection); in tab 1 keep using the IDE (type, run a command: the WebSocket stays); then `k scale deploy/$FULL-authz --replicas=2` and `k rollout status deploy/$FULL-authz`; reload.
Expect: anonymous and bogus-cookie requests are answered 302 by the OIDC filter whether authz is up or down, so they prove nothing; only a request with the owner's cookie shows the result (first run: 500, never IDE content). While authz is down new requests to any session route are refused (403 or 5xx from Envoy: record), never served (`failOpen: false`); the IDE connection that was already open keeps working (WebSockets are checked only at the upgrade) but a reload of tab 1 fails; the landing page and the API keep working (they are not behind authz); after authz is back the reload works within the informer sync time (record seconds). Alert on authz down fires (MON-05).
Cleanup: replicas restored to the recorded count (2).

### AUTHZ-10 Not-Ready and deleting sessions are refused
Safety: test-only
Needs: logged in as `ME`.
Steps: (1) create a cold session of `ME` with a slow start (`ft_template` clone with `.spec.image` unchanged and `imagePullPolicy: Always` on a node without the image, or the capacity test OPR-15 so that the session stays `Starting`) and, as soon as the pod has an instance label (`k get pod -l eduide.github.io/session=<n> -o jsonpath='{.items[0].metadata.labels.eduide\.github\.io/instance}'`), navigate the tab to `https://$INSTANCE_HOST/<instance>/` every few seconds until the session is Ready; (2) stop a Ready session with a finalizer delay (the session has the finalizer `eduide.github.io/session`; hold it: `k patch idesession <n> --type merge -p '{"metadata":{"finalizers":["eduide.github.io/session","eduide.dev/ft-hold"]}}'`, then `k delete idesession <n> --wait=false`) and navigate to its URL; remove the hold afterwards (`k patch ... '{"metadata":{"finalizers":["eduide.github.io/session"]}}'`).
Expect: (1) 403 while the phase is `Starting` (even for the owner and although the route and pod exist), then 200 once the phase is `Ready` and the first request after that passes; (2) 403 while `deletionTimestamp` is set, although the pod may still run.
Cleanup: remove the hold finalizer first, then `ft_cleanup`.

### AUTHZ-11 SecurityPolicy and route wiring
Safety: prod-safe
Steps: `k get securitypolicy $FULL-session -o json | jq '{targets:.spec.targetSelectors, oidc:(.spec.oidc|{issuer:.provider.issuer, clientID, cookieNames, cookieDomain, refreshToken, logoutPath, redirectURL, scopes}), extAuth:(.spec.extAuth|{grpc:.grpc.backendRefs, failOpen, headersToExtAuth})}'` (no client secret reference value is printed: `clientSecret` is a name only); `k get httproute -l eduide.github.io/route=session -o name | wc -l`; `k get httproute $FULL-oauth2 -o json | jq '.spec|{hostnames, rules}'`; `k get svc $FULL-authz`; `k get pdb`.
Expect: the policy selects HTTPRoutes by the label `eduide.github.io/route=session` (all `ide-<instance>` routes carry it, OPR-20); OIDC against the deployment's realm with the confidential gateway client, `cookieNames.idToken` equal to `config.oidc.idTokenCookie`, `cookieDomain` covering the instance and the webview host, refresh token on, redirect URL on the instance host (`/oauth2/callback`); `extAuth` is gRPC to `$FULL-authz:9001` with `failOpen: false`; the route `$FULL-oauth2` serves `/oauth2/` on the instance host with the same label (so the callback has a route); authz has 2 replicas and a PodDisruptionBudget; the landing and API routes are not under the policy's authz (they have their own token check). No session route exists without the label (`k get httproute -o json | jq -r '.items[] | select(.metadata.name|startswith("ide-")) | select(.metadata.labels["eduide.github.io/route"]!="session") | .metadata.name'` prints nothing).

### AUTHZ-12 Decision metrics
Safety: test-only
Steps: after AUTHZ-01 to AUTHZ-08: `k port-forward deploy/$FULL-authz 19092:9090 >/dev/null 2>&1 & P=$!; sleep 2; curl -s http://127.0.0.1:19092/metrics | grep -E '^eduide_authz_(decisions_total|check_seconds_(count|sum))'; kill $P`.
Expect: `eduide_authz_decisions_total` has series for `result` `allow`, `deny` and `login` with a `reason` label each (as in the contract); the counts match the number of tests run (allow for owner and no-cookie passes, deny for foreign, free, unknown, not Ready, login for the invalid cookie); `eduide_authz_check_seconds` has a count that grows with requests. No label holds an instance id, user or token (cardinality).

### AUTHZ-13 authz survives a replica loss and a rollout
Safety: test-only, disruptive
Needs: logged in as `ME`; an open session of `ME`.
Steps: in the tab run `setInterval(()=>fetch(location.href,{credentials:'include',redirect:'manual'}).then(r=>{ if(r.status!==200) (window.__bad=window.__bad||[]).push([Date.now(),r.status]) }), 500)` on the IDE origin; `k delete pod <one authz pod> --grace-period=0 --force`; wait for it to come back; `k rollout restart deploy/$FULL-authz` and wait; read `window.__bad` and clear the interval.
Expect (anonymous probes cannot see this, see AUTHZ-09): no non-200 answers for the owner during the pod loss (the other replica answers, Envoy retries) and during the rolling restart (maxUnavailable 0 or the PodDisruptionBudget holds one replica); a new replica serves only after its informer synced (readiness `/readyz` waits for it), so it never denies an owner because its cache is empty. Count and times of any blip go into the report (known risk: authz is in the critical path of every session).
Cleanup: none (the deployment is restored by the rollout).

## Explore

- Logged in as the owner of A, request `/x/../<B>/` and `/<A>/../<B>/` (B another instance): never served (authz denies `bad-path` or the owner check fails).
- Token of another client or audience (a valid token of the realm that is not the gateway client's): refused by authz (audience check)? Needs a second Keycloak client; otherwise `blocked`.
- A session URL opened with a trailing path that escapes the prefix after a rewrite (`/<instance>/../<other>/`): authz sees the original path; Envoy normalises before routing?
- Case variants of the instance id (upper case) and the instance id as a later path segment (`/x/<instance>/`): never allowed.
- Cookie of the foreign user replayed in another browser: out of scope without cookie handling; describe, do not run.
- Two owners with the same `preferred_username` case variants (`Alice` and `alice`): is the comparison exact? What does `ME` see for a session of the other?
- authz with 500 sessions in the informer: latency per decision (PERF-06) and memory (PERF-01).
- Logout at Keycloak while the IDE is open: does the open WebSocket end, and what does the next request do (AUTHZ-08)?
