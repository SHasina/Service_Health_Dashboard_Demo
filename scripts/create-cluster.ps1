<#
.SYNOPSIS
    Creates the local kind cluster used to run the Service Health Dashboard.
#>

$ErrorActionPreference = "Stop"

try {
    docker info | Out-Null
} catch {
    Write-Error "Docker Desktop does not appear to be running. Start it before creating the cluster."
    exit 1
}

$clusterName = "health-dashboard"
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$existing = kind get clusters 2>$null
$ErrorActionPreference = $prevEAP
if ($existing -contains $clusterName) {
    Write-Host "Cluster '$clusterName' already exists." -ForegroundColor Yellow
    exit 0
}

kind create cluster --config "$PSScriptRoot\..\infra\kind\kind-config.yaml"
kubectl cluster-info --context "kind-$clusterName"
