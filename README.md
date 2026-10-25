# cyberlab-infra

[![CI](https://github.com/jakefrenzel/cyberlab-infra/actions/workflows/ci.yml/badge.svg)](https://github.com/jakefrenzel/cyberlab-infra/actions/workflows/ci.yml)

Terraform for my homelab's Kubernetes cluster: three [Talos Linux](https://www.talos.dev/) VMs on a Proxmox VE node, created and configured entirely from code. The design decisions, network setup, and lessons learned are written up in my lab documentation: [jakefrenzel-cyberlab](https://github.com/jakefrenzel/jakefrenzel-cyberlab).

> [!NOTE]
> IP addresses in this README and in `terraform.tfvars.example` are documentation values, not the ones the lab uses. Real values live only in a gitignored `terraform.tfvars`.

## What it builds

| Node | Role | vCPU | RAM | Disk | IP |
|------|------|------|-----|------|----|
| talos-cp-01 | Control plane | 2 | 4 GB | 40 GB | `.11` |
| talos-wk-01 | Worker | 2 | 6 GB | 40 GB | `.21` |
| talos-wk-02 | Worker | 2 | 6 GB | 40 GB | `.22` |

- **Image:** Talos `nocloud` image from [Image Factory](https://factory.talos.dev) with the QEMU guest agent extension, downloaded straight onto the Proxmox node
- **Network:** every node sits on a private NAT bridge (`vmbr1`) with a static IP from cloud-init. Nothing on the upstream network can reach the nodes; the admin laptop reaches them through a Tailscale subnet route
- **Talos:** cluster secrets, per-node machine config, bootstrap, and kubeconfig are all Terraform resources (`siderolabs/talos` provider)

## Layout

| Path | Contents |
|------|----------|
| `providers.tf` | Provider pins (`bpg/proxmox`, `siderolabs/talos`) and the Proxmox connection |
| `variables.tf` | Inputs: API endpoint and token, `cluster_cidr`, Talos version |
| `image.tf` | Image Factory schematic and image download |
| `nodes.tf` | Cluster topology (one map) and the VMs |
| `talos.tf` | Machine secrets, machine configs, bootstrap, client configs |
| `main.tf` | Read-only smoke test of the Proxmox API |
| `host/pve1/setup-vmbr1.sh` | Host network setup the Proxmox API can't do (NAT bridge + Tailscale route) |

Adding a worker is one line in the `nodes` map in `nodes.tf`.

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

## CI

Every push and pull request runs [`ci.yml`](.github/workflows/ci.yml):

- **Terraform:** `fmt -check`, `validate` (providers from the lock file, no backend), and `tflint`
- **ShellCheck** on every shell script
- **gitleaks** over the full git history, with an extra rule for Proxmox API tokens, which the default rules don't recognize ([`.gitleaks.toml`](.gitleaks.toml))

CI is static only. GitHub's runners can't reach the lab, and no Proxmox token or Tailscale key is given to a public repository's workflows. Actions are pinned to commit SHAs, and the workflow token is read-only.

## Security notes

- **Terraform state contains the cluster's root CA** and every node's credentials. It is gitignored and must be backed up separately; never commit it
- `terraform.tfvars`, `talosconfig`, and `kubeconfig` are gitignored for the same reason
- The Proxmox provider uses `insecure = true` because the node has a self-signed certificate. The API is only reachable over Tailscale, which encrypts the traffic
