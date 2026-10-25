# Persistent storage: each worker's data disk (nodes.tf) becomes a Talos user volume,
# mounted at /var/mnt/local-path-provisioner. Local Path Provisioner (k8s/storage)
# carves PersistentVolumes out of that directory.

locals {
  worker_patches = [
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "UserVolumeConfig"
      name       = "local-path-provisioner"
      provisioning = {
        # Only the data disk: not the system disk, and not the cloud-init CD-ROM (SATA)
        diskSelector = { match = "!system_disk && disk.transport == 'virtio'" }
        minSize      = "10GB"
        grow         = true
      }
    }),
  ]
}
