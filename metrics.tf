# Control-plane metrics: Talos binds kube-scheduler, kube-controller-manager, and the
# etcd metrics listener to localhost, so Prometheus (kube-prometheus-stack) can't scrape
# them. Listen on all interfaces instead. Scheduler (:10259) and controller-manager
# (:10257) still require an authorized bearer token; etcd :2381 serves metrics only,
# unauthenticated, and no etcd data.

locals {
  cp_metrics_patches = [
    yamlencode({ apiVersion = "v1alpha1", kind = "KubeSchedulerConfig", extraArgs = { bind-address = "0.0.0.0" } }),
    yamlencode({ apiVersion = "v1alpha1", kind = "KubeControllerManagerConfig", extraArgs = { bind-address = "0.0.0.0" } }),
    # etcd has no multi-doc kind yet; it still lives in the v1alpha1 document
    yamlencode({ cluster = { etcd = { extraArgs = { listen-metrics-urls = "http://0.0.0.0:2381" } } } }),
  ]
}
