# k8s/monitoring

Plain manifests for the monitoring stack, synced by the `monitoring-config` Application. The chart itself is the `kube-prometheus-stack` Application in [`../apps`](../apps).

## Bootstrap secret (once per cluster)

Grafana reads its admin login from a `grafana-admin` Secret that is created by hand and never committed. After a rebuild, create it once the `monitoring` namespace exists:

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

Until it exists, the Grafana pod waits in `CreateContainerConfigError` and recovers on its own once the Secret is created.
