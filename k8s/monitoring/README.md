# k8s/monitoring

Plain manifests for the monitoring stack, synced by the `monitoring-config` Application through [`kustomization.yaml`](kustomization.yaml): the namespace, Cilium and Argo CD scrape configs, the lab's own alert rules, and its Grafana dashboards. The chart itself is the `kube-prometheus-stack` Application in [`../apps`](../apps).

## Dashboards

[`dashboards/cyberlab-overview.json`](dashboards/cyberlab-overview.json) is Grafana's home page: cluster, network, and security health on one screen, with links to the detailed dashboards behind each panel. Every count at the top of a section is zero when things are healthy.

Kustomize ships each file as a ConfigMap labelled `grafana_dashboard: "1"`, and Grafana's sidecar loads it within a minute of an Argo CD sync. Dashboards provisioned this way are read-only in the UI: to change one, edit it in Grafana, export the JSON (**Export → Export as JSON**), replace the file here, and push.

## Bootstrap secrets (once per cluster)

Two Secrets are created by hand and never committed. After a rebuild, create them once the `monitoring` namespace exists.

**Grafana admin login.** Until it exists, the Grafana pod waits in `CreateContainerConfigError` and recovers on its own once the Secret is created:

```powershell
$b = New-Object byte[] 24; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
$pw = [Convert]::ToBase64String($b).TrimEnd('=').Replace('+','-').Replace('/','_')
kubectl -n monitoring create secret generic grafana-admin --from-literal=admin-user=admin --from-literal=admin-password=$pw
Remove-Variable pw, b
```

Read it back when you need it:

```powershell
kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | % { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_)) }
```

**Discord webhook for Alertmanager.** In Discord: **Server Settings → Integrations → Webhooks → New Webhook**, pick the channel, and copy the URL. Anyone with the URL can post to that channel, so treat it like a password. Single quotes keep PowerShell from touching any characters in it:

```powershell
kubectl -n monitoring create secret generic alertmanager-discord --from-literal=webhook-url='<webhook URL>'
```

Alertmanager mounts it as a file, so without it the Alertmanager pod can't start. Create it before the first sync.

## Alert routing

Alertmanager's routes are in [`../apps/kube-prometheus-stack.yaml`](../apps/kube-prometheus-stack.yaml). Warning and critical alerts go to Discord, grouped by namespace, with a reminder every 12 hours while they keep firing and a message when they resolve. These are muted (still visible in Alertmanager):

| Alert | Why |
|-------|-----|
| `Watchdog` | Always firing by design: proves the pipeline works |
| `InfoInhibitor`, `severity=info` | Informational, for dashboards |
| `source=falco` | Falco events, until the rules are tuned against a baseline |

### Lab alert rules

kube-prometheus-stack ships about 150 rules for nodes, Kubernetes, etcd, and itself. [`cyberlab-alerts.yaml`](cyberlab-alerts.yaml) adds rules for what it doesn't cover. A component that stops answering is already caught by the chart's `TargetDown`.

| Alert | Fires when |
|-------|------------|
| `ArgoCDAppOutOfSync` | An app hasn't matched `main` for 15 minutes (auto-sync is failing) |
| `ArgoCDAppUnhealthy` | An app's resources have been unhealthy for 15 minutes |
| `ArgoCDSyncFailed` | A sync ended in `Error` or `Failed` |
| `CiliumNodesUnreachable` (critical) | A node can't reach other nodes for 5 minutes |
| `CiliumHealthEndpointsUnreachable` | Pod-network health checks fail for 5 minutes |
| `CiliumPolicyImportFailed` | A NetworkPolicy or host firewall policy failed to apply |
| `CiliumEndpointRegenerationFailing` | Cilium keeps failing to program pods' networking |
| `CiliumControllersFailing` | A Cilium agent's background reconcilers keep erroring |
| `CiliumBPFMapPressure` | A BPF map is over 90% full |
| `CiliumPolicyDropsHigh` | Over 100 policy-denied packets on a node in 10 minutes (the baseline is under 10): something is probing the node, or a rule blocks real traffic |
| `HubbleLostEvents` | Hubble has been dropping flow events for 15 minutes |

Check rule changes before pushing (the Prometheus image has `promtool` but no shell, so the rules go in on stdin):

```powershell
$l = Get-Content k8s/monitoring/cyberlab-alerts.yaml; $i = [array]::IndexOf($l, 'spec:')
($l[($i+1)..($l.Count-1)] | % { if ($_.Length -ge 2) { $_.Substring(2) } else { $_ } }) -join "`n" | kubectl -n monitoring exec -i prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- promtool check rules /dev/stdin
```

### Test alert

To send a test alert to Discord: it arrives about 30 seconds later and resolves on its own after 5 minutes. amtool prints warnings about its new matcher parser; they're harmless, and the alert still goes through.

```powershell
kubectl -n monitoring exec alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager -- amtool alert add CyberlabTest severity=warning namespace=test --annotation=summary="Test alert from the cyberlab" --alertmanager.url=http://localhost:9093
```
