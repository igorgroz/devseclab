# DevSecOps Lab — Evidence-Based Technical Inventory

Repository: `igorgroz/devseclab`

Assessment date: 12 September 2026
Scope: active repository files. Material under `Archive/` is treated as historical and is not counted as current implementation.

## Executive assessment

This is a substantial hands-on DevSecOps learning lab built around a deliberately vulnerable wardrobe application. Its strongest evidence is the implemented and demonstrated CI/CD and software-supply-chain design: automated SAST, dependency and container scanning, DAST, review gates, keyless image signing, a signed vulnerability-decision attestation, ECR verification, and Kyverno admission enforcement that rejects application images lacking valid signatures and acceptable attestation outcomes.

The application and AWS/EKS infrastructure are implemented in source. Updated repository records identify GitHub Actions security-pipeline run #157 for commit `719f8a91afb10b859ca22af7037a4731a1d92fc8` as successful across the complete pipeline. Runtime evidence records Kyverno `Ready=True` in `Enforce` mode with three healthy admission-controller replicas, successful admission and execution of the signed frontend/backend images, and rejection of an unsigned backend image in a server-side dry-run. The correct claim is therefore that the pipeline and runtime admission control were demonstrated end-to-end.

This work should be described as a personal, hands-on lab inspired by enterprise security patterns. It must not be presented as technology delivered at Transport for NSW unless separate professional evidence supports that claim.

## Status legend

- **Implemented** — active source/configuration directly implements the capability.
- **Demonstrated** — repository evidence records a successful execution or validation.
- **Partially verified** — implemented, but an important live/runtime test remains outstanding.
- **Planned/deferred** — explicitly identified as future work or a production-hardening gap.

## Architecture and application

| Area | Status | Evidence-based inventory |
|---|---|---|
| Application topology | Implemented | React single-page frontend, Node.js/Express backend, and PostgreSQL 16 database. Local execution uses Docker Compose; cloud execution uses Kubernetes on Amazon EKS. |
| Frontend | Implemented | React 18, React Router, Axios, Apollo Client, MSAL Browser and MSAL React. Production container is served by unprivileged NGINX on port 8080. |
| Backend | Implemented | Node.js/Express service exposing REST and GraphQL endpoints, PostgreSQL access via `pg`, Swagger/OpenAPI support, CORS, Helmet, JWT middleware, and health endpoints. |
| Database | Implemented | PostgreSQL schema for users, clothes, and user-to-clothes relationships; initialization data is supplied through SQL/ConfigMap resources. EKS persistence uses a PVC backed by the EBS CSI driver and a `gp3` StorageClass. |
| Security-learning design | Implemented | Parallel intentionally vulnerable and secure REST/GraphQL paths demonstrate raw SQL interpolation versus parameterised queries, unauthenticated versus authenticated access, and scanner detection. The vulnerable paths are deliberate teaching material, not accidental production defects. |
| Local/dev environments | Implemented | Docker Compose and a dev-container/Codespaces configuration support local and hosted development. A separate Compose override creates an ephemeral DAST environment. |

## APIs and application security

| Capability | Status | Details |
|---|---|---|
| REST APIs | Implemented | Insecure routes expose user and clothing operations without authentication and deliberately interpolate input into SQL. Secure routes use parameterised queries and enforce bearer-token authentication, OAuth scopes, and Entra application roles. |
| GraphQL APIs | Implemented | Separate insecure and secure GraphQL endpoints. Recent active commits add authenticated user context and role enforcement to the active secure GraphQL path. |
| SQL-injection controls | Implemented | Secure REST and GraphQL resolvers use PostgreSQL placeholders; insecure equivalents exist explicitly for comparative testing and DAST/SAST validation. |
| HTTP protections | Implemented | Helmet middleware, configurable CORS allowlist, JSON body parsing, generic errors on secure routes, and explicit health handling. No application rate limiter was found. |
| API documentation | Implemented | Swagger/OpenAPI is generated/exposed by the backend and a filtered OpenAPI specification is generated for ZAP active API scanning. |

## Identity, OAuth and authorization

| Capability | Status | Details |
|---|---|---|
| Interactive identity | Implemented | Microsoft Entra ID authenticates the React SPA through MSAL. The SPA requests OpenID Connect scopes plus API scopes `user.read` and `user.write`. MSAL uses the current origin as its redirect URI and acquires access tokens silently after sign-in. |
| OAuth/OIDC flow | Implemented | Public SPA pattern using authorization code flow with PKCE as provided by MSAL Browser; no frontend client secret is used. |
| API token validation | Implemented | Backend fetches Entra v2 JWKS and verifies JWT signature, issuer, and audience using `jose`. It extracts subject, tenant, scopes, and roles. |
| Authorization | Implemented | Secure endpoints require both delegated OAuth scopes and Entra application roles. Reader/Creator roles distinguish read and mutation permissions. |
| Identity-as-code | Planned/deferred | Entra app registrations, scopes, roles, redirect URIs, and consent are not managed through Terraform; the repository explicitly identifies the absence of an `azuread` provider. |
| Audience validation | Implemented/tested | `JWT_AUDIENCE` is configured for the Entra API application, and the updated state records successful Entra authorization testing for both Reader and Creator roles. |
| DAST authentication | Implemented with accepted lab risk | CI uses `AUTH_MODE=dast` and an HS256 test token so ZAP can scan protected routes without interactive Entra authentication. The bypass is compiled into the same backend image and activated by environment variable; the repository correctly records this as a production-hardening gap. |

## CI/CD and security gates

The active GitHub Actions security workflow supports pushes to `main`/`master`, pull requests, weekly scheduled dependency scanning, and manual runs. Its principal chain is:

1. Semgrep SAST and SARIF upload to GitHub code scanning.
2. Backend and frontend SCA using `npm audit`.
3. Conditional SAST and SCA review environments when findings are present.
4. Docker Buildx builds for frontend and backend.
5. Trivy container scans with explicit, documented exception handling.
6. Conditional Trivy review environment.
7. Push to GHCR, mirror to private ECR, then read back and use the actual ECR digest.
8. Cosign keyless signing using GitHub Actions OIDC/Sigstore.
9. OWASP ZAP baseline and active API DAST against an ephemeral Compose stack, including authenticated route exercise.
10. Conditional DAST review environment.
11. Creation and Cosign signing of a custom `vuln-signoff/v1` attestation containing the SAST, SCA, Trivy, and DAST decisions.
12. Verification of signatures and attestations against the ECR copies.
13. Deployment patch to an already-running EKS environment, or a documented graceful skip when the cluster/deployments are absent.

Status: **Implemented and demonstrated.** The supplied GitHub Actions screenshot shows run #157 with every listed job green: SAST, both SCA jobs, all four review gates, build, Trivy, keyless signing, ZAP DAST, vulnerability-signoff attestation, and deployment to EKS. Updated `SESSION_STATE.md` supplies the runtime detail needed to distinguish a real rollout from the workflow's graceful-skip path. This remains repository/user-supplied execution evidence rather than a live GitHub API query in this assessment.

Important qualifications:

- Findings do not automatically hard-fail the scan jobs. They are surfaced and routed to GitHub protected-environment approval gates. Approved findings become explicit `accepted` decisions in the attestation.
- `AUTO_APPROVE_GATES` can bypass manual environments. This is useful for lab operation but should be described transparently.
- PR triggers exist, but the repository says the project was worked directly on `master`; the preventive pre-merge workflow has therefore not been practically exercised.
- The weekly trigger covers SCA, not the entire pipeline.
- Documentation-, Kubernetes-, Helm-, and Terraform-only changes are excluded from the push-triggered security pipeline; the repository notes that the `paths-ignore` behavior remains unverified.

## Image build, signing, provenance and admission control

| Capability | Status | Details |
|---|---|---|
| Registries | Implemented | Images are pushed to GHCR and mirrored into private AWS ECR repositories for frontend and backend. ECR repositories use immutable tags, scan-on-push, AES-256 default encryption, lifecycle policies, and an account-scoped repository policy. |
| Immutable deployment identity | Implemented | Deploy workflow requires an explicit 40-character Git SHA image tag. Signing and attestation use resolved image digests, while deployment uses the matching immutable full-SHA tag. Hidden fallback to stale checked-in tags was deliberately removed. |
| Keyless signing | Demonstrated | Cosign signs the observed ECR digest with GitHub Actions OIDC/Sigstore Fulcio and Rekor; the workflow verifies both images after signing. No long-lived signing key is stored. |
| Vulnerability sign-off attestation | Demonstrated | A custom JSON predicate records outcomes for SAST, SCA, Trivy, and DAST. Cosign signs the attestation and verifies it on both ECR image digests. A JSON schema is committed under `.github/attestations/`. |
| Digest-integrity learning | Demonstrated | Repository history documents diagnosis of digest changes caused by provenance/index wrapping and registry copy approaches. The implemented correction mirrors first, reads the ECR digest back, and signs/attests that exact digest. |
| Kyverno admission | Implemented/demonstrated | `dsl-verify-images` runs in `Enforce` mode for Pods in namespace `dsl`. It restricts registries and requires application images to carry a valid keyless signature and `vuln-signoff/v1` attestation whose four gate statuses are `clean`, `accepted`, or `skipped`. Signed frontend/backend Pods were admitted and ran; an unsigned backend image was rejected in a server-side dry-run. This also demonstrates Kyverno's IRSA-authenticated access to private ECR and fail-closed behavior. |
| Verification scope | Implemented with limitation | Signature/attestation checks target the lab frontend/backend images. PostgreSQL is allowlisted as `postgres:*` but is not signature-verified or digest-pinned. |

## Infrastructure as code and AWS platform

Terraform is split into two independently stored states:

- **`infra-base` (persistent):** private ECR repositories, GitHub Actions OIDC provider and role, CodeBuild nightly-destroy project, EventBridge schedule/target, IAM roles/policies, and CloudWatch log group.
- **`infra-lab` (ephemeral):** VPC, public/private subnets across three availability zones, Internet Gateway, NAT Gateway and routes, EKS, managed nodes, EKS access entries, EBS CSI support, ALB Controller identity, External Secrets/Backend/Kyverno IRSA roles, Secrets Manager entries, and cluster bootstrap/cleanup hooks.

Additional details:

- Remote Terraform state is stored in S3 with S3-native state locking.
- EKS worker nodes reside in private subnets; an internet-facing ALB is placed through public-subnet routing.
- The VPC uses a single NAT Gateway as a deliberate lab cost trade-off rather than a highly available per-AZ arrangement.
- The EKS API endpoint is public; this is explicitly deferred hardening.
- Managed node egress is unrestricted through NAT; restrictive egress is deferred.
- AWS Load Balancer Controller and EBS CSI use scoped AWS identities.
- GitHub Actions assumes AWS access via OIDC, but the role currently has `AdministratorAccess`; the trust subject has been narrowed to the main branches and `lab` environment. Splitting it into least-privilege build, deploy, and infrastructure roles is deferred.
- The nightly destroy mechanism is implemented but recorded as disabled.
- Terraform creates Secrets Manager placeholders but intentionally ignores later value changes so real secret values are not stored in Terraform source/state updates.

## Kubernetes implementation and runtime controls

| Area | Status | Details |
|---|---|---|
| Namespace/workloads | Implemented | Dedicated `dsl` namespace; Deployments and ClusterIP Services for frontend, backend, and database. |
| Ingress/TLS | Implemented | AWS ALB Controller ingress, internet-facing ALB, IP targets, HTTP-to-HTTPS redirect, ACM certificate, TLS 1.2/1.3 policy, and an operator-supplied inbound CIDR restriction. |
| Workload health | Implemented | Readiness/liveness probes for all three workloads and CI smoke tests through `kubectl port-forward`. |
| Resource governance | Implemented | CPU and memory requests/limits are set on application/database containers and Helm controller values. |
| Container hardening | Partially implemented | Frontend/backend run as non-root and disable privilege escalation. PostgreSQL retains root initialization as an accepted lab constraint but disables privilege escalation. Read-only root filesystems, dropped Linux capabilities, seccomp profiles, Pod Security Admission labels, and NetworkPolicies are not evident in active manifests. |
| Persistent storage | Implemented | PostgreSQL PVC with EBS CSI and a Terraform-created/default `gp3` StorageClass. |
| Controllers/operators | Implemented | AWS Load Balancer Controller, External Secrets Operator, Kyverno, and AWS EBS CSI add-on. |
| Teardown safety | Implemented | Terraform contains pre-destroy ingress cleanup to avoid ALB-managed AWS resources blocking VPC deletion. The current state records that the lab has been stopped and the EKS cluster no longer exists while persistent base infrastructure remains. |

## Secrets and workload identity

| Capability | Status | Details |
|---|---|---|
| Secret system of record | Implemented | AWS Secrets Manager holds the database password and JWT secret entries. |
| Secret synchronization | Implemented | External Secrets Operator uses a `ClusterSecretStore` and hourly-refreshing `ExternalSecret` resources to create Kubernetes Secrets. |
| Pod identity | Implemented | EKS IRSA uses cluster OIDC tokens and subject-constrained trust for specific service accounts. ESO receives Secrets Manager read access; backend has a separately scoped role for its own secret path. |
| Secret consumption | Implemented | Backend and PostgreSQL consume explicitly mapped keys from ESO-managed Kubernetes Secrets; non-sensitive values reside in ConfigMaps. |
| Rotation behavior | Partially implemented | ESO refreshes Kubernetes Secrets, but pods consuming secrets as environment variables do not automatically restart. A rotation-aware restart mechanism is not implemented. |
| Encryption hardening | Planned/deferred | No customer-managed KMS encryption for Kubernetes secrets/etcd is evident. ECR uses AWS-managed AES-256 rather than a customer-managed key. |
| Legacy manifests | Not current deployment path | Plain Kubernetes `secret.yaml` files exist for backend/database, but the active deploy workflow applies ESO resources instead and does not apply these legacy secret manifests. They should not be cited as the current secret-management approach. |

## Testing and validation

| Type | Status | Details |
|---|---|---|
| Static application security testing | Implemented/demonstrated | Semgrep rule packs for JavaScript, React, Node.js, OWASP Top Ten, and SQL injection; SARIF is uploaded and retained. |
| Software composition analysis | Implemented/demonstrated | Separate backend and production-only frontend `npm audit` jobs evaluate high/critical findings against documented exception files. |
| Container vulnerability testing | Implemented/demonstrated | Trivy table and JSON scans for both images; high/critical findings are evaluated after documented exceptions. |
| Dynamic security testing | Implemented/demonstrated | ZAP baseline/spider and active OpenAPI API scanning with an ephemeral database, authenticated test mode, evidence collection, and a review gate. |
| Deployment validation | Implemented | Terraform plan/apply, controller rollout waits, webhook readiness checks, ESO readiness, workload rollouts, and backend health smoke tests. |
| Unit/integration tests | Minimal/absent | No backend test suite is configured (`npm test` intentionally exits with “no test specified”). Frontend includes testing-library dependencies and the default test command, but no active test files were found. There is no meaningful automated functional unit/integration suite. |
| Policy tests | Runtime-demonstrated, no automated suite | Positive runtime admission of signed/attested images and negative rejection of an unsigned image are recorded. No repeatable Kyverno CLI fixture suite or equivalent policy unit-test suite was found. |

## Observability and operations

Implemented operational visibility consists mainly of application console logs, Kubernetes status/rollout checks, health endpoints and probes, GitHub Actions logs/artifacts/summaries, SARIF/code-scanning results, ZAP evidence, ECR scan results, and a CloudWatch log group for the nightly CodeBuild destroy job.

No active evidence was found for a broader observability platform such as CloudWatch Container Insights, Prometheus, Grafana, OpenTelemetry, distributed tracing, centralized application log ingestion, SLOs, alerting, or runtime security monitoring. These should be described as gaps, not implemented capabilities.

## Implemented versus planned summary

### Strongest demonstrated hands-on capabilities

- Designing and troubleshooting a multi-stage GitHub Actions DevSecOps pipeline.
- Integrating Semgrep, npm audit, Trivy, OWASP ZAP, SARIF, artifacts, protected-environment review gates, and exception records.
- Building and publishing containers to GHCR/ECR and resolving registry digest-integrity problems.
- Using Cosign keyless signing and signed custom attestations with GitHub OIDC/Sigstore/Rekor.
- Implementing Terraform for AWS networking, EKS, IAM/OIDC/IRSA, ECR, Secrets Manager, EBS CSI, scheduled teardown, and remote state.
- Implementing Kubernetes deployments, services, ingress/TLS, health probes, resource bounds, non-root application containers, ESO, and Kyverno policies.
- Implementing Entra ID SPA authentication, JWT/JWKS validation, OAuth scopes, application roles, and secure/insecure API comparisons.

### Implemented but not fully proven

- Docs/IaC-only GitHub Actions path filtering.
- Preventive PR gating in an actual feature-branch/merge workflow.
- Current live application availability is intentionally absent because the ephemeral EKS lab is stopped; base IAM, ECR and Terraform state persist.

### Explicit production-hardening gaps/deferred work

- Replace broad GitHub Actions and destroy-role `AdministratorAccess` with split least-privilege roles.
- Remove or isolate the DAST authentication bypass from production artifacts.
- Make the EKS control-plane endpoint private/restricted and tighten node egress.
- Add Kubernetes NetworkPolicies, Pod Security Admission/security standards, seccomp, dropped capabilities, and read-only filesystems where practical.
- Pin and verify the PostgreSQL image by digest/signature.
- Add KMS-backed encryption where required.
- Manage Entra registrations/scopes/roles/redirects as code.
- Add meaningful unit, integration, API authorization, and Kyverno policy tests.
- Add comprehensive metrics, logs, traces, alerting, and runtime detection.
- Reassess ECR lifecycle retention because signatures and attestations accelerate count-based churn.

## Safe phrasing for the job application

Use language such as:

> In a personal hands-on DevSecOps lab, I designed and implemented an AWS/EKS delivery path for a React, Node.js and PostgreSQL application. I built GitHub Actions security gates integrating Semgrep, npm audit, Trivy and OWASP ZAP; implemented keyless Cosign signing and signed vulnerability-decision attestations; and codified EKS, IAM/OIDC/IRSA, ECR, Secrets Manager, External Secrets and Kubernetes controls with Terraform and manifests. I implemented and runtime-tested Kyverno admission enforcement requiring valid pipeline signatures and approved SAST, SCA, container-scan and DAST outcomes: signed and attested images were admitted, while an unsigned image was rejected.

Keep this in a clearly labelled “personal lab,” “hands-on learning,” or “independent technical project” section. Use Transport for NSW experience separately for professional security architecture, stakeholder engagement, governance, risk, assurance, design review, and organisational delivery evidence. Do not imply that EKS, Cosign, Kyverno, Terraform, or the specific pipeline were deployed at TfNSW unless that is independently true and supported by your work history.

## Primary evidence reviewed

- `.github/workflows/security-pipeline.yml`
- `.github/workflows/deploy-lab.yml`
- `.github/attestations/vuln-signoff.schema.json`
- `terraform/infra-base/` and `terraform/infra-lab/`
- `k8s/`, including ESO and Kyverno resources
- `helm/` controller values
- `backend/` and `frontend/src/`
- `docker-compose.yml` and `docker-compose.dast.yml`
- `README.md`, `docs/Architecture.md`, `docs/SESSION_STATE.md`, and the security deep-dive/decision records under `docs/`

Repository state and runtime claims were reconciled against `SESSION_STATE.md` on 12 September 2026.
