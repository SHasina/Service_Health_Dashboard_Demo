<#
.SYNOPSIS
    Smoke-tests the deployed cluster: pod readiness, Istio sidecar injection,
    and an end-to-end curl through port-forwarding.
#>

$ErrorActionPreference = "Stop"
$namespace = "health-dashboard"

Write-Host "== Pods ==" -ForegroundColor Yellow
kubectl get pods -n $namespace -o wide

Write-Host "`n== Istio analyze ==" -ForegroundColor Yellow
istioctl analyze -n $namespace

Write-Host "`n== Port-forwarding frontend on http://localhost:8080 (Ctrl+C to stop) ==" -ForegroundColor Yellow
kubectl port-forward -n $namespace svc/frontend 8080:80
