# DevSecOps Learning Path
## SQL Injection Lab → Production-Grade Secure Microservices

**Audience:** This path is written for someone who is CISSP-certified with a strong infra/network background, understands identity well (SAML → now OAuth/OIDC), and wants to close the gap in application security, DevSecOps tooling, and cloud-native architecture.

**Anchor project:** This React/Node.js/PostgreSQL SQL Injection Lab — already containerised, running locally and in Codespaces, authenticated via Entra ID with OAuth Auth Code + PKCE.

---

## Where You Are Now ✅

- React SPA (Auth Code + PKCE via Entra ID)
- Node.js Express backend with secure and intentionally vulnerable REST + GraphQL endpoints
- PostgreSQL with schema/seed auto-initialised from dump on container startup
- Docker Compose orchestration — works on local Mac and GitHub Codespaces
- JWT validation via Entra JWKS endpoint, scope-based authorisation middleware
- Architecture documented (Architecture.md)

---

## The Full Path at a Glance

```
Phase 0  ✅  Containerised app, local + Codespaces
Phase 1      Git Workflow + Local Kubernetes (minikube)
Phase 2      Pipeline with Security Gates (GitHub Actions)
Phase 3      EKS on AWS with Terraform + Helm
Phase 4      API Security Layer (WAF + API Gateway)
Phase 5      Advanced DevSecOps (Policy-as-Code, Service Mesh, Supply Chain)
```

Each phase builds directly on the previous one using the same app — you are not throwing away work, you are layering security and operations on top of something that already runs.

---

## Phase 1 — Git Workflow + Local Kubernetes with minikube

### Part A — Git Branching Strategy and Parallel Development

#### What You Will Learn
Professional Git workflow is foundational to everything that follows — pipelines trigger on branches, security gates run on PRs, releases are tagged commits. Getting this right now means Phase 2 (CI/CD) slots in naturally on top of an already clean branching model.

#### Choosing a Branching Strategy

There are three common strategies. For a solo lab that will grow into a pipeline, **GitHub Flow** is the right choice — it is simple, maps cleanly to CI/CD, and scales well when you add automated gates.

**GitFlow** — two permanent branches (`main` and `develop`), plus `feature/`, `release/`, and `hotfix/` branches. Designed for scheduled release cycles. Adds overhead that is unnecessary until you have multiple teams or formal release cadences. Not recommended here.

**Trunk-based development** — everyone commits directly to `main`, with short-lived feature branches (hours, not days). Requires strong automated test coverage to work safely. Good end goal but premature at this stage.

**GitHub Flow** — this is what you will use. One permanent branch (`main`), short-lived `feature/` branches for all work, every change goes through a Pull Request before merging to `main`. Simple, auditable, and the natural fit for GitHub Actions pipelines.

```
main  ──────────────────────────────────────────► (always deployable)
         │                    ▲
         └─ feature/xxx ──────┘  (PR → review → merge)
```

#### Branch Naming Convention

Use a consistent prefix pattern — this becomes important when pipeline triggers use branch filters:

```
feature/   — new functionality        e.g. feature/add-user-profile
fix/       — bug fixes                e.g. fix/cors-header-missing
chore/     — non-functional changes   e.g. chore/update-dependencies
docs/      — documentation only       e.g. docs/update-architecture
k8s/       — infrastructure/K8s work  e.g. k8s/add-backend-deployment
```

#### Releases and Tagging

In GitHub Flow, a release is a **tag on main** — not a separate branch. After merging features and verifying the app works, you tag the commit:

```bash
git tag -a v1.0.0 -m "Phase 1 complete: K8s local deployment"
git push origin v1.0.0
```

Semantic versioning (`MAJOR.MINOR.PATCH`): increment MAJOR for breaking changes, MINOR for new features, PATCH for fixes. For a lab you can use `v0.x.x` until you consider it production-ready.

GitHub automatically creates a Release page from a tag — you can add release notes documenting what changed. This becomes the artefact your pipeline later promotes through environments.

#### Pull Requests as a Security Control

A PR is not just a code review mechanism — in a DevSecOps context it is a security gate. When you add the pipeline in Phase 2, every PR will automatically run SAST, SCA, and container scanning before a merge is allowed. You are establishing the habit now so the tooling slots in without changing your workflow.

Good PR hygiene:
- Keep PRs small and focused — one feature, one fix
- Write a meaningful PR description explaining *why*, not just *what*
- Link to any relevant issue or learning objective
- Review your own diff before merging (`git diff main...feature/your-branch`)

#### Practical Exercise — Parallel Development Across Two Environments

This exercise simulates real-world parallel development: two developers (you, on two different machines) working on separate features simultaneously, then merging both into a release.

**Setup — configure your identity on both environments if not already done:**
```bash
git config --global user.name "Your Name"
git config --global user.email "your@email.com"
```

**Feature 1 — on your local Mac:**

Pick a small, self-contained change. Good candidates for your lab:
- Add a `/health` endpoint to the backend (returns `{ status: "ok", timestamp: "..." }`) — useful for K8s liveness probes later
- Add a version number to the frontend home page
- Add a `CONTRIBUTING.md` documenting how to run the project locally

```bash
# On Mac, from your project directory
git checkout main
git pull origin main
git checkout -b feature/health-endpoint

# Make your change, then:
git add <files>
git commit -m "feat: add /health endpoint for K8s liveness probe"
git push origin feature/health-endpoint
```

Then open a Pull Request on GitHub: `feature/health-endpoint → main`.

**Feature 2 — in Codespaces:**

Pick a different small change:
```bash
# In Codespaces terminal
git checkout main
git pull origin main
git checkout -b feature/version-display

# Make your change, then:
git add <files>
git commit -m "feat: display app version on home page"
git push origin feature/version-display
```

Open a second Pull Request on GitHub: `feature/version-display → main`.

**Merge both PRs** (merge Feature 1 first, then Feature 2):

When merging Feature 2, Git may detect a conflict if both changes touched the same file. This is intentional — resolving merge conflicts is a core skill:

```bash
# If there's a conflict after merging Feature 1 into main:
git checkout feature/version-display
git pull origin main          # bring in the merged Feature 1
# resolve any conflicts in your editor
git add <resolved files>
git commit -m "chore: resolve merge conflict with feature/health-endpoint"
git push origin feature/version-display
# now the PR is clean to merge
```

**Tag the release:**
```bash
git checkout main
git pull origin main
git tag -a v0.2.0 -m "Phase 1a complete: parallel feature development and merge workflow"
git push origin v0.2.0
```

#### What This Teaches
By doing this exercise you will have experienced: branch isolation (changes on one branch don't affect the other), the PR review surface (you see the diff before it hits main), conflict resolution (the reality of parallel development), and release tagging (a named point in history you can always return to). Every subsequent phase assumes this workflow — pipelines trigger on PR, deploy on tag.

---

### Part B — Local Kubernetes with minikube

### What You Will Learn
Kubernetes is the de-facto container orchestration platform for microservices. Before you deploy to EKS (managed K8s on AWS), you need to be fluent with K8s primitives locally where iteration is fast and free. Everything you configure here maps directly to EKS — the API is identical.

### Key Concepts

**Pod** — the smallest deployable unit in K8s. Wraps one or more containers. Your `sqlinj-backend` container becomes a Pod.

**Deployment** — manages a desired number of Pod replicas, handles rolling updates and rollback. You declare "I want 2 replicas of the backend" and K8s ensures that is always true.

**Service** — stable network endpoint for a set of Pods. Pods come and go (they are ephemeral); a Service gives them a consistent DNS name and port. Equivalent concept to a load balancer target group.

**ConfigMap** — stores non-sensitive configuration as key-value pairs mounted into Pods as environment variables or files.

**Secret** — like ConfigMap but base64-encoded and with tighter RBAC. Important: base64 is not encryption. This is addressed in Phase 3 with proper secrets management.

**Namespace** — logical isolation boundary within a cluster. You would put your lab in a `sqlinj` namespace, keeping it separate from system components.

**Ingress** — HTTP/S routing rules at the cluster edge. Maps hostname/path to a Service. Requires an Ingress Controller (nginx-ingress is standard locally; AWS Load Balancer Controller on EKS).

**PersistentVolumeClaim (PVC)** — requests durable storage for stateful workloads like PostgreSQL, so data survives Pod restarts.

### Your App in K8s Terms

| Docker Compose service | K8s equivalent |
|---|---|
| `db` | Deployment + Service + PVC |
| `backend` | Deployment + Service |
| `frontend` | Deployment + Service |
| `ports:` mapping | Service NodePort or Ingress |
| `env_file: backend/.env` | Secret + ConfigMap |
| `depends_on:` | Init containers or readiness probes |

### What to Build
You already have `infra/EKS/k8s-manifests/` in your repo. Start by adapting those manifests for local minikube use (remove AWS-specific annotations, replace ECR image references with local builds via `minikube image load`).

1. Install minikube and kubectl
2. Deploy PostgreSQL with a PVC and a Kubernetes Secret for credentials
3. Deploy backend referencing the Secret as env vars
4. Deploy frontend
5. Configure nginx-ingress and access the app via a local hostname

### Security Focus in This Phase
- **Never use default namespace** — create `sqlinj` namespace and deploy there
- **Resource limits** — set CPU/memory limits on all containers; a container without limits can starve the node
- **Readiness and liveness probes** — K8s needs to know when your app is actually ready to serve traffic, not just started
- **Non-root containers** — add `runAsNonRoot: true` and `runAsUser: 1000` in your Pod security context; your backend Dockerfile should not run as root
- **Read-only root filesystem** — where possible, mount the filesystem as read-only and use `emptyDir` for writable paths

### Why This Matters Architecturally
Docker Compose is a single-host tool. Kubernetes is designed for multi-node, multi-tenant, self-healing workloads. The mental model shift is from "I run containers" to "I declare desired state and the control plane enforces it." This declarative model is what makes K8s security auditable — your security posture is in YAML, reviewable in Git, enforceable via policy.

---

## Phase 2 — CI/CD Pipeline with Security Gates

### What You Will Learn
A pipeline is not just automation — it is a security enforcement boundary. Every code change passes through security scans before it can reach any environment. This phase introduces SAST, SCA, DAST, container scanning, and image signing — the core toolset of application security in a DevSecOps context.

### Key Concepts

**SAST (Static Application Security Testing)** — analyses source code without running it, looking for vulnerable patterns (SQL injection, hardcoded secrets, insecure deserialization, etc.). Runs in seconds and provides feedback during a PR. Your `insecureRoutes.js` should light up on any SAST scanner.

**SCA (Software Composition Analysis)** — analyses your third-party dependencies (everything in `package.json`) for known CVEs. Your app pulls in Express, Apollo, Jose, jsonwebtoken — each of these has a release history and associated vulnerability disclosures. SCA tells you when a dependency you rely on is compromised.

**DAST (Dynamic Application Security Testing)** — attacks your running application the way a penetration tester would. Unlike SAST which reads code, DAST fires real HTTP requests, including payloads like `1 OR 1=1`. OWASP ZAP is the standard open-source tool. Your insecure endpoints should produce findings; your secure endpoints should not.

**Container Image Scanning** — analyses your Docker images layer by layer for OS-level CVEs (e.g. a vulnerable version of OpenSSL in the base image). Trivy is the leading open-source tool. Your `node:18` backend base image has a specific set of packages — some will have CVEs; scanning tells you which and at what severity.

**Image Signing (Cosign)** — cryptographically signs your container images after they pass scanning. Your deployment pipeline can then enforce that only signed images are deployed, preventing supply-chain attacks where an attacker substitutes a malicious image. This is part of the SLSA framework (Supply-chain Levels for Software Artifacts).

**Secrets Scanning** — scans commits and history for accidentally committed credentials. Your `backend/.env` is gitignored, but secrets scanning (Gitleaks, truffleHog) would catch it if it slipped through.

### Pipeline Architecture

```
Push / PR
    │
    ├── SAST (Semgrep)                 ← catches: SQLi patterns, hardcoded secrets
    ├── Secrets Scan (Gitleaks)        ← catches: committed .env, API keys
    ├── SCA (npm audit + Snyk)         ← catches: CVEs in dependencies
    │
    ├── Docker Build
    ├── Container Scan (Trivy)         ← catches: OS CVEs in image layers
    ├── Image Sign (Cosign)            ← produces: signed artifact
    │
    ├── Deploy to staging
    ├── DAST (OWASP ZAP)               ← attacks: running insecure endpoints
    │
    └── Gate: all findings above threshold → block merge
```

### Your App as a Teaching Tool
This is where your deliberately insecure endpoints become extremely valuable. You will be able to:
- Watch SAST flag the string concatenation in `insecureRoutes.js` and `insecureGraphQL.js`
- Watch DAST detect SQL injection on `/api/insecure-users/:userid`
- Watch DAST find no injection vulnerability on `/api/safe-users/:userid`
- Show the contrast in a pipeline run log — this is a powerful teaching artefact

### GitHub Actions
Your repo is already on GitHub. GitHub Actions is the natural CI/CD choice here — it runs in the same platform, integrates natively with PR reviews, and has a marketplace with pre-built actions for Trivy, Semgrep, ZAP, and Cosign. You also already have a `buildspec.yml` in the repo (AWS CodeBuild) — understanding both gives you platform flexibility.

### Security Focus in This Phase
- **Branch protection rules** — require pipeline to pass before merge to main
- **PR review requirement** — no direct push to main
- **Least privilege for pipeline credentials** — the GitHub Actions runner should have the minimum AWS permissions needed (later: OIDC federation, no long-lived access keys)
- **Pinned action versions** — `uses: actions/checkout@v4` not `@main` — prevents supply-chain compromise of the pipeline itself

---

## Phase 3 — EKS on AWS with Terraform and Helm

### What You Will Learn
This phase moves your working local K8s deployment to production-grade infrastructure on AWS. You introduce infrastructure-as-code (Terraform), managed Kubernetes (EKS), proper secrets management (AWS Secrets Manager), private container registry (ECR), and IAM integration with Kubernetes workloads (IRSA).

### Key Concepts

**Terraform** — declarative infrastructure-as-code tool. You write HCL describing your desired AWS infrastructure (VPC, subnets, EKS cluster, IAM roles, ECR repositories) and Terraform creates, updates, and tracks it. State is stored remotely (S3 + DynamoDB for locking). The key mental model: infrastructure becomes code, reviewable in Git, deployable via pipeline.

**EKS (Elastic Kubernetes Service)** — AWS-managed Kubernetes control plane. You manage worker nodes (or use Fargate for serverless nodes); AWS manages the API server, etcd, scheduler. EKS integrates deeply with AWS IAM, VPC networking, ALB, and Secrets Manager.

**ECR (Elastic Container Registry)** — AWS-managed Docker registry. Your pipeline builds images and pushes to ECR. EKS pulls from ECR. ECR has native vulnerability scanning (using Trivy under the hood), image lifecycle policies, and supports immutable tags (a pushed image tag cannot be overwritten — prevents tampering).

**IRSA (IAM Roles for Service Accounts)** — allows a Kubernetes Service Account to assume an AWS IAM role without any long-lived credentials in the Pod. The mechanism: EKS creates an OIDC provider; your IAM role trusts that provider for a specific service account. Your backend Pod can then call AWS Secrets Manager to fetch credentials at runtime without any secrets in environment variables or K8s Secrets. This is the correct production pattern.

**External Secrets Operator (ESO)** — a K8s operator that syncs secrets from AWS Secrets Manager (or Parameter Store, Vault, etc.) into Kubernetes Secrets. Your Pod never sees raw credentials — ESO fetches them on its behalf and keeps them in sync. You already have ESO manifests in `DevSecOps/Helm_Charts/`.

**Helm** — the package manager for Kubernetes. Rather than managing raw YAML manifests per environment, Helm templates let you parameterise your deployments (image tag, replica count, resource limits, environment-specific values). A Helm Chart is a versioned, reusable deployment unit. You already have a Helm chart started in `DevSecOps/Helm_Charts/sqlinj-backend-chart/`.

**AWS Load Balancer Controller** — provisions ALB (Application Load Balancer) or NLB from Kubernetes Ingress/Service resources. Your Ingress resource annotated with `kubernetes.io/ingress.class: alb` becomes a real ALB in AWS, with TLS termination, health checks, and target group registration.

### Infrastructure Architecture

```
Internet
    │
    ▼
Route 53 (DNS)
    │
    ▼
CloudFront (frontend CDN + WAF — Phase 4)
    │
    ▼
ALB (AWS Load Balancer Controller)
    │
    ├── /api/*      → backend Service → backend Pods
    └── /*          → frontend Service → frontend Pods
                              │
                    EKS Node Group (private subnets)
                              │
                    RDS PostgreSQL (private subnet)
                    or db Pod with PVC (simpler for lab)
```

### Terraform Module Structure
```
infra/
  terraform/
    modules/
      vpc/          ← VPC, subnets, route tables, NAT gateway
      eks/          ← EKS cluster, node groups, OIDC provider
      ecr/          ← ECR repos for frontend and backend
      iam/          ← IRSA roles, ESO role, pipeline role
      rds/          ← RDS PostgreSQL (optional — or keep db in K8s)
    envs/
      dev/          ← var files for development
      prod/         ← var files for production
```

### Security Focus in This Phase
- **Private subnets** — worker nodes should not have public IPs; only the ALB is public-facing
- **Security Groups as micro-segmentation** — backend SG allows inbound only from ALB SG; db SG allows inbound only from backend SG
- **No long-lived IAM credentials anywhere** — IRSA for pods, OIDC federation for GitHub Actions pipeline
- **ECR immutable tags** — once an image is pushed with a tag, it cannot be overwritten
- **K8s RBAC** — define Roles and RoleBindings; your app's service account should have no cluster-wide permissions
- **Envelope encryption for EKS Secrets** — enable KMS encryption for K8s etcd (Secrets at rest)
- **VPC flow logs** — enable at the VPC level; these are your network audit trail

### Connecting to Your Existing Codebase
You already have CloudFormation stacks in `infra/` and `DevSecOps/` — you will be replacing or supplementing these with Terraform. Your existing `deploy_be_minus_EKS.yaml` and `create-eks-cluster-for-app.yaml` become reference documents as you rewrite them in Terraform HCL. The Helm chart in `DevSecOps/Helm_Charts/sqlinj-backend-chart/` already has External Secrets templates — you will wire these to real Secrets Manager entries.

---

## Phase 4 — API Security Layer (WAF + API Gateway)

### What You Will Learn
Your app now runs in EKS behind an ALB. This phase adds the security controls that protect the API surface itself — WAF for HTTP-layer attack filtering, API Gateway for traffic management, and hardening of your OAuth/JWT validation at the edge.

### Key Concepts

**AWS WAF (Web Application Firewall)** — operates at Layer 7. Inspects HTTP requests and matches them against rules before they reach your application. Key rule groups:
- **AWS Managed Rules - Core Rule Set (CRS)** — covers OWASP Top 10 including SQL injection and XSS. Attach this to your ALB and watch it fire on your lab's insecure endpoints.
- **Rate-based rules** — block IPs exceeding a request threshold; mitigates brute force and scraping
- **IP reputation lists** — block known malicious IPs (AWS managed or custom)
- **Geo-blocking** — restrict to specific countries if appropriate for your threat model

Your SQL injection lab has a specific training value here: you can demonstrate that WAF catches the `1 OR 1=1` attack at the edge — before it even reaches Node.js — and contrast it with the application-level parameterised query defence. Defence in depth.

**AWS API Gateway** — managed API front door. Provides request validation, throttling, usage plans, caching, and can do JWT authorisation at the gateway level (before your backend even processes the request). For a microservices architecture, API Gateway is the single ingress point for all API traffic.

**JWT Validation at the Edge** — your backend currently validates JWTs itself via the JWKS endpoint (in `authJwt.js`). In a production architecture you may push this to API Gateway (which supports Cognito or custom JWT authorisers), offloading the validation from every backend service. This is the zero-trust principle applied to service ingress: authenticate at the boundary, not inside.

**mTLS (Mutual TLS)** — while standard TLS authenticates only the server, mTLS requires both client and server to present certificates. Used for service-to-service communication inside the cluster (e.g. frontend pod to backend pod) or between your EKS cluster and external services. Preview concept here; implemented properly in Phase 5 with a service mesh.

**OWASP API Security Top 10** — distinct from the standard OWASP Top 10, this list targets API-specific vulnerabilities. Your lab already demonstrates:
- **API1 - Broken Object Level Authorisation (BOLA)**: your insecure `/insecure-users/:userid` — any user can request any userid
- **API3 - Broken Object Property Level Authorisation**: returning full user objects including fields that shouldn't be exposed
- **API8 - Security Misconfiguration**: GraphiQL enabled in insecure endpoint

This is a rich testing surface for DAST and manual penetration testing.

### CloudFront Integration
For the frontend, CloudFront (your existing `deploy_fe_cloudfront.yaml`) adds:
- Global CDN with edge caching
- WAF at the CloudFront distribution level (different from ALB WAF — you can attach WAF to both)
- Custom SSL certificate via ACM
- Geo-restriction
- Origin access control (frontend S3 bucket not publicly accessible — only via CloudFront)

---

## Phase 5 — Advanced DevSecOps

### What You Will Learn
This phase moves from "we have security controls" to "we enforce security policy as code, we have full supply-chain integrity, and our service-to-service communication is cryptographically authenticated." These are the concepts that differentiate a mature DevSecOps posture from basic compliance.

### Key Concepts

**Policy-as-Code (OPA / Kyverno)** — Kubernetes admission controllers that intercept API requests before objects are created or modified. You write policies like "no container may run as root," "all images must come from ECR," "all Deployments must have resource limits," "all Pods must have a non-default service account." These policies run at deployment time — a non-compliant manifest is rejected by the cluster. Kyverno is K8s-native (policies are Custom Resources); OPA/Gatekeeper is more general-purpose and used beyond K8s.

**Service Mesh (Istio)** — a dedicated infrastructure layer for service-to-service communication. Istio injects a sidecar proxy (Envoy) into every Pod. Traffic between your frontend, backend, and database Pods flows through these proxies, giving you:
- **mTLS automatically** — all service-to-service traffic is encrypted and mutually authenticated by default
- **Observability** — distributed tracing (Jaeger), metrics (Prometheus), traffic visualisation (Kiali)
- **Traffic management** — canary deployments, circuit breakers, retries, timeouts at the mesh layer, not in application code
- **Authorisation policies** — "backend Pod may only be called by frontend Pod on port 5001" — this is zero-trust network policy

**SBOM (Software Bill of Materials)** — a machine-readable inventory of all components in your software, including transitive dependencies. Like a nutrition label for software. Generated by Syft or Trivy. Increasingly required for supply-chain compliance (US Executive Order 14028, EU Cyber Resilience Act).

**SLSA (Supply-chain Levels for Software Artifacts)** — a framework for software supply-chain integrity. At SLSA Level 2 (achievable with GitHub Actions), you produce a signed provenance attestation proving: this image was built from this commit, by this pipeline, and has not been tampered with. Your Cosign image signing from Phase 2 is the foundation.

**Container Runtime Security (Falco)** — runtime threat detection. While image scanning (Phase 2) checks for known vulnerabilities before deployment, Falco monitors running containers for anomalous behaviour: a container spawning a shell, reading `/etc/passwd`, making unexpected network connections, or writing to unexpected paths. Think of it as EDR for containers.

**Compliance as Code (AWS Security Hub, CIS Benchmarks)** — automated checking of your infrastructure configuration against CIS benchmarks, AWS Foundational Security Best Practices, and PCI-DSS/SOC2 controls. Security Hub aggregates findings from GuardDuty (threat detection), Inspector (vulnerability management), Macie (S3 data classification), and Config (configuration compliance) into a unified dashboard.

---

## Skill Reinforcement Touchpoints

At each phase, your lab gives you concrete artefacts to validate learning:

| Phase | What you build | What you validate |
|---|---|---|
| 1a | Feature branches, PRs, release tag | Two features merged from Mac + Codespaces, v0.2.0 tagged |
| 1b | K8s manifests for your 3 services | App runs in minikube, Secrets not in env vars |
| 2 | GitHub Actions pipeline | SAST flags insecureRoutes.js, DAST finds SQLi on insecure endpoint only |
| 3 | Terraform EKS + Helm deploy | App runs in EKS, IRSA working, no hardcoded creds |
| 4 | WAF on ALB | SQLi payload blocked at edge, JWT validated at gateway |
| 5 | Kyverno policies, Istio mTLS | Non-compliant deploy rejected, all service traffic mTLS |

---

## Recommended Toolchain Summary

| Category | Tool | Why |
|---|---|---|
| IaC | Terraform | Industry standard, AWS provider is comprehensive |
| K8s packaging | Helm | Already started in your repo |
| Container scanning | Trivy | Covers images, K8s manifests, IaC, SBOM |
| SAST | Semgrep | Fast, rule-based, Node.js rules cover your codebase |
| DAST | OWASP ZAP | Open source, GitHub Action available, targets your endpoints |
| Secrets management | AWS Secrets Manager + ESO | Already wired in your Helm chart |
| Image signing | Cosign (Sigstore) | SLSA-compatible, GitHub Actions support |
| Policy-as-code | Kyverno | K8s-native, easier learning curve than OPA |
| Service mesh | Istio | Most mature, AWS EKS add-on available |
| Runtime security | Falco | CNCF project, EKS compatible |
| Identity | Entra ID | Already implemented — extend to workload identity |

---

## A Note on Your Background

Your CISSP and AWS Security Specialty background is directly applicable — you already understand the threat models, the principles (least privilege, defence in depth, zero trust), and the AWS security services. What you are building here is the engineering implementation of those principles in a cloud-native context. The conceptual gap is smaller than it might feel; the execution gap is what these phases close.

Your choice of Auth Code + PKCE with Entra ID is the correct, current standard for SPA authentication. Understanding it at the implementation level (which you now do) is significantly ahead of most people who only know it from documentation.

---

*Last updated: March 2026*
*Project: devseclab*
