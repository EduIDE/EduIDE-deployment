# Theia Deployment

This repository manages automated deployments of [Theia Cloud](https://github.com/eclipse-theia/theia-cloud) to Kubernetes clusters using GitHub Actions. Theia Cloud provides browser-based development environments, allowing students and developers to work in containerized IDEs without local setup.

## What is This Repository?

This repository serves as the infrastructure-as-code for deploying and managing Theia Cloud instances across multiple environments (production, staging, and testing). It provides:

- **Automated CI/CD pipelines** for deploying Theia Cloud via GitHub Actions
- **Environment-specific configurations** for production, staging, and test environments
- **Custom Helm charts** for AppDefinitions, certificates, metrics, and combined deployments
- **GitOps workflow** for managing deployments with approval gates and automated rollouts

## Repository Structure

```
.
├── .github/workflows/       # GitHub Actions workflows for automated deployment
│   ├── deploy-theia.yml    # Reusable core deployment workflow
│   ├── deploy-pr.yml       # PR-triggered test deployments
│   ├── deploy-staging.yml  # Auto-deploy to staging on main push
│   └── deploy-production.yml # Manual production deployments
│
├── deployments/            # Environment-specific Helm values
│   ├── theia.artemis.cit.tum.de/              # Production config
│   ├── theia-staging.artemis.cit.tum.de/      # Staging config
│   └── test1.theia-test.artemis.cit.tum.de/   # Test environment config
│
├── charts/                 # Custom Helm charts
│   ├── theia-cloud-combined/    # Combined chart with all components
│   ├── theia-shared-gateway/    # Shared Gateway API entrypoint
│   ├── theia-internal-tls/      # Cluster-scoped internal CA + trust bundle
│   ├── theia-appdefinitions/    # Custom IDE environments (images/configs)
│   ├── theia-certificates/      # SSL certificate management (per-namespace)
│   └── theia-metrics/           # Prometheus/Grafana dashboards
│
├── value-reference-files/  # Reference Helm values for different setups
│
└── docs/                   # Detailed documentation
    ├── deployment-workflows.md  # How deployments work
    ├── adding-environments.md   # Adding new environments
    ├── keycloak-setup.md        # Authentication configuration
    ├── tum-certificates.md      # TUM-specific SSL certificate process
    └── monitoring-setup.md      # Prometheus & Grafana setup
```

## Deployment Architecture

```
┌───────────────────────────────────────────────────────────────┐
│                      GitHub Actions Workflows                 │
├───────────────────────────────────────────────────────────────┤
│                                                               │
│  ┌─────────────┐    ┌──────────────┐    ┌─────────────────┐   │
│  │   PR Push   │    │ Push to main │    │ Manual Trigger  │   │
│  │             │    │              │    │  (GitHub UI)    │   │
│  └──────┬──────┘    └──────┬───────┘    └────────┬────────┘   │
│         │                  │                     │            │
│         ▼                  ▼                     ▼            │
│  ┌─────────────┐    ┌──────────────┐    ┌─────────────────┐   │
│  │deploy-pr.yml│    │deploy-staging│    │deploy-production│   │
│  │             │    │    .yml      │    │     .yml        │   │
│  └──────┬──────┘    └──────┬───────┘    └────────┬────────┘   │
│         │                  │                     │            │
│         └──────────────────┴─────────────────────┘            │
│                            │                                  │
│                            ▼                                  │
│                  ┌──────────────────┐                         │
│                  │  deploy-theia.yml│                         │
│                  │ (Reusable Core)  │                         │
│                  └────────┬─────────┘                         │
│                           │                                   │
└───────────────────────────┼───────────────────────────────────┘
                            │
            ┌───────────────┴───────────────┐
            │                               │
            ▼                               ▼
┌───────────────────────────┐   ┌───────────────────────────┐
│   Production Cluster      │   │  Staging/Test Cluster     │
│   (Separate Kubeconfig)   │   │  (Shared Kubeconfig)      │
├───────────────────────────┤   ├───────────────────────────┤
│                           │   │                           │
│  ┌─────────────────────┐  │   │  ┌─────────────────────┐  │
│  │  theia-prod         │  │   │  │  theia-staging      │  │
│  │  Manual Deploy      │  │   │  │  Auto on main       │  │
│  │  (Approval Req.)    │  │   │  │  (No Approval)      │  │
│  └─────────────────────┘  │   │  └─────────────────────┘  │
│                           │   │                           │
└───────────────────────────┘   │  ┌─────────────────────┐  │
                                │  │  theia-test1        │  │
                                │  │  Auto on PR         │  │
                                │  │  (Approval Req.)    │  │
                                │  └─────────────────────┘  │
                                │                           │
                                └───────────────────────────┘
```

**Deployment Triggers:**
- **theia-prod**: Manual via GitHub UI with approval required
- **theia-staging**: Automatic on push to `main` branch (no approval)
- **test1**: Automatic on PR push with approval gate (configurable)

## Environments

| Environment | Namespace | Domain | Deployment Trigger | Approval Required |
|------------|-----------|--------|-------------------|-------------------|
| **Production** | `theia-prod` | `theia.artemis.cit.tum.de` | Manual (GitHub UI) | Yes |
| **Staging** | `theia-staging` | `theia-staging.artemis.cit.tum.de` | Push to `main` | No |
| **Test1** | `test1` | `test1.theia-test.artemis.cit.tum.de` | PR push | Yes (configurable) |

Configuration files for each environment are located in the [deployments/](deployments/) directory.

## Quick Start

### Prerequisites

- Kubernetes cluster with Envoy Gateway (Gateway API) installed
- cert-manager installed and a ClusterIssuer available for certificate issuance
- Helm 3.x installed
- kubectl configured for your cluster
- GitHub repository with appropriate secrets configured

### Basic Installation

1. **Prepare your cluster** (install Envoy Gateway and Gateway API CRDs):
   ```bash
   # Install Envoy Gateway and Gateway API CRDs according to your cluster provider.
   # Ensure the GatewayClass name matches `theia-cloud.gateway.className` (default: "envoy").
   ```

2. **Install Theia Cloud base charts**:
   ```bash
   helm registry login ghcr.io

   helm upgrade theia-cloud-base oci://ghcr.io/eduide/charts/theia-cloud-base --version 1.2.0-next.0 --install \
     -f deployments/your-environment/theia-base-helm-values.yml

   helm upgrade theia-cloud-crds oci://ghcr.io/eduide/charts/theia-cloud-crds --version 1.2.0-next.0 --install \
     -f deployments/your-environment/theia-crds-helm-values.yml
   ```

3. **Install the shared Gateway chart (once per cluster)**:
   ```bash
   helm upgrade --install theia-shared-gateway ./charts/theia-shared-gateway \
     --namespace gateway-system --create-namespace \
     -f deployments/shared-gateway/values.yaml
   ```
   For the dedicated production cluster, use:
   `deployments/shared-gateway-prod/values.yaml`.

4. **Install the internal TLS infrastructure (once per cluster)**:
   ```bash
   helm upgrade --install theia-internal-tls ./charts/theia-internal-tls \
     --namespace cert-manager
   ```
   This deploys the cluster-scoped internal CA and trust bundle used for TLS
   between internal services (e.g., shared cache and workspaces). The trust
   bundle ConfigMap is automatically distributed to all namespaces.

5. **Install the combined Theia Cloud chart**:
   ```bash
   helm registry login ghcr.io
   helm upgrade --install theia-cloud-combined ./charts/theia-cloud-combined \
     --namespace your-namespace --create-namespace \
     -f deployments/your-environment/values.yaml
   ```

Normal deployments consume released OCI charts from `ghcr.io/eduide/charts`.
The `theia-cloud` dependency version in `charts/theia-cloud-combined/Chart.yaml` controls the main application chart, while `theia-cloud-base` and `theia-cloud-crds` are pinned separately in the workflow at `1.2.0-next.0` and `1.4.0-next.0`.
For PR previews, you can set `helm_chart_tag` to a value like `pr-123` to pull preview OCI charts published from `theia-cloud-helm` pull requests as versions such as `<chart-version>.pr-123`.

When using GitHub Actions, shared-gateway settings are passed as hardcoded inputs
by the caller workflows (`deploy-pr.yml`, `deploy-staging.yml`, `deploy-production.yml`):
- `deploy_shared_gateway` (`true`/`false`)
- `shared_gateway_values_file` (e.g. `deployments/shared-gateway/values.yaml`)
- `shared_gateway_namespace` (optional, defaults to `gateway-system`)

### Using GitHub Actions for Deployment

The recommended approach is to use the automated GitHub Actions workflows:

1. **Configure GitHub Environment** with required secrets and variables (see [Adding Environments](docs/adding-environments.md))
2. **Push to main** to deploy to staging automatically
3. **Create a PR** to deploy to test environment with approval
4. **Manually trigger production** deployment from GitHub Actions UI

See [Deployment Workflows](docs/deployment-workflows.md) for detailed instructions.

### Updating pinned release tags

Staging and production intentionally pin several images to SHA-suffixed tags such as `latest-dfe0d09`, `latest-2c6f8ac`, and `latest-0c8eec9`.

When a new release is published, you must update the short SHA suffix in the environment values files instead of relying on plain `latest`. In practice this means bumping:

- `theia-cloud.operator.image`
- `theia-cloud.service.image`
- `theia-cloud.preloading.images`
- `theia-cloud.landingPage.image`
- `theia-appdefinitions.defaultImageTag`
- `conversion.image` in `theia-crds-helm-values.yml`

The landing page can use a different SHA suffix from the IDE images, so keep `theia-cloud.landingPage.image` and `theia-cloud.preloading.images[0]` aligned with each other, and keep the IDE preload/appdefinition tags aligned separately.

See [Deployment Workflows](docs/deployment-workflows.md#release-process-for-pinned-image-tags) for the full release checklist.

## Common Tasks

- **Deploy a PR to test environment**: See [Deployment Workflows](docs/deployment-workflows.md#pull-request-deployments)
- **Bump release image tags**: See [Deployment Workflows](docs/deployment-workflows.md#release-process-for-pinned-image-tags)
- **Add a new environment**: See [Adding Environments](docs/adding-environments.md)
- **Configure Keycloak authentication**: See [Keycloak Setup](docs/keycloak-setup.md)
- **Request TUM wildcard certificates**: See [TUM Certificates](docs/tum-certificates.md)
- **Set up monitoring**: See [Monitoring Setup](docs/monitoring-setup.md)

## AppDefinitions

*AppDefinitions* define the IDE environments that users work in. Custom AppDefinitions are built in a three-stage pipeline at [artemis-theia-blueprints](https://github.com/ls1intum/artemis-theia-blueprints).

To install or update AppDefinitions:

```bash
helm dependency update ./charts/theia-cloud-combined
helm upgrade --install theia-cloud-combined ./charts/theia-cloud-combined \
  --namespace your-namespace --create-namespace \
  -f deployments/your-environment/values.yaml
```

The AppDefinitions chart configuration is documented in [charts/theia-appdefinitions/templates/appdefinition.yaml](charts/theia-appdefinitions/templates/appdefinition.yaml).

### Scaling API and Helm behavior

- Runtime scaling values are managed through Theia Cloud admin API endpoints:
  - `GET /service/admin/appdefinition`
  - `GET /service/admin/appdefinition/{appDefinitionName}`
  - `PATCH /service/admin/appdefinition/{appDefinitionName}`
- Access requires the `X-Admin-Api-Token` header with the token from `theia.cloud.admin.api.token`.
- The `theia-appdefinitions` chart always uses Helm `lookup` to preserve live `spec.minInstances` and `spec.maxInstances` from existing `AppDefinition` resources during upgrades.
- Values from Helm values files are only used when an `AppDefinition` does not exist yet.

## Documentation

Detailed documentation is available in the [docs/](docs/) directory:

- [Deployment Workflows](docs/deployment-workflows.md) - How automated deployments work
- [Adding Environments](docs/adding-environments.md) - Step-by-step guide to add new environments
- [Keycloak Setup](docs/keycloak-setup.md) - Authentication and authorization configuration
- [TUM Certificates](docs/tum-certificates.md) - TUM-specific SSL certificate process
- [Monitoring Setup](docs/monitoring-setup.md) - Prometheus and Grafana installation

## Related Projects

- [Theia Cloud](https://github.com/eclipse-theia/theia-cloud) - Main Theia Cloud project
- [Theia Cloud Helm Charts](https://github.com/eclipse-theia/theia-cloud-helm) - Official Helm charts
- [Artemis Theia Blueprints](https://github.com/ls1intum/artemis-theia-blueprints) - Custom IDE images and configurations
- [Theia Cloud Observability](https://github.com/eclipsesource/theia-cloud-observability) - Monitoring and observability

## Support

For issues or questions:
- Check the [documentation](docs/)
- Review existing [GitHub Issues](../../issues)
- Consult the [Theia Cloud documentation](https://theia-cloud.io/)
