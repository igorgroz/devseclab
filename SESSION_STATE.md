# SESSION_STATE — DevSecOps Platform Lab

> Load this file first at the start of every session. Update it at the end.
> Keep it under ~80 lines. Detailed runbooks live in PHASE*.md.

## Project framing
DevSecOps platform lab: hardened CI/CD supply-chain pipeline and EKS runtime.
Learning exercise — app has no practical value; all value is in DevSecOps and
modern app security concepts built around it.

## Current phase
**Kyverno Enforce mode + registry allowlist — positive test in progress.** Lab deploying.
deploy-lab (run_terraform=false) failed at Install Kyverno: pods came up Running but the
SA-annotate step died with `kubectl annotate ... all resources must be specified before
annotation changes: exited`. Root cause = two compounding deploy-lab.yml bugs (fixed):
(1) `terraform init` was gated behind run_terraform, so deploy-without-apply read an
uninitialised S3 backend and tf outputs came back empty/garbage; (2) setup-terraform's
default stdout wrapper leaked tokens into `$(terraform output -raw …)`, appending a stray
`exited` to the role ARN → kubectl saw it as a stray resource arg.

## Last commit
`fix: auto-pin image tags to github.sha in deploy-lab; update manifests to 5af67ab`
(amended — includes deploy-lab SHA pin + manifest update + static attestation messages).
All previously uncommitted changes are now committed and pushed.

## Resolved this session (May 22 2026)
- **Attestation condition JMESPath prefix bug.** Sig verify passed; attestation conditions
  failed: `Unknown key "predicate"` resolving `predicate.gates.sast.status`. Kyverno exposes
  the decoded predicate CONTENT at the JMESPath root, so the `key` fields must be
  `gates.<tool>.status`, NOT `predicate.gates.<tool>.status`. Fixed all four keys in
  `k8s/kyverno/clusterpolicy-image-verify.yaml` + corrected the misleading comment.
  Predicate shape (from schema): predicate = {pipeline_run, reviewer, approved_at, gates:{sast,sca,trivy,dast}}.
  NOT yet committed. Apply: `kubectl apply -f k8s/kyverno/clusterpolicy-image-verify.yaml`.
- **annotate fix verified — Kyverno now enforcing.** Webhook correctly blocked backend
  Deployment: image pinned to deploy commit SHA `a0e0ffb` (workflow-only commit, no image
  in ECR) → MANIFEST_UNKNOWN. Root cause: "Pin image tags to deploy SHA" step defaulted to
  `github.sha`, clobbering the checked-in signed pin `5af67ab43c90...`. Fixed: step now only
  rewrites manifests when `image_tag` is provided; blank = keep checked-in (signed) pin.
  NOT yet committed/pushed. Immediate unblock = dispatch deploy-lab with
  image_tag=5af67ab43c9060b846cb71d16749fc427b63bb55.
- **deploy-lab tf-output corruption → kubectl annotate failure** — three fixes in
  `.github/workflows/deploy-lab.yml`: (a) `terraform_wrapper: false` on setup-terraform so
  command-substitution captures aren't contaminated; (b) split out an ungated `Terraform
  init` step (init is idempotent, only configures backend) so outputs are readable when
  run_terraform=false; (c) Export-outputs step now `set -euo pipefail` + per-output empty
  check that fails loudly; (d) annotate step validates the ARN matches `arn:aws:iam::*:role/*`
  and quotes it. NOT yet committed/run.
- **Stale manifest SHA** — `k8s/backend/deployment.yaml` and `k8s/frontend/deployment.yaml`
  referenced `b0b6db1` (signed before ECR digest fix; `.sig` indexed under wrong digest).
  Updated to `5af67ab` which was correctly signed by security-pipeline.
- **deploy-lab SHA auto-pin** — added "Pin image tags to deploy SHA" step after Checkout:
  uses `inputs.image_tag || github.sha`, rewrites manifests via `sed` before any
  `kubectl apply`. Removed the redundant post-deploy `kubectl set image` override step.
  `image_tag` dispatch input retained for rollback / pinning a specific signed SHA.
- **Attestation condition message scoping bug** — `{{ predicate.gates.*.status }}` in
  `message` fields of `attestations.conditions` fails in Kyverno 3.x (predicate context
  not available at message evaluation time). Replaced all four with static strings.
  Same class of bug as the `{{ element.image }}` in `validate.message` fixed last session.

## Resolved prior sessions
- ECR sign/attest digest mismatch fixed in `security-pipeline.yml` (May 21–22).
- Kyverno IRSA chain fixed — admission controller SA annotated, rollout restart asserted (May 19).
- ClusterPolicy flipped to Enforce; registry allowlist rule added; negative test passed.
- Kyverno webhook TLS/caBundle stale cert issue — clean reinstall pattern in deploy-lab.

## Open issues
1. **Positive admission test PASSED (May 22)** — backend + frontend admitted and Running at
   `5af67ab` in ns `dsl` after the JMESPath prefix fix. Full chain verified: registry
   allowlist → cosign signature → attestation conditions. Policy applied via direct kubectl.
2. **ALBC vpcId pin** — hop_limit=1 prevents IMDS auto-discovery (pinned via TF output).
3. **Identity/secrets hardening backlog**: GitHub Actions + nightly-destroy roles hold
   `AdministratorAccess`; GitHub OIDC `sub` is repo-wide; `AUTH_MODE=dast` HS256
   bypass ships in prod image; public EKS endpoint; no KMS on etcd Secrets.

## Next actions — start of next session
1. **Confirm positive test** — backend and frontend rollout succeeded, PolicyReport PASS.
2. **NetworkPolicies + PSS** on the `dsl` namespace.
3. **IAM hardening** — narrow GitHub Actions role from AdministratorAccess; tighten OIDC `sub`.
4. **Istio + Kong study** — deploy manually into cluster alongside existing app, outside pipeline.

## Lab state
**DEPLOYING.** deploy-lab triggered (run_terraform=false). Kyverno 3.2.6 HA IRSA,
ClusterPolicy `dsl-verify-images` Enforce with registry allowlist + attestation conditions
(static messages). Backend/frontend targeting SHA `5af67ab`. Restart: deploy-lab.yml.

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
- EKS cluster `dsl-eks` (v1.35.4, AL2023)
- ECR: `510151297987.dkr.ecr.ap-southeast-2.amazonaws.com/dsl-{backend,frontend}`
- Running image SHA: `5af67ab` (signed + attested in ECR; ECR digest `07e6aada…`)
- IRSA: `dsl-eks-eso-role`, `dsl-backend-sa`, `dsl-eks-kyverno-ecr-read`
- Secrets (SM): `dsl/backend/db-password`, `dsl/backend/jwt-secret`
- Entra: tenant `487f7bd9-…`, SPA `a6960366-…`, API `af63b7cb-…` (v2 tokens)
- Lab URL: `https://lab.oznetsecure.com.au`
