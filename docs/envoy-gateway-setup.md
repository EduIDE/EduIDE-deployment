# Envoy Gateway

How EduIDE's traffic reaches a session, and the parts of the Gateway layer that
have to be set up per cluster.

For the full cluster preparation sequence see
[cluster-setup.md](cluster-setup.md); this page is the Gateway detail behind
step 2 of it.

## The traffic path

1. DNS points the EduIDE hostnames at Envoy Gateway's load balancer address.
2. Envoy Gateway watches Gateway API resources and programs Envoy.
3. `Bootstrap cluster` creates one shared `Gateway` in `eduide-system`, with
   four listeners per environment.
4. Each `Deploy` creates `HTTPRoute` resources in that environment's namespace,
   attaching to the shared Gateway by `sectionName`.
5. The operator edits the instances `HTTPRoute` at runtime as sessions start and
   stop.

One Gateway per cluster rather than one per environment, because a Gateway is
cluster-scoped in everything but name: it owns an address, a certificate set and
a data plane.

## Listeners are derived, not written

Four listeners per environment, named after the `sectionName`s that environment
declares in its own values:

```yaml
gateway:
  create: false
  parentRefs:
    - { name: theia-shared-gateway, namespace: eduide-system, sectionName: test1-landing }
    - { name: theia-shared-gateway, namespace: eduide-system, sectionName: test1-service }
    - { name: theia-shared-gateway, namespace: eduide-system, sectionName: test1-instances }
    - { name: theia-shared-gateway, namespace: eduide-system, sectionName: test1-webview }
```

`Bootstrap cluster` reads those, maps each to a hostname and to the TLS secret
its role uses on this cluster, and renders the listener. A listener therefore
cannot disagree with the route that attaches to it, and adding an environment
never means editing a second file.

The prefix is not the landing host. Production's landing host is `eduide` and
its sections are `prod-*`; the `e2e.` one's are `e2e-*`. CI rejects two environments
on one cluster sharing a prefix.

`create: false` matters. With `create: true` the tenant chart renders a Gateway
of its own and you get two.

## The load balancer address

Envoy Gateway assigns the data plane address, and it is the single most common
way to get a cluster that looks healthy and serves nothing.

If the GatewayClass is configured with `mergeGateways: true`, **every** Gateway
using that class shares one Envoy deployment and one external address. On
`tum-student` today:

```
GatewayClass envoy
  -> EnvoyProxy envoy-gateway-system/artemis-envoy-proxy
       mergeGateways: true
       metallb.universe.tf/address-pool: lb2   ->  131.159.88.15
```

while `*.eduide.student.k8s.aet.cit.tum.de` resolves to `131.159.88.14`
(pool `lb3`). A Gateway created there with `gatewayClassName: envoy` is
`Programmed=True` on the wrong address.

Either point DNS at the merged address, or give EduIDE its own GatewayClass and
`EnvoyProxy` pinned to the right pool. The chart can create both:

```yaml
gatewayClass:
  create: true
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
  parametersRef:
    group: gateway.envoyproxy.io
    kind: EnvoyProxy
    name: eduide-envoy-proxy
    namespace: envoy-gateway-system
envoyProxy:
  create: true
  name: eduide-envoy-proxy
  namespace: envoy-gateway-system
  spec:
    provider:
      type: Kubernetes
      kubernetes:
        envoyService:
          annotations:
            metallb.universe.tf/address-pool: lb3
          externalTrafficPolicy: Local
          type: LoadBalancer
```

**`bootstrap-cluster.yml` does not pass either block.** Until it does, create
them by hand or add the values to the workflow. `spec.loadBalancerIP` in
`clusters/tum-production.yaml` records the intended address but is read by
nothing.

### MetalLB

Both TUM clusters use MetalLB, and on both every pool has `autoAssign: true`.
Without an explicit pool annotation a new LoadBalancer service can pick up any
free address, so the pool must be pinned rather than left to chance.

`tum-student`:

| Pool | Address | DNS |
|---|---|---|
| `lb0` | `131.159.88.51` | |
| `lb1` | `131.159.88.50` | |
| `lb2` | `131.159.88.15` | Artemis, current merged Envoy |
| `lb3` | `131.159.88.14` | `k8s-stud-lb3`, where EduIDE's names point |

The production cluster uses pool `ingress` at `131.159.88.82`
(`k8s-theia-lb1.aet.cit.tum.de`), with a second pool `general` at
`131.159.88.81` that is not Envoy's. Pin the pool explicitly there for the same
reason.

Checks:

```bash
kubectl get ipaddresspools.metallb.io -A
kubectl get envoyproxies.gateway.envoyproxy.io -A \
  -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,MERGE:.spec.mergeGateways
kubectl get svc -n envoy-gateway-system -o wide
kubectl -n eduide-system get gateway theia-shared-gateway \
  -o jsonpath='{.status.addresses[*].value}{"\n"}'
dig +short eduide.student.k8s.aet.cit.tum.de A
```

The Gateway's address and the DNS answer must be the same. A service's
`clusterIP` is internal and never what DNS should point at.

## TLS

Each listener terminates with a Secret named per cluster in
`clusters/<name>.yaml`:

```yaml
tls:
  landing: shared-theia-cert
  service: shared-theia-cert
  instances: shared-theia-cert
  webview: static-theia-cert     # always separate
  acmeHttp: true                 # adds a plain :80 listener per non-wildcard host
```

`tum-student` terminates the first three with one shared certificate;
`tum-production` has cert-manager issue one per role. The webview secret is
always its own: those hosts are two labels below the instance host, so no
certificate covering the others covers them.

`acmeHttp: true` adds an HTTP listener on port 80 per non-wildcard host, because
that is where cert-manager's HTTP-01 challenge arrives. Dropping them breaks
nothing until a certificate comes up for renewal.

An HTTPS listener with no secret renders an empty `certificateRefs`. The Gateway
is accepted and simply never programs TLS for that hostname, so the first
symptom is a browser connection failure. The chart fails the render instead, and
`test-deploy-logic.sh` checks the policy is complete before it gets that far.

## Common failure modes

**A route does not attach.** The `sectionName` names no listener, or the
listener's hostname does not match the route's. `NoMatchingListenerHostname` on
three of four `parentRefs` is normal: each route lists all four sections and
matches its own.

```bash
kubectl -n <ns> describe httproute landing-route
```

**TLS fails.** The Secret does not exist in `eduide-system`, or the certificate
does not cover the hostname. Gateway API never compares the two, so the listener
reports healthy either way:

```bash
h=test1.eduide.student.k8s.aet.cit.tum.de
echo | openssl s_client -connect "$h:443" -servername "$h" 2>/dev/null \
  | openssl x509 -noout -checkhost "$h"
```

Never `curl -k` here. It hides precisely this.

**The Gateway has no address.** No load balancer implementation, or MetalLB
annotations that do not match a pool.

**Two Gateways.** A tenant left `gateway.create: true`.

**Certificates never issue.** The `ClusterIssuer` the derived certificates
reference cannot solve over Gateway API. See step 3 of
[cluster-setup.md](cluster-setup.md).

## References

- [`charts/eduide-cluster/templates/gateway/`](https://github.com/EduIDE/EduIDE-Helm/tree/main/charts/eduide-cluster/templates/gateway)
- [`charts/eduide-cluster/values-example.yaml`](https://github.com/EduIDE/EduIDE-Helm/blob/main/charts/eduide-cluster/values-example.yaml)
- [`.github/workflows/bootstrap-cluster.yml`](https://github.com/EduIDE/EduIDE-deployment/blob/main/.github/workflows/bootstrap-cluster.yml)
- [Envoy Gateway Helm installation](https://gateway.envoyproxy.io/docs/install/install-helm/)
- [cert-manager Gateway API HTTP-01 solver](https://cert-manager.io/docs/configuration/acme/http01/)
