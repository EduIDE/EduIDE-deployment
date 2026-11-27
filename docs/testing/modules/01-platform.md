# 01 Platform health and versions (PLAT)

Runs first in every run. Pins the versions the report refers to and checks that the installation is up before anything else is judged.

Sources: control plane `docs/architecture/overview.md` and `data-model.md`, `charts/eduide-control-plane/templates/*`; EduIDE-Helm `charts/eduide/{Chart.yaml,values.yaml,templates/{gateway,ide-templates,oidc-bridge}.yaml}`; this repository `clusters/<cluster>.yaml`, `.github/workflows/bootstrap-cluster.yml`.

Facts:
- One release `eduide` per environment (chart `eduide`, umbrella of `eduide-control-plane` and `eduide-landing-page`). The CRDs come from a per-cluster release `eduide-crds` in `eduide-system` (chart `eduide-control-plane-crds`, version `spec.controlPlaneCRDs` of `clusters/<cluster>.yaml`).
- Workloads: `$P-operator` (1 replica, leader election Lease `eduide-operator`), `$P-service` (2), `$P-authz` (2, PodDisruptionBudget), `$P-pool-scaler` (only with `poolScaler.enabled`), `eduide-landing-page`, `eduide-oidc-bridge` (2, with `oidcBridge.enabled`, set in `_base-go.yaml`).
- Session pods are bare pods `ide-<instance>` with containers `ide` and `agent`.

### PLAT-01 Deployed versions
Safety: prod-safe
Steps:
1. `helm --kube-context "$CTX" -n "$NS" list` (chart and app version of `eduide`).
2. `helm --kube-context "$CTX" -n eduide-system list` (release `eduide-crds`) and `yq -r .spec.controlPlaneCRDs clusters/$CLUSTER.yaml`.
3. `k get deploy -o custom-columns=NAME:.metadata.name,IMAGE:.spec.template.spec.containers[*].image`
4. `k get idetemplates -o custom-columns=NAME:.metadata.name,IMAGE:.spec.image,VERSION:.status.image.version`
5. `k get cm $P-config -o jsonpath='{.data.config\.yaml}' | yq .agent.image` (the agent image of new session pods).
6. `yq .spec.platform environments/$ENV/env.yaml` (the pin this repo declares).
Expect:
- The `eduide` chart version matches `spec.platform.chartVersion`, unless the run deliberately tests an override; then the override is recorded.
- The `eduide-crds` release version equals `spec.controlPlaneCRDs`.
- Operator, service, authz, landing page and agent run the same control plane tag (the chart's `appVersion` of `eduide-control-plane`, for example 0.2.3). All IDE template images share one tag (the `eduide` chart `appVersion` unless `images.tag` is overridden).
- Every IDETemplate that has image metadata reports `status.image.version` equal to its image tag.
- All versions go into the report's run metadata table.

### PLAT-02 Components ready, no restarts
Safety: prod-safe
Steps:
1. `k get deploy` and `k get pods -l app.kubernetes.io/instance=eduide -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount,AGE:.metadata.creationTimestamp'`
2. `k get lease eduide-operator -o jsonpath='{.spec.holderIdentity}'`
3. `k get pdb`
Expect: every deployment fully available (operator 1/1, service 2/2, authz 2/2, landing page, OIDC bridge 2/2, pool scaler 1/1 where enabled). The lease holder starts with the name of the operator pod. PodDisruptionBudgets exist for service and authz. Restart counts are recorded; any restart of the operator, service or authz since the last deploy is a finding (check `k logs deploy/$P-operator --previous | tail -50` for the cause, without copying lines that could hold values).

### PLAT-03 Public endpoints answer with valid certificates
Safety: prod-safe
Steps:
```bash
for u in "$LANDING/" "$LANDING/config.json" "$LANDING/api/v1/status"; do
  curl -sS -o /dev/null -w "%{http_code} %{ssl_verify_result} $u\n" "$u"; done
for h in $ENV instance.$ENV webview.instance.$ENV; do
  echo | openssl s_client -connect "$h:443" -servername "$h" 2>/dev/null | openssl x509 -noout -ext subjectAltName -enddate
  curl -s -o /dev/null -w "%{http_code} %{redirect_url} http://$h/\n" "http://$h/"; done
```
Expect: `200 0` for all three URLs. Each certificate names exactly the host it is served for (the webview host has its own certificate, no wildcard) and expires more than 21 days from now. Port 80 answers 301 to the https URL on all three hosts. AGENTS.md explains why a wrong-name certificate is otherwise silent.

### PLAT-04 Gateway, routes and SecurityPolicy attached
Safety: prod-safe
Steps:
1. `k get gateway eduide -o json | jq -r '.status.listeners[] | .name + " " + ([.conditions[] | .type + "=" + .status] | join(","))'`
2. `k get httproute -o json | jq -r '.items[] | .metadata.name as $n | .status.parents[]? | $n + " " + ([.conditions[] | .type + "=" + .status] | join(","))'`
3. `k get securitypolicy $P-session -o json | jq -c '.status.ancestors[]? | [.conditions[] | .type + "=" + .status]'`
Expect: the Gateway has the listeners `https-service`, `https-instance`, `https-webview` and `http-service`, `http-instance`, `http-webview`, each `Programmed=True`, `Accepted=True`, `ResolvedRefs=True`. Routes `$P-api`, `$P-session-fallback`, `eduide-landing-page`, `eduide-https-redirect` and one `ide-<instance>` per session pod are `Accepted=True` and `ResolvedRefs=True`. The SecurityPolicy is `Accepted=True`. A route with no status parent is attached to a section that does not exist (AGENTS.md, Gateway section prefix).

### PLAT-05 Templates and pools consistent with the environment
Safety: prod-safe
Steps: compare `k get idetemplates -o name` and `k get idepools -o name` with the keys of `templates:` in `environments/$ENV/values.yaml` (the pool exists only where the entry has `pool:`), with `curl -s $LANDING/api/v1/status | jq -r '.templates[].name'`, and with `k get idetemplates -o custom-columns=NAME:.metadata.name,MANAGED:.metadata.labels.app\\.kubernetes\\.io/managed-by`.
Expect: one IDETemplate per `templates:` key and one IDEPool per entry with `pool:`; the public status lists exactly the IDETemplate names; every template has `Ready=True` (`k get idetemplate <n> -o jsonpath='{.status.conditions}'`) and the condition `ImageMetadata` is `Read` (`AnnotationMissing` or `RegistryError` is recorded, it never affects `Ready`); no IDETemplate without the Helm owner (`managed-by=Helm`) except `ft-` fixtures; a difference between deployed and repo values is a recorded override of this run or a finding.

### PLAT-06 Image prepull done
Safety: prod-safe
Needs: `placement.prepull.enabled: true` in the values (test3, bonn, production; not test1, test2). Otherwise record `skipped: prepull disabled`.
Steps: `k get daemonset -l eduide.github.io/component=prepull` and the readiness of its pods.
Expect: one DaemonSet per template, fully rolled out (desired equals ready). If not, the first cold launches after a deploy are slow; wait before running modules 04, 05 and 08.

### PLAT-07 Leftover sessions and instances
Safety: prod-safe
Steps:
```bash
# sessions whose template no longer exists
k get idesessions -o json | jq -r --argjson t "$(k get idetemplates -o json | jq '[.items[].metadata.name]')" \
  '.items[] | select(.spec.templateRef as $a | $t | index($a) | not) | .metadata.name + " " + .spec.templateRef + " " + .metadata.creationTimestamp'
# failed sessions older than 15 minutes (the operator deletes them after 10)
k get idesessions -o json | jq -r --arg c "$(date -u -v-15M +%FT%TZ 2>/dev/null || date -u -d '15 min ago' +%FT%TZ)" \
  '.items[] | select(.status.phase=="Failed" and .metadata.creationTimestamp < $c) | .metadata.name'
# claimed pods whose session is gone
for s in $(k get pods -l eduide.github.io/state=claimed -o jsonpath='{range .items[*]}{.metadata.labels.eduide\.github\.io/session}{"\n"}{end}'); do
  k get idesession "$s" >/dev/null 2>&1 || echo "orphan claim: $s"; done
```
Expect: no output. A session whose template was deleted keeps running when it already has an instance (it ends by the timeouts); report names of `ft-` sessions only and count the others.

### PLAT-08 CRDs installed
Safety: prod-safe
Steps: `kubectl --context "$CTX" get crd | grep eduide.github.io` and `k api-resources --api-group=eduide.github.io`.
Expect: four CRDs `idetemplates`, `idepools`, `idesessions`, `ideworkspaces`, all version `v1alpha1`, namespaced. The operator checks them at start and refuses to run without them (log `service failed` or `operator failed` otherwise).

### PLAT-09 Certificates and OIDC bridge
Safety: prod-safe
Steps: `k get certificate,issuer` and `k get deploy eduide-oidc-bridge`; `k get secret -o name | grep -E 'tls$'` (names only).
Expect: Certificates `eduide-service-tls`, `eduide-instance-tls`, `eduide-webview-tls` (and `eduide-oidc-bridge` where the bridge is enabled) `READY=True`; the Issuer `letsencrypt-prod-gateway` and the bridge's self-signed Issuer `READY=True`; the TLS Secrets exist. The bridge Deployment is fully available (Envoy cannot reach the TUM Keycloak without it, so a login fails when it is down).

### PLAT-10 Deployment config matches the values
Safety: prod-safe
Steps: `k get cm $P-config -o jsonpath='{.data.config\.yaml}' | yq -o json | jq '{deployment, hosts, sessionsPerUser, workspaces, oidc: {issuerURL: .oidc.issuerURL, clientIDs: .oidc.clientIDs, gatewayClientID: .oidc.gatewayClientID, userClaim: .oidc.userClaim, admin: .oidc.admin}, allowedHosts}'` (mikefarah yq 4.x rejects the `{a, b}` shorthand: convert to JSON and select with jq) and compare with `environments/$ENV/values.yaml` (`eduide-control-plane.config`). Never print the whole ConfigMap of another object, and never read Secrets.
Expect: the values equal the file (defaults where the file is silent: `sessionsPerUser` 3, `workspaces.perUser` 20, retention 14 days, grace 24 h, `userClaim` `preferred_username`, `idTokenCookie` `eduide-id`). `hosts` follow the pattern of the Setup section. `oidc.admin` is set only where the admin panel is meant to work. Record the limits for the other modules.

### PLAT-11 Pod images are the registry images
Safety: prod-safe (read-only; step 4 may start one fixture session where fixtures are allowed)
Needs: `docker buildx imagetools` (or `crane`) with read access to `ghcr.io`; the deploy has finished.
Why: a preview tag such as `pr-33` is mutable and a pod uses `imagePullPolicy: IfNotPresent` unless the chart says otherwise, so a node that cached an older build keeps running it ("already present on machine") while the registry has moved on. The control plane Deployments of test2 use `Always` and are not affected. The agent sidecar is built by the operator, not by the chart; it had no pull policy of its own (Kubernetes default `IfNotPresent` for a non-`latest` tag), and the spec hash covers only the tag string, so a deploy neither pulls a new agent nor replaces idle pods that run the old one (POOL Facts). The control plane fix (EduIDE/EduIDE-control-plane PR 33) makes the agent follow `image.pullPolicy` and adds that policy to the spec hash; this test proves the fix on the deployed build. A deploy restarts a pod only when its spec changes, so a reused tag can still leave a stale pod (seen with the landing page): run this test after every deploy of a preview tag, and give a stale pod a rollout restart (`k rollout restart deploy/<name>`; for idle pool pods see POOL Facts). Released versions use immutable tags and pass trivially.
Steps:
1. The images that should run: `k get deploy -o json | jq -r '.items[] | .spec.template.spec.containers[] | .image' | sort -u`, `k get cm $P-config -o jsonpath='{.data.config\.yaml}' | yq -r .agent.image` and the IDE images of `k get idetemplates -o custom-columns=NAME:.metadata.name,IMAGE:.spec.image`.
2. The registry digest of each: `docker buildx imagetools inspect <image> | grep -m1 Digest` (the index digest). Per-platform manifests, if the runtime reports those instead: `docker buildx imagetools inspect <image> --raw | jq -r '.manifests[].digest'`.
3. What the pods run: `k get pods -o json | jq -r '.items[] | .metadata.name as $n | .status.containerStatuses[] | [$n, .name, .image, (.imageID | split("@")[1])] | @tsv'` (digest only, no secrets). Compare per container with step 2. Also `k get pods -o json | jq -r '.items[] | [.metadata.name, .metadata.creationTimestamp] | @tsv'` for the age.
4. The agent of a session pod created after the deploy: start one fixture session (`ft_session ft-plat-s1 <TPL_STD>`, `ft_wait ft-plat-s1`; where fixtures are not allowed use the newest session pod and record its creation time), then `k get pod <pod> -o json | jq -r '.status.containerStatuses[] | select(.name=="agent") | .imageID'`, `k get pod <pod> -o json | jq -r '.spec.containers[] | select(.name=="agent") | .imagePullPolicy'` and `k logs <pod> -c agent | head -1 | jq -r .version` (the build the binary reports). Do the same for one idle pool pod and note its `eduide.github.io/spec-hash` and age.
Expect: every container of every pod, the agent of the new session pod included, runs the registry digest of its tag. Pass and fail are per image. The agent pull policy follows `image.pullPolicy` of the control plane chart (`Always` on a test environment that deploys `pr-` tags; confirmed 2026-11-25: the `agent` container carries `Always` and runs the registry digest). A mismatch is a finding with image, tag, both digests, the pod, its node and age. On idle pods an older agent is expected only when the hash did not change; say so in the finding and propose `Always` or a digest reference (`agent.image` with `@sha256:`) for the environment, then deploy again. Other tests of this run that exercise the agent (module 06, GIT) test the agent that this test names: do not trust their result for the final build while this test fails.
Cleanup: `ft_cleanup`.

## Unverified, check in the first run

- PLAT-11: the `imageID` of a multi-arch image can be the index or the platform manifest digest depending on the runtime; step 2 lists both.
- `eduide-system/eduide-cluster-identity` and the release `eduide-crds` were not read on test2 (outside the allowed namespace of the authoring session); their names come from `bootstrap-cluster.yml`.
- PLAT-06 against a live environment with prepull (test2 has none). The label `eduide.github.io/component=prepull` comes from `internal/controller/template.go`.
- The `date` fallback in PLAT-07 on the agent's platform.

## Explore

- Compare the landing page footer version (`EduIDE <version>`, from `footerLinks.attribution.version` of `/config.json`) with the deployed landing image tag.
- `k get events --sort-by=.lastTimestamp | tail -30` for warnings nobody looks at (FailedMount, BackOff, quota, `QuotaExceeded`).
- Look for resources that no release owns: `k get all,cm,secret,pvc,httproute --show-labels` and anything without `app.kubernetes.io/managed-by` or an owner reference.
- Leftover Java-stack objects in the namespace or cluster (`theia.cloud` CRDs, the lease `theia-cloud-operator-leaders` still exists on test2): are they harmless?
