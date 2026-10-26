# cyberlab-infra

[![CI](https://github.com/jakefrenzel/cyberlab-infra/actions/workflows/ci.yml/badge.svg)](https://github.com/jakefrenzel/cyberlab-infra/actions/workflows/ci.yml)

Terraform for my homelab's Kubernetes cluster: three [Talos Linux](https://www.talos.dev/) VMs on a Proxmox VE node, created and configured entirely from code. The design decisions, network setup, and lessons learned are written up in my lab documentation: [jakefrenzel-cyberlab](https://github.com/jakefrenzel/jakefrenzel-cyberlab).

> [!NOTE]
> IP addresses in this README and in `terraform.tfvars.example` are documentation values, not the ones the lab uses. Real values live only in a gitignored `terraform.tfvars`.

## What it builds

| Node | Role | vCPU | RAM | Disk | IP |
|------|------|------|-----|------|----|
| talos-cp-01 | Control plane | 2 | 4 GB | 40 GB | `.11` |
| talos-wk-01 | Worker | 2 | 6 GB | 40 GB + 20 GB data | `.21` |
| talos-wk-02 | Worker | 2 | 6 GB | 40 GB + 20 GB data | `.22` |

- **Image:** Talos `nocloud` image from [Image Factory](https://factory.talos.dev) with the QEMU guest agent extension, downloaded straight onto the Proxmox node
- **Network:** every node sits on a private NAT bridge (`vmbr1`) with a static IP from cloud-init. Nothing on the upstream network can reach the nodes; the admin laptop reaches them through a Tailscale subnet route
- **Talos:** cluster secrets, per-node machine config, bootstrap, and kubeconfig are all Terraform resources (`siderolabs/talos` provider)

On top of the nodes:

| Layer | Component | Installed by |
|-------|-----------|--------------|
| CNI | [Cilium](https://cilium.io) 1.20 with kube-proxy replacement, NetworkPolicy enforcement, and Hubble flow visibility | Terraform → Talos inline manifest |
| GitOps | [Argo CD](https://argo-cd.readthedocs.io) 3.5 with an app-of-apps `root` Application watching [`k8s/apps`](k8s/apps) | Terraform → Talos inline manifest |
| Monitoring | kube-prometheus-stack (Prometheus, Grafana, Alertmanager), plus Cilium, Hubble, and control-plane (etcd, scheduler, controller-manager) metrics and dashboards; Argo CD metrics; a custom Cyberlab Overview home dashboard; extra alert rules for Argo CD and Cilium; warning and critical alerts to Discord | Argo CD, from this repo |
| Host firewall | Cilium host policies: every node drops ingress that isn't explicitly allowed; control-plane metrics are reachable by Prometheus only | Feature by Terraform; policies by Argo CD |
| Runtime security | [Falco](https://falco.org) 0.45 watching every node's syscalls with the modern eBPF driver; Falcosidekick forwards events to Alertmanager and a web UI, with metrics and dashboards in Prometheus/Grafana | Argo CD, from this repo |
| Storage | [Local Path Provisioner](https://github.com/rancher/local-path-provisioner) as the default StorageClass, backed by each worker's data disk (a Talos user volume) | Talos volume from Terraform; provisioner by Argo CD |

Terraform owns the cluster and the two components it can't run without (CNI and the GitOps controller). Everything else is a file in `k8s/` that Argo CD deploys from `main`.

## Layout

| Path | Contents |
|------|----------|
| `providers.tf` | Provider pins (`bpg/proxmox`, `siderolabs/talos`) and the Proxmox connection |
| `variables.tf` | Inputs: API endpoint and token, `cluster_cidr`, Talos version |
| `image.tf` | Image Factory schematic and image download |
| `nodes.tf` | Cluster topology (one map) and the VMs |
| `talos.tf` | Machine secrets, machine configs, bootstrap, client configs |
| `cilium.tf` | Cilium chart rendered with `helm_template`, plus the Talos patches that remove flannel and kube-proxy |
| `argocd.tf` | Argo CD chart (with metrics Services) and the `root` Application |
| `storage.tf` | Talos user volume on each worker's data disk, mounted for Local Path Provisioner |
| `metrics.tf` | Control-plane-only Talos patch that exposes etcd, scheduler, and controller-manager metrics |
| `main.tf` | Read-only smoke test of the Proxmox API |
| `host/pve1/setup-vmbr1.sh` | Host network setup the Proxmox API can't do (NAT bridge + Tailscale route) |
| `k8s/apps/` | One Argo CD `Application` per file; this is what `root` syncs |
| `k8s/monitoring/` | Namespace, Prometheus scrape configs, the lab's alert rules, and its Grafana dashboards (as JSON) |
| `k8s/storage/local-path/` | Local Path Provisioner, pointed at the Talos user volume |
| `k8s/security/` | Cilium host firewall policies |

Adding a worker is one line in the `nodes` map in `nodes.tf`. Adding an app is one file in `k8s/apps/` and a push to `main`.

## Usage

Requirements: Terraform ≥ 1.16, `talosctl`, `kubectl`, a Proxmox VE 9 node, and a Proxmox API token for a least-privilege `terraform@pve` user.

1. Create the NAT bridge on the Proxmox host (once):
   ```bash
   scp host/pve1/setup-vmbr1.sh root@<proxmox-host>:/root/
   ssh root@<proxmox-host> bash /root/setup-vmbr1.sh 10.127.40
   ```
2. Copy `terraform.tfvars.example` to `terraform.tfvars` and fill in the endpoint, token, and cluster subnet
3. Build the cluster:
   ```bash
   terraform init
   terraform plan -out tfplan
   terraform apply tfplan
   ```
4. Export the credentials (the `_out/` directory is gitignored):
   ```bash
   terraform output -raw talosconfig > _out/talosconfig
   terraform output -raw kubeconfig  > _out/kubeconfig
   export TALOSCONFIG=$PWD/_out/talosconfig KUBECONFIG=$PWD/_out/kubeconfig
   talosctl -n 10.127.40.11 health
   kubectl get nodes
   ```
   On Windows PowerShell 5.1, write the files with `| Set-Content -Encoding ascii` instead of `>`, which produces UTF-16.
5. Create the Grafana admin and Discord webhook Secrets once the `monitoring` namespace exists (see [`k8s/monitoring/README.md`](k8s/monitoring/README.md)), and the Falcosidekick UI login once the `falco` namespace exists (see [Falco](#falco)). Argo CD's own admin password is generated in-cluster:
   ```bash
   kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
   kubectl -n argocd port-forward svc/argocd-server 8080:443
   ```

### Changing Cilium or Argo CD

Talos treats inline manifests as **create-only**: once an object exists, Talos never updates or deletes it, even if the manifest in the machine config changes. After editing `cilium.tf` or `argocd.tf`:

```bash
terraform apply
talosctl -n 10.127.40.11 upgrade-k8s --to <current Kubernetes version> --dry-run   # review the diff
talosctl -n 10.127.40.11 upgrade-k8s --to <current Kubernetes version>             # sync manifests
```

Passing the version the cluster already runs skips the Kubernetes upgrade and only syncs manifests (server-side apply; removed objects are pruned).

Objects that are new in the manifest are created by `terraform apply` on its own; `upgrade-k8s` is only needed to change or remove objects that already exist. If the dry run shows nothing but `unchanged`, there's nothing to sync.

Changes under `k8s/` need none of this: push to `main` and Argo CD syncs them.

### Changing control-plane settings

Machine-config changes such as `metrics.tf` apply with a plain `terraform apply`. The scheduler and controller-manager restart on their own within a minute. etcd only reads its flags at startup, and Talos won't restart it through the API, so etcd changes need a control-plane reboot (about two minutes without the Kubernetes API; workloads on the workers keep running):

```bash
talosctl -n 10.127.40.11 reboot --wait
```

### Host firewall

Every node carries the label `cyberlab.io/host-firewall=enabled` (set in `talos.tf`), which opts it into the policies in [`k8s/security/host-firewall.yaml`](k8s/security/host-firewall.yaml). Ingress to a node is dropped unless one of these allows it:

| From | Allowed |
|------|---------|
| Other nodes, API server, Cilium health | Everything (VXLAN, kubelet, Talos API proxying, health checks) |
| Outside the cluster (the admin laptop, via the Tailscale route) | Kubernetes API `6443`, Talos API `50000`, ping |
| Any pod | API server `6443`, Talos host DNS `53` |
| Prometheus only | kubelet, node-exporter, Cilium/Hubble metrics; on the control plane also etcd `2381`, controller-manager `10257`, scheduler `10259` |
| Hubble Relay only | Hubble `4244` |

Policies are identity-based, so "Prometheus only" means the Prometheus pod wherever it runs, and the files contain no IP addresses. Outgoing traffic from the nodes isn't filtered.

To change the rules safely, put the node's host endpoint into audit mode first (allowed-but-would-drop flows are logged, nothing is dropped), then watch the verdicts:

```bash
kubectl -n kube-system exec <cilium-pod-on-node> -c cilium-agent -- cilium-dbg endpoint list   # host endpoint = identity 1
kubectl -n kube-system exec <cilium-pod-on-node> -c cilium-agent -- cilium-dbg endpoint config <id> PolicyAuditMode=Enabled
kubectl -n kube-system exec <cilium-pod-on-node> -c cilium-agent -- cilium-dbg monitor -t policy-verdict --related-to <id>
```

Audit mode is also the emergency off switch if a rule blocks something it shouldn't: it takes effect immediately, and nothing else reverts it. Removing the label or deleting the policy by hand doesn't stick, because Talos restores the label within seconds and Argo CD recreates the policy. Fix the rule in git, or drop the label from `talos.tf` and apply. Audit mode doesn't survive a Cilium agent restart; the node goes back to enforcing.

### Falco

Falco runs on every node, control plane included ([`k8s/apps/falco.yaml`](k8s/apps/falco.yaml)), and alerts on suspicious behaviour inside containers and on the host: shells spawned in containers, reads of sensitive files, writes below system directories, and the rest of the upstream default ruleset. Talos only loads signed kernel modules, so Falco uses its modern eBPF probe, built against the kernel's BTF. That needs no driver download and runs with four capabilities (`BPF`, `PERFMON`, `SYS_RESOURCE`, `SYS_PTRACE`) instead of a privileged container. Events carry the pod and namespace, read from containerd's CRI socket.

Events go to stdout as JSON and to Falcosidekick, which forwards `warning` and above to Alertmanager and everything to its web UI (kept for 7 days). Alertmanager doesn't pass Falco events on to Discord yet; that waits until the rules are tuned against a baseline. Falco and Falcosidekick metrics are scraped by Prometheus, with a dashboard each in Grafana.

The UI reads its login from a `falcosidekick-ui-auth` Secret that is created by hand and never committed (the chart default is `admin:admin`). After a rebuild, create it once the `falco` namespace exists; until then the UI pod waits in `CreateContainerConfigError`:

```powershell
$b = New-Object byte[] 24; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
$pw = [Convert]::ToBase64String($b).TrimEnd('=').Replace('+','-').Replace('/','_')
kubectl -n falco create secret generic falcosidekick-ui-auth --from-literal=FALCOSIDEKICK_UI_USER="admin:$pw"
Remove-Variable pw, b
```

Read the login back and open the UI at <http://localhost:2802>:

```powershell
kubectl -n falco get secret falcosidekick-ui-auth -o jsonpath='{.data.FALCOSIDEKICK_UI_USER}' | % { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_)) }
kubectl -n falco port-forward svc/falco-falcosidekick-ui 2802:2802
```

To see a detection end to end, read a sensitive file from a throwaway pod. A `Read sensitive file untrusted` event shows up in the UI and in Alertmanager within seconds:

```bash
kubectl run falco-test --image=busybox:1.37.0 --restart=Never --command -- sleep 600
kubectl exec -t falco-test -- cat /etc/shadow > /dev/null
kubectl delete pod falco-test
```

## CI

Every push and pull request runs [`ci.yml`](.github/workflows/ci.yml):

- **Terraform:** `fmt -check`, `validate` (providers from the lock file, no backend), and `tflint`
- **ShellCheck** on every shell script
- **gitleaks** over the full git history, with an extra rule for Proxmox API tokens, which the default rules don't recognize ([`.gitleaks.toml`](.gitleaks.toml))

CI is static only. GitHub's runners can't reach the lab, and no Proxmox token or Tailscale key is given to a public repository's workflows. Actions are pinned to commit SHAs, and the workflow token is read-only.

## Security notes

- **Terraform state contains the cluster's root CA** and every node's credentials. It is gitignored and must be backed up separately; never commit it
- `terraform.tfvars`, `talosconfig`, and `kubeconfig` are gitignored for the same reason
- Admin passwords for Argo CD, Grafana, and the Falcosidekick UI, and the Discord webhook URL, live only in in-cluster Secrets, never in git or Terraform state. The chart defaults (`prom-operator`, `admin:admin`) are never used
- Pod Security Admission enforces the `baseline` level cluster-wide. The exceptions (`privileged`) are `monitoring`, because node-exporter needs host access, and `falco`, because Falco needs host mounts and eBPF capabilities
- Control-plane metrics listen on the node's network: scheduler (`:10259`) and controller-manager (`:10257`) require an authorized token, and etcd's `:2381` is unauthenticated (metrics only, no etcd data). The host firewall limits all three to the Prometheus pod
- Every node runs a default-deny ingress host firewall; only the Kubernetes and Talos APIs are reachable from outside the cluster
- The Proxmox provider uses `insecure = true` because the node has a self-signed certificate. The API is only reachable over Tailscale, which encrypts the traffic
