locals {
  # Cluster topology. host = last octet in cluster_cidr; vm_id = 40 (Lab VLAN) + host octet.
  # Adding a worker is one line here.
  nodes = {
    talos-cp-01 = { role = "controlplane", host = 11, vm_id = 4011, cores = 2, memory = 4096 }
    talos-wk-01 = { role = "worker", host = 21, vm_id = 4021, cores = 2, memory = 6144 }
    talos-wk-02 = { role = "worker", host = 22, vm_id = 4022, cores = 2, memory = 6144 }
  }

  gateway   = cidrhost(var.cluster_cidr, 1)
  prefixlen = split("/", var.cluster_cidr)[1]
  node_ips  = { for name, n in local.nodes : name => cidrhost(var.cluster_cidr, n.host) }

  # Single control-plane node for now: API endpoint, bootstrap, and kubeconfig all go through it
  cp_name = "talos-cp-01"
  cp_ip   = local.node_ips[local.cp_name]
}

# The control plane was first written as a standalone resource; keep Terraform from
# reading the rename as destroy + create
moved {
  from = proxmox_virtual_environment_vm.cp
  to   = proxmox_virtual_environment_vm.node["talos-cp-01"]
}

resource "proxmox_virtual_environment_vm" "node" {
  for_each = local.nodes

  name      = each.key
  node_name = var.proxmox_node
  vm_id     = each.value.vm_id
  tags      = ["talos", replace(each.value.role, "controlplane", "control-plane"), "terraform"]
  on_boot   = true

  machine       = "q35"
  scsi_hardware = "virtio-scsi-single"

  operating_system {
    type = "l26"
  }

  # Talos needs x86-64-v2+, which the default kvm64 CPU type does not provide
  cpu {
    cores = each.value.cores
    type  = "host"
  }

  memory {
    dedicated = each.value.memory
  }

  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    import_from  = proxmox_download_file.talos.id
    file_format  = "raw"
    size         = 40
    iothread     = true
    discard      = "on"
    ssd          = true
  }

  # Private NAT bridge: no inbound from the upstream network
  network_device {
    bridge = "vmbr1"
    model  = "virtio"
  }

  initialization {
    datastore_id = "local-lvm"

    ip_config {
      ipv4 {
        address = "${local.node_ips[each.key]}/${local.prefixlen}"
        gateway = local.gateway
      }
    }

    dns {
      servers = var.dns_servers
    }
  }

  agent {
    enabled = true
    # The static IP is already known; don't block apply/refresh on the agent reporting it
    wait_for_ip {
      disabled = true
    }
  }

  # Destroying a lab node shouldn't hang waiting on a graceful guest shutdown
  stop_on_destroy = true
}

output "node_ips" {
  value = local.node_ips
}
