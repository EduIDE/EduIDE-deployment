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
> ConfigMaps) is part of the `eduide-cluster` chart and is installed by
> `.github/workflows/bootstrap-cluster.yml`, once per cluster.

## The watched namespaces are derived

The two PodMonitors name every namespace they scrape. That list used to be
written by hand in the chart's values and had gone stale — it still named
`theia` and `theia-staging`, so some environments were scraped and others were
not, silently.

`Bootstrap cluster` now derives it from the environments that claim the
cluster, the same way it derives the Gateway's listeners. Adding an environment
picks up monitoring with no second edit. A PodMonitor rendered with an empty
namespace list fails the template rather than watching nothing.
