# Envoy Gateway Setup

This repository deploys Theia Cloud through Gateway API resources backed by Envoy Gateway. The setup is split across two repositories:

- [EduIDE-Helm](https://github.com/EduIDE/EduIDE-Helm) renders the Theia Cloud `HTTPRoute` resources and, for simple installations, can also render a namespace-local `Gateway`.
- [EduIDE-deployment](https://github.com/EduIDE/EduIDE-deployment) uses those charts internally and adds the [`eduide-cluster`](https://github.com/EduIDE/EduIDE-Helm/tree/main/charts/eduide-cluster/templates/gateway) chart, which owns one cluster-level Gateway shared by multiple Theia namespaces.

For the Artemis/EduIDE deployments, the shared gateway model is the expected setup. Tenant releases should create only their namespace-local routes and workloads; the shared gateway release owns the edge Gateway, listener hostnames, GatewayClass customization, and TLS material.

## Architecture

The traffic path is:

1. DNS points Theia hostnames to the Envoy Gateway load balancer address.
2. Envoy Gateway watches Gateway API resources and programs Envoy.
3. The `eduide-cluster` release creates the shared `Gateway` in `eduide-system`.
4. Each Theia tenant release creates `HTTPRoute` resources in its own namespace.
5. Those `HTTPRoute` resources attach to the shared Gateway through `theia-cloud.gateway.parentRefs`.
6. The Theia Cloud operator later edits the instances `HTTPRoute` to attach newly created IDE sessions.

This replaces the older ingress-controller style setup with Gateway API. The main practical benefit is that route updates can be applied dynamically without making every tenant release own a separate edge gateway.

## Prerequisites

Before deploying Theia Cloud, the cluster needs:

- Gateway API CRDs
- Envoy Gateway
- cert-manager
- cert-manager Gateway API support, if ACME HTTP-01 challenges should be solved through Gateway API
- a load balancer implementation for the Envoy data plane, for example a cloud load balancer or MetalLB
- DNS records for landing, service, instance, and webview hostnames
- TLS certificate material, either managed through cert-manager or provided as a wildcard certificate secret

Use the official installation documentation for exact versions and compatibility:

- [Envoy Gateway Helm installation](https://gateway.envoyproxy.io/docs/install/install-helm/)
- [cert-manager Gateway API HTTP-01 solver](https://cert-manager.io/docs/configuration/acme/http01/)

## Install Envoy Gateway

Install Gateway API CRDs and Envoy Gateway once per cluster. A typical Helm-based installation looks like this:

```bash
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
  --namespace envoy-gateway-system \
  --create-namespace
```

If your cluster already has Gateway API CRDs managed separately, follow the Envoy Gateway documentation for the matching `--skip-crds` flow.

After installation, verify that the controller is running:

```bash
kubectl get pods -n envoy-gateway-system
kubectl get gatewayclasses
kubectl get crd | grep -E 'gateway.networking.k8s.io|gateway.envoyproxy.io'
```

The default GatewayClass name expected by the Theia charts is `envoy`. If you use another class name, set it consistently in both the shared gateway values and the tenant values:

```yaml
gateway:
  className: envoy

theia-cloud:
  gateway:
    className: envoy
```

## Install cert-manager With Gateway API Support

cert-manager is still responsible for certificate resources. If certificates are issued through Gateway API HTTP-01 challenges, install or upgrade cert-manager with Gateway API support enabled.

The exact values depend on the cert-manager version. For current cert-manager versions, use the file-based `config.enableGatewayAPI` value described in the cert-manager documentation.

Example shape:

```bash
helm upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true \
  --set config.enableGatewayAPI=true
```

If cert-manager was already running before Gateway API CRDs were installed, restart cert-manager after enabling Gateway API support so it discovers the new resource types.

```bash
kubectl rollout restart deployment/cert-manager -n cert-manager
kubectl rollout restart deployment/cert-manager-webhook -n cert-manager
kubectl rollout restart deployment/cert-manager-cainjector -n cert-manager
```

## Deploy the Shared Gateway

The shared Gateway is deployed from the [`eduide-cluster`](https://github.com/EduIDE/EduIDE-Helm/tree/main/charts/eduide-cluster/templates/gateway) chart's gateway templates, in EduIDE-Helm:

```bash
helm upgrade --install eduide-cluster oci://ghcr.io/eduide/charts/eduide-cluster \
  --namespace eduide-system \
  --create-namespace \
  --version 2.0.0 -n eduide-system -f listeners.yaml
```

For the dedicated production cluster, use:

```bash
helm upgrade --install eduide-cluster oci://ghcr.io/eduide/charts/eduide-cluster \
  --namespace eduide-system \
  --create-namespace \
  --version 2.0.0 -n eduide-system -f listeners.yaml
```

The deployment workflow can also install this release automatically when the caller workflow passes:

```yaml
with:
  deploy_shared_gateway: true
  (listeners are derived by the workflow; there is no values file to name)
  shared_gateway_namespace: eduide-system
```

The workflow injects `THEIA_WILDCARD_CERTIFICATE_CERT` and `THEIA_WILDCARD_CERTIFICATE_KEY` into the shared gateway chart as `wildcardTLSSecret.certificate` and `wildcardTLSSecret.key`.

## Shared Gateway Values

The shared gateway chart can create:

- a `Gateway`
- an optional `GatewayClass`
- an optional Envoy Gateway `EnvoyProxy`
- optional cert-manager `Certificate` resources
- an optional Gateway API ACME `ClusterIssuer`
- an optional static wildcard TLS secret

Listeners are no longer written by hand. `Bootstrap cluster` derives them from
the `gateway.parentRefs` each environment declares, so a listener cannot
disagree with the route that attaches to it and adding an environment needs no
second file. The TLS secrets are assumed to exist or are supplied through the
workflow.

On the production cluster the same chart additionally creates:

- a `GatewayClass` named `envoy`
- an `EnvoyProxy` that customizes the Envoy data-plane service
- a Gateway API ACME `ClusterIssuer`
- cert-manager `Certificate` resources for concrete production hostnames
- the static wildcard webview TLS secret from deployment secrets

The production `EnvoyProxy` currently contains MetalLB-specific annotations and a fixed load-balancer IP:

```yaml
envoyProxy:
  spec:
    provider:
      type: Kubernetes
      kubernetes:
        envoyService:
          annotations:
            metallb.io/address-pool: ingress
            metallb.io/loadBalancerIPs: 131.159.88.82
```

Adjust this section for a different cluster. On cloud providers, this may be replaced by provider-specific load balancer annotations or omitted entirely.

## MetalLB IP Assignment

The following values describe the current production Theia cluster. Treat them as an example of the pattern, not as universal defaults. Other deployments must use their own MetalLB pools, external IPs, DNS records, and load-balancer annotations.

In the current Artemis cluster, MetalLB exposes two single-address pools:

| Pool | Address | DNS label on the pool | Current purpose |
| --- | --- | --- | --- |
| `general` | `131.159.88.81/32` | `k8s-theia-lb0.aet.cit.tum.de` | general load balancer pool, not assigned to Envoy Gateway |
| `ingress` | `131.159.88.82/32` | `k8s-theia-lb1.aet.cit.tum.de` | Envoy Gateway ingress pool |

The production Theia DNS names in this cluster resolve to `k8s-theia-lb1.aet.cit.tum.de`, which resolves to `131.159.88.82`. Therefore this deployment's Envoy Gateway data-plane service must receive `131.159.88.82`, not the other MetalLB address.

The general procedure is to choose the MetalLB pool and external address that DNS points to, then encode that choice in the shared gateway values. In this production setup, that is enforced through the shared gateway production values, not by manually editing the generated service. The `eduide-cluster` chart creates an Envoy Gateway `EnvoyProxy` resource with:

```yaml
envoyProxy:
  create: true
  name: theia-shared-gateway
  namespace: envoy-gateway-system
  spec:
    provider:
      type: Kubernetes
      kubernetes:
        envoyService:
          annotations:
            metallb.io/address-pool: ingress
            metallb.io/loadBalancerIPs: 131.159.88.82
          externalTrafficPolicy: Local
          type: LoadBalancer
```

Envoy Gateway reads this `EnvoyProxy` configuration and creates the actual data-plane service in `envoy-gateway-system`. The live service is named like:

```text
envoy-gateway-system-theia-shared-gateway-74c11d26
```

That service is generated and managed by Envoy Gateway. It currently has these relevant annotations and status:

```yaml
metadata:
  annotations:
    metallb.io/address-pool: ingress
    metallb.io/ip-allocated-from-pool: ingress
    metallb.io/loadBalancerIPs: 131.159.88.82
spec:
  type: LoadBalancer
  clusterIP: 198.19.125.184
  externalTrafficPolicy: Local
status:
  loadBalancer:
    ingress:
      - ip: 131.159.88.82
```

The `clusterIP` is only the internal Kubernetes service address. Public DNS must point to the MetalLB-assigned LoadBalancer address in `status.loadBalancer.ingress`, not to the internal `clusterIP`.

The `metallb.io/address-pool: ingress` annotation selects the MetalLB pool. The `metallb.io/loadBalancerIPs: 131.159.88.82` annotation pins the exact address from that pool. MetalLB then records the actual allocation with `metallb.io/ip-allocated-from-pool: ingress` and publishes the address in the service status.

Do not rely on MetalLB auto-assignment when the public DNS name must target a specific address. In the production cluster, both pools have `autoAssign: true`, so without the explicit EnvoyProxy annotations a new LoadBalancer service could receive the wrong address. If Envoy Gateway receives `131.159.88.81` while public DNS points at `131.159.88.82`, Theia hostnames will resolve to an address that is not serving the Gateway.

For a different deployment, adapt all of the following together:

- the MetalLB `IPAddressPool` name
- the exact external IP requested through `metallb.io/loadBalancerIPs`
- the DNS `A` / `AAAA` records for the public Theia hostnames
- the shared gateway `EnvoyProxy` load-balancer annotations
- any provider-specific load balancer annotations if the cluster does not use MetalLB

Use these checks after installing or changing the shared gateway:

```bash
kubectl get ipaddresspools.metallb.io -n metallb-system
kubectl get l2advertisements.metallb.io -n metallb-system
kubectl get envoyproxy theia-shared-gateway -n envoy-gateway-system -o yaml
kubectl get svc -n envoy-gateway-system -o wide
kubectl get svc -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-name=theia-shared-gateway,gateway.envoyproxy.io/owning-gateway-namespace=eduide-system \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.metallb\.io/address-pool}{"\t"}{.metadata.annotations.metallb\.io/loadBalancerIPs}{"\t"}{.status.loadBalancer.ingress[*].ip}{"\n"}{end}'
dig +short theia.artemis.cit.tum.de A
dig +short k8s-theia-lb1.aet.cit.tum.de A
```

In the current Artemis production setup, the expected result is that the Envoy Gateway LoadBalancer service and the public DNS chain both end at `131.159.88.82`. In another deployment, the same check should end at that deployment's chosen public load-balancer address.

## Configure Tenant Theia Releases

Each tenant environment should attach its routes to the shared Gateway instead of creating a namespace-local Gateway:

```yaml
theia-cloud:
  gateway:
    enabled: true
    create: false
    routes:
      enabled: true
    parentRefs:
      - name: theia-shared-gateway
        namespace: eduide-system
        sectionName: test1-landing
      - name: theia-shared-gateway
        namespace: eduide-system
        sectionName: test1-service
      - name: theia-shared-gateway
        namespace: eduide-system
        sectionName: test1-instances
      - name: theia-shared-gateway
        namespace: eduide-system
        sectionName: test1-webview
```

The `sectionName` values must match listener names in the shared gateway values file. If a route references a listener name that does not exist, or if the listener hostname does not match the route hostname, the `HTTPRoute` will not attach.

Disable tenant-local certificate resources when using the shared gateway:

```yaml
theia-certificates:
  certificates:
    enabled: false
  wildcardTLSSecret:
    enabled: false
  adminApiTokenSecret:
    enabled: true
```

Do not set `theia-cloud.gateway.instancesWildcardSecretNames` in tenant values when `gateway.create: false`. That map is only used when the Theia Cloud chart renders its own `Gateway`. In the shared-gateway setup, wildcard TLS secrets are owned by the shared gateway release in `eduide-system`.

## Add or Change Hostnames

For every environment, keep these values aligned:

- tenant `hosts.configuration.landing`
- tenant `hosts.configuration.service`
- tenant `hosts.configuration.instance`
- tenant `hosts.allWildcardInstances`
- tenant `theia-cloud.gateway.parentRefs[*].sectionName`
- shared gateway `gateway.listeners[*].name`
- shared gateway `gateway.listeners[*].hostname`
- DNS records for the same hostnames
- TLS certificate DNS names

Each environment usually needs listeners for:

- landing page hostname
- service API hostname
- session instance hostname
- webview wildcard hostname

If cert-manager should issue concrete host certificates through HTTP-01, also add matching HTTP listeners on port `80` so cert-manager can attach solver routes to the Gateway.

## Manual Steps That Automation Does Not Fully Own

Some cluster-level setup still has to be done manually or by separate infrastructure automation:

- Install or upgrade Envoy Gateway and Gateway API CRDs.
- Install or upgrade cert-manager with Gateway API support.
- Ensure the Envoy Gateway load balancer receives the intended external IP or hostname.
- Point DNS records at the Envoy Gateway load balancer.
- Provide wildcard certificate secrets for webview hosts, or configure cert-manager to issue suitable certificates.
- For production-style MetalLB clusters, reserve the configured load-balancer IP and keep `envoyProxy.spec.provider.kubernetes.envoyService.annotations` in sync.
- Create or update Keycloak clients separately; see [`docs/keycloak-setup.md`](https://github.com/EduIDE/EduIDE-deployment/blob/main/docs/keycloak-setup.md).

The GitHub Actions workflow installs Theia Cloud base charts, CRDs, monitoring, the optional shared gateway release, and tenant releases. It does not install Envoy Gateway itself.

## Validation

After deploying the shared gateway and a tenant release, check:

```bash
kubectl get gatewayclass
kubectl get gateway -n eduide-system
kubectl get httproute -A
kubectl describe gateway theia-shared-gateway -n eduide-system
kubectl describe httproute landing-route -n <tenant-namespace>
kubectl describe httproute service-route -n <tenant-namespace>
kubectl describe httproute theia-cloud-demo-ws-route -n <tenant-namespace>
```

The important conditions are:

- the shared `Gateway` is accepted and programmed
- tenant `HTTPRoute` resources are accepted
- each route has a resolved parent reference
- the Envoy data-plane service has an external address
- TLS secrets referenced by HTTPS listeners exist in `eduide-system`

For a quick end-to-end check, open the landing hostname and then start an IDE session. The operator should add a rule to the instances route, and the generated session URL should resolve through the shared Gateway.

## Common Failure Modes

`HTTPRoute` does not attach:

- the `sectionName` in tenant `parentRefs` does not match a listener name
- the route hostname is not allowed by the listener hostname
- cross-namespace routes are blocked by `allowedRoutes`
- Gateway API CRDs are missing or too old for the rendered resources

TLS fails:

- the listener references a secret that does not exist in `eduide-system`
- the certificate does not cover the concrete or wildcard hostname
- cert-manager Gateway API support is not enabled for HTTP-01 challenges

The load balancer has no address:

- Envoy Gateway is installed but the cluster has no load balancer implementation
- MetalLB address pools or fixed IP annotations do not match the cluster
- cloud-provider load balancer annotations are missing or invalid

The Theia Cloud chart renders a duplicate Gateway:

- tenant values forgot `theia-cloud.gateway.create=false`
- the release still carries legacy namespace-local Gateway or certificate values

## References

- [`charts/theia-shared-gateway/README.md`](https://github.com/EduIDE/EduIDE-deployment/blob/main/charts/theia-shared-gateway/README.md)
- [`charts/eduide-cluster/templates/gateway/`](https://github.com/EduIDE/EduIDE-Helm/tree/main/charts/eduide-cluster/templates/gateway) in EduIDE-Helm
- [`.github/workflows/bootstrap-cluster.yml`](https://github.com/EduIDE/EduIDE-deployment/blob/main/.github/workflows/bootstrap-cluster.yml)
- [`docs/environments.md`](https://github.com/EduIDE/EduIDE-deployment/blob/main/docs/environments.md)
- [`charts/theia-cloud/values.yaml`](https://github.com/EduIDE/EduIDE-Helm/blob/main/charts/theia-cloud/values.yaml)
