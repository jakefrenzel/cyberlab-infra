# Talos node image, built by Image Factory and pulled straight onto pve1.

# A schematic is the recipe for a custom image; the factory returns a content-addressed ID.
resource "talos_image_factory_schematic" "this" {
  schematic = yamlencode({
    customization = {
      systemExtensions = {
        # Lets Proxmox see the VM's IPs and shut it down cleanly
        officialExtensions = ["siderolabs/qemu-guest-agent"]
      }
    }
  })
}

# nocloud reads its network config from the Proxmox cloud-init drive, so static IPs work
# from first boot. qcow2 is uncompressed, which Proxmox can import directly.
data "talos_image_factory_urls" "this" {
  talos_version     = var.talos_version
  schematic_id      = talos_image_factory_schematic.this.id
  platform          = "nocloud"
  disk_image_format = "qcow2"
}

resource "proxmox_download_file" "talos" {
  node_name    = var.proxmox_node
  datastore_id = "local"
  content_type = "import"
  url          = data.talos_image_factory_urls.this.urls.disk_image
  file_name    = "talos-${var.talos_version}-${substr(talos_image_factory_schematic.this.id, 0, 8)}-nocloud-amd64.qcow2"
}
