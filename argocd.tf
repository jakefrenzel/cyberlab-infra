# Argo CD, installed by Talos at bootstrap the same way as Cilium. Terraform owns Argo CD
# itself (upgrades = bump argocd_chart_version); Argo CD owns everything under k8s/apps.

variable "argocd_chart_version" {
  description = "argo-cd Helm chart version (argoproj/argo-helm)"
  type        = string
  default     = "10.11.1"
}

variable "gitops_repo_url" {
  description = "Public repo Argo CD syncs from"
  type        = string
  default     = "https://github.com/jakefrenzel/cyberlab-infra.git"
}

data "helm_template" "argocd" {
  name         = "argocd"
  repository   = "https://argoproj.github.io/argo-helm"
  chart        = "argo-cd"
  version      = var.argocd_chart_version
  namespace    = "argocd"
  kube_version = "1.37.0"
  include_crds = true

  values = [yamlencode({
    # No SSO or notification integrations in the lab; the built-in admin user is enough
    dex           = { enabled = false }
    notifications = { enabled = false }
  })]
}

locals {
  # App of apps: every Application manifest in k8s/apps is deployed and kept in sync.
  # No finalizer, so deleting this Application never cascades into the apps it created.
  argocd_root_app = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata   = { name = "root", namespace = "argocd" }
    spec = {
      project = "default"
      source = {
        repoURL        = var.gitops_repo_url
        targetRevision = "main"
        path           = "k8s/apps"
      }
      destination = { server = "https://kubernetes.default.svc", namespace = "argocd" }
      syncPolicy = {
        automated = { prune = true, selfHeal = true }
      }
    }
  })

  argocd_patches = [
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "KubeInlineManifestConfig"
      name       = "argocd"
      manifest = join("\n---\n", [
        yamlencode({ apiVersion = "v1", kind = "Namespace", metadata = { name = "argocd" } }),
        data.helm_template.argocd.manifest,
        local.argocd_root_app,
      ])
    }),
  ]
}
