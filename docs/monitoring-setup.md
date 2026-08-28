# Monitoring and alerting

What EduIDE measures, what it alerts on, and how to point those alerts at a
chat channel.

## What is installed, and by whom

| | Who installs it |
|---|---|
| Prometheus, Alertmanager, Grafana | **not this repository**. On the TUM clusters this is Rancher's monitoring stack, installed out of band |
| PodMonitor for the REST service | `Bootstrap cluster`, from the `eduide-cluster` chart |
| ServiceMonitor for cert-manager | same, when the cluster sets `spec.monitorCertManager` |
| Four Grafana dashboards | same |
| PrometheusRule and AlertmanagerConfig | same, when the cluster sets `spec.alerting.enabled` |

The values used for the manual kube-prometheus-stack install are preserved at
[`reference/kube-prometheus-stack-values.yaml`](reference/kube-prometheus-stack-values.yaml)
as the only record of it. Nothing applies them and they may have drifted.

## Where the numbers come from

**Session pods export no metrics.** This is the single most important thing on
this page, because assuming otherwise produced a PodMonitor that scraped every
session pod for a year and never collected one sample: session pods are Theia
IDEs, they serve HTML on that port, and Prometheus rejected every response with
`unsupported Content-Type "text/html"`. That PodMonitor is gone. Everything
about sessions is observed from outside them:

| Source | What it gives us |
|---|---|
| cAdvisor | per-container CPU, memory, throttling, network |
| kubelet | workspace volume bytes and inodes |
| kube-state-metrics | pod phase, restarts, termination reason and exit code, deployment availability, PVC phase |
| the REST service, at `/q/metrics` | session startup latency, JVM health |
| cert-manager | certificate expiry and readiness |

Only one custom metric exists: `application_application_theiacloud_session_startup_seconds_*`.
It is **registered lazily**, on the first session the service serves. After a
restart it does not exist until somebody starts a session, so an empty startup
panel on a freshly deployed environment is expected rather than broken.

## The dashboards

| Dashboard | uid | For |
|---|---|---|
| EduIDE Sessions | `eduide-sessions` | who is using it, how well it serves them, what it costs |
| EduIDE Session Detail | `eduide-session-detail` | one session: is it about to be OOM-killed, why did it stop |
| Theia Cloud | `bdrjgy1fv3d34b` | the original overview |
| Session Startup Time | `bf4ha4miogutcc` | startup latency quantiles |

The environment picker on every dashboard is a query over the namespaces the
cluster actually monitors, derived from the environments. It used to be a
hand-written list, which went stale the moment the environments were renamed:
it still offered `theia`, `theia-staging` and `test1`, none of which exist, so
every panel was empty whatever you picked.

## The alerts

Off by default. Switch on per cluster:

```yaml
spec:
  alerting:
    enabled: true
    minSeverity: warning
    grafanaUrl: https://rancher.example.tum.de/.../grafana
    channels:
      - name: platform-slack
        type: slack
        secretKey: slack-platform
        channel: "#eduide-alerts"
```

**A channel can be scoped to one installation.** One cluster may host
installations that belong to different people: Bonn and Mannheim share the
`eduide` cluster, and neither wants the other's incidents.

```yaml
    channels:
      - name: mannheim
        type: discord
        secretKey: discord-mannheim
        environments: [eduide-mannheim]
      - name: bonn
        type: discord
        secretKey: discord-bonn
        environments: [eduide-bonn]
```

`environments` lists **namespaces**, not hostnames, and each becomes a sub-route
matched on `eduide_namespace`. First match wins.

**Anything no scoped channel claims goes to every channel.** That is deliberate
and it is the part worth remembering: a certificate expiring or the conversion
webhook failing is cluster-scoped, belongs to no tenant namespace, and would
otherwise be dropped for failing to match a tenant route. Those are the alerts
you least want to lose, so they go to everyone.

A scoped channel pointing at a namespace no environment on that cluster uses
would match nothing and quietly receive only the cluster-scoped alerts, so
`test-deploy-logic.sh` checks every `environments` entry against the
environments actually on the cluster.

**`minSeverity` is what reaches the channels, not what fires.** Everything
fires and is visible in Alertmanager and on the dashboards; the channels get a
filtered subset. This is deliberate and it is the whole reason the split
exists: a channel that receives every capacity blip stops being read, and then
the platform is unmonitored no matter how many rules are defined.

**critical** - a person should look now

| Alert | Meaning |
|---|---|
| `EduIDEComponentDown` | operator, REST service, landing page or garbage collector has no available replica. The description says what each one breaks |
| `EduIDEConversionWebhookDown` | cluster-wide: no CRD read or write succeeds while it is down |
| `EduIDEComponentCrashLooping` | a platform container is restarting repeatedly |
| `EduIDEServiceScrapeDown` | the REST service is unscrapeable. Students may be fine; we are blind |
| `EduIDEWarmPoolEmpty` | every pre-warmed instance is gone, so every student now waits for a cold start |

**warning** - worth knowing today

| Alert | Meaning |
|---|---|
| `EduIDESessionOOMKillSpike` | sessions being killed for memory above a rate threshold |
| `EduIDESessionCrashSpike` | sessions exiting with errors above a rate threshold |
| `EduIDESessionStartupSlow` | p95 startup over the threshold, while sessions are actually starting |
| `EduIDESessionPodPending` | a session cannot be scheduled |
| `EduIDESessionImagePullFailing` | a tag that does not exist, usually a blanket image override |
| `EduIDESessionEvicted` | node ran out of ephemeral disk, typically build caches |
| `EduIDEWorkspaceVolumeFilling` | a workspace is over 85% full by bytes |
| `EduIDEWorkspaceInodesFilling` | over 85% full by inodes, which happens long before bytes do |
| `EduIDEPVCPending` | a workspace volume will not provision |
| `EduIDECertificateExpiringSoon` | under 21 days left and not renewed |
| `EduIDECertificateNotReady` | a certificate has been failing to issue for an hour |

Session-level faults alert on **rates across an environment, never per pod**.
This platform runs student code: sessions get OOM-killed and crash during
normal exercise work, and one notification per event is how a channel becomes
noise. Exit codes 137 and 143 are excluded outright, because those are the
garbage collector stopping an idle session.

Every threshold is a chart value. Tune one in `values.yaml` under
`monitoring.alerting.thresholds` rather than waiting on a rule change.

## Silences: match on `eduide_namespace`, not `namespace`

Every EduIDE alert carries `namespace: eduide-system` regardless of which
environment it is about. **That label is a routing artifact.** The Prometheus
Operator defaults `alertmanagerConfigMatcherStrategy` to `OnNamespace`, which
prepends `namespace = <the AlertmanagerConfig's own namespace>` to every route
it generates, so an alert has to claim that namespace to reach any receiver.

The environment an alert is actually about is in **`eduide_namespace`**.

```bash
# silence maintenance on one environment
amtool silence add eduide_namespace=eduide-test1 --duration=2h --comment="upgrade"
```

Silencing `namespace=eduide-test1` matches nothing. Silencing
`namespace=eduide-system` silences every EduIDE alert on the cluster, which is
almost certainly not what was meant. The same applies to any inhibition rule:
compare `eduide_namespace`, or one environment's outage will suppress warnings
in all the others.

## Adding a channel

Webhook URLs are credentials. They never go in a manifest, a values file or a
`--set`, which would put them in the process list and in Actions debug logs.

1. Create the incoming webhook in Slack or Discord.
2. Put it on the **cluster** GitHub Environment. The secret is named after the
   channel's `secretKey`, uppercased with hyphens as underscores and prefixed
   `ALERT_WEBHOOK_`, so one cluster can hold a different webhook per
   installation:

   | `secretKey` | GitHub Environment secret |
   |---|---|
   | `discord-mannheim` | `ALERT_WEBHOOK_DISCORD_MANNHEIM` |
   | `discord-bonn` | `ALERT_WEBHOOK_DISCORD_BONN` |
   | `slack-platform` | `ALERT_WEBHOOK_SLACK_PLATFORM` |

   ```bash
   REPO=EduIDE/EduIDE-deployment
   gh secret set ALERT_WEBHOOK_DISCORD_MANNHEIM --repo "$REPO" --env cluster-eduide < webhook.txt
   ```

   Pipe from a file or use `--body`; never paste a webhook URL into a shell you
   share, and never into a manifest.

3. Add the channel to `clusters/<name>.yaml`. The `secretKey` prefix decides
   which webhook type it is, so it must be `slack-*` for a Slack channel and
   `discord-*` for a Discord one, and the rest must be a valid Kubernetes Secret
   data key. `test-deploy-logic.sh` and the cluster schema both check this.
4. Re-run `Bootstrap cluster`.

Alerting enabled with no channels fails the render rather than firing into
nowhere, and a channel whose webhook secret is unset fails the bootstrap with a
message naming the key.

Discord is a first-class receiver here, not a Slack-compatible shim:
Alertmanager 0.25 and later support `discord_configs` natively, and the
`AlertmanagerConfig` CRD on these clusters exposes it.

## Checking it works

```bash
# the rules are loaded
kubectl -n eduide-system get prometheusrule eduide-alerts

# Alertmanager picked up the receivers
kubectl -n eduide-system get alertmanagerconfig eduide-alerts -o yaml

# nothing is silently failing to scrape
kubectl -n cattle-monitoring-system port-forward svc/rancher-monitoring-prometheus 9090:9090
# then: http://127.0.0.1:9090/targets, filter for theia-cloud
```

To prove the whole path end to end, scale the garbage collector to zero and
wait five minutes. `EduIDEComponentDown` should fire and arrive in the channel
with a description, a runbook link and, if `grafanaUrl` is set, a dashboard
link. Scale it back and confirm the resolved message.
