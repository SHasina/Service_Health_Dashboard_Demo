# Service Health Dashboard

A service health monitoring platform: a FastAPI backend concurrently health-checks a set of
downstream services and a React/TypeScript frontend renders their status, latency, and failure
reason in real time.

| Service         | Status | Details  |
|------------------|--------|----------|
| user-service     | UP     | 120 ms   |
| order-service    | DOWN   | Timeout  |
| payment-service  | UP     | 85 ms    |

This repository goes beyond the minimal exercise to demonstrate a production-style DevSecOps
delivery pipeline: containerized services, a local Kubernetes deployment (kind) behind an Istio
service mesh, infrastructure managed with Terraform, and a shift-left security pipeline in GitHub
Actions. See `ARCHITECTURE.md` for design decisions, `SECURITY.md` for the shift-left/security
narrative, and `docs/DEMO_GUIDE.md` for a full presentation walkthrough (business context,
architecture, a file-by-file codebase tour, and a PowerPoint version).

## Prerequisites

| Tool | Version used | Install |
|---|---|---|
| Python | 3.12 | `scripts/install-prereqs.ps1` |
| Node.js | 20 LTS | `scripts/install-prereqs.ps1` |
| Docker Desktop | latest, WSL2 backend | manual (requires Administrator) |
| git, GitHub CLI | latest | `scripts/install-prereqs.ps1` |
| kubectl, kind, Helm, Terraform | latest | `scripts/install-prereqs.ps1` |
| istioctl | pinned in the script | `scripts/install-prereqs.ps1` |

Run `./scripts/install-prereqs.ps1` from an ordinary PowerShell window. Docker Desktop and WSL2
need Administrator privileges and a one-time interactive setup, so those two are not automated —
the script tells you if either is missing.

## Quick start: docker-compose

The fastest way to see the whole system running:

```powershell
docker compose up --build
```

- Frontend: http://localhost:8080
- Backend API: http://localhost:8000/api/health

`order-service` is intentionally configured to respond slowly (`MOCK_MODE=slow`) so the dashboard
demonstrates a real timeout/DOWN state out of the box. Stop any mock container to see its row
change live; refresh from the dashboard's Refresh button or stop the backend entirely to see the
"backend unavailable" state.

## Full stack: kind + Terraform + Istio

```powershell
./scripts/create-cluster.ps1   # creates the local kind cluster
./scripts/deploy.ps1           # builds images, loads them into kind, applies Terraform
./scripts/verify.ps1           # checks pod status, runs istioctl analyze, port-forwards the UI
```

Then open http://localhost:8080. Tear down with `./scripts/delete-cluster.ps1`.

## Common commands

| Command | Purpose |
|---|---|
| `./scripts/install-prereqs.ps1` | Install/verify the local toolchain |
| `./scripts/create-cluster.ps1` | Create the local kind cluster |
| `./scripts/delete-cluster.ps1` | Delete the local kind cluster |
| `./scripts/deploy.ps1` | Build, load, and deploy the app + Istio to kind |
| `./scripts/verify.ps1` | Smoke-test the deployment |
| `docker compose up --build` | Run the whole stack locally without Kubernetes |
| `cd backend; pytest --cov=app` | Run backend unit tests |
| `cd frontend; npm run test` | Run frontend unit tests |
| `cd infra/terraform; terraform plan -var-file=envs/local/terraform.tfvars` | Preview infrastructure changes |

## Repository layout

```
backend/            FastAPI health-check service
frontend/           React/TypeScript dashboard
services/mock-service/  Single parameterized mock for user/order/payment-service
infra/kind/         Local Kubernetes cluster definition
infra/terraform/    Namespace, workload, and Istio mesh IaC
scripts/            PowerShell automation for the workflows above
docs/               Presentation material: demo guide and slide deck
.github/            CI/CD: lint, tests, security scanning, image build + SBOM
```

## License

MIT — see `LICENSE`.
