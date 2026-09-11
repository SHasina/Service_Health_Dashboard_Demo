# Security approach

This project treats the take-home exercise as an opportunity to demonstrate a shift-left security
pipeline end to end, not just an application. Every gate below runs before anything is deployed,
and each one is chosen so that a real finding fails the build rather than merely getting logged.

## Shift-left pipeline (`.github/workflows/`)

| Stage | Tool | Gate | Why here, not later |
|---|---|---|---|
| Lint / type-check | ruff, black, mypy, eslint | `ci.yml` | Cheapest possible signal; catches whole classes of bugs before any code runs. |
| Secret scanning | gitleaks | `security-scan.yml` | A committed credential is a security incident regardless of what the code does; must be caught at commit/PR time, not at deploy time. |
| SAST | Semgrep, Bandit | `security-scan.yml` | Static analysis finds injection, unsafe deserialization, and similar classes of bug without needing a running system. |
| SCA (dependency scanning) | pip-audit, npm audit, Dependabot | `security-scan.yml` | Most real-world breaches trace back to a known-vulnerable dependency, not novel code. Dependabot keeps the baseline moving; pip-audit/npm audit gate each PR. |
| IaC scanning | tfsec | `security-scan.yml` | A misconfigured NetworkPolicy or overly permissive RBAC role is a production incident waiting to happen; catching it in the Terraform plan is orders of magnitude cheaper than catching it in the cluster. |
| Kubernetes manifest linting | kube-linter | `security-scan.yml` | Flags missing resource limits, privileged containers, and other manifest-level anti-patterns that IaC scanners aimed at Terraform HCL don't cover. |
| Container image scanning | Trivy | `docker-build-scan.yml` | Scans the actual built artifact — including OS packages pulled in at build time, not just application dependencies — and fails the build on HIGH/CRITICAL findings. |
| SBOM generation | Syft | `docker-build-scan.yml` | Produces a Software Bill of Materials per image as a build artifact, supporting downstream vulnerability re-scanning and license auditing without rebuilding. |
| Tests | pytest, vitest | `ci.yml` | Functional correctness is itself a security property here: a health checker that silently swallows a timeout is a monitoring blind spot. |

All third-party GitHub Actions are pinned to a specific released version, never `@main` or a
floating `@latest`, to avoid an upstream action compromise silently changing pipeline behavior.

**A scoping decision on the frontend SCA gate**: `npm audit` runs with `--omit=dev` in CI. At the
time of writing, the only findings in `frontend/` are in the `vite`/`vitest`/`esbuild` dev-tooling
chain (moderate-to-critical advisories that affect the local Vite dev server's request handling,
not the static assets actually shipped in the built, deployed image). Failing every build on a
dev-only advisory that requires a major-version upgrade of the whole test toolchain would train
the team to ignore red builds rather than fix real risk. Dependabot still tracks and proposes
upgrades for these packages; the CI gate is scoped to what a production audit should actually
block on. This tradeoff is intentional and documented here rather than silently suppressed.

**A scoping decision on the container image scan gate**: Trivy runs with `ignore-unfixed: true`.
The base images (`python:3.12-slim`, `nginx:1.27-alpine`) carry a handful of HIGH/CRITICAL
findings in OS packages incidental to running a Python or nginx process (`util-linux`, `perl`,
`systemd` libraries) that the upstream distribution has not shipped a fix for yet - Trivy itself
reports these with no fixed version at all. Failing the build on a CVE nobody can currently patch
does not reduce risk; it just trains the team to treat a red build as normal. Any finding that
*does* have an available fix still fails the build immediately. This is the same triage principle
applied to the SCA gate above: block on what is actionable, track and document what isn't.

## Why deployment isn't a CI job

`docker-build-scan.yml` builds and scans images; nothing in this repository's CI deploys to the
local kind cluster. A GitHub-hosted runner cannot reach a cluster running inside Docker Desktop on
a personal laptop, and a self-hosted runner on the same machine would blur the line between "CI
validated this" and "CD to a machine only the developer controls." `scripts/deploy.ps1` is a
deliberate, documented local step. In a real deployment target (a shared or cloud cluster), the
natural next step is either a self-hosted runner with network access to that cluster, or a GitOps
agent (Argo CD, Flux) pulling from a container registry that this pipeline would push signed,
scanned images to.

## Runtime security controls (cluster + mesh)

- **Pod Security Standards**: the `health-dashboard` namespace enforces the `restricted` profile
  (`infra/terraform/modules/namespace`).
- **Least-privilege identity**: each workload (backend, frontend, mocks) runs under its own
  `ServiceAccount` with `automountServiceAccountToken` disabled, used both for Kubernetes RBAC
  scoping and as the Istio mTLS identity that `AuthorizationPolicy` rules match against.
- **Default-deny network posture**: NetworkPolicies deny all ingress/egress by default and allow
  only the specific paths the application needs (frontend → backend, backend → mocks, DNS
  egress). See `ARCHITECTURE.md` for the honest caveat about enforcement on kind's default CNI.
- **Mutual TLS**: `PeerAuthentication` set to `STRICT` in the mesh namespace — every in-mesh
  connection is encrypted and mutually authenticated, independent of the NetworkPolicy layer.
- **Identity-based authorization**: Istio `AuthorizationPolicy` resources enforce the same
  allow-list as the NetworkPolicies, but at request time using cryptographically verified
  workload identity rather than IP-based rules.
- **Rate limiting**: an `EnvoyFilter` installing Envoy's local rate limiter protects the backend's
  aggregate health endpoint from being overwhelmed by a misbehaving or malicious client.
- **Traffic policy and circuit breaking**: a `DestinationRule` on the backend adds outlier detection
  (ejecting an unhealthy instance after 3 consecutive 5xx responses) and connection pool limits, so
  a struggling replica is automatically pulled out of rotation rather than continuing to receive
  traffic. Effect is currently latent — the backend runs a single replica by design, so there is
  nothing to eject to yet — but the policy is real, applied config, not a placeholder.
- **No hardcoded secrets**: this application has none to store yet, but the pattern is
  established — GitHub Actions secrets for CI-time credentials, and gitleaks as a backstop against
  anything landing in the repository by accident.

## Mapping to a Well-Architected-style review

- **Security**: covered throughout this document — shift-left scanning, mTLS, least privilege,
  default-deny networking, rate limiting.
- **Reliability**: liveness/readiness probes on every workload, resource requests/limits to avoid
  noisy-neighbor eviction (single-node kind here given this host's memory budget - see
  `ARCHITECTURE.md`), and a health checker that degrades gracefully (per-service failure never
  blocks the others, thanks to
  `asyncio.gather`).
- **Operational excellence**: structured JSON logging, everything as code (Terraform, kind config,
  CI pipelines), and a documented two-path deployment story (compose for fast iteration, kind for
  the real target) so there is always a way to verify a change.
- **Performance efficiency**: concurrent, timeout-bounded health checks instead of sequential
  polling; slim multi-stage container images; async I/O throughout the backend.
- **Cost optimization**: minimal base images, explicit resource requests/limits so the local
  cluster (and, by extension, a real one) never over-provisions per workload — evaluated here
  through the lens of resource efficiency, since this project runs entirely on local infrastructure
  rather than billed cloud capacity.
