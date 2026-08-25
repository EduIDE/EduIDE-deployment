# Monitoring Setup

This guide explains how to set up monitoring and observability for Theia Cloud deployments using Prometheus and Grafana.

## Overview

Monitoring is essential for understanding system health, resource usage, and performance. This setup is based on the [Theia Cloud Observability](https://github.com/eclipsesource/theia-cloud-observability) project and includes:

- **Prometheus**: Metrics collection and storage
- **Grafana**: Visualization dashboards
- **Theia-specific dashboards**: Custom dashboards for Theia Cloud metrics
- **Kubernetes metrics**: Cluster and pod-level monitoring

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Theia Cloud Deployment                  │
│                                                             │
│  ┌─────────────────┐  ┌─────────────────┐                  │
│  │  Theia Pods     │  │ Operator Pods   │                  │
│  │  (Metrics)      │  │  (Metrics)      │                  │
│  └────────┬────────┘  └────────┬────────┘                  │
│           │                    │                            │
└───────────┼────────────────────┼────────────────────────────┘
            │                    │
            │    (scrape)        │
            ▼                    ▼
  ┌─────────────────────────────────────┐
  │         Prometheus Server            │
  │  (Collects and Stores Metrics)      │
  └──────────────┬──────────────────────┘
                 │
                 │ (query)
                 ▼
  ┌─────────────────────────────────────┐
  │           Grafana                    │
  │  (Visualizes Metrics in Dashboards) │
  └─────────────────────────────────────┘
```

## Prerequisites

- Kubernetes cluster with Theia Cloud deployed
- kubectl configured for your cluster
- Helm 3.x installed
- Admin access to the cluster

## Step 1: TBA

> **Note:** this guide is unfinished. No workflow in this repository installs
> kube-prometheus-stack, so the Prometheus/Grafana stack was installed manually
> and out-of-band. The values used are preserved at
> [`reference/kube-prometheus-stack-values.yaml`](reference/kube-prometheus-stack-values.yaml)
> as the only surviving record of that install. They are not applied by any
> automation and may have drifted from what is running.
>
> Only the `theia-monitoring` chart (PodMonitors and Grafana dashboard
> ConfigMaps) is installed automatically, by `.github/workflows/deploy-theia.yml`.
