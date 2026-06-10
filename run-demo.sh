#!/usr/bin/env bash
# ArgoCD + Kustomize demo — one-shot runner for Mahesh's machine.
# Prereqs: Docker Desktop running, kind, kubectl. (brew install kind kubectl)
set -euo pipefail
cd "$(dirname "$0")"

echo "==> 1/5 Render check (what ArgoCD will deploy)"
kubectl kustomize overlays/dev | grep -E 'kind:|name:|replicas:' | head -12
kubectl kustomize overlays/prod | grep -E 'kind:|name:|replicas:|minAvailable:' | head -16

echo "==> 2/5 kind cluster"
kind get clusters 2>/dev/null | grep -q '^gitops-demo$' || kind create cluster --name gitops-demo
kubectl config use-context kind-gitops-demo

echo "==> 3/5 Install ArgoCD (takes ~2 min)"
kubectl get ns argocd >/dev/null 2>&1 || kubectl create namespace argocd
# --server-side: the ApplicationSet CRD exceeds the 256KB annotation limit
# that client-side apply needs for last-applied-configuration.
kubectl apply -n argocd --server-side -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd wait deploy --all --for=condition=Available --timeout=300s

echo "==> 4/5 Register the Applications"
echo "    NOTE: repoURL in argocd/*.yaml must point at YOUR pushed repo."
echo "    Push this folder to github.com/maheshrajannan/argocd-kustomize-demo first, or edit repoURL."
read -p "    Repo pushed and repoURL correct? [y/N] " ok
if [[ "${ok:-n}" == "y" ]]; then
  kubectl apply -f argocd/app-dev.yaml -f argocd/app-prod.yaml
fi

echo "==> 5/5 UI access"
echo "    password: $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
echo "    user: admin  ->  https://localhost:8080"
echo "    kubectl -n argocd port-forward svc/argocd-server 8080:443"
echo
echo "DRIFT DEMO:  kubectl -n hello-dev scale deploy dev-hello-web --replicas=5   (watch selfHeal snap it back)"
echo "             kubectl -n hello-prod scale deploy prod-hello-web --replicas=1 (stays OutOfSync until PR/manual sync)"
echo "CLEANUP:     kind delete cluster --name gitops-demo"
