# SESSION_STATE — DevSecOps Platform Lab

> Load this file first at the start of every session. Update it at the end.
> Keep it under ~80 lines. Detailed runbooks live in PHASE*.md.

## Project framing
DevSecOps platform lab: hardened CI/CD supply-chain pipeline and EKS runtime.
Learning exercise — app has no practical value; all value is in DevSecOps and
modern app security concepts built around it. Igor is starting a second,
parallel lab (Azure DevOps + APIM, ground-up) next — this lab is being
parked in a studyable state, not actively developed further for now.

## Current phase — image-integrity fix PROVEN, awaiting clean run (Jul 28)
The read-back-and-sign restructure was committed (`796dcc4`) and run as
pipeline **#145 — and the approach is confirmed correct**: `cosign verify`
passed against `dsl-frontend@sha256:3af412fc…` and
`dsl-backend@sha256:0c81f795…`, both digests read back *from ECR* after the
mirror step. The tag-vs-signed-digest divergence that defeated three
different copy tools on Jul 27 is resolved.

#145 still failed, but only on a **stray `fi`** at the end of the "Verify
signatures" step — leftover from the deleted GHCR sig/att copy block. Bash
executes incrementally, so both verifies ran and passed before the parser
hit it and exited 2. Fixed Jul 28 (single line deleted); whole workflow now
passes `yaml.safe_load` + `bash -n` on every `run` block.

**Consequence: `796dcc4` is NOT deployable.** `push-and-sign` exited
non-zero → `attest` skipped → no `vuln-signoff/v1` attestation on those
digests, and `dsl-verify-images` requires signature *and* attestation.
Next action: commit the `fi` fix, let the pipeline run green through
`attest`, take the tag from "Print image details", then `deploy-lab.yml`.
That should be the first-ever end-to-end verified deploy.

## Prior phase — CI/CD image-integrity bug hunt (Jul 27)
**The app was never successfully deployed this session.** Every
`deploy-lab.yml` attempt was blocked by Kyverno's `dsl-verify-images`
policy, for three *different* underlying reasons found in sequence:
1. Checked-in pin `5af67ab` was silently expired by the ECR lifecycle cap
   (see issue below) → `MANIFEST_UNKNOWN`.
2. `docker/build-push-action`'s default provenance/SBOM attestation wraps
   the pushed image in a multi-manifest index → the tag resolved to a
   different digest than the one cosign signed → "no signatures found".
   Fixed: `provenance: false`, `sbom: false` on both push steps.
3. Still mismatched after (2) — the ECR mirror step's `docker pull`+`tag`+
   `push` re-serializes the manifest through the local Docker engine (same
   layers, different manifest bytes, different digest). Tried `docker
   buildx imagetools create` next — **also** changed the digest (wraps a
   single source in a fresh OCI index). Tried `cosign copy` for the mirror
   — unverified when this was tried.

**Real fix landed (architectural, not another tool swap):** stopped
propagating a pre-copy digest through the mirror step at all. Restructured
`push-and-sign` to mirror to ECR first, then **read back whatever digest
ECR actually has** (`aws ecr describe-images` right after the mirror step),
then sign *that observed digest* directly against ECR — not the GHCR copy.
`attest` job now does the same: attests/verifies against ECR directly using
the observed digest passed through as a job output, no GHCR references
left anywhere in the signing/attestation chain, and the old "copy sig+att
from GHCR to ECR" step is gone entirely since attestation now happens on
ECR from the start. This removed the whole bug class instead of hoping a
fourth copy tool would behave — validated in #145, see Current phase.
No known-good pinned image exists right now; nothing has deployed
successfully since `37d8e41` (Jul 23, in-pipeline only, never
runtime-verified either).

## Resolved this session
- **GitHub Actions OIDC narrowed**: `terraform/infra-base/main.tf` `sub`
  condition went from `repo:igorgroz/devseclab:*` (any branch/PR could
  assume `AdministratorAccess`) to exact matches on
  `ref:refs/heads/{master,main}` and `environment:lab`. Applied + committed.
- **CI/CD redesigned to remove hidden state**: `deploy-lab.yml`'s
  `image_tag` is now `required: true`, no "blank = use checked-in
  manifest" fallback (that's what let issue 1 above happen silently) —
  40-char-SHA format is validated, fails loudly otherwise.
  `security-pipeline.yml` gained `workflow_dispatch` (all job-gates
  updated), a "Print image details" step on `attest` (tag/digests/ready
  `deploy-lab.yml` command in the job summary), and its `deploy` job now
  checks cluster reachability *and* Deployment existence before patching —
  skips gracefully with a warning instead of failing when either isn't
  ready (was a hard failure before).
- `README.md` rewritten as the actual runbook: from-scratch bootstrap
  order, normal start, CI/CD stage breakdown, Terraform state reference
  (incl. the one-way `infra-lab` → `infra-base` dependency via the
  `data "aws_iam_role" "github_actions"` lookup).

## Open issues
1. **Kyverno cleanup CronJob (`79b310c`) still NOT runtime-verified** —
   three lab-up cycles now, never reached `Completed`.
2. **`paths-ignore` still unverified** — no genuinely docs-only commit
   pushed yet (every push this session mixed in code/workflow changes).
3. **ECR lifecycle policy needs a real look, not just the Jul 23 tag-match
   fix.** Each build pushes 3 tagged entries per service (SHA tag + `.sig`
   + `.att`); count-based cap (`lifecycle_tagged_count=10`) churns fast
   across a few pipeline runs. Also observed 25+ entries sitting unpruned
   past the cap same day — enforcement timing is unclear/unreliable, not
   just the threshold. Investigate before trusting any pinned tag again.
4. **Repo workflow was direct-to-master all session** — `pull_request`
   trigger's SAST/SCA "fast gate before merge" design was never actually
   exercised as a pre-merge gate. Fine for solo lab, worth doing properly
   (feature branch → PR → main) in the new Azure lab.
5. **Identity/secrets backlog** (deferred to new lab by design): IAM roles
   still `AdministratorAccess` (sub-narrowing done, full least-privilege
   redesign not); `AUTH_MODE=dast` HS256 bypass compiled into prod image;
   public EKS endpoint; no KMS on etcd; `JWT_AUDIENCE` unconfirmed against
   Entra API app manifest; no `azuread` Terraform provider.
6. Nightly-destroy still disabled; ALBC vpcId pin (hop_limit=1) — both
   unchanged, non-urgent.

## Lab state — infra-lab status still UNCONFIRMED
Jul 27's "didn't work" referred to the **CI commit/pipeline**, not
`stoplab.sh` — that's now understood (the stray `fi`). But whether
`infra-lab` is actually torn down was never confirmed either way. Verify
directly before assuming, since #145's `deploy` job never ran:
`aws eks describe-cluster --name dsl-eks --region ap-southeast-2` and
`terraform -chdir=terraform/infra-lab show`. `infra-base` is never
destroyed by this runbook.

## Key paths
- Start/stop runbook: `README.md`
- Kyverno policy: `k8s/kyverno/clusterpolicy-image-verify.yaml`
- Kyverno IRSA: `terraform/infra-lab/kyverno-irsa.tf` · chart values: `helm/kyverno/values.yaml`
- Runbooks: `KYVERNO_ECR_VERIFY_FIX.md`, `KYVERNO_DEEP_DIVE.md`, `IDENTITY_TRUST_AND_SECRETS.md`
- IaC: `terraform/infra-lab/`, `terraform/infra-base/`
- Pipeline: `.github/workflows/security-pipeline.yml`, `deploy-lab.yml`
- Entra auth: `frontend/src/auth/authConfig.js`, `backend/authJwt.js`

## AWS / cluster identifiers
- Account `510151297987`, region `ap-southeast-2`
- EKS cluster `dsl-eks` (v1.35.4, AL2023)
- ECR: `510151297987.dkr.ecr.ap-southeast-2.amazonaws.com/dsl-{backend,frontend}`
- No valid pinned image SHA currently — see Current phase
- IRSA: `dsl-eks-eso-role`, `dsl-backend-sa`, `dsl-eks-kyverno-ecr-read`
- Secrets (SM): `dsl/backend/db-password`, `dsl/backend/jwt-secret`
- Entra: tenant `487f7bd9-…`, SPA `a6960366-…`, API `af63b7cb-…` (v2 tokens)
- Lab URL: `https://lab.oznetsecure.com.au`
