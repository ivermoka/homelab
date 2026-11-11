# Helm and ArgoCD setup

## Basics explained

### Helm

Helm is a package manager for Kubernetes (k3s), and is used to install and configure packages. 
An example of package is ArgoCD.
Helm uses `Chart` files to specify packages. Depoyments, Services and so on. You can configure Helm with a Values file, then point it to it. 
Helm runs installs straight to the cluster (i.e. no files generated).

Helm CLI has the same kubeconfig syntax as `kubectl`, which means we can configure it to use our `homelab.yaml` config file.

### ArgoCD

ArgoCD is a deployment tool, which automates `kubectl apply -f`, with GitHub integration. It takes manifests and updates the cluster based on what is configured. Automatically syncs, generates new resources if either connected GitHub repo changes, or manifests change.

NOTE: When first deploying applications, you have to specify the "entrypoint" to the application. 
You use `Application` manifests for this entrypoint, which defines which values file(s) to look for and use. In addition to GitOps stuff, like the manifests repo (in this case, Homelab), `targetRevision` (which branch to use), and sets config for kubernetes - namespace, prune & selfHeal + properties for the pods made.

Example:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: 'gli-ui-s1' # Application name
  namespace: 'bgl-argocd' # ArgoCD namespace (in my case: argocd)
spec:
  project: 'default'
  source:
    repoURL: 'https://github.com/tietoevryfs/bgl-manifests.git'
    targetRevision: HEAD # GitHub branch
    path: 's1/bgl/gli-ui' # Here the value file path is defined
    helm:
      valueFiles:
        - values.yaml
  destination:
    server: 'https://kubernetes.default.svc'
    namespace: 'gli-test' # Kubernetes namespace (in my case )
  syncPolicy:
    syncOptions:
      - CreateNamespace=false
    automated:
      prune: true
      selfHeal: true
```


## Install ArgoCD with Helm

Add argo-helm repo
`hh repo add argo https://argoproj.github.io/argo-helm`

Install it
`hh upgrade --install argocd argo/argo-cd -n argocd --create-namespace`

Since ArgoCD now runs in the server, you have to forward its port. Easiest solution for now is:
`kubectl port-forward service/argocd-server -n argocd 8080:443`

This forwards the argocd-server to port `8080` on localhost.

After reaching the UI the first time you can login with username: admin and the random password generated during the installation. You can find the password by running:

`kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d`




