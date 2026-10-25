# Cilium replaces flannel (which can't enforce NetworkPolicy) and kube-proxy (eBPF instead
# of iptables). The chart is rendered here and handed to Talos as an inline manifest, so
# Talos applies it during bootstrap and no one has to install the CNI by hand.

variable "cilium_version" {
  description = "Cilium Helm chart version"
  type        = string
  default     = "1.20.4"
}

data "helm_template" "cilium" {
  name         = "cilium"
  repository   = "https://helm.cilium.io"
  chart        = "cilium"
  version      = var.cilium_version
  namespace    = "kube-system"
  kube_version = "1.37.0" # Talos v1.14.4's default Kubernetes

  # Talos-specific settings from the Talos "Deploy Cilium CNI" guide
  values = [yamlencode({
    ipam = { mode = "kubernetes" }

    # eBPF service handling instead of kube-proxy; reach the API server through
    # KubePrism (Talos' per-node API load balancer on :7445)
    kubeProxyReplacement = true
    k8sServiceHost       = "localhost"
    k8sServicePort       = 7445

    # Talos forbids loading kernel modules, so SYS_MODULE is dropped from the defaults
    securityContext = {
      capabilities = {
        ciliumAgent      = ["CHOWN", "KILL", "NET_ADMIN", "NET_RAW", "IPC_LOCK", "SYS_ADMIN", "SYS_RESOURCE", "DAC_OVERRIDE", "FOWNER", "SETGID", "SETUID"]
        cleanCiliumState = ["NET_ADMIN", "SYS_ADMIN", "SYS_RESOURCE"]
      }
    }

    # Talos already mounts cgroup v2 and bpffs
    cgroup = {
      autoMount = { enabled = false }
      hostRoot  = "/sys/fs/cgroup"
    }

    # One operator is plenty for a three-node lab
    operator = {
      replicas   = 1
      prometheus = { enabled = true }
      dashboards = { enabled = true }
    }

    # Metrics endpoints only. The ServiceMonitors that tell Prometheus to scrape them live
    # in k8s/monitoring, because their CRD comes from kube-prometheus-stack (installed by
    # Argo CD) and doesn't exist yet when Talos applies this manifest at bootstrap.
    prometheus = { enabled = true }

    # Grafana dashboards as ConfigMaps (label grafana_dashboard=1), picked up by the
    # Grafana sidecar from any namespace
    dashboards = { enabled = true }

    hubble = {
      relay = { enabled = true }
      ui    = { enabled = true }
      # Generate Hubble's TLS certs inside the cluster. The default ("helm") makes new
      # random certs on every render, which would change the machine config on every plan.
      tls = { auto = { method = "cronJob" } }

      # Turn observed flows into metrics, labelled by source/destination workload
      metrics = {
        enableOpenMetrics = true
        enabled = [
          "dns",
          "drop",
          "tcp",
          "flow",
          "port-distribution",
          "icmp",
          "httpV2:exemplars=true;labelsContext=source_ip,source_namespace,source_workload,destination_ip,destination_namespace,destination_workload,traffic_direction",
        ]
        dashboards = { enabled = true }
      }
    }
  })]
}

locals {
  # Control-plane-only documents: these are cluster-wide settings, and worker configs
  # don't contain the flannel or kube-proxy documents at all
  cni_patches = [
    yamlencode({ apiVersion = "v1alpha1", kind = "KubeFlannelCNIConfig", "$patch" = "delete" }),
    yamlencode({ apiVersion = "v1alpha1", kind = "KubeProxyConfig", enabled = false }),
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "KubeInlineManifestConfig"
      name       = "cilium"
      manifest   = data.helm_template.cilium.manifest
    }),
  ]
}
