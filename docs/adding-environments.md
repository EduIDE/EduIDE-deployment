# Adding New Environments

This guide walks you through adding a new environment (e.g., test2, staging2) to the Theia deployment infrastructure.

## Overview

Each environment consists of:
- Deployment configuration files in the `deployments/` directory
- GitHub Environment with secrets and variables
- Workflow configuration in `.github/workflows/deploy-pr.yml`

## Step 1: Create Deployment Configuration

### 1.1 Create Directory Structure

Create a new directory in `deployments/` with your environment's domain name:

```bash
mkdir -p deployments/test2.theia-test.artemis.cit.tum.de
```

### 1.2 Copy Existing Configuration

Copy the values files from an existing environment:

```bash
cp -r deployments/test1.theia-test.artemis.cit.tum.de/* deployments/test2.theia-test.artemis.cit.tum.de/
```

### 1.3 Update Configuration Files

#### Update `values.yaml`

The `values.yaml` file contains environment-specific settings. The most important section is the `hosts` configuration.

**For test environments**, use the `theia-test.artemis.cit.tum.de` base domain structure:

```yaml
hosts:
  configuration:
    &hostsConfig
    baseHost: theia-test.artemis.cit.tum.de  # Shared base for all test envs
    service: service.test2                    # test2, test3, etc.
    landing: test2
    instance: instance.test2
```

**For staging environments**, use the main `artemis.cit.tum.de` base domain:

```yaml
hosts:
  configuration:
    &hostsConfig
    baseHost: artemis.cit.tum.de
    service: service.theia-staging2  # or theia-staging3, etc.
    landing: theia-staging2
    instance: instance.theia-staging2
```

**Also update these fields:**

- `theia-cloud.app.name` - Change to reflect the new environment (e.g., "Artemis Online IDE (Test2)")
- `landingPage.infoTitle` - Update the environment name in the title
- `theia-cloud.gateway.parentRefs` - Keep this pointing to the shared gateway (`theia-shared-gateway` in `gateway-system`)

For shared-gateway deployments, tenant namespaces should not create their own gateway:

```yaml
theia-cloud:
  gateway:
    enabled: true
    create: false
    routes:
      enabled: true
    parentRefs:
      - name: theia-shared-gateway
        namespace: gateway-system
```

Also update the shared Gateway listeners in `deployments/shared-gateway/values.yaml` (or `deployments/shared-gateway-prod/values.yaml` for production clusters).  
For each new environment, add listener hostnames for landing, service, instances, and `*.webview.instance...`; otherwise Gateway API routes will not attach for that hostname.

#### Update `theia-base-helm-values.yml`

Usually only requires updating the issuer email if needed:

```yaml
issuer:
  email: your-email@example.com
```

#### `theia-crds-helm-values.yml`

Typically no changes needed for this file.

## Step 2: Create GitHub Environment

### 2.1 Create the Environment

1. Go to your repository **Settings > Environments**
2. Click **New environment**
3. Enter the environment name (e.g., `test2`)

### 2.2 Configure Protection Rules (Optional)

Configure **Environment protection rules** if needed:
- Add required reviewers for approval gates
- Set deployment branch rules (e.g., only allow deployments from `main` or specific branches)
- Set deployment wait timer if needed

**Recommended Settings:**

| Environment Type | Protection Rules |
|-----------------|------------------|
| Production | Required reviewers (2+), limited to `main` branch |
| Staging | No approval required, auto-deploy on `main` |
| Test | Required reviewer (1), allow all branches |

## Step 3: Configure Environment Variables and Secrets

### 3.1 Add Environment Variables

Navigate to **Settings > Environments > [your-environment]** and add these variables:

| Variable Name | Description | Example Value |
|---------------|-------------|---------------|
| `NAMESPACE` | Target Kubernetes namespace | `theia-test2` |
| `HELM_VALUES_PATH` | Path to Helm values directory | `deployments/test2.theia-test.artemis.cit.tum.de` |

**Steps:**
1. Under **Environment variables**, click **Add variable**
2. Enter the **Name** (exactly as shown)
3. Enter the **Value**
4. Click **Add variable**

### 3.2 Add Secrets

Add the following secrets to your environment:

| Secret Name | Description | How to Obtain |
|-------------|-------------|---------------|
| `KUBECONFIG` | Kubernetes cluster configuration | Get from cluster admin. For test/staging, use the same kubeconfig as other test environments. For production, use a separate kubeconfig. |
| `THEIA_WILDCARD_CERTIFICATE_CERT` | Wildcard SSL certificate  | See [TUM Certificates](tum-certificates.md) |
| `THEIA_WILDCARD_CERTIFICATE_KEY` | Wildcard SSL key | See [TUM Certificates](tum-certificates.md) |
| `THEIA_KEYCLOAK_COOKIE_SECRET` | OAuth2 proxy cookie secret | See below |

Create the `THEIA_KEYCLOAK_COOKIE_SECRET` using the following command:
```bash
dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64 | tr -d -- '\n' | tr -- '+/' '-_' ; echo
```

**Steps:**
1. Navigate to **Settings > Environments > [your-environment]**
2. Under **Environment secrets**, click **Add secret**
3. Enter the **Name** and **Value**
4. Click **Add secret**

### 3.3 Important Notes

- **Certificate wildcards**: Ensure your certificate covers the correct wildcard domain (e.g., `*.webview.instance.test2.theia-test.artemis.cit.tum.de`)
- **Keycloak setup**: You may need to create a new Keycloak client or reuse an existing one. See [Keycloak Setup](keycloak-setup.md)
- **Namespace isolation**: Each environment uses its own Kubernetes namespace, but test/staging environments typically share the same cluster
- **Shared gateway values path**: For dedicated clusters (e.g. production), use a cluster-specific shared gateway values file, e.g. `deployments/shared-gateway-prod/values.yaml`
- **Shared gateway workflow inputs**: Configure `deploy_shared_gateway`, `shared_gateway_values_file`, and `shared_gateway_namespace` in the caller workflows.

## Step 4: Update Workflow Configuration

### 4.1 Add to PR Deployment Workflow

Edit [.github/workflows/deploy-pr.yml](../.github/workflows/deploy-pr.yml):

1. Add the environment to the `options` list:

```yaml
workflow_dispatch:
  inputs:
    environment:
      description: 'Target Environment'
      required: true
      type: choice
      options:
        - test1
        - test2  # Add your new environment
```

2. Add a new job for the environment:

```yaml
deploy-test2:
  if: github.event_name == 'pull_request' || (github.event_name == 'workflow_dispatch' && inputs.environment == 'test2')
  name: Deploy to Test2
  uses: ./.github/workflows/deploy-theia.yml
  with:
    environment: test2
    theia_cloud_tag: ${{ inputs.theia_cloud_tag || 'latest' }}
    ide_images_tag: ${{ inputs.ide_images_tag || 'latest' }}
    helm_chart_branch: ${{ inputs.helm_chart_branch || '' }}
    deploy_shared_gateway: true
    shared_gateway_values_file: deployments/shared-gateway/values.yaml
    shared_gateway_namespace: gateway-system
  secrets: inherit
```

**Note**: The job automatically reads `NAMESPACE` and `HELM_VALUES_PATH` from the GitHub Environment variables you configured in Step 3.

### 4.2 For Staging Environments (Optional)

If you want automatic deployments on `main` branch push, create a new workflow file or modify [.github/workflows/deploy-staging.yml](../.github/workflows/deploy-staging.yml):

```yaml
name: Deploy Staging2

on:
  push:
    branches:
      - main

jobs:
  deploy-staging2:
    name: Deploy to Staging2
    uses: ./.github/workflows/deploy-theia.yml
    with:
      environment: staging2
    secrets: inherit
```
