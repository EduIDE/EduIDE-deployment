# Rolling out EduIDE 3.0 on tum-production

`eduide.artemis.cit.tum.de` runs the java stack (chart 2.8.0). The 3.0 values
are prepared in `environments/eduide.artemis.cit.tum.de/values-3.0.yaml` and
nothing deploys them until `env.yaml` is switched. This page is the order of
operations. The generic method is in the control plane's
`docs/operations/migration.md` (EduIDE-control-plane).

## Prerequisites

Do all of these before the first deploy.

1. **A published chart.** `helm show chart oci://ghcr.io/eduide/charts/eduide --version <3.x>` works, and the IDE images of that chart exist.
2. **DNS** for the three hosts, all pointing at the address of the `envoy` GatewayClass (131.159.88.82):
   - `eduide.artemis.cit.tum.de` (landing page and `/api/v1`, already exists)
   - `instance.eduide.artemis.cit.tum.de` (already exists)
   - `webview.instance.eduide.artemis.cit.tum.de` (new; java used `*.webview.instance...`)
3. **Keycloak.** In realm `tum`, the client `eduide` is confidential for the gateway, with valid redirect URI `https://eduide.artemis.cit.tum.de/oauth2/callback`. The landing page keeps using the public client of the same name or a separate public client listed in `clientIDs`. See [keycloak-setup.md](keycloak-setup.md).
4. **GitHub Environment secret** `OIDC_CLIENT_SECRET` on the environment `eduide.artemis.cit.tum.de`: the client secret of that confidential client.
5. **CRDs.** Done by `Bootstrap cluster` for `tum-production` once the environment has `stack: go` (`spec.controlPlaneCRDs` in `clusters/tum-production.yaml`). The CRD chart sits next to the Theia Cloud CRDs. Do not install the 3.x `eduide-cluster` chart here: it refuses while Theia Cloud CRDs exist.
6. **Artemis** runs a version with ls1intum/Artemis#14702 (it sends the token in the URL fragment and the repository URL with credentials), and its EduIDE link configuration points at `https://eduide.artemis.cit.tum.de/`.
7. **Egress and monitoring** values in `values-3.0.yaml` (AET CIDRs, `cattle-monitoring-system`, `cattle-dashboards`) match the cluster. Check against the live cluster before the first deploy.
8. **Gateway class.** AET's operators own the GatewayClass `envoy` and its EnvoyProxy. 3.0 renders one Gateway per deployment, so the EnvoyProxy needs `mergeGateways: true`. It is set on `tum-student`; ask the operators for it on `tum-production` before the in-place option.

## Exam-period rule

No productive deployment moves during an exam period. Do not start either option while Artemis exams run.

## Option A: parallel run in a new namespace (preferred)

Java keeps serving; 3.0 runs next to it with its own hosts, so Artemis can be pointed at it when ready.

1. Copy `values-3.0.yaml` to a new environment directory, for example `environments/eduide3.artemis.cit.tum.de/` with namespace `eduide-tum-production-3`, `stack: go`, and new hosts (`eduide3.artemis.cit.tum.de` and so on). Mind that the hostnames in the copy, `config.deployment`, and the Gateway namespace change together. Create its GitHub Environment with `KUBECONFIG` and `OIDC_CLIENT_SECRET`, and a Keycloak redirect URI for the new instance host.
2. Run `Bootstrap cluster` for `tum-production` with `dry_run: true`, then for real. Check `kubectl get crd | grep eduide.github.io`.
3. Run `Deploy environment` with `dry_run: true`, then for real.
4. Verify (checklist below), then point Artemis at the new host.
5. Retire the java environment after the grace period (the way back stays open until the end of the month after the switch).

## Option B: in place

Same hosts, same namespace. Sessions of the java stack end.

1. Announce a window outside any exam period.
2. In one PR: `env.yaml` gets `stack: go` and `chartVersion: 3.x`; `values-3.0.yaml` replaces `values.yaml` (keep `values.yaml` in git history). Merging deploys nothing.
3. `Bootstrap cluster` for `tum-production`: it installs the CRD chart and no longer derives listeners for this environment. The shared-Gateway listeners of the old java release stay until the java release is removed.
4. Uninstall the java release `eduide` in `eduide-tum-production` (`helm uninstall eduide -n eduide-tum-production`) or let the deploy upgrade over it. The upgrade drops the java workloads and routes; Theia Cloud CRs stay behind and are unused.
5. `Deploy environment`, first with `dry_run: true`.

Session data is not migrated (running sessions end). Workspaces are ephemeral on this installation, so nothing needs importing.

## Rollback

- **Within the 3.x release:** Actions, **Rollback**. It reverts to a previous Helm revision of `eduide`.
- **Back to java (Option B):** revert the PR of step 2 (`stack: java`, `chartVersion: 2.8.0`, old `values.yaml`), run `Bootstrap cluster`, then `Deploy environment`. The java stack gets only security fixes until the end of the month after the switch.
- **Option A:** point Artemis back to the old host. Nothing else changed.

The `eduide-crds` release is never uninstalled: `helm uninstall` deletes the CRDs and every session and workspace with them.

## Verification checklist

- [ ] `https://<service host>/api/v1/status` answers 200 and `overall` is not `down`.
- [ ] `kubectl -n <ns> get idetemplate` lists all ten templates; `get idepool` shows `java-17` and `java-25` with `minIdle: 3`.
- [ ] The landing page loads, sign-in works, only the `-standalone` templates are listed.
- [ ] A launch from Artemis (java-17, with token in the URL fragment) opens the IDE and clones the repository.
- [ ] A warm launch is fast, a cold launch (c, python) works.
- [ ] A foreign user opening someone else's session gets 403.
- [ ] Sessions cannot reach 131.159.88.0/24 or the cluster ranges (network policy negative test), but can reach Artemis.
- [ ] Prometheus scrapes the PodMonitor, the dashboard shows the deployment, alerts route to Discord.
- [ ] Certificates are issued for the three hosts (`kubectl -n <ns> get certificate`).
