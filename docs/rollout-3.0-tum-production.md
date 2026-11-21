# Rolling out EduIDE 3.0 on tum-production

`eduide.artemis.cit.tum.de` ran the java stack (chart 2.8.0) until 2026-11-21
and moved to the go stack in place (option B). Its values are
`environments/eduide.artemis.cit.tum.de/values.yaml`. This page is the order of
operations, kept for the record and for the way back. The generic method is in the control plane's
`docs/operations/migration.md` (EduIDE-control-plane).

## Prerequisites

Do all of these before the first deploy.

1. **A published chart.** `helm show chart oci://ghcr.io/eduide/charts/eduide --version <3.x>` works, and the IDE images of that chart exist.
2. **DNS** for the three hosts, all pointing at the address of the `envoy` GatewayClass (131.159.88.82):
   - `eduide.artemis.cit.tum.de` (landing page and `/api/v1`, already exists)
   - `instance.eduide.artemis.cit.tum.de` (already exists)
   - `webview.instance.eduide.artemis.cit.tum.de` (new; java used `*.webview.instance...`)
3. **Keycloak.** In realm `tum`, the gateway client (`gatewayClientID`) has the valid redirect URI `https://instance.eduide.artemis.cit.tum.de/oauth2/callback` (the instance host, not the landing host). test1 to test3 and Bonn use one client `eduide` for the gateway and the landing page; see [keycloak-setup.md](keycloak-setup.md).
4. **GitHub Environment secret** `OIDC_CLIENT_SECRET` on the environment `eduide.artemis.cit.tum.de`: the client secret of that confidential client.
5. **CRDs.** Done by `Bootstrap cluster` for `tum-production` once the environment has `stack: go` (`spec.controlPlaneCRDs` in `clusters/tum-production.yaml`). The CRD chart sits next to the Theia Cloud CRDs. Do not install the 3.x `eduide-cluster` chart here: it refuses while Theia Cloud CRDs exist.
6. **Artemis** runs a version with ls1intum/Artemis#14702 (it sends the token in the URL fragment and the repository URL with credentials), and its EduIDE link configuration points at `https://eduide.artemis.cit.tum.de/`.
7. **Egress and monitoring** values in the go values (AET CIDRs, `cattle-monitoring-system`, `cattle-dashboards`) match the cluster. Check against the live cluster before the first deploy.
8. **Gateway class.** AET's operators own the GatewayClass `envoy` and its EnvoyProxy. 3.0 renders one Gateway per deployment, so the EnvoyProxy needs `mergeGateways: true`. It is set on `tum-student` and on `tum-production` (checked 2026-11-21).

## Exam-period rule

No productive deployment moves during an exam period. Do not start either option while Artemis exams run.

## Option A: parallel run in a new namespace (preferred)

Java keeps serving; 3.0 runs next to it with its own hosts, so Artemis can be pointed at it when ready.

1. Copy the go values to a new environment directory, for example `environments/eduide3.artemis.cit.tum.de/` with namespace `eduide-tum-production-3`, `stack: go`, and new hosts (`eduide3.artemis.cit.tum.de` and so on). Mind that the hostnames in the copy, `config.deployment`, and the Gateway namespace change together. Create its GitHub Environment with `KUBECONFIG` and `OIDC_CLIENT_SECRET`, and a Keycloak redirect URI for the new instance host.
2. Create DNS records for the three hosts of the copy (`eduide3.artemis.cit.tum.de`, `instance.eduide3.artemis.cit.tum.de`, `webview.instance.eduide3.artemis.cit.tum.de`), all pointing at the `envoy` GatewayClass address (131.159.88.82), and add the new environment to the `environment` choice lists in `.github/workflows/deploy-dispatch.yml` and `rollback.yml`.
3. Run `Bootstrap cluster` for `tum-production` with `dry_run: true`, then for real. Check `kubectl get crd | grep eduide.github.io`.
4. Run `Deploy environment` with `dry_run: true`, then for real.
5. Verify (checklist below), then point Artemis at the new host.
6. Retire the java environment after the grace period (the way back stays open until the end of the month after the switch).

## Option B: in place

Same hosts, same namespace. Sessions of the java stack end.

1. Announce a window outside any exam period.
2. In one PR: `env.yaml` gets `stack: go` and `chartVersion: 3.x`; `values-3.0.yaml` replaces `values.yaml` (keep `values.yaml` in git history). Merging deploys nothing.
3. `Bootstrap cluster` for `tum-production`: it installs the CRD chart and no longer derives listeners for this environment. With no java environment left on the cluster it does not touch the 2.x `eduide-cluster` release at all, so the shared Gateway keeps the `prod-*` listeners.
4. Remove the `prod-*` listeners and their certificates from the shared Gateway by hand, keeping the `legacy-landing` redirect (`theia.artemis.cit.tum.de`). With `mergeGateways` they claim the same hostnames and ports as the new Gateway `eduide`, and Envoy Gateway marks one side `Conflicted`. `helm upgrade eduide-cluster <2.8.0 chart> -n eduide-system --reuse-values -f <file>` with `gateway.listeners` and `managedCertificates.certificates` set to the two legacy entries; check `kubectl -n eduide-system get gateway theia-shared-gateway`.
5. Uninstall the java release `eduide` in `eduide-tum-production` (`helm uninstall eduide -n eduide-tum-production`) or let the deploy upgrade over it. The upgrade drops the java workloads and routes; Theia Cloud CRs stay behind and are unused.
6. `Deploy environment` with `dry_run: true` and review the diff.
7. `Deploy environment` without `dry_run`. Step 5 may already have removed the java release, so do not stop after the dry run.

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
