# theia-shared-gateway

Central Gateway API entrypoint shared by multiple Theia namespaces.

## Purpose

- Own the cluster edge Gateway in one place.
- Keep tenant releases namespace-local (HTTPRoutes, services, operators).
- Avoid Helm ownership conflicts for a shared Gateway object.

## Usage

```bash
helm upgrade --install theia-shared-gateway ./charts/theia-shared-gateway \
  --namespace gateway-system \
  --create-namespace \
  -f deployments/shared-gateway/values.yaml
```

For production cluster values, use `deployments/shared-gateway-prod/values.yaml`.

## Notes

- The shared gateway chart should own the TLS material referenced by its listeners.
- For production, use cert-manager `Certificate` resources for concrete hosts and create the wildcard webview secret in `gateway.namespace` from the deploy-time wildcard certificate/key.
- Tenant charts should set:
  - `theia-cloud.gateway.create=false`
  - `theia-cloud.gateway.routes.enabled=true`
  - `theia-cloud.gateway.parentRefs` to this shared Gateway.
