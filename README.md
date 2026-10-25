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
| Monitoring | kube-prometheus-stack (Prometheus, Grafana, Alertmanager), plus Cilium, Hubble, and control-plane (etcd, scheduler, controller-manager) metrics and dashboards | Argo CD, from this repo |
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
| `argocd.tf` | Argo CD chart and the `root` Application |
| `storage.tf` | Talos user volume on each worker's data disk, mounted for Local Path Provisioner |
| `metrics.tf` | Control-plane-only Talos patch that exposes etcd, scheduler, and controller-manager metrics |
| `main.tf` | Read-only smoke test of the Proxmox API |
| `host/pve1/setup-vmbr1.sh` | Host network setup the Proxmox API can't do (NAT bridge + Tailscale route) |
| `k8s/apps/` | One Argo CD `Application` per file; this is what `root` syncs |
| `k8s/monitoring/` | Namespace and Prometheus scrape configs for the monitoring stack |
| `k8s/storage/local-path/` | Local Path Provisioner, pointed at the Talos user volume |

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
5. Create the Grafana admin Secret once the `monitoring` namespace exists (see [`k8s/monitoring/README.md`](k8s/monitoring/README.md)). Argo CD's own admin password is generated in-cluster:
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

Changes under `k8s/` need none of this: push to `main` and Argo CD syncs them.

### Changing control-plane settings

Machine-config changes such as `metrics.tf` apply with a plain `terraform apply`. The scheduler and controller-manager restart on their own within a minute. etcd only reads its flags at startup, and Talos won't restart it through the API, so etcd changes need a control-plane reboot (about two minutes without the Kubernetes API; workloads on the workers keep running):

```bash
talosctl -n 10.127.40.11 reboot --wait
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
- Admin passwords for Argo CD and Grafana live only in in-cluster Secrets, never in git or Terraform state. Grafana's chart default (`prom-operator`) is never used
- Pod Security Admission enforces the `baseline` level cluster-wide. The `monitoring` namespace is the one exception (`privileged`), because node-exporter needs host access
- Control-plane metrics listen on the node's network: scheduler (`:10259`) and controller-manager (`:10257`) still require an authorized token, but etcd's `:2381` is unauthenticated (metrics only, no etcd data). They're reachable from pods and over the Tailscale route; restricting them to Prometheus with Cilium host firewall policies is planned
- The Proxmox provider uses `insecure = true` because the node has a self-signed certificate. The API is only reachable over Tailscale, which encrypts the traffic
