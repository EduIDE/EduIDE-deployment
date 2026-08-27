# Preparing a cluster

What has to exist on a TUM cluster before EduIDE can be deployed to it, which
parts `Bootstrap cluster` does for you, and which parts it does not.

Read this end to end before bootstrapping a cluster for the first time. Two of
the manual steps below cannot be discovered by trying: they produce a cluster
that reports itself healthy and serves nothing.

## The short version

| | Who does it |
|---|---|
| Gateway API CRDs, Envoy Gateway, cert-manager, storage | **you**, once per cluster |
| A GatewayClass whose load balancer address matches DNS | **you** |
| An ACME `ClusterIssuer` that can solve over Gateway API | **you** |
| The webview wildcard certificate | **you**, see [tum-certificates.md](tum-certificates.md) |
| DNS records | **you** (RBG) |
| Keycloak client and redirect URIs | **you**, see [keycloak-setup.md](keycloak-setup.md) |
| The `KUBECONFIG` and certificate secrets | **you**, see [github-environments.md](github-environments.md) |
| CRDs, conversion webhook, ClusterRoles | `Bootstrap cluster` |
| The shared Gateway and all its listeners | `Bootstrap cluster` |
| The certificate covering every environment's hosts | `Bootstrap cluster` |
| PodMonitors, Grafana dashboards, watched namespaces | `Bootstrap cluster` |
| The cluster identity ConfigMap | `Bootstrap cluster` |
| The operator, service, landing page, routes, apps | `Deploy` |

`Bootstrap cluster` installs the `eduide-cluster` chart and nothing else. It
does not install a Gateway controller, an issuer, cert-manager or a CNI. It
assumes the platform underneath already works.

## Step 1: the platform layer

Install these once per cluster. On TUM's clusters they are already present and
owned by whoever runs the cluster, so in practice this step is a check rather
than an install.

```bash
kubectl get crd gateways.gateway.networking.k8s.io      # Gateway API
kubectl get gatewayclass                                # a controller, Accepted
kubectl -n cert-manager get deploy                      # cert-manager
kubectl get storageclass                                # dynamic provisioning
kubectl get crd podmonitors.monitoring.coreos.com       # only if you want metrics
```

cert-manager must have been installed with `config.enableGatewayAPI=true`.
Without it, cert-manager ignores Gateway resources entirely and every HTTP-01
challenge stays pending forever. If it was installed without the flag, upgrade
and restart it:

```bash
kubectl -n cert-manager rollout restart deploy/cert-manager
```

Verified as present on both TUM clusters at the time of writing:

| | `tum-student` (`stud-cp`) | the current test cluster (`theia-prod`) |
|---|---|---|
| Gateway API CRDs | yes | yes |
| Envoy Gateway | yes | yes |
| cert-manager | yes | yes |
| Prometheus Operator CRDs | yes | yes |
| `cattle-monitoring-system`, `cattle-dashboards` | yes | yes |
| Storage classes | `csi-rbd-sc` (default), `longhorn`, `longhorn-static` | `csi-rbd-sc` **and** `longhorn`, **both default** |
| Nodes | 28 | |

**The test cluster has two default StorageClasses.** A PVC that names no class
gets an arbitrary one. Nothing in this repository can fix that; it is worth
raising with whoever owns the cluster. The deploy sidesteps it by always naming
`spec.storageClassName` from `clusters/<name>.yaml` explicitly.

**28 nodes is a real number here.** Image preloading pulls every IDE image onto
every node, so the default set of eight is roughly 20 GB per node, once. Budget
it before the first bootstrap rather than discovering it as disk pressure.

## Step 2: decide which load balancer address serves EduIDE

This is the step that produces a healthy-looking cluster that serves nothing,
so do it before anything else.

Envoy Gateway can be configured to **merge gateways**: every `Gateway` using a
GatewayClass shares one Envoy deployment and therefore one external address.
`tum-student` is configured that way today:

```
GatewayClass envoy
  -> parametersRef: EnvoyProxy envoy-gateway-system/artemis-envoy-proxy
       mergeGateways: true
       metallb.universe.tf/address-pool: lb2   ->  131.159.88.15
```

and the EduIDE hostnames point somewhere else:

```
eduide.student.k8s.aet.cit.tum.de  ->  k8s-stud-lb3  ->  131.159.88.14   (pool lb3)
```

So a Gateway created with `gatewayClassName: envoy` on that cluster comes up
`Programmed=True`, is served on `131.159.88.15`, and is unreachable at every
name DNS actually publishes. Nothing reports an error.

There are two ways out, and it is a decision, not a default:

**(a) Join the existing merged gateway.** Ask for the EduIDE DNS names to point
at `131.159.88.15` instead. Nothing in this repository changes. EduIDE then
shares an Envoy data plane with Artemis, so a configuration mistake in either
can affect the other.

**(b) Give EduIDE its own GatewayClass.** Create a second GatewayClass with its
own `EnvoyProxy` pinned to pool `lb3`, and set `gatewayClassName` in
`clusters/tum-student.yaml` to match. EduIDE then has its own data plane on
`131.159.88.14`, which is what DNS already says.

The `eduide-cluster` chart can create both objects (`gatewayClass.create` and
`envoyProxy.create`), but **`bootstrap-cluster.yml` does not pass either**, so
today option (b) means creating them by hand or extending the workflow. See
[envoy-gateway-setup.md](envoy-gateway-setup.md) for the MetalLB details.

`clusters/tum-production.yaml` carries `spec.loadBalancerIP: 131.159.88.82`.
**Nothing reads it.** It records the intent; it does not enforce it.

Whichever option is chosen, verify it after bootstrap:

```bash
kubectl -n eduide-system get gateway theia-shared-gateway \
  -o jsonpath='{.status.addresses[*].value}{"\n"}'
dig +short eduide.student.k8s.aet.cit.tum.de A
```

Those two must end at the same address.

## Step 3: an ACME issuer that speaks Gateway API

`Bootstrap cluster` derives a cert-manager `Certificate` covering every
environment's landing, service and instance hostnames. That `Certificate`
references a `ClusterIssuer` by name, and **the workflow does not create the
issuer, nor does it choose which one to use** - the chart's default,
`letsencrypt-prod`, is what the derived certificate asks for.

An issuer of that name exists on both TUM clusters, but on `tum-student` its
only solver is an nginx Ingress solver:

```yaml
solvers:
  - http01:
      ingress:
        class: nginx
```

cert-manager cannot solve a Gateway API challenge with that. The certificate
would stay pending indefinitely, and, as ever, the Gateway would keep reporting
`Programmed=True` while serving whatever stale certificate the secret holds.

You need a `ClusterIssuer` whose HTTP-01 solver is `gatewayHTTPRoute`. The chart
creates one:

```yaml
gatewayAcmeIssuer:
  enabled: true
  name: letsencrypt-prod-gateway
  email: ls1.itg@in.tum.de
managedCertificates:
  issuerRef:
    kind: ClusterIssuer
    name: letsencrypt-prod-gateway
```

Until `bootstrap-cluster.yml` passes those two blocks, supply them by hand: run
the chart once with a values file containing them, or create the `ClusterIssuer`
directly. The test cluster already carries a working
`letsencrypt-prod-gateway`, created out of band.

The wildcard webview certificate is **not** issued this way and never can be.
ACME does not permit HTTP-01 for wildcards. See
[tum-certificates.md](tum-certificates.md).

## Step 4: DNS

Four records per environment, all pointing at the address from step 2:

```
<landing>                             the landing page
service.<landing>                     the REST service
instance.<landing>                    session ingress
*.webview.instance.<landing>          per-session webviews
```

The fourth is a wildcard. RBG issues these; ask early.

Current state:

| Host | Resolves |
|---|---|
| `*.eduide.student.k8s.aet.cit.tum.de` | `131.159.88.14` |
| `eduide.artemis.aet.cit.tum.de` | **not yet** |
| `bonn.eduide.aet.cit.tum.de`, `mannheim.…` | **not yet** |

## Step 5: the GitHub Environment

Bootstrap reads its `KUBECONFIG` and the wildcard certificate from a GitHub
Environment named in `clusters/<name>.yaml` as `spec.bootstrapEnvironment`.
Deploying reads its own `KUBECONFIG` from a GitHub Environment named after the
environment. They are different environments and hold different secrets.

Full instructions, including what is missing today, are in
[github-environments.md](github-environments.md).

## Step 6: bootstrap

```
Actions -> Bootstrap cluster
  cluster:       tum-student
  chart_version: 2.1.0
  dry_run:       true
```

Read the rendered values and the `helm diff` in the job summary. The workflow
prints the listeners, watched namespaces and certificate names it derived, so
this is where a wrong `sectionName` or a missing environment shows up.

What it derives, from the environments that claim the cluster:

- **Gateway listeners**, from each environment's `gateway.parentRefs[].sectionName`
  plus its hosts. Four per environment, plus a plain `:80` listener per
  non-wildcard host when the cluster sets `spec.tls.acmeHttp: true`.
- **The TLS secret per listener**, from `spec.tls` in the cluster manifest. A
  listener with no secret renders an empty `certificateRefs`, is accepted, and
  never programs TLS, so the chart fails the render instead.
- **The certificate's `dnsNames`**, from the same pass, so a listener and its
  certificate cannot disagree. Only landing, service and instance hosts go on
  it: a name without a listener answers 404 to its HTTP-01 challenge, stays
  pending, and blocks the certificate for every other name on it.
- **The namespaces the PodMonitors watch**, from each environment's
  `spec.namespace`, skipping any that set `monitoring.enabled: false`.

It refuses to run when no environment claims the cluster, and it refuses to
bootstrap a cluster that already carries a different name in
`eduide-system/eduide-cluster-identity` - that almost always means the
`KUBECONFIG` on the GitHub Environment points somewhere unexpected.

Then run it again with `dry_run: false`.

## Step 7: verify

```bash
kubectl -n eduide-system get cm eduide-cluster-identity \
  -o jsonpath='{.data.clusterName}{"\n"}'
kubectl get crd | grep theia.cloud                    # 3 CRDs
kubectl -n eduide-system get gateway -o wide          # Programmed, with an address
kubectl -n eduide-system get certificate              # Ready=True
kubectl -n cattle-monitoring-system get podmonitor    # 2
```

Every listener should report `Programmed`. A listener that reports
`ResolvedRefs=False` names a Secret that does not exist yet, which is normal
until the certificate issues for the first time.

**Do not check TLS with `curl -k`.** It suppresses exactly the failure that is
worth finding. Check each hostname against the certificate the server actually
presents:

```bash
for h in test1.eduide.student.k8s.aet.cit.tum.de \
         service.test1.eduide.student.k8s.aet.cit.tum.de \
         instance.test1.eduide.student.k8s.aet.cit.tum.de; do
  echo | openssl s_client -connect "$h:443" -servername "$h" 2>/dev/null \
    | openssl x509 -noout -checkhost "$h"
done
```

Each must print `Host <name> matches certificate`. Gateway API never compares a
certificate's names against its listener's hostname, so a listener holding a
certificate for entirely different hosts reports `Programmed=True
ResolvedRefs=True` and looks perfect. test3 ran that way for 184 days: the
landing page loaded past the browser warning, then silently could not call its
own REST service, because the browser blocks a cross-origin request over an
invalid certificate. Nothing appeared in any log.

## Step 8: deploy an environment

```
Actions -> Deploy (dispatch) -> environment: test1, dry_run: true
```

The deploy asserts the cluster identity before touching anything, so a
`KUBECONFIG` pointing at the wrong cluster stops here rather than installing
EduIDE somewhere unexpected.

## Adding a cluster

1. `clusters/<name>.yaml`. It is validated against
   `schemas/cluster.schema.json`, which rejects unknown keys.

   ```yaml
   apiVersion: eduide.dev/v1
   kind: Cluster
   metadata:
     name: eduide
     displayName: EduIDE cluster
   spec:
     storageClassName: local        # must exist on the cluster
     gatewayClassName: envoy        # see step 2 before accepting this default
     tls:                           # the Secret each listener role terminates with
       landing: shared-theia-cert
       service: shared-theia-cert
       instances: shared-theia-cert
       webview: static-theia-cert   # always separate - two labels lower
       acmeHttp: false              # true adds :80 listeners for HTTP-01
     sharedGateway: { namespace: eduide-system, name: theia-shared-gateway }
     runner: ubuntu-latest          # must be able to reach the API server
     bootstrapEnvironment: cluster-eduide
   ```

2. Add the name to the `cluster` choice list in
   `.github/workflows/bootstrap-cluster.yml`. Workflow inputs cannot be derived
   from a file.
3. Create the GitHub Environment named in `bootstrapEnvironment`.
4. Work through steps 1 to 7 above.

`runner` is per cluster because deploying is not building: a deploy has to reach
the API server, and the clusters may differ in how they are reachable.

## Known gaps

Three things this repository describes but does not yet apply. All three are
listed above in context; collected here so they are not missed:

| Gap | Consequence |
|---|---|
| `bootstrap-cluster.yml` passes no `gatewayClass` or `envoyProxy` | A cluster needing its own data plane address must have it created by hand (step 2) |
| `bootstrap-cluster.yml` passes no `gatewayAcmeIssuer` and no `managedCertificates.issuerRef` | Derived certificates ask for `letsencrypt-prod`, which on `tum-student` cannot solve Gateway API challenges (step 3) |
| `spec.loadBalancerIP` is in the schema and in `tum-production.yaml` | Nothing reads it. It records intent only (step 2) |
