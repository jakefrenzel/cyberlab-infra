# Read-only smoke test: proves Terraform can authenticate to pve1.
# Nothing here creates or changes anything.

data "proxmox_version" "pve" {}

data "proxmox_virtual_environment_nodes" "all" {}

output "pve_version" {
  value = data.proxmox_version.pve.version
}

output "pve_nodes" {
  value = data.proxmox_virtual_environment_nodes.all.names
}
