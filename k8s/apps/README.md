# k8s/apps

Argo CD's `root` Application (defined in [`argocd.tf`](../../argocd.tf)) syncs this folder: every `*.yaml` here is an Argo CD `Application`, and Argo CD deploys whatever it points to. Adding an app to the cluster means adding a file here and pushing to `main`.

Sync is automated with `prune` and `selfHeal`, so the cluster always matches `main`: manual `kubectl` changes to these apps are reverted, and deleting a file removes its app.
