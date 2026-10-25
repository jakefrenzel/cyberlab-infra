terraform {
  required_version = ">= 1.16"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.118"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.12"
    }
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  # pve1 uses Proxmox's self-signed cert; traffic already rides Tailscale (WireGuard)
  insecure = true
}
