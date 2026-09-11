# Demo Guide: Service Health Dashboard

This document is written to be talked from, live, for a roughly 30-minute interview demo. It
covers the business case, the architecture, a file-by-file walkthrough of the codebase, the
infrastructure and CI/CD pipeline, the operational issues actually hit while building this, and a
step-by-step run sheet. Where a question is likely to come up mid-demo ("why Istio for something
this small," "kind vs Docker Hub," "why localhost") there is a dedicated section written as a
direct answer, not just background reading.

Companion documents in this repository: `ARCHITECTURE.md` (design decisions and tradeoffs),
`SECURITY.md` (the shift-left pipeline and runtime security controls), `README.md` (setup and
commands), and `docs/Service-Health-Dashboard-Deck.pptx` (a 16-slide presentation covering the same
material, for talking through without a terminal open).

---

## 1. Prerequisites and installation

| Tool | Version used | How it's installed |
|---|---|---|
| Python | 3.12 | `scripts/install-prereqs.ps1` (winget) |
| Node.js | 20 LTS | `scripts/install-prereqs.ps1` (winget) |
| git, GitHub CLI | latest | `scripts/install-prereqs.ps1` (winget) |
| kubectl, kind, Helm, Terraform | latest | `scripts/install-prereqs.ps1` (winget) |
| istioctl | 1.23.2, pinned | `scripts/install-prereqs.ps1` (direct download - no winget package exists) |
| Docker Desktop, WSL2 backend | latest | Manual, requires Administrator |

**Step 1 - Docker Desktop (manual, one-time)**: install Docker Desktop for Windows with the WSL2
backend enabled. This step is intentionally not automated: it requires Administrator privileges and
an interactive first-run/license step that a script can't safely do unattended. Confirm it's
working with `docker info`.

**Step 2 - everything else (automated)**:

```powershell
./scripts/install-prereqs.ps1
```

This is idempotent - it checks each tool with `Get-Command` before installing, so re-running it
after a partial setup only fills in what's missing. It installs the CLI toolchain via `winget`,
downloads and unzips `istioctl` directly from GitHub Releases (pinned to 1.23.2, since no winget
package exists for it) and adds it to your user `PATH`, then prints a version summary so you can
see at a glance what's present and what isn't. If anything prints `NOT AVAILABLE`, open a **new**
terminal (PATH changes need a fresh shell) and re-run the script.

**Step 3 - clone and verify**:

```powershell
git clone https://github.com/SHasina/Service-Health-Dashboard.git
cd Service-Health-Dashboard
docker info        # confirm Docker Desktop is actually running
```

From here, either `docker compose up --build` (fastest path, no Kubernetes) or the full
kind+Terraform+Istio stack in section 15 below.

## 2. Business case: what problem is this solving

Any system built from more than one service has a moment where "is everything up?" stops being a
question a person can answer by memory. The scenario here is deliberately ordinary: a backend that
depends on three downstream services (`user-service`, `order-service`, `payment-service`), and the
need for one place that says, right now, which of them are healthy, how slow they are, and why a
failing one is failing.

The two things this exercise is actually testing are:

1. **Can the candidate build a small, correct, well-tested service** that does concurrent
   health-checking with proper timeout handling and doesn't collapse different failure modes into
   one useless "error" state.
2. **Can the candidate reason about the platform the service runs on** — containerization,
   orchestration, service-to-service security, and a CI/CD pipeline that actually gates on
   security findings rather than only running tests.

Everything past the FastAPI backend and React frontend — kind, Terraform, Istio, the three-workflow
GitHub Actions pipeline — exists to answer the second question, deliberately, because a DevSecOps
role is being evaluated on platform judgment as much as application code.

---

## 3. Architecture, end to end

```
Browser
   |
   v
frontend (nginx : 8080)  -- static React build + reverse proxy for /api/*
   |
   v
backend (FastAPI : 8000)  -- concurrent health checks, 5s timeout each
   |         |         |
   v         v         v
user-service  order-service  payment-service   (one mock image, 3 instances)
```

Everything below the frontend/backend/mocks line runs inside a single-node **kind** (Kubernetes
IN Docker) cluster, wrapped in an **Istio** service mesh, provisioned by **Terraform**, built and
scanned by a three-workflow **GitHub Actions** pipeline. Two deployment paths exist side by side:
`docker compose up` for a 30-second local run with zero orchestration, and the full kind+Istio
stack for the platform story.

---

## 4. Frontend — file by file

**`frontend/src/main.tsx`** — the React entry point; mounts `<App />` into `#root`. Nothing
notable, standard Vite/React bootstrap.

**`frontend/src/App.tsx`** — the entire application state lives here as one discriminated union:

```ts
type LoadState =
  | { status: "loading" }
  | { status: "loaded"; services: ServiceHealth[]; checkedAt: string }
  | { status: "error"; message: string };
```

This is the one design choice worth calling out unprompted: instead of `isLoading` / `isError` /
`data` as three separate booleans/values (which lets you represent nonsense states like "loading
AND error at once"), the state is one value that can only ever be exactly one of three shapes.
`load()` calls the backend, and on failure narrows the error into a `BackendUnavailableError` with
a specific message rather than a generic "something went wrong." `useEffect` fires `load()` once on
mount; the refresh button calls the same function again.

**`frontend/src/api/healthClient.ts`** — `fetchHealth()` wraps `fetch("/api/health")` and turns
three distinct failure modes into one `BackendUnavailableError`: the network call itself throwing
(backend unreachable), a non-2xx response (backend up but erroring), and a response body that
doesn't parse as JSON (backend up but returning garbage). Three different root causes, one clear
user-facing state — this is the frontend's version of the same "classify, don't collapse" principle
the backend applies to downstream failures.

**`frontend/src/components/`** — four small, single-purpose components:
- `ServiceTable.tsx`: renders the array of services; `formatDetails()` shows latency in ms for an
  UP service, or the failure detail (falling back to "Unknown error") for a DOWN one.
- `StatusBadge.tsx`: a `<span>` colored by `status-up`/`status-down` CSS class — no logic beyond a
  ternary.
- `RefreshButton.tsx`: a controlled button; disabled and relabeled "Refreshing..." while a request
  is in flight, so a user can't fire a second overlapping request.
- `BackendUnavailableBanner.tsx`: `role="alert"` on the wrapping `div` — the one accessibility
  detail in the app, so screen readers announce it immediately rather than a sighted-only user
  noticing a color change.

**`frontend/src/types/health.ts`** — the TypeScript mirror of the backend's Pydantic
`HealthReport`/`ServiceHealth` models. There's no runtime schema validation on the frontend
(no Zod, no io-ts) — the contract is trusted because both sides are written and deployed together
in this repo; the honest caveat is that a truly untrusted or independently-versioned backend would
need runtime validation at this boundary too.

**`frontend/nginx.conf`** — two responsibilities: serve the built static assets with a
`try_files $uri /index.html` SPA fallback (so a browser refresh on any route still resolves to
`index.html`), and reverse-proxy `/api/` to `http://backend:8000/api/`. This is *why* the browser
never needs to know the backend's network address — the Docker Compose service name / Kubernetes
Service name `backend` resolves via each environment's own DNS, and the browser only ever talks to
its own origin.

**`frontend/vite.config.ts`** — configures the React plugin, a dev-server proxy (so `npm run dev`
behaves like production nginx without needing nginx locally), and Vitest (`jsdom` environment,
global test functions, a setup file).

**Tests** (`frontend/tests/`): `ServiceTable.test.tsx` asserts the table renders the right status
text and latency formatting for a mixed UP/DOWN input; `healthClient.test.ts` asserts each of the
three `BackendUnavailableError` paths actually fires for the right underlying cause.

---

## 5. Backend — file by file

**`backend/app/main.py`** — builds the FastAPI app. The one thing worth narrating live: service
configuration is loaded **once**, in the `lifespan` context manager, not per-request —
`app.state.services` and `app.state.settings` are set at startup. CORS is restricted to a
configured origin list (`allow_methods=["GET"]`) rather than left open.

**`backend/app/config.py`** — `Settings` (Pydantic `BaseSettings`) reads everything from
environment variables with typed defaults: `services_config_path`, `health_check_timeout_seconds`
(default 5.0 — this is the number that actually matters for the whole demo), `cors_allow_origins`,
`log_level`. `load_service_registry()` reads a YAML file into a list of `ServiceConfig` (`name` +
`url: HttpUrl`, so a malformed URL fails fast at startup, not mid-request).

**`backend/app/models.py`** — three Pydantic models: `ServiceConfig` (input), `ServiceHealth`
(`status: Literal["UP", "DOWN"]`, optional `latency_ms`, optional `detail`), and `HealthReport`
(the list plus a `checked_at` timestamp generated at construction time). Because these are
Pydantic models wired to `response_model=HealthReport` on the route, FastAPI validates and
documents the response shape automatically — this is what generates the OpenAPI schema for free.

**`backend/app/health_checker.py`** — the actual core logic, and the part worth walking through
line by line in the demo:

```python
async def check_service(client, service, timeout_seconds) -> ServiceHealth:
    start = time.perf_counter()
    try:
        response = await client.get(str(service.url))
        latency_ms = (time.perf_counter() - start) * 1000
        response.raise_for_status()
        return ServiceHealth(name=service.name, status="UP", latency_ms=round(latency_ms, 1))
    except httpx.TimeoutException:
        return ServiceHealth(name=service.name, status="DOWN", detail="Timeout")
    except httpx.ConnectError:
        return ServiceHealth(name=service.name, status="DOWN", detail="Connection refused")
    except httpx.HTTPStatusError as exc:
        return ServiceHealth(name=service.name, status="DOWN", detail=f"HTTP {exc.response.status_code}")
    except httpx.RequestError:
        return ServiceHealth(name=service.name, status="DOWN", detail="Request failed")
```

Four distinct exception types map to four distinct, operator-meaningful `detail` strings, instead
of one bare `except Exception: status = "DOWN"`. Timeout and connection-refused look identical from
a naive try/except, but they mean different things operationally (a Timeout suggests the service is
overloaded or network-partitioned; Connection refused suggests the process isn't listening at all).

```python
async def check_all_services(services, timeout_seconds) -> list[ServiceHealth]:
    async with httpx.AsyncClient(timeout=timeout_seconds) as client:
        results = await asyncio.gather(
            *(check_service(client, service, timeout_seconds) for service in services)
        )
    return list(results)
```

`asyncio.gather` fires all checks concurrently, so the total wall time for the whole `/api/health`
call is bounded by the *slowest single check* (5 seconds, worst case), not the sum of all three —
that's the difference between a 5-second dashboard load and a 15-second one, and it's also what
makes one failing service unable to block the others from reporting.

**`backend/app/routers/health.py`** — the actual `/api/health` endpoint; five lines, all of them
just wiring: pull `services` and the timeout off app state, call `check_all_services`, return a
`HealthReport`.

**`backend/app/routers/probes.py`** — `/healthz` (liveness: "is the process alive," always returns
200) and `/readyz` (readiness: "have I loaded config," returns 503 if `app.state.services` isn't
populated yet). This split matters in Kubernetes: a liveness-probe failure gets the container
*killed and restarted*; a readiness-probe failure just pulls it out of the Service's load-balancing
rotation. Conflating the two means a slow-to-configure pod gets killed instead of just
temporarily skipped, which is strictly worse.

**`backend/app/logging_config.py`** — a custom `JsonFormatter` so every log line is structured JSON
(timestamp, level, logger, message, plus any `extra_fields`) rather than free-text — this is what
makes the logs greppable/queryable in a real log aggregator (Loki, CloudWatch Logs Insights,
Splunk) instead of needing regex parsing.

**`backend/config/services.yaml`** — the default, bare-metal service registry, pointing at
`localhost:8001/8002/8003` — this is what a `pytest`/local `uvicorn` run without Docker uses.
Docker Compose overrides this with `services.docker-compose.yaml` (container hostnames); the
Kubernetes deployment doesn't use this file at all — the ConfigMap in
`infra/terraform/modules/app/main.tf` generates the registry directly from Terraform's
`mock_services` map, so the three environments each get a config file shaped correctly for how DNS
actually resolves in that environment.

**Tests** (`backend/tests/`): `test_health_checker.py` uses `respx` to mock each of the four HTTP
outcomes and asserts the resulting `status`/`detail`, plus a mixed-results test proving one DOWN
service doesn't affect the others' results; `test_health_endpoint.py` and `test_probes.py` test the
routes themselves through FastAPI's test client.

---

## 6. Mock service

One FastAPI app (`services/mock-service/app/main.py`), 22 lines, deployed three times under three
names. A single `GET /health` route branches on the `MOCK_MODE` environment variable: `healthy`
returns 200 immediately, `error` raises a 500, `slow` sleeps `MOCK_DELAY_SECONDS` (default 8, which
is deliberately longer than the backend's 5-second client timeout) before returning 200. This one
image reused three times, parameterized purely by env vars, is what makes the exercise's three
named services deterministic and demo-safe instead of depending on flaky public endpoints — you can
make `order-service` "go down" on command by changing one environment variable, with no code
change.

---

## 7. Infrastructure — Terraform

Terraform manages three things, split into modules under `infra/terraform/modules/`:

- **`namespace`** — creates the `health-dashboard` namespace with
  `pod-security.kubernetes.io/enforce: restricted` and the `istio-injection: enabled` label.
- **`app`** — per-workload `ServiceAccount`s (with `automountServiceAccountToken = false`),
  `Deployment`s (one replica each, explicit `resources.requests`/`limits`, and full pod/container
  `security_context` blocks satisfying the Restricted Pod Security Standard: non-root, numeric
  UID/GID, no privilege escalation, all Linux capabilities dropped, `seccompProfile: RuntimeDefault`),
  `Service`s, a `ConfigMap` for the backend's service registry, and `NetworkPolicy` resources
  (default-deny plus an explicit allow-list for every real traffic path).
- **`istio`** — `helm_release` resources for `istio-base` (CRDs), `istio-cni` (traffic redirection
  DaemonSet), `istiod` (control plane), and `istio-ingressgateway` (mesh edge, `ClusterIP` here
  since kind has no LoadBalancer controller); plus a `local-exec` provisioner applying the mesh's
  custom resources (`Gateway`, `VirtualService`, `PeerAuthentication`, `AuthorizationPolicy`,
  `EnvoyFilter`) via `kubectl apply` — Terraform's `kubernetes_manifest` resource can't resolve a
  CRD schema that doesn't exist yet on a first-ever apply, so shelling out after the Helm releases
  succeed sidesteps that ordering problem.

**Providers**: `hashicorp/kubernetes` and `hashicorp/helm` only — there is no cloud provider block.
This is entirely local infrastructure, talking to kind through your kubeconfig context.

**State**: local (`terraform.tfstate`, gitignored). See section 11 ("Why localhost, and the state
question") for how to talk about this in an interview — the short version is: don't avoid the
topic, raise the tradeoff yourself.

---

## 8. Istio — what's actually implemented, and why it's here at all

**"Isn't this overkill for three mock services?"** is a fair question to expect, and the honest
answer has two parts. First: the exercise explicitly asks for rate limiting, and Istio is the
realistic way a platform team would deliver rate limiting, mutual TLS, and identity-based
authorization together from one control plane, rather than three separate bespoke mechanisms.
Second, and more important for an interview: **the value being demonstrated is the ability to
reason about and operate a service mesh under real constraints** — Pod Security Standards, network
policy interaction, certificate lifecycle — not that this specific three-service demo *needs* a
mesh at its current scale. In a real system, the trigger for adopting Istio is usually "we have
enough services that consistent mTLS/authz/observability by hand becomes unmanageable," and it's
worth saying that plainly rather than justifying it as necessary for three pods.

What's actually running:

| Component | What it does here |
|---|---|
| `istio-base` | Installs the mesh CRDs |
| `istiod` | Control plane: pushes Envoy config (xDS) to every sidecar, and issues short-lived mTLS certificates as the mesh's CA |
| `istio-cni` | Node-level DaemonSet that redirects pod traffic into the sidecar via CNI chaining, instead of a privileged per-pod init container (required here because the namespace's Restricted PSA rejects the privileged alternative) |
| `istio-ingressgateway` | Dedicated edge Envoy proxy (`ClusterIP`, no cloud LB on kind) |
| `PeerAuthentication` (`default`, STRICT) | Every in-mesh connection must be mutually authenticated and encrypted |
| `PeerAuthentication` (`frontend-nodeport`) | Port-level exception: frontend:8080 is PERMISSIVE, because the external NodePort client has no sidecar and can't originate mTLS |
| `AuthorizationPolicy` (x4) | Identity-based allow-list: only `sa/frontend` may call the backend; only `sa/backend` may call each mock — checked against a cryptographically verified SPIFFE identity, not an IP |
| `EnvoyFilter` (local rate limit) | Token bucket (20 requests / 10 seconds) on the backend's inbound Envoy listener |
| `DestinationRule` (`backend`) | Outlier detection (ejects an instance after 3 consecutive 5xx responses) plus connection pool limits (50 max TCP connections, 20 max pending HTTP requests) on calls to the backend |

**On the `DestinationRule` specifically**: it's real, applied config, not a demo prop — but with the
backend intentionally running a single replica (see the incidents list in section 13), outlier
detection has nothing to eject *to* right now. Its value is fully realized the moment backend scales
beyond one replica; until then it's correctly-configured insurance rather than something you can
show actively triggering. Worth saying exactly that if asked to demonstrate it live, rather than
implying it's doing something today that it isn't.

**mTLS certificate lifetime** is worth a proactive mention if the demo runs across multiple
sessions: Istio's default workload certificate TTL is 24 hours, and this was actually hit live
during development — the mesh had been up longer than 24h, sidecars' certificates expired with no
visible re-issuance in the logs, and every in-mesh call started failing with connection resets. The
fix was setting `meshConfig.defaultConfig.proxyMetadata.SECRET_TTL: "168h"` on the `istiod` Helm
release (the `DEFAULT_WORKLOAD_CERT_TTL` env var some documentation points to does not reliably take
effect; `SECRET_TTL` in `proxyMetadata` is the value the istio-agent actually honors when requesting
a certificate). This is a genuinely good "issue I hit and fixed" story for the demo — see section 12.

---

## 9. CI/CD — GitHub Actions

Three workflows, all in `.github/workflows/`, all gating (a real finding fails the build, it
doesn't just log a warning):

**`ci.yml`** — backend: `ruff` (lint) -> `black --check` (format) -> `mypy` (types) -> `pytest
--cov`. Frontend: `eslint` -> `npm run build` -> `vitest run`.

**`security-scan.yml`** — five jobs: `gitleaks` (secret scanning, full git history); `Semgrep` +
`Bandit` (SAST); `pip-audit` (both Python services) + `npm audit --omit=dev --audit-level=high`
(dependency scanning); `tfsec` (Terraform IaC scanning); `kube-linter` (Kubernetes manifest
linting).

**`docker-build-scan.yml`** — matrix build of all three images, Trivy scan
(`severity: HIGH,CRITICAL`, `exit-code: 1`, `ignore-unfixed: true`), then an SPDX SBOM per image via
Syft, uploaded as a build artifact.

**`dependabot.yml`** — weekly updates across five ecosystems: pip (both Python services), npm,
Terraform, GitHub Actions, and Docker (all three images).

Every third-party Action is pinned to an exact released version (never `@main`/`@latest`) so an
upstream Action compromise can't silently change pipeline behavior. Two scoping decisions are
documented, not silent: `npm audit --omit=dev` (the only current findings are in the
vite/vitest/esbuild dev-tooling chain, which never ships in the built image) and Trivy's
`ignore-unfixed: true` (the base images carry a few HIGH/CRITICAL OS-package CVEs with no upstream
fix available yet — failing the build on those forever trains a team to ignore red builds; anything
with a real fix still blocks immediately). Both tradeoffs are written out in `SECURITY.md`.

**What's deliberately not here**: nothing in this pipeline deploys anywhere. A GitHub-hosted runner
cannot reach a kind cluster running inside Docker Desktop on a personal laptop. `scripts/deploy.ps1`
is a documented, deliberate local step; the natural evolution in a real environment is a
self-hosted runner with network access to the target cluster, or a GitOps agent (Argo CD/Flux)
pulling from a registry this pipeline would push signed, scanned images to.

---

## 10. Scripts

| Script | Purpose |
|---|---|
| `install-prereqs.ps1` | Idempotent local toolchain installer (winget for git/gh/terraform/kubectl/kind/helm/python/node; direct download for istioctl, since no winget package exists) |
| `create-cluster.ps1` | Creates the kind cluster from `infra/kind/kind-config.yaml` |
| `delete-cluster.ps1` | `kind delete cluster --name health-dashboard` |
| `deploy.ps1` | Builds all three images, `kind load docker-image`s them in, runs Terraform in two passes (namespace+app+Istio control plane, then mesh policies) |
| `verify.ps1` | Pod status, `istioctl analyze`, port-forwards the frontend Service for a manual check |

---

## 11. kind vs Docker Hub — a direct answer

This is worth pre-empting rather than waiting to be asked, because the two tools solve genuinely
different problems and it's an easy pair to conflate:

**Docker Hub is a container registry** — a place to store and distribute built images by name and
tag (`docker push`/`docker pull`). It has nothing to do with running containers; it's just storage
and distribution.

**kind is a way to run a real, multi-... (here, single-)node Kubernetes cluster, entirely inside
Docker containers on your own machine.** Each "node" in a kind cluster is itself a Docker container
that runs a full kubelet/containerd stack inside it, so kind gives you a real Kubernetes API server
to develop and test against without needing a cloud account.

**They're not a "test then promote" pipeline relative to each other** — that's the misconception
worth correcting directly. This project never uses Docker Hub at all: `scripts/deploy.ps1` builds
the three images locally and loads them directly into the kind cluster's containerd with
`kind load docker-image`, which copies the image straight from your local Docker daemon into the
cluster's nodes. No registry involved, no push, no pull.

**Where a registry *would* enter the picture**: the moment you have more than one machine that
needs the same image — a real multi-node cloud cluster, a CI runner and a production cluster that
are different machines — you need a shared place both can pull from, and that's what a registry
(Docker Hub, or more typically for a real deployment, a private registry like Amazon ECR, Google
Artifact Registry, or GitHub Container Registry) is for. `docker-build-scan.yml` already builds and
scans every image on every push; the natural next step for a real deployment is adding a `docker
push` step there, and switching the cluster's `imagePullPolicy` from `IfNotPresent` (local-only, as
now) to `Always` pointed at that registry.

---

## 12. Why localhost, and the state-file question

**Why localhost, not a real URL**: this cluster exists entirely inside Docker Desktop on one
laptop. There's no public IP, no DNS record, and no cloud load balancer — `kind-config.yaml` maps
the frontend's Kubernetes `NodePort` (30080) to `localhost:8080` on the host purely so a browser on
this machine can reach it. Getting a real DNS name/URL requires, in order: (1) a cluster that
actually runs somewhere with a routable address — a managed Kubernetes service (EKS/GKE/AKS) or any
VM with a public IP; (2) a `LoadBalancer`-type Service or Ingress controller that a cloud provider
can hand a real external IP to (kind has neither, which is exactly why the Istio ingress gateway
here is `ClusterIP` instead of its chart default of `LoadBalancer`); (3) a DNS record (Route 53,
Cloudflare, etc.) pointed at that IP; (4) a TLS certificate for that hostname, typically automated
via cert-manager and Let's Encrypt. None of that is meaningful to build for a take-home exercise
that's explicitly scoped to local infrastructure — but being able to name the exact chain above, on
request, is the signal an interviewer is actually checking for.

**Terraform state stored locally — is that against best practice?** Yes, as a general principle,
for infrastructure with more than one operator or any production weight, for four concrete reasons:
no locking (two concurrent applies can corrupt the state — this project actually hit an adjacent
failure mode, a Terraform process crash that truncated `terraform.tfstate` to zero bytes mid-write,
recovered from `terraform.tfstate.backup`); no shared visibility (nobody else can safely apply
against infrastructure whose only record lives on one laptop); no encryption-at-rest guarantee or
access control; no versioned history independent of Terraform's own last-known backup file.

**But for this project specifically, local state is the correct, deliberately scoped choice, not
an oversight** — there's no team and no cloud account behind this exercise, and no CI runner that
can even reach this cluster (the same reason there's no CD job). `ARCHITECTURE.md` says this
explicitly. The strong interview answer is to raise this tradeoff unprompted rather than avoid the
word "Terraform": *"State is local because this targets one local kind cluster with nobody else
touching it. The moment this touched shared or production infrastructure, before anything else, I'd
move to a remote backend with locking and encryption — S3 with DynamoDB locking and SSE-KMS, or
Terraform Cloud if I wanted policy-as-code and run approval on top — and I'd split state per
environment so a mistake in staging can't reach production's state."* Avoiding the topic would
remove the single strongest piece of IaC evidence in the repository; raising it yourself and naming
the exact remediation is a materially stronger answer than a project that silently already has a
remote backend wired up with no story behind it.

---

## 13. Issues actually hit while building this (a real "lessons learned" list)

These are genuine incidents from building and operating this stack, not hypothetical
"what could go wrong" filler — good material for "tell me about a problem you debugged":

1. **`kubernetes_network_policy_v1` used `port {}` blocks instead of `ports {}`** — a Terraform
   provider schema mismatch that silently existed until the very first `terraform apply`, which
   failed with "Unsupported block type." Fixed by correcting the block name across six resources.
2. **Every pod failed PodSecurity admission** — the namespace enforces the Restricted Pod Security
   Standard, but the Deployments had no `security_context` at all. Fixed by adding
   `run_as_non_root`, `seccomp_profile`, `allow_privilege_escalation = false`, and
   `capabilities.drop = ["ALL"]` to every pod and container.
3. **`runAsNonRoot` couldn't be verified** — even after adding `security_context`, pods still failed
   with "cannot verify user is non-root," because the Dockerfiles used a *named* user (`USER
   appuser`), and kubelet can't resolve a UID from an image without inspecting it. Fixed by pinning
   an explicit numeric UID/GID (10001) in each Dockerfile.
4. **A mock service crash-looped forever** — `order-service` runs `MOCK_MODE=slow` (an 8-second
   delay, deliberately longer than the backend's 5-second timeout, to demonstrate a real DOWN/
   Timeout row). Its own Kubernetes liveness probe hit that same slow `/health` endpoint with a
   1-second timeout, so kubelet killed the container as "unhealthy" every ~30 seconds — the demo
   feature and the pod's own health check were fighting each other. Fixed by switching the mock
   deployment's probes to TCP checks, decoupling pod liveness from the app-level simulated latency.
5. **Istio's ingress gateway hung Helm's install for its full timeout** — the `gateway` chart
   defaults to a `LoadBalancer` Service, which never gets an external IP on kind (no cloud LB
   controller), so `helm_release`'s wait-for-ready blocked until timing out. Fixed by pinning
   `service.type: ClusterIP`.
6. **Classic sidecar injection is fundamentally incompatible with the Restricted PSA** — Istio's
   `istio-init` container needs `NET_ADMIN`/`NET_RAW` capabilities and root to set up iptables
   redirection, which the namespace flatly rejects. Fixed by installing the `istio-cni` Helm chart
   and setting `istio_cni.enabled: true` on `istiod`, moving that redirection to a node-level
   DaemonSet so injected pods need no privileged init container at all.
7. **Sidecars couldn't reach `istiod`** — the namespace's default-deny `NetworkPolicy` blocked pod
   egress to `istio-system` entirely, so every sidecar timed out trying to fetch its initial
   certificate and config, staying `NotReady` forever. Fixed with an explicit egress rule to
   `istio-system` on TCP 15012/15010.
8. **STRICT mTLS blocked the one external entry point** — the frontend is reached via NodePort from
   outside the mesh, and an external client has no sidecar to originate mTLS with, so the
   namespace-wide `PeerAuthentication: STRICT` rejected it. Fixed with a per-port
   `PeerAuthentication` override (frontend:8080 -> PERMISSIVE) plus a matching NetworkPolicy ingress
   rule (default-deny blocks NodePort ingress too, independently of mTLS).
9. **Workload mTLS certificates expired mid-project** — see section 7; fixed with
   `SECRET_TTL: 168h` on `istiod`, which also surfaced that `DEFAULT_WORKLOAD_CERT_TTL` (a
   commonly-suggested env var) does not reliably work in this Istio release.
10. **Host memory exhaustion under a 3-node kind cluster** — Docker Desktop + a 3-node cluster +
    Istio's control plane + 5 app pods (each with a sidecar) repeatedly exceeded available RAM on
    this laptop, causing OOM kills and thrashing crash-loops whenever pods restarted together.
    Reduced the cluster to a single control-plane node (kind does not taint a lone control-plane
    node, so it stays schedulable) and, when restarting pods, brought them up one at a time instead
    of all at once, to avoid a simultaneous memory spike.
11. **A Terraform process crash corrupted local state twice** — an unrelated upstream Terraform 1.16.1
    bug panics while serializing state under certain long-running applies. Recovered both times from
    `terraform.tfstate.backup` rather than losing track of already-created resources. This is the
    live example used in section 11 for why remote state locking/versioning matters at scale.
12. **A second backend replica exposed a Kubernetes rollout deadlock, not a code bug** — added to try
    a second backend replica for the `DestinationRule`'s outlier detection to have something to eject
    from. The new pod's cold start repeatedly failed its first liveness checks under this host's CPU
    contention; diffed the "old" and "new" ReplicaSets' pod templates byte-for-byte and found them
    identical in `.spec` — the only difference was a stray `kubectl.kubernetes.io/restartedAt`
    annotation left on the old pod from a manual restart days earlier, which Terraform doesn't manage
    and therefore never reproduces. Because the default `RollingUpdate` strategy rounds
    `maxUnavailable` down to 0 at `replicas: 1`, the deployment could not retire the healthy old pod
    until the flaky new one proved ready — a genuine deadlock, not a hang. Root-caused by checking
    `kubectl describe pod` for the exact liveness-probe-kill signature (`Reason: Error`, exit 137,
    tied to explicit "failed liveness probe" events, not a silent OOM), confirming host memory stayed
    flat throughout (ruling out OOM), and diffing the ReplicaSets directly rather than guessing.
    Resolved by pinning the deployment's strategy to `maxUnavailable: 100%, maxSurge: 0` (a straight
    replace instead of a surge — see `infra/terraform/modules/app/main.tf`) and reverting the extra
    replica. This is arguably the best "tell me about a hard bug you debugged" story in the whole
    project: the fix wasn't a config error at all, it was recognizing a rollout *strategy* mismatch
    for a single-replica workload on a resource-constrained host.

---

## 14. Scalability, reliability, and what changes for a production-grade enterprise system

**What's already in place and would carry over unchanged**: concurrent, timeout-bounded health
checks (the core design is already horizontally efficient — checking 30 downstream services costs
the same wall time as checking 3, bounded by the slowest one); explicit resource requests/limits
per workload; readiness/liveness separated correctly; structured JSON logging; stateless services
(no database, no in-memory session state) so horizontal scaling is just changing `replicas`.

**What would need to change for real production scale**:

- **Replicas and autoscaling**: every Deployment here is pinned to `replicas = 1` by design (a
  single demo instance on a memory-constrained laptop). Production would set a real replica count
  behind a `HorizontalPodAutoscaler`, and a `PodDisruptionBudget` so a node drain or rolling update
  never takes the whole service to zero.
- **Multi-node, multi-AZ**: this is intentionally single-node right now for local resource reasons
  (see incident 10 above) — a production cluster would be multi-node across availability zones, with
  Kubernetes' own pod anti-affinity spreading replicas so a single node or AZ failure doesn't take
  out every instance of a service at once.
- **A real registry and image promotion**: local `kind load docker-image` only works because
  everything runs on one machine (see section 10) — production needs a registry, image signing
  (cosign), and an admission policy verifying signatures before a pod is scheduled.
- **Remote Terraform state with locking** — covered in section 11.
- **Observability beyond logs**: structured logs exist, but there's no metrics/tracing story yet —
  production would add Prometheus scraping (Istio's sidecars already expose Envoy metrics for free)
  and distributed tracing (Istio again makes this close to free via its tracing headers), plus
  alerting on the SLOs that actually matter (P99 latency of `/api/health`, error rate per
  downstream).
- **CD, not just CI**: as documented in `SECURITY.md`, nothing here deploys anywhere automatically.
  Production needs either a self-hosted runner with cluster network access or a GitOps agent
  (Argo CD/Flux) with automated promotion between environments and a real rollback story.
- **Secrets management**: there are no secrets to manage yet, but production would need a pattern
  established before one shows up — External Secrets Operator or a cloud KMS-backed secret store,
  not a Kubernetes `Secret` object typed in by hand (those are only base64-encoded, not encrypted,
  by default).
- **DNS, TLS, and a real ingress** — the full chain from section 11.

---

## 15. Where sensitive values live (and where they would go)

This application currently has no secrets to store — no database credentials, no API keys, no
tokens. That's an accurate, checkable fact, not an omission: `.gitignore` excludes `.env*` (except
the committed `.env.example` template), `*.tfstate*`, and `kubeconfig*.yaml`; `gitleaks` runs on
every push and PR against the full git history as a backstop; and there is nothing in the
Kubernetes manifests beyond a `ConfigMap` holding non-sensitive service URLs. If this application
needed a real secret tomorrow (a downstream API key, a database password), the pattern that's
already established but not yet needed would be: GitHub Actions repository/environment secrets for
CI-time credentials, and in-cluster, either a Kubernetes `Secret` synced from a real secret store
(External Secrets Operator pointed at AWS Secrets Manager / Azure Key Vault / HashiCorp Vault) or,
for a smaller footprint, Sealed Secrets — never a plaintext value committed to the repository or
typed directly into a raw Kubernetes `Secret` manifest.

---

## 16. Step-by-step demo run procedure

Run this before the interview starts, and again as the live walkthrough:

```powershell
# 1. Confirm Docker Desktop is running, then create the cluster
./scripts/create-cluster.ps1

# 2. Build the three images, load them into kind, apply Terraform (two-phase)
./scripts/deploy.ps1

# 3. Sanity-check pod status and the mesh
kubectl get pods -n health-dashboard -o wide
kubectl get peerauthentication,authorizationpolicy -n health-dashboard

# 4. Open the dashboard
# http://localhost:8080
```

**Live things to actually demo, in order**:

1. Load `http://localhost:8080` — show `user-service` and `payment-service` UP with a latency
   number, `order-service` DOWN with detail `Timeout`.
2. Hit Refresh — show the button disabling itself and the timestamp updating.
3. `kubectl scale deployment/user-service -n health-dashboard --replicas=0`, refresh the
   dashboard — show `user-service` flip to DOWN with `Connection refused` (a different `detail`
   string than the timeout case, proving the classification is real, not cosmetic). Scale it back
   to 1 afterward.
4. `kubectl exec` into any pod, show two containers (`kubectl get pod <name> -n health-dashboard -o
   jsonpath='{.spec.containers[*].name}'`) — narrate that the second one is the Istio sidecar, and
   that `kubectl get peerauthentication -n health-dashboard` shows STRICT mTLS is actually enforced,
   not just configured.
5. Show the three GitHub Actions workflows and point at one real, specific gate (e.g. the Trivy
   scan step) rather than describing the pipeline only in the abstract.
6. If time remains: open `infra/terraform/modules/app/main.tf` and show one `NetworkPolicy` plus
   its matching `AuthorizationPolicy`, and explain that they enforce the same allow-list at two
   different layers (L3/L4 IP-based vs L7 cryptographic identity).

## 17. Cluster teardown

```powershell
./scripts/delete-cluster.ps1
```
