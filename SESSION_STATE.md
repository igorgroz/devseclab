# SESSION_STATE — DevSecOps Platform Lab

> Load this file first at the start of every session. Update it at the end.
> Keep it under ~80 lines. Detailed runbooks live in PHASE*.md.

## Project framing
DevSecOps platform lab: hardened CI/CD supply-chain pipeline and EKS runtime.
Learning exercise — app has no practical value; all value is in DevSecOps and
modern app security concepts built around it.

## Current phase
**Kyverno admission enforcement — operational end-to-end.** Cluster UP.
deploy-lab.yml runs clean with `run_terraform` checked: Terraform applies,
Kyverno installs HA with IRSA wired to ECR, admission-controller pods carry
AWS_ROLE_ARN + AWS_WEB_IDENTITY_TOKEN_FILE, backend + frontend roll out and
pass cosign signature + vuln-signoff/v1 attestation verify on admission.
ClusterPolicy still set to `Audit` (validationFailureAction). Next: flip to
`Enforce` and validate end-to-end (signed image passes, unsigned rejected).

## Last commit
`fix(deploy-lab): apply Kyverno IRSA annotation via kubectl, not helm --set` (757ecd3)
Uncommitted: 3 new docs (KYVERNO_ECR_VERIFY_FIX, KYVERNO_DEEP_DIVE,
IDENTITY_TRUST_AND_SECRETS) + this SESSION_STATE update.

## Resolved this session (May 19 2026)
- **Kyverno ECR verify chain fixed.** Real root cause: kyverno-admission-controller
  SA had no IRSA, so cosign couldn't authenticate to private ECR for .sig/.att
  artifacts — the /v2/ auth-challenge loop hung against hop-limit-blocked IMDS
  until the 10s webhook timeout fired with "context deadline exceeded". The
  symptom looked like webhook unreachability but was stalled verify.
- **Three compounding fixes deployed**:
  - `terraform/infra-lab/kyverno-irsa.tf` — IRSA role + policy, ECR read scoped
    to dsl-backend / dsl-frontend, OIDC trust pinned to the kyverno SA.
  - `helm/kyverno/values.yaml` — replicas=3, webhookTimeoutSeconds=30,
    memory.limit=1Gi, PDB, `registry.k8s.io/kubectl` for cleanup CronJobs
    (kills the dead `bitnami/kubectl:1.28.5` ImagePullBackOff).
  - `.github/workflows/deploy-lab.yml` — reads new TF output, applies IRSA
    annotation via `kubectl annotate sa --overwrite` (helm --set with dotted
    key was unreliable) + rollout restart, asserts AWS_ROLE_ARN /
    AWS_WEB_IDENTITY_TOKEN_FILE on the pod via jsonpath (distroless = no exec).
- **Doc**: `KYVERNO_ECR_VERIFY_FIX.md` (root) — full root-cause analysis,
  diagnostic flow, fix rationale per value, success criteria.
- **Side discovery**: `validationFailureAction: Audit` does NOT save you when
  verify *errors* (vs *fails*) — Kyverno ≥ v1.12 treats verifyImages errors
  as deny by default. Worth a callout in LAB_SECURITY_DECISIONS.md later.
- **Learning docs written**: `KYVERNO_DEEP_DIVE.md` (concepts, controllers,
  best practices, phase fit) and `IDENTITY_TRUST_AND_SECRETS.md` (full
  identity/trust/secrets map + risk review, built from a repo-wide audit).

## Open issues
1. **ClusterPolicy still in Audit mode.** Flip back to `Enforce` after a clean
   run, then redeploy backend/frontend to re-exercise admission. Add a
   negative-test step: deploy an unsigned `nginx:latest` and confirm rejection.
2. **ALBC vpcId pin** — hop_limit=1 prevents IMDS auto-discovery. Preferred fix:
   cluster-info ConfigMap from Terraform VPC output.
3. **ALB allowlist /32** — `bin/whitelist-me.sh` reduces toil.
4. **Bitnami fallback risk** — chart upgrades may regress to `bitnami/kubectl`.
   Pin the chart version explicitly and watch upstream for cleanupJobs image
   structure changes.
5. **Identity/secrets hardening backlog** (from IDENTITY_TRUST_AND_SECRETS.md
   risk review): GitHub Actions + nightly-destroy roles hold `AdministratorAccess`;
   GitHub OIDC `sub` is repo-wide (`repo:igorgroz/devseclab:*`); `AUTH_MODE=dast`
   HS256 bypass ships in the prod image; public EKS endpoint; no KMS on etcd
   Secrets; `dsl-eks-backend-role` IRSA is dormant; single Postgres superuser
   doubles as app login.

## Next actions — start of next session
1. **Negative-test the policy**: `kubectl run nginx --image=nginx:latest -n dsl`
   should be rejected. Confirm Kyverno blocks with a clean error.
2. **Flip ClusterPolicy to Enforce**, redeploy, confirm continued success.
3. **NetworkPolicies + PSS** on the `dsl` namespace.
4. **Node-group hop-limit fix** — cluster-info ConfigMap, drop vpcId pin.
5. **Enterprise platform track** — Kong, Istio mTLS, CloudFront + WAF.
   Decision pending: build new microservices app or use reference workload
   (Google Online Boutique / Weaveworks Sock Shop).

## Lab state
**UP.** EKS `dsl-eks` running with Kyverno 3.2.6 (HA, IRSA, 30s webhook
timeout), backend + frontend rolled out at SHA `d90ba8a`, ClusterPolicy
`dsl-verify-images` in Audit. Use `stoplab.sh` to tear down when done.

## Key paths
- Kyverno policy: `k8s/kyverno/clusterpolicy-image-verify.yaml`
- Kyverno IRSA: `terraform/infra-lab/kyverno-irsa.tf`
- Kyverno chart values: `helm/kyverno/values.yaml`
- Verify-fix runbook: `KYVERNO_ECR_VERIFY_FIX.md`
- Kyverno concepts: `KYVERNO_DEEP_DIVE.md`
- Identity/trust/secrets map + risk review: `IDENTITY_TRUST_AND_SECRETS.md`
- Phase docs: `PHASE2.md`, `PHASE3B3.md`
- Manifests: `k8s/{backend,frontend,db,eso}/`, `k8s/ingress.yaml`
- Helm values: `helm/{alb-controller,external-secrets,kyverno}/values.yaml`
- IaC: `terraform/infra-lab/`, `terraform/infra-base/`
- Pipeline: `.github/workflows/security-pipeline.yml`, `deploy-lab.yml`
- Attestation schema: `.github/attestations/vuln-signoff.schema.json`

## AWS / cluster identifiers
- Account `510151297987`, region `ap-southeast-2`
- EKS cluster `dsl-eks` (v1.35.4, AL2023) — **UP**
- ECR: `510151297987.dkr.ecr.ap-southeast-2.amazonaws.com/dsl-{backend,frontend}`
- Running image SHA: `d90ba8a` (signed + attested in ECR + GHCR)
- IRSA: `dsl-eks-eso-role`, `dsl-backend-sa`, `dsl-eks-kyverno-ecr-read` (new)
- Secrets (SM, authoritative): `dsl/backend/db-password`, `dsl/backend/jwt-secret`
  (state bucket still legacy `sqlinj-tfstate-*` — can't rename in place)
- Entra: tenant `487f7bd9-…`, SPA `a6960366-…`, API `af63b7cb-…` (v2 tokens)
- Lab URL: `https://lab.oznetsecure.com.au`
