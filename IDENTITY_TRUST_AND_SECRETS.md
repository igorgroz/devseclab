# Identity, trust and secrets — how access works across the lab

**Purpose:** a single explanatory map of every identity, trust relationship and secret in the DevSecOps lab — who can assume what, how one identity hands off to the next, and where each credential physically lives. Companion to `KYVERNO_DEEP_DIVE.md` (runtime admission) and `COSIGN_SIGNING_DEEP_DIVE.md` (signing). Section 9 is a security-posture / risk review.

**Environment fixtures:** AWS account `510151297987`, region `ap-southeast-2`, EKS cluster `dsl-eks`, repo `igorgroz/devseclab`, app domain `lab.oznetsecure.com.au`.

> **Naming note, read this first.** AWS-side names mix three prefixes and it will trip you up: `dsl-eks-*` / `dsl-*` for the cluster, IRSA roles and Secrets Manager paths; `devseclab-*` for the GitHub Actions role; and a legacy `sqlinj-*` for the Terraform state bucket. The Secrets Manager paths are `dsl/backend/*` — but `SESSION_STATE.md` still records them as `sqlinj/backend/*`, which is stale. Treat `dsl/backend/*` as authoritative.

---

## 1. The mental model — five kinds of identity

Before the inventory, the conceptual frame. There are five distinct identity mechanisms in play, and almost every access problem in this lab is really a question of *which* of these is being used and *what it trusts*:

**Federated OIDC identities (short-lived, keyless).** The good kind. An external token issuer (GitHub Actions, or the EKS cluster's own OIDC provider) mints a short-lived JWT that AWS STS exchanges for temporary credentials, gated by trust conditions on the token's claims. No stored AWS keys. Used by GitHub Actions → AWS, and by every in-cluster workload that touches AWS (IRSA).

**Service-linked trust (AWS-internal).** An AWS service (`eks.amazonaws.com`, `ec2.amazonaws.com`, `codebuild.amazonaws.com`, `events.amazonaws.com`) assumes a role to act on your behalf. No human or external party can assume these.

**A long-lived IAM user.** Exactly one: `user/terraform`, the human operator's identity. This is the only non-federated principal with standing credentials, and it carries cluster-admin. It's the lab's biggest single-point-of-trust.

**Application OIDC/OAuth (end users).** Microsoft Entra ID (Azure AD) issues v2.0 access tokens to human users of the app via the frontend SPA; the backend validates them against Microsoft's JWKS. This identity plane is entirely separate from the AWS/infra plane — it governs *who can use the app*, not *who can change the infrastructure*.

**Database account.** A Postgres login the backend uses to reach the data. In this lab it's a single account that doubles as superuser and app user.

Keep these five buckets in mind; the rest of the document walks each environment and says which mechanism it uses and what the trust is shaped like.

---

## 2. Local CLI / the human operator

The human operator authenticates to AWS as the IAM user `arn:aws:iam::510151297987:user/terraform`. This is a classic long-lived IAM user with an access key — the only standing credential in the system. Everything the operator does locally (Terraform, `aws` CLI, `kubectl`) runs under this identity.

Cluster access is granted not through the legacy `aws-auth` ConfigMap but through the **EKS Access Entries** API. `terraform/infra-lab/main.tf` (lines ~85-104) creates an access entry for `user/terraform` and associates `AmazonEKSClusterAdminPolicy` at cluster scope. The principal ARN is derived dynamically from `data.aws_caller_identity`, so the access entry always targets whoever runs Terraform — which implicitly assumes that's `user/terraform`.

The cluster runs `authentication_mode = API_AND_CONFIG_MAP` (`modules/eks/main.tf:216`), meaning Access Entries are primary but the old ConfigMap path still exists as a fallback. The worker nodes join via an `EC2_LINUX` access entry rather than aws-auth (`modules/eks/main.tf:442`).

`kubectl` configuration is never committed. It's generated on demand with `aws eks update-kubeconfig`, which writes a context that calls the AWS CLI to fetch a token at connect time — so the kubeconfig itself holds no secret, only a reference to the IAM identity. The cluster's API endpoint is **public and open to `0.0.0.0/0`** (`infra-lab/main.tf:59-63`), an acknowledged lab convenience that section 9 flags.

**Trust chain:** access key → `user/terraform` → (EKS Access Entry) → cluster-admin on `dsl-eks`. One credential, full control.

---

## 3. Terraform execution identity

Terraform has no identity of its own — it runs under whatever principal invokes it. Locally that's `user/terraform`; in CI it's the GitHub Actions role (section 4). State lives in the S3 bucket still named `sqlinj-tfstate-*` (the bucket can't be renamed in place, hence the lingering legacy prefix).

The infrastructure is split into two roots with different lifecycles:

`terraform/infra-base/` holds the durable, rarely-destroyed resources: the ECR repositories, the GitHub Actions OIDC provider and its role, the Secrets Manager *definitions*, the ACM cert, the Route 53 zone, and the nightly-destroy CodeBuild automation. This survives lab teardowns.

`terraform/infra-lab/` holds the ephemeral cluster: the VPC, the EKS cluster and its OIDC provider, all the IRSA roles, the EKS addons, and the access entries. This is what `deploy-lab.yml` stands up and `stoplab.sh` tears down.

The practical consequence for permissions: IRSA roles and the EKS OIDC provider are recreated on every spin-up (so their ARNs are stable by name but the OIDC provider thumbprint is fresh), while the GitHub OIDC trust and the SM secret containers persist.

---

## 4. GitHub Actions → AWS (federated OIDC)

This is the first of the two big OIDC federation stories, and worth understanding end to end because it's the access path with the most reach.

**The provider.** `terraform/infra-base/main.tf` (lines ~314-325) registers an IAM OIDC identity provider for `https://token.actions.githubusercontent.com` with client ID `sts.amazonaws.com` and GitHub's thumbprint. This tells AWS "trust JWTs signed by GitHub's Actions OIDC issuer."

**The role and its trust.** `devseclab-github-actions` (`infra-base/main.tf:357-373`) is the role CI assumes. Its trust policy (lines ~327-355) allows `sts:AssumeRoleWithWebIdentity` from that provider when two conditions hold: `aud StringEquals sts.amazonaws.com` and `sub StringLike "repo:igorgroz/devseclab:*"`. **The `sub` is a wildcard over the entire repo** — any branch, any pull request, any workflow can assume this role. The code comment itself flags that production should pin to a branch + environment claim.

**What the role can do.** It's attached to the AWS-managed `AdministratorAccess` policy. Full account control. It is also granted cluster-admin on EKS via a second access entry (`infra-lab/main.tf:114-133`).

**The handoff at runtime.** Each workflow declares `permissions: id-token: write` (plus `contents: read`, and `packages: write` for the pipeline), which lets the job request a GitHub OIDC token. `aws-actions/configure-aws-credentials@v4` exchanges that token at STS for ~1-hour credentials, using the role ARN stored in the repo secret `secrets.AWS_GITHUB_ACTIONS_ROLE_ARN`.

The two workflows differ in what they do with it:

`deploy-lab.yml` (`environment: lab`, top-level `contents: read` + `id-token: write`) assumes the role, runs `terraform apply`, refreshes kubeconfig, and drives helm/kubectl. It does no registry login because it consumes images that already exist.

`security-pipeline.yml` (top-level `contents: read` + `packages: write` + `id-token: write`) is the build-and-sign path. It logs in to **GHCR** with the built-in `secrets.GITHUB_TOKEN` (no AWS involved) and to **ECR** with `aws-actions/amazon-ecr-login@v2` after assuming the role. It signs images **keylessly with cosign** — the cosign signing identity is itself a GitHub OIDC token exchanged with Sigstore's Fulcio, so there is no signing key stored anywhere. Verification later pins `--certificate-identity-regexp = https://github.com/igorgroz/devseclab/.github/workflows/.*` and issuer `https://token.actions.githubusercontent.com`. The pipeline also carries manual-approval gate environments (`sast-review`, `sca-review`, `trivy-review`, `dast-review`) and DAST-only secrets (`DAST_DB_PASSWORD`, `DAST_JWT_SECRET`, `DAST_BEARER_TOKEN`).

**Trust chain:** workflow run → GitHub OIDC token (`sub: repo:igorgroz/devseclab:...`) → STS AssumeRoleWithWebIdentity → `devseclab-github-actions` (admin) → AWS + cluster-admin. Plus a parallel keyless identity: workflow run → GitHub OIDC → Fulcio short-lived cert → cosign signature in Rekor.

---

## 5. EKS workloads → AWS (IRSA, the second OIDC story)

Inside the cluster, pods that need AWS access use IRSA — IAM Roles for Service Accounts. The cluster has its own OIDC provider (`modules/eks/main.tf:278-290`, client ID `sts.amazonaws.com`), and IAM roles trust that provider with a `sub` condition pinning to a specific `system:serviceaccount:<namespace>:<name>`. When a pod's ServiceAccount carries the `eks.amazonaws.com/role-arn` annotation, the EKS Pod Identity Webhook injects `AWS_ROLE_ARN` and `AWS_WEB_IDENTITY_TOKEN_FILE` plus a projected SA token; the AWS SDK in the pod exchanges that token at STS for temporary credentials scoped to the role. No node-role credentials, no stored keys.

The bindings, each `SA → namespace → role`:

| ServiceAccount | Namespace | IAM role | Granted via |
|---|---|---|---|
| `aws-load-balancer-controller` | `kube-system` | `dsl-eks-alb-controller-role` | `helm/alb-controller/values.yaml` |
| `external-secrets-sa` | `external-secrets` | `dsl-eks-eso-role` | `helm/external-secrets/values.yaml` |
| `dsl-backend-sa` | `dsl` | `dsl-eks-backend-role` | `k8s/backend/serviceaccount.yaml` |
| `kyverno-admission-controller` | `kyverno` | `dsl-eks-kyverno-ecr-read` | `kubectl annotate` in `deploy-lab.yml` |
| `ebs-csi-controller-sa` | `kube-system` | `dsl-eks-ebs-csi-role` | EKS managed-addon `service_account_role_arn` |

What each role can do, and why:

The **ALB controller role** carries the upstream AWS Load Balancer Controller v3.2.2 policy verbatim (`alb-controller-iam-policy-v3.2.2.json`). It's deliberately broad — EC2, ELBv2, WAFv2, Shield, ACM, and `iam:CreateServiceLinkedRole` — because the controller manages the full ALB lifecycle. The lab keeps the upstream policy intact rather than trimming it, on the principle that you harden via Condition blocks layered on top, not by hand-editing AWS-maintained policies.

The **ESO role** can `secretsmanager:GetSecretValue`/`DescribeSecret`/`ListSecrets` across the whole `dsl/*` prefix (`modules/iam-irsa/main.tf:59-115`). This is what lets External Secrets Operator pull secrets into the cluster — section 6 details the flow.

The **backend role** can read `secretsmanager:*` on `dsl/backend/*` — but here's the catch: **the backend never uses it.** The application reads everything from environment variables (section 7), makes no AWS SDK calls, so this IRSA role is provisioned but dormant. It's a standing grant with no consumer, which section 9 flags.

The **Kyverno role** is the one we built during the admission-controller fix: `ecr:GetAuthorizationToken` (must be `*`-scoped, ECR tokens are account-wide) plus read actions scoped to the `dsl-backend` and `dsl-frontend` repos, so cosign can fetch `.sig` and `.att` artifacts from private ECR. See `KYVERNO_ECR_VERIFY_FIX.md` for the full story of why this was the missing piece.

The **EBS CSI role** carries the AWS-managed `AmazonEBSCSIDriverPolicy` so the driver can provision and attach gp3 volumes.

Two more roles use **service-linked trust** rather than OIDC: `dsl-eks-cluster-role` (assumed by `eks.amazonaws.com`, carries `AmazonEKSClusterPolicy`) and `dsl-eks-node-role` (assumed by `ec2.amazonaws.com`, carries the worker-node, CNI, ECR-read-only and SSM managed policies). The ECR-read-only on the node role is what lets nodes *pull* app images — distinct from the Kyverno role that lets cosign *verify* them.

**Trust chain (example, ESO):** ESO pod → projected SA token (`sub: system:serviceaccount:external-secrets:external-secrets-sa`) → STS AssumeRoleWithWebIdentity → `dsl-eks-eso-role` → `secretsmanager:GetSecretValue` on `dsl/*`.

---

## 6. Secrets flow — from Secrets Manager into the cluster

This is the join between the AWS secret store and the running workloads, and it's worth tracing because it's how the database password reaches both the app and the database without ever being committed.

The secret *containers* are defined in Terraform (`modules/iam-irsa/main.tf:186-225`) with placeholder values (`PLACEHOLDER_REPLACE_BEFORE_DEPLOY`) and `ignore_changes` on the value — so Terraform creates the secret but never manages its real content. The operator sets the real values out-of-band with `aws secretsmanager put-secret-value` (the post-apply checklist in `outputs.tf` spells this out).

External Secrets Operator then bridges AWS → Kubernetes. A `ClusterSecretStore` named `aws-secrets-manager` (`k8s/eso/clustersecretstore.yaml`) points at Secrets Manager in `ap-southeast-2` and authenticates via the ESO ServiceAccount's IRSA role. Two `ExternalSecret` resources in the `dsl` namespace each pull one secret on a 1-hour refresh with `creationPolicy: Owner`:

`dsl/backend/db-password` → K8s Secret `db-password` (key `password`).
`dsl/backend/jwt-secret` → K8s Secret `jwt-secret` (key `secret`).

Both the backend Deployment and the Postgres Deployment read `db-password` via `secretKeyRef`, so there is a single source of truth for the database credential — change it in Secrets Manager and ESO propagates it to both pods within the refresh window. The `jwt-secret` backs only the legacy HS256 token path, which production auth has superseded (section 7), so it's largely vestigial.

**Where each secret lives, by lifecycle stage:**

| Secret | Authoritative store | In-cluster form | Consumed by | Notes |
|---|---|---|---|---|
| DB password | SM `dsl/backend/db-password` | K8s Secret `db-password` (via ESO) | backend + postgres pods | single source of truth |
| JWT signing secret | SM `dsl/backend/jwt-secret` | K8s Secret `jwt-secret` (via ESO) | backend (HS256 path only) | vestigial under Entra auth |
| GitHub Actions role ARN | repo secret `AWS_GITHUB_ACTIONS_ROLE_ARN` | n/a | CI workflows | a pointer, not a credential |
| DAST DB password | repo secret `DAST_DB_PASSWORD` | n/a (CI only) | DAST job | ephemeral CI |
| DAST JWT secret | repo secret `DAST_JWT_SECRET` | n/a (CI only) | DAST job | HS256 bypass token |
| DAST bearer token | repo secret `DAST_BEARER_TOKEN` | n/a (CI only) | DAST job | see `generateDastToken.js` |
| ACM private key | AWS-managed (ACM) | n/a | ALB | never exposed |
| Cosign signing key | **none — keyless** | n/a | pipeline | Fulcio short-lived cert |
| Kyverno webhook TLS | auto-generated in-cluster | Secret `kyverno-svc...tls-pair` | API server ↔ Kyverno | ephemeral |

The thing to internalise: the only secrets a human ever sets by hand are the two Secrets Manager values and the GitHub repo secrets. Everything else is either keyless, AWS-managed, or auto-generated.

---

## 7. In-app authentication — end users (Entra OIDC/OAuth)

This plane is independent of all the AWS identity above. It answers "who is allowed to use the application," and it's a textbook OIDC authorization-code-with-PKCE flow against Microsoft Entra ID issuing v2.0 tokens.

**The registrations** (Entra tenant `487f7bd9-65ec-4967-83e5-94f06e11b6d1`):
- Frontend SPA, client ID `a6960366-f171-44e0-9fa1-d0792977a23d` (`frontend/src/auth/authConfig.js`, MSAL).
- Backend API, app ID `af63b7cb-1958-4029-b50c-3f2c17655120`, exposing scopes `user.read` / `user.write` under `api://af63b7cb-.../`.

**The flow.** The SPA uses MSAL to run the auth-code+PKCE dance against `https://login.microsoftonline.com/487f7bd9-.../`, acquiring an access token scoped to the backend API. It sends that token as a bearer credential. The backend (`backend/authJwt.js`) validates it: it reads `JWT_ISSUER`, `JWT_AUDIENCE` and `ENTRA_TENANT_ID` from env (set in `k8s/backend/configmap.yaml`), fetches Microsoft's signing keys from the JWKS endpoint `https://login.microsoftonline.com/${tenantId}/discovery/v2.0/keys`, and verifies the token signature, issuer and audience with the `jose` library. **No signing secret is stored** — trust is anchored in Microsoft's published JWKS.

**The bypass path, and why it matters.** `authJwt.js` honours an `AUTH_MODE=dast` switch (evaluated once at startup) that disables Entra validation and instead verifies an HS256 token against the shared `DAST_JWT_SECRET`. This exists so the DAST scanner can authenticate in CI without an interactive Entra login. It's CI-only by intent — but the code path is compiled into the production image, so if `AUTH_MODE=dast` ever leaked into a real deployment, the entire auth model would collapse to a single shared static secret. Section 9 treats this as a real risk, not a theoretical one.

**Trust chain:** user → Entra login (tenant `487f7bd9`) → access token (`aud: af63b7cb`) → backend validates against Microsoft JWKS → request authorized.

---

## 8. Application → database

The backend reaches Postgres with the `pg` driver, building a connection pool purely from environment variables (`backend/db.js`): `DB_USER`, `DB_HOST`, `DB_NAME`, `DB_PORT` come from the `backend-config` ConfigMap, and `DB_PASSWORD` comes from the `db-password` K8s Secret via `secretKeyRef` (`k8s/backend/deployment.yaml:42-47`).

The database itself (`postgres:16`, `k8s/db/deployment.yaml`) bootstraps with `POSTGRES_USER=sql_lab_user`, `POSTGRES_PASSWORD` from the same `db-password` Secret, and `POSTGRES_DB=devseclab`. The init SQL (`postgredb/init/01-init.sql`) creates only the application tables and seed data — no `CREATE ROLE`, no `GRANT`. That means **`sql_lab_user` is simultaneously the cluster superuser/owner and the account the application logs in as.** There is no separate least-privilege application role. Functionally fine for a lab; a privilege-separation gap to note.

**Trust chain:** backend pod → `DB_PASSWORD` (from K8s Secret `db-password`) → Postgres login as `sql_lab_user` (superuser).

---

## 9. Security posture — risks and tightening opportunities

Inventory is only half the value; here's where the trust is shaped more loosely than it should be, roughly in priority order. None of these are wrong *for a lab* — they're documented here so the gap between lab and production is explicit and the hardening backlog is visible.

**1. Two roles carry `AdministratorAccess` reachable from federated trust.** Both `devseclab-github-actions` and the `dsl-codebuild-nightly-destroy` CodeBuild role have full account control. For CI this is the highest-leverage tightening target: scope the GitHub Actions role to the specific actions the pipeline and deploy actually perform (ECR push, EKS describe, the specific Terraform-managed resource types) rather than `*`.

**2. The GitHub OIDC trust is repo-wide.** `sub StringLike "repo:igorgroz/devseclab:*"` means any branch, any pull request, any workflow file in the repo can assume the admin role. A PR from a fork (if ever enabled) or a malicious workflow edit on any branch inherits full AWS admin. Pin `sub` to `repo:igorgroz/devseclab:ref:refs/heads/master` and/or `:environment:lab`, and split deploy vs build into separate roles with separate trusts.

**3. One long-lived IAM user holds cluster-admin.** `user/terraform` is the only standing credential and the only non-federated human identity. Its access key is the master key to the lab. Mitigations: move the human to federated SSO (IAM Identity Center) and make `user/terraform` assume-role-only, rotate the key on a schedule, and ensure it's never committed or placed in CI.

**4. `AUTH_MODE=dast` static-HS256 bypass ships in the production image.** The DAST auth shortcut in `authJwt.js` is compiled into the same artifact that runs in `dsl`. Defence in depth: gate it behind a build-time flag so it's physically absent from production images, or at minimum add a startup assertion that refuses to boot with `AUTH_MODE=dast` unless an explicit non-prod marker is also set.

**5. Public EKS API endpoint (`0.0.0.0/0`).** The control plane is reachable from the internet. For the lab it's convenience; the production posture is private endpoint + VPN/PrivateLink, or at least an allowlist of the operator's `/32` (the same pattern `bin/whitelist-me.sh` already applies to the ALB).

**6. No KMS envelope encryption for Kubernetes Secrets.** etcd stores Secrets base64-only (`modules/eks/main.tf:229-237` documents the omission). Anyone with etcd or API read on Secrets sees plaintext. Enabling EKS KMS encryption-at-rest with a CMK closes this and is a one-field change.

**7. Dormant `dsl-eks-backend-role` grant.** The backend reads only env vars and makes no AWS calls, yet its IRSA role can read `secretsmanager:*` on `dsl/backend/*`. An unused standing permission is pure downside — either wire the app to read secrets directly via the SDK (removing the ESO-injected Secret from the pod env, a genuine improvement) or remove the role until it's needed.

**8. Single Postgres account doubles as superuser and app login.** `sql_lab_user` owns the database and is what the app authenticates as. A compromised app credential is a database-admin credential. Add a least-privilege application role with `SELECT/INSERT/UPDATE/DELETE` on the app tables only, and reserve the superuser for migrations.

**9. Hardcoded credentials in committed dev files.** `docker-compose.yml` carries `StrongPassword123` for local Postgres. It's local-only, but it's in Git history forever. Move local dev secrets to a `.env` file that's gitignored, and scrub history if any of these values were ever reused in a real environment.

**10. Naming inconsistencies create operational risk.** Three prefixes (`dsl-*`, `devseclab-*`, `sqlinj-*`) coexist, and `SESSION_STATE.md` records the SM paths as `sqlinj/backend/*` when the live paths are `dsl/backend/*`. Stale identifiers in runbooks lead to "why can't I find this secret" dead-ends. Fix the SESSION_STATE reference, and decide whether the state bucket rename is worth the migration.

**11. ESO role reads the whole `dsl/*` prefix.** Slightly broader than the two secrets it actually pulls. Scope it to `dsl/backend/*` (or the exact two ARNs) so a future secret under `dsl/` isn't automatically readable by ESO.

What's already done well, for balance: cosign is fully keyless (no signing key to leak), the DB password is single-source via ESO, no `.pem`/`.key` material is committed anywhere, EBS and ECR are encrypted at rest, kubectl access is via modern EKS Access Entries rather than the brittle aws-auth ConfigMap, kubeconfig holds no embedded secret, and the in-app auth anchors trust in Microsoft's JWKS rather than a stored secret.

---

## 10. One-glance reference

**Who can assume admin:** `user/terraform` (IAM user, standing), `devseclab-github-actions` (any ref in the repo, via OIDC), `dsl-codebuild-nightly-destroy` (CodeBuild service).

**Short-lived / keyless identities:** all IRSA roles, GitHub Actions → AWS, cosign signing. **Long-lived:** `user/terraform` access key, GitHub repo secrets.

**Where secrets live:** AWS Secrets Manager (`dsl/backend/db-password`, `dsl/backend/jwt-secret`) → mirrored into K8s Secrets by ESO; GitHub repo secrets (CI only); ACM (cert key, never exposed); nothing for cosign (keyless); auto-generated TLS for webhooks.

**Two separate identity planes:** infra/AWS (federated OIDC + one IAM user) governs *changing the system*; Entra OIDC governs *using the app*. They never cross.

**Source-of-truth files:** IAM/OIDC/IRSA in `terraform/infra-base/` and `terraform/infra-lab/`; IRSA annotations in `helm/*/values.yaml` and `k8s/backend/serviceaccount.yaml`; secret bridging in `k8s/eso/`; app auth in `frontend/src/auth/authConfig.js` and `backend/authJwt.js`; DB in `k8s/db/` and `backend/db.js`.
