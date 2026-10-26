# k8s/monitoring

Plain manifests for the monitoring stack, synced by the `monitoring-config` Application through [`kustomization.yaml`](kustomization.yaml): the namespace, Cilium scrape configs, and the lab's own Grafana dashboards. The chart itself is the `kube-prometheus-stack` Application in [`../apps`](../apps).

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

To send a test alert to Discord: it arrives about 30 seconds later and resolves on its own after 5 minutes. amtool prints warnings about its new matcher parser; they're harmless, and the alert still goes through.

```powershell
kubectl -n monitoring exec alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager -- amtool alert add CyberlabTest severity=warning namespace=test --annotation=summary="Test alert from the cyberlab" --alertmanager.url=http://localhost:9093
```
