<#
.SYNOPSIS
    Installs and verifies the local toolchain required to build, test, and deploy the
    Service Health Dashboard on Windows.

.DESCRIPTION
    Idempotent: each tool is checked via Get-Command before an install is attempted.
    Docker Desktop and WSL2 are verified but not installed here, since both require
    Administrator privileges and interactive setup steps.

.EXAMPLE
    ./scripts/install-prereqs.ps1
#>

$ErrorActionPreference = "Stop"

$wingetPackages = @(
    @{ Id = "Git.Git";              Command = "git";       Scope = "user" }
    @{ Id = "GitHub.cli";           Command = "gh";        Scope = "user" }
    @{ Id = "Hashicorp.Terraform";  Command = "terraform";  Scope = "user" }
    @{ Id = "Kubernetes.kubectl";   Command = "kubectl";    Scope = "user" }
    @{ Id = "Kubernetes.kind";      Command = "kind";       Scope = "user" }
    @{ Id = "Helm.Helm";            Command = "helm";       Scope = "user" }
    @{ Id = "Python.Python.3.12";   Command = "python";     Scope = "user" }
    @{ Id = "OpenJS.NodeJS.LTS";    Command = "node";       Scope = "user" }
)

$istioVersion = "1.23.2"
$istioInstallDir = "$env:LOCALAPPDATA\istio"

function Install-WingetPackage {
    param($Id, $Command, $Scope)

    if (Get-Command $Command -ErrorAction SilentlyContinue) {
        Write-Host "[skip]    $Command already installed" -ForegroundColor DarkGray
        return
    }

    Write-Host "[install] $Id" -ForegroundColor Cyan
    winget install --id $Id --scope $Scope -e --silent `
        --accept-package-agreements --accept-source-agreements
}

function Install-Istioctl {
    if (Get-Command istioctl -ErrorAction SilentlyContinue) {
        Write-Host "[skip]    istioctl already installed" -ForegroundColor DarkGray
        return
    }

    Write-Host "[install] istioctl $istioVersion (direct download, no winget package exists)" -ForegroundColor Cyan
    $zipPath = Join-Path $env:TEMP "istio-$istioVersion-win.zip"
    $url = "https://github.com/istio/istio/releases/download/$istioVersion/istio-$istioVersion-win.zip"

    Invoke-WebRequest -Uri $url -OutFile $zipPath
    Expand-Archive -Path $zipPath -DestinationPath $istioInstallDir -Force
    Remove-Item $zipPath -Force

    $binPath = Join-Path $istioInstallDir "istio-$istioVersion\bin"
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($userPath -notlike "*$binPath*") {
        [Environment]::SetEnvironmentVariable("Path", "$userPath;$binPath", "User")
        $env:Path = "$env:Path;$binPath"
    }
}

Write-Host "`n== Installing CLI toolchain ==`n" -ForegroundColor Yellow
foreach ($pkg in $wingetPackages) {
    Install-WingetPackage -Id $pkg.Id -Command $pkg.Command -Scope $pkg.Scope
}
Install-Istioctl

Write-Host "`n== Docker Desktop / WSL2 (manual, requires Administrator) ==`n" -ForegroundColor Yellow
$dockerOk = [bool](Get-Command docker -ErrorAction SilentlyContinue)
if (-not $dockerOk) {
    Write-Host "[missing] Docker Desktop was not found. Install it yourself from an elevated" -ForegroundColor Red
    Write-Host "          PowerShell window: 'choco install docker-desktop -y', then launch it" -ForegroundColor Red
    Write-Host "          once and confirm the WSL2 backend is enabled." -ForegroundColor Red
}

Write-Host "`n== Version summary ==`n" -ForegroundColor Yellow
$checks = [ordered]@{
    "git"       = { git --version }
    "gh"        = { gh --version | Select-Object -First 1 }
    "terraform" = { terraform -version | Select-Object -First 1 }
    "kubectl"   = { kubectl version --client --output=yaml 2>$null | Select-String "gitVersion" }
    "kind"      = { kind version }
    "helm"      = { helm version --short }
    "istioctl"  = { istioctl version --remote=false }
    "python"    = { python --version }
    "node"      = { node -v }
    "docker"    = { docker --version }
}

foreach ($name in $checks.Keys) {
    try {
        $output = & $checks[$name]
        Write-Host ("{0,-10} {1}" -f $name, $output) -ForegroundColor Green
    } catch {
        Write-Host ("{0,-10} NOT AVAILABLE" -f $name) -ForegroundColor Red
    }
}

Write-Host "`nIf any tool shows NOT AVAILABLE, open a new terminal (PATH changes need a fresh" -ForegroundColor Yellow
Write-Host "session to take effect) and re-run this script." -ForegroundColor Yellow
