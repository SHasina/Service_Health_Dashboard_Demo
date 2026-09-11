<#
.SYNOPSIS
    Builds the application images, loads them into the local kind cluster, and
    applies the Terraform-managed Kubernetes + Istio resources.
#>

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path "$PSScriptRoot\.."
$clusterName = "health-dashboard"

Write-Host "== Building images ==" -ForegroundColor Yellow
docker build -t health-dashboard/backend:local "$repoRoot\backend"
docker build -t health-dashboard/frontend:local "$repoRoot\frontend"
docker build -t health-dashboard/mock-service:local "$repoRoot\services\mock-service"

Write-Host "== Loading images into kind ==" -ForegroundColor Yellow
kind load docker-image health-dashboard/backend:local --name $clusterName
kind load docker-image health-dashboard/frontend:local --name $clusterName
kind load docker-image health-dashboard/mock-service:local --name $clusterName

Push-Location "$repoRoot\infra\terraform"
try {
    Write-Host "== terraform init ==" -ForegroundColor Yellow
    terraform init -input=false

    # First apply: only the namespace and Istio Helm releases. The Istio
    # custom resources (module.istio's null_resource.apply_istio_manifests)
    # depend on istiod's CRDs already existing in the cluster, and the app
    # workloads should exist before the injection rollout-restart runs.
    Write-Host "== terraform apply (namespace + app + istio control plane) ==" -ForegroundColor Yellow
    terraform apply -input=false -auto-approve `
        -var-file="envs/local/terraform.tfvars" `
        -target="module.namespace" `
        -target="module.app" `
        -target="module.istio[0].helm_release.istio_base" `
        -target="module.istio[0].helm_release.istiod" `
        -target="module.istio[0].helm_release.istio_ingressgateway"

    Write-Host "== terraform apply (mesh policies) ==" -ForegroundColor Yellow
    terraform apply -input=false -auto-approve -var-file="envs/local/terraform.tfvars"
} finally {
    Pop-Location
}

Write-Host "`nDeployed. Run scripts/verify.ps1 to check pod status and reach the dashboard." -ForegroundColor Green
