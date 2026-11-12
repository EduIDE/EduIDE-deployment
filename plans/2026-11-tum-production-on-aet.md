# TUM production on the AET cluster

Status: production live on AET since 2026-11-12 (bootstrap run 43124990540,
deploy run 43125443894). Open: a human login and session start (step 10) and
the Artemis switch (step 11).

## Decisions

| Topic | Decision |
|---|---|
| Gateway | Join the AET operators' merged gateway (#162) |
| Storage | `longhorn`, 3 replicas |
| Node pool | `pve`, via `spec.nodeSelector` (EduIDE/EduIDE-Helm#73, chart 2.8.0, EduIDE-Cloud 1.3.0) |
| Rancher project | `eduide` (`p-9s76d`); Kyverno's namespace isolation exempts it, so only the chart's NetworkPolicies apply |
| Session egress | also deny 198.18.0.0/15 (pods, services) and 131.159.88.0/24 (nodes, load balancers, API server) |
| Apps | the eight catalog apps: Artemis production's five plus the three playground variants |
| Chart | `eduide` and `eduide-cluster` 2.8.0 |
| Cookie secret | rotated |


Moves `eduide.artemis.cit.tum.de` (cluster manifest `tum-production`) onto the
new AET cluster (kube context `aet-cp`, Rancher `c-9jjmv`). Bonn and Mannheim
are out of scope and must not be deployed.

## What the AET cluster looks like (read-only, 2026-11-11)

| | Finding |
|---|---|
| Kubernetes | RKE2 v1.35.9 (test cluster: v1.34.12) |
| Nodes | 33: 3 control (tainted), 3 storage (tainted), 7 `ito` workers (8 CPU, 16 GB, 250 GB), 20 `pve` workers (16 CPU, 32 GB, 500 GB) |
| Storage | `longhorn` (default, 3 replicas), `longhorn-single` (1 replica), `longhorn-static`. No `csi-rbd-sc`. |
| GatewayClass | `envoy` -> EnvoyProxy `envoy-gateway-system/envoy`, `mergeGateways: true`, 2 replicas, PDB, pods on `pve` pool, MetalLB pool `envoy` = 131.159.88.82 + 2a09:80c0:88::82 (dual stack). The data plane Service appeared with the shared Gateway at bootstrap. |
| Other classes | `envoy-internal` (.134, VPN only), `traefik-external` (.81), `traefik-internal` (.133) |
| cert-manager | present, Gateway API CRDs present. ClusterIssuers `letsencrypt-production`, `letsencrypt-staging` (HTTP-01 over `traefik-external` Ingress) and `internal-acme` (Harica, `traefik-internal`). None can solve over Gateway API, so bootstrap adds `letsencrypt-prod-gateway`. |
| Monitoring | rancher-monitoring, PodMonitor CRDs, Prometheus selects PodMonitors in all namespaces |
| Kyverno | `namespace-isolation` GeneratingPolicy: every namespace in a Rancher team project gets an ingress-only NetworkPolicy allowing same namespace, namespaces labelled `aet.cit.tum.de/network=gateway` (`envoy-gateway-system`, `traefik`), `cattle-monitoring-system`, `cnpg-system` and the three control plane IPs. Namespaces in no project get nothing. `restrict-network-label` reserves the gateway label. |
| Pod network | Calico, pods 198.18.0.0/16 + 2a09:80c0:88::13:0:0/96, services 198.19.0.0/16 + IPv6 inside the same /96. Pods have public IPv6 addresses. |
| Pod Security | RKE2 PSS config file `/etc/rancher/rke2/rke2-pss.yaml`, contents not readable from here |

## Production state

- Live on AET since 2026-11-12. All five hosts (`eduide.`, `service.eduide.`,
  `instance.eduide.`, `*.webview.instance.eduide.` and the redirect
  `theia.artemis.cit.tum.de`) resolve to `k8s-aet-lb1` = 131.159.88.82 /
  2a09:80c0:88::82; `service.`, `instance.` and the webview wildcard still go
  through the `k8s-theia-lb1` CNAME.
- The old production cluster is switched off and gone from Rancher. There is no
  rollback target outside AET.

## Gaps and decisions (as decided before go-live)

1. **Gateway / data plane.** Join the operators' merged gateway (option (a) of
   docs/cluster-setup.md). PR #162 does exactly that. Merge as is.
2. **Storage class.** Manifest says `csi-rbd-sc`, which does not exist.
   Proposal: `longhorn` (3 replicas) for student workspaces. Alternative
   `longhorn-single` if workspaces count as disposable.
3. **Certificates.** Keep `acmeHttp: true` and the bootstrap-created
   `letsencrypt-prod-gateway` issuer (HTTP-01 via `gatewayHTTPRoute`). The AET
   issuers solve over Traefik on .81, while DNS points at .82, so they cannot
   issue for these names. Needs the DNS fix in 3a first.
   - 3a. RBG: `service.`, `instance.` and `*.webview.instance.` still CNAME to
     `k8s-theia-lb1`, which now itself CNAMEs to `k8s-aet-lb1` (done by the
     user 2026-11-11; verified at ns1.rbg.tum.de, 1.1.1.1 and 8.8.8.8, A + AAAA).
     A chain of two CNAMEs; pointing the three names at `k8s-aet-lb1` directly
     would let `k8s-theia-lb1` go later.
   - 3b. Webview wildcard: the Harica certificate in GitHub Environment
     `cluster-tum-production` (set 2026-08-27) is reused by bootstrap. User
     checks SAN and expiry locally.
4. **Kubeconfigs.** Both GitHub Environments hold Rancher kubeconfigs for AET
   (`https://<rancher>/k8s/clusters/c-9jjmv`), because AET's API server is not
   reachable from GitHub's runners. A ServiceAccount kubeconfig was tried and
   reverted for that reason. `THEIA_KEYCLOAK_COOKIE_SECRET` was rotated.
5. **Rancher project / Kyverno isolation.** `eduide-system` and
   `eduide-tum-production` are in Rancher project `eduide`, which the
   isolation policy exempts, so only the chart's own NetworkPolicies apply.
   The conversion webhook works.
6. **Session egress.** `networkPolicies.privateEgressCidrs` adds
   198.18.0.0/15 (pod + service CIDR), as on the test environments, and
   131.159.88.0/24 (AET nodes, load balancers, API server; Artemis is at
   131.159.89.175 and stays reachable). IPv6 egress is denied entirely by the
   chart (it only allows 0.0.0.0/0); git and Java fall back to IPv4 at once.
7. **Chart version.** Fresh install, so go straight to `eduide` 2.8.0 and
   bootstrap with `eduide-cluster` 2.8.0. No old AppDefinitions exist on AET,
   so nothing gets deleted, but the old `-latest` names no longer exist either:
   Artemis must switch `theiaImage` to the new names (`java-17`, ...) at go-live.
   Split production out of draft #155 (which also touches Bonn and Mannheim)
   into its own PR. Keep `java-25` `minInstances: 3`.
8. **Kubernetes 1.35.** Render both charts with `--kube-version 1.35` and run a
   server-side dry run against AET before the real bootstrap, so removed APIs
   or a restrictive PSS profile surface before anything is installed.
9. **Apps.** Exactly what Artemis production launches since
   ls1intum/artemis-ansible#116 (`java-17`, `java-25`, `c`, `javascript`,
   `python`) plus the playground variants the catalog has (`java-17-templates`,
   `java-25-templates`, `c-templates`). That is all eight catalog entries today;
   list them in `appDefinitions.enabled` anyway, so a new catalog entry does not
   reach production unasked. Existing exercises still carry `-latest` names in
   `theiaImage` and need the data migration #116 mentions.
12. **Node pool.** EduIDE belongs on the `pve` pool (20 workers, 16 CPU / 32 GB).
    Implemented before go-live (EduIDE/EduIDE-Helm#73, chart 2.8.0,
    EduIDE-Cloud 1.3.0, `spec.nodeSelector`); every EduIDE pod runs on `pve`.
10. **Keycloak.** Hostnames do not change, so client `eduide` in realm `tum`
    on keycloak.aet.cit.tum.de needs no change. Verify a login after deploy.
11. **Old cluster teardown.** Done. Left: remove the `k8s-theia-lb1`
    references from DNS (3a).

## Order of PRs and steps

| # | What | Who |
|---|---|---|
| 0 | ~~EduIDE/EduIDE-Helm#73: node pool selection~~ done: EduIDE-Cloud#164 (v1.3.0), workspace-garbage-collector#23 (0.2.0), EduIDE-Helm#74 (2.8.0), EduIDE-deployment#163 | Claude |
| 0b | ~~Namespaces `eduide-system`, `eduide-tum-production` in Rancher project `eduide`~~ done | Claude |
| 1 | ~~Merge PR #162 (operators' GatewayClass and EnvoyProxy)~~ done | user |
| 2+3 | ~~PR #165~~ done: `longhorn`, production on chart 2.8.0 with the app catalog, `java-25` warm, `privateEgressCidrs`; replaces the production part of #155 | Claude |
| 4 | ~~DNS for `service.`, `instance.`, `*.webview.instance.`~~ done | user |
| 5 | ~~done~~ Replace both `KUBECONFIG` secrets with Rancher kubeconfigs (`https://<rancher>/k8s/clusters/c-9jjmv`): the AET control plane is not reachable from the internet, so GitHub runners deploy through Rancher. Cookie secret ~~rotated~~ done | user |
| 6 | ~~Local render with `--kube-version 1.35` and server dry run~~ done | Claude |
| 7 | ~~`Bootstrap cluster` tum-production, `eduide-cluster` 2.8.0, dry run, then real~~ done, run 43124990540 | user approves |
| 8 | ~~Verify: identity, CRDs, Gateway address = .82, certificates Ready, `openssl -checkhost` per host, redirect 301~~ done | Claude |
| 9 | ~~`Deploy` eduide.artemis.cit.tum.de, dry run, then real~~ done, run 43125443894 | user approves |
| 10 | Verify: ~~landing, git clone, egress blocked~~ done; login, java-17 and java-25 session start, webview preview open | Claude + user |
| 11 | Artemis switches `theiaImage` to the new app names | Artemis team |

## Verified after go-live (2026-11-12)

- Gateway `theia-shared-gateway` Programmed on 131.159.88.82 and
  2a09:80c0:88::82; identity `tum-production`; three CRDs.
- Let's Encrypt certificates for landing, service, instance and `theia.` Ready
  within a minute; `openssl -checkhost` passes for every host, the Harica
  webview wildcard included (valid until 2027-03-14).
- `theia.artemis.cit.tum.de/foo?bar=1` answers 301 to
  `eduide.artemis.cit.tum.de/foo?bar=1`.
- Operator (3), service 1.3.0, landing page and garbage collector on `pve`;
  eight AppDefinitions on 1.5.0; three warm `java-17` and three warm `java-25`
  instances; landing page 200 over IPv4 and IPv6.
- Keycloak accepts the landing and instance redirect URIs (303) and rejects a
  foreign one (400).
- From a session: git to GitHub and GitLab, Java to Maven Central and
  `artemis.tum.de` work over IPv4. Pod and service networks, the API server,
  the load balancer addresses and the metadata address are blocked. IPv6 is
  denied entirely; git and Java fall back to IPv4 at once, IPv6-only tools such
  as bash `/dev/tcp` fail.
- The instance host answers 500 on `/` until a session claims an instance,
  same as staging.
- Preloading was still pulling on the 20 `pve` nodes at the time of writing.

Rollback: none to the old cluster (gone). Within AET, `Rollback` workflow for
the tenant release; the bootstrap release can be rolled back with Helm.
