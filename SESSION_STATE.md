# SESSION_STATE — DevSecOps Platform Lab

> Load this file first at the start of every session. Update it at the end.
> Keep it under ~80 lines. Detailed runbooks live in PHASE*.md.

## Project framing
DevSecOps platform lab: hardened CI/CD supply-chain pipeline and EKS runtime.
Learning exercise — app has no practical value; all value is in DevSecOps and
modern app security concepts built around it.

## Current phase
**Kyverno Enforce mode + registry allowlist — partially validated.** Lab DOWN.
ClusterPolicy flipped to `Enforce`. Registry allowlist rule (`restrict-image-registries`)
added and confirmed blocking Docker Hub images (nginx:latest rejected). Signed ECR
images still not completing positive admission test — rollout restart timed out with
0/1 new replicas ready. Root cause suspected: `NotEquals` wildcard matching in the
`foreach/deny` rule may not perform glob expansion, causing legitimate ECR images
to match the deny conditions. Needs diagnostic on next startup.

## Last commit
`docs: add Kyverno + identity/secrets deep-dives; refresh SESSION_STATE` (b0b6db1)
Code state last touched at 757ecd3 (Kyverno IRSA fix); everything since is docs.
**Uncommitted changes**: `clusterpolicy-image-verify.yaml` (Enforce + registry rule),
`k8s/backend/deployment.yaml`, `k8s/frontend/deployment.yaml` (both updated to SHA
`b0b6db1`), `.github/workflows/security-pipeline.yml` (ECR digest fix for sign/attest).

## Resolved this session (May 21–22 2026)
- **ECR sign/attest digest mismatch fixed** in `security-pipeline.yml`. Root cause:
  `docker pull ghcr → docker tag → docker push ecr` re-serialises the manifest JSON,
  producing a different SHA-256 in ECR. Pipeline was signing ECR images using the GHCR
  digest, so cosign stored `.sig` tagged `sha256-<ghcr-digest>.sig` in ECR, but Kyverno
  looks for `sha256-<ecr-digest>.sig`. Fixed by querying actual ECR digest via
  `aws ecr describe-images` after mirror push, then using that digest for all
  cosign sign/attest/verify operations in ECR.
- **Deployment manifests updated** — both backend and frontend updated from stale
  `d90ba8a` to current pipeline SHA `b0b6db1`.
- **ClusterPolicy flipped to Enforce** — `validationFailureAction: Audit → Enforce`.
- **Registry allowlist rule added** (`restrict-image-registries`) — rejects any Pod
  in `dsl` ns whose image doesn't match ECR dsl-*, GHCR dsl-*, or postgres:*. Fixed
  a `foreach` variable scoping bug: `{{ element.image }}` is only valid inside the
  foreach body, not at `validate.message` level — changed to static message string.
- **Negative test passed** — `nginx:latest` from Docker Hub correctly rejected by
  both the registry allowlist rule and (in earlier test) the verifyImages rule.
- **Positive test incomplete** — rollout restart timed out (0/1 replicas updated).
  Suspect `NotEquals` wildcard glob not expanding in deny conditions.

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
1. **Positive Kyverno admission test incomplete.** Rollout restart timed out — ECR
   images (backend/frontend at `b0b6db1`) not being admitted. Probable cause:
   `NotEquals` + wildcard pattern in `foreach/deny` not doing glob expansion. On
   next startup: check events + policyreport messages to confirm, then fix the
   matching operator (try `AnyNotIn` with a list, or restructure as `validate.pattern`
   instead of `foreach/deny`).
2. **Commit pending changes** — clusterpolicy, deployment manifests, security-pipeline
   sign/attest fixes are all uncommitted.
3. **ALBC vpcId pin** — hop_limit=1 prevents IMDS auto-discovery.
4. **Identity/secrets hardening backlog**: GitHub Actions + nightly-destroy roles hold
   `AdministratorAccess`; GitHub OIDC `sub` is repo-wide; `AUTH_MODE=dast` HS256
   bypass ships in the prod image; public EKS endpoint; no KMS on etcd Secrets.

## Next actions — start of next session
1. **Diagnose rollout timeout**: `kubectl get events -n dsl --sort-by=.lastTimestamp | tail -20`
   and `kubectl get policyreport -n dsl -o jsonpath='{range .items[*].results[*]}{.message}{"\n"}{end}'`
2. **Fix registry allowlist wildcard matching** if `NotEquals` glob isn't expanding —
   restructure the deny rule or switch to `AnyNotIn`.
3. **Confirm positive test** — signed ECR images admitted, PASS in PolicyReport.
4. **Commit all pending changes** with a descriptive message.
5. **NetworkPolicies + PSS** on the `dsl` namespace.
6. **IAM hardening** — narrow GitHub Actions role from AdministratorAccess.

## Lab state
**DOWN.** Torn down at end of May 21–22 session. Last known running state:
Kyverno 3.2.6 HA IRSA, ClusterPolicy `dsl-verify-images` in **Enforce** with
registry allowlist rule. Backend/frontend at SHA `b0b6db1` but rollout restart
was still pending (timed out). Restart with `bin/startlab.sh` or deploy-lab.yml.

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
- Running image SHA: `b0b6db1` (signed + attested in ECR + GHCR; pipeline run `228aacde` also signed)
- IRSA: `dsl-eks-eso-role`, `dsl-backend-sa`, `dsl-eks-kyverno-ecr-read` (new)
- Secrets (SM, authoritative): `dsl/backend/db-password`, `dsl/backend/jwt-secret`
  (state bucket still legacy `sqlinj-tfstate-*` — can't rename in place)
- Entra: tenant `487f7bd9-…`, SPA `a6960366-…`, API `af63b7cb-…` (v2 tokens)
- Lab URL: `https://lab.oznetsecure.com.au`
