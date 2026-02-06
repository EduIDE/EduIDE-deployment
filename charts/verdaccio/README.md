# Verdaccio Helm Chart

Private npm registry cache for Theia IDE builds running in Kubernetes.

## Overview

This chart deploys [Verdaccio](https://verdaccio.org/) - a lightweight private npm proxy registry that caches packages from npmjs.org. It's used to:

- Speed up npm installs in CI/CD pipelines by caching packages locally
- Reduce external network dependencies during builds
- Provide a consistent package source for all builds in the cluster

## Prerequisites

- Kubernetes 1.19+
- Helm 3.0+
- PersistentVolume support (uses `csi-rbd-sc` by default)

## Installation

```bash
helm install verdaccio ./charts/verdaccio --namespace verdaccio --create-namespace
```

## Configuration

### Key Values

| Parameter | Description | Default |
|-----------|-------------|---------|
| `replicaCount` | Number of replicas | `1` |
| `image.repository` | Verdaccio image repository | `verdaccio/verdaccio` |
| `image.tag` | Verdaccio image tag | `5` |
| `service.type` | Kubernetes service type | `ClusterIP` |
| `service.port` | Service port | `4873` |
| `storage.enabled` | Enable persistent storage | `true` |
| `storage.size` | PVC size | `50Gi` |
| `storage.storageClass` | Storage class name | `csi-rbd-sc` |
| `storage.uid` | User ID for Verdaccio process | `10001` |
| `storage.gid` | Group ID for Verdaccio process | `65533` |

### Storage Configuration

The chart includes a **critical init container** that fixes permissions on the storage directory. This is required because:

1. Verdaccio runs as a non-root user (uid `10001`, gid `65533` by default)
2. Persistent volumes may be created with root ownership
3. Without proper permissions, Verdaccio cannot write cached packages → `500 Internal Server Error`

The init container runs as root and executes:
```bash
chown -R 10001:65533 /verdaccio/storage
chmod -R 755 /verdaccio/storage
```

**This init container is NOT optional** - without it, Verdaccio will fail to cache packages.

## Usage in CI/CD

Configure npm/yarn to use Verdaccio as the registry:

### npm
```bash
npm config set registry http://verdaccio.verdaccio.svc.cluster.local:4873
```

### yarn
```bash
yarn config set registry http://verdaccio.verdaccio.svc.cluster.local:4873
```

### Dockerfile
```dockerfile
RUN npm config set registry http://verdaccio.verdaccio.svc.cluster.local:4873 && \
    yarn install --frozen-lockfile
```

## Troubleshooting

### "500 Internal Server Error" during npm install

**Cause**: Verdaccio cannot write to `/verdaccio/storage` due to permission issues.

**Solution**: 
1. Check pod logs: `kubectl logs -n verdaccio deployment/verdaccio`
2. Verify init container ran: `kubectl describe pod -n verdaccio <pod-name>`
3. Check storage permissions inside pod:
   ```bash
   kubectl exec -n verdaccio deployment/verdaccio -- ls -ld /verdaccio/storage
   # Should show: drwxr-xr-x verdaccio nogroup
   ```

### Packages not being cached

**Cause**: Verdaccio might not be running or configuration issue.

**Solution**:
1. Check if Verdaccio is healthy: `kubectl get pods -n verdaccio`
2. Test direct access: `curl http://verdaccio.verdaccio.svc.cluster.local:4873/-/ping`
3. Review configuration: `kubectl get configmap -n verdaccio verdaccio-config -o yaml`

## Upgrading

```bash
helm upgrade verdaccio ./charts/verdaccio --namespace verdaccio
```

Note: Uses `Recreate` strategy to avoid multiple instances writing to the same PVC.

## Uninstalling

```bash
helm uninstall verdaccio --namespace verdaccio
```

**Warning**: This will NOT delete the PVC. To also delete the PVC:
```bash
kubectl delete pvc -n verdaccio verdaccio-storage
```

## Architecture

```
┌─────────────────┐
│  CI/CD Pipeline │
│  (npm install)  │
└────────┬────────┘
         │
         │ http://verdaccio:4873
         │
┌────────▼────────────────────────┐
│      Verdaccio Service          │
│  (ClusterIP, Port 4873)         │
└────────┬────────────────────────┘
         │
┌────────▼────────────────────────┐
│     Verdaccio Deployment        │
│  ┌──────────────────────────┐   │
│  │  Init Container          │   │
│  │  (fix permissions)       │   │
│  └──────────────────────────┘   │
│  ┌──────────────────────────┐   │
│  │  Verdaccio Container     │   │
│  │  (uid:10001, gid:65533)  │   │
│  └──────────────────────────┘   │
└────────┬────────────────────────┘
         │
┌────────▼────────────────────────┐
│   PersistentVolumeClaim         │
│   (50Gi, csi-rbd-sc)            │
│   /verdaccio/storage            │
│   (owned by 10001:65533)        │
└─────────────────────────────────┘
         │
         │ proxy cache
         │
┌────────▼────────────────────────┐
│   npmjs.org                     │
│   (upstream registry)           │
└─────────────────────────────────┘
```

## Development

### Validating Chart Changes

```bash
# Lint the chart
helm lint ./charts/verdaccio

# Render templates (dry-run)
helm template verdaccio ./charts/verdaccio --namespace verdaccio

# Test installation (dry-run)
helm install verdaccio ./charts/verdaccio --namespace verdaccio --dry-run
```

## References

- [Verdaccio Official Documentation](https://verdaccio.org/docs/what-is-verdaccio)
- [Verdaccio Docker Hub](https://hub.docker.com/r/verdaccio/verdaccio)
- [Verdaccio GitHub](https://github.com/verdaccio/verdaccio)
