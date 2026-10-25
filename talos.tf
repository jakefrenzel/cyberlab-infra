# Talos machine config, bootstrap, and client credentials.
# Everything secret here (cluster CA, talosconfig, kubeconfig) lands in Terraform state,
# which is why *.tfstate is gitignored and must be backed up.

# Cluster PKI: the root of trust for both the Talos API and Kubernetes
resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version
}

locals {
  # Talos 1.14 config is multi-document; patches target documents by kind
  install_patch = yamlencode({
    apiVersion = "v1alpha1"
    kind       = "UnattendedInstallConfig"
    installer = {
      # nocloud installer from the same schematic, so upgrades keep the guest agent
      image = data.talos_image_factory_urls.this.urls.installer
    }
    provisioning = {
      diskSelector = { match = "disk.dev_path == \"/dev/sda\"" }
    }
  })
}

# One config per node: same secrets and role defaults, plus the node's own hostname
data "talos_machine_configuration" "node" {
  for_each = local.nodes

  cluster_name     = var.cluster_name
  cluster_endpoint = "https://${local.cp_ip}:6443"
  machine_type     = each.value.role
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  talos_version    = var.talos_version
  config_patches = concat(
    [
      local.install_patch,
      # Replace the generated `auto: stable` hostname; auto and hostname can't coexist
      yamlencode({ apiVersion = "v1alpha1", kind = "HostnameConfig", "$patch" = "delete" }),
      yamlencode({ apiVersion = "v1alpha1", kind = "HostnameConfig", hostname = each.key }),
    ],
    each.value.role == "controlplane" ? local.cni_patches : [],
  )
}

moved {
  from = talos_machine_configuration_apply.cp
  to   = talos_machine_configuration_apply.node["talos-cp-01"]
}

# First apply goes to each node's maintenance-mode API; workers then join via the control plane
resource "talos_machine_configuration_apply" "node" {
  for_each = local.nodes

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.node[each.key].machine_configuration
  node                        = local.node_ips[each.key]

  depends_on = [proxmox_virtual_environment_vm.node]
}

# Starts etcd. Runs exactly once per cluster, on one control-plane node
resource "talos_machine_bootstrap" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.cp_ip

  depends_on = [talos_machine_configuration_apply.node]
}

resource "talos_cluster_kubeconfig" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.cp_ip

  depends_on = [talos_machine_bootstrap.this]
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = [local.cp_ip]
  nodes                = values(local.node_ips)
}

output "talosconfig" {
  value     = data.talos_client_configuration.this.talos_config
  sensitive = true
}

output "kubeconfig" {
  value     = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive = true
}
