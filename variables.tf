variable "proxmox_endpoint" {
  description = "Proxmox API URL (pve1 over Tailscale). Set in terraform.tfvars (gitignored)."
  type        = string
}

variable "proxmox_api_token" {
  description = "API token in the form terraform@pve!tf=<secret>. Set in terraform.tfvars (gitignored)."
  type        = string
  sensitive   = true
}

variable "proxmox_node" {
  description = "Proxmox node name as shown in the GUI tree"
  type        = string
  default     = "pve1"
}

variable "cluster_cidr" {
  description = "The /24 on vmbr1 the cluster lives in. Must not overlap the k8s service (10.96.0.0/12) or pod (10.244.0.0/16) CIDRs. Set in terraform.tfvars (gitignored)."
  type        = string

  validation {
    condition     = can(cidrhost(var.cluster_cidr, 0)) && endswith(var.cluster_cidr, "/24")
    error_message = "cluster_cidr must be a /24, e.g. 10.127.40.0/24."
  }
}

variable "dns_servers" {
  description = "Upstream DNS for the Talos nodes"
  type        = list(string)
  default     = ["1.1.1.1", "9.9.9.9"]
}

variable "cluster_name" {
  description = "Kubernetes cluster name"
  type        = string
  default     = "cyberlab"
}

variable "talos_version" {
  description = "Talos release for the node image (keep in step with the local talosctl)"
  type        = string
  default     = "v1.14.4"
}
