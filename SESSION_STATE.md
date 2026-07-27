# SESSION_STATE — DevSecOps Platform Lab

> Load this file first at the start of every session. Update it at the end.
> Keep it under ~80 lines. Detailed runbooks live in PHASE*.md.

## Project framing
DevSecOps platform lab: hardened CI/CD supply-chain pipeline and EKS runtime.
Learning exercise — app has no practical value; all value is in DevSecOps and
modern app security concepts built around it.

## Current phase
**Kyverno Enforce — full verify chain reconfirmed live (Jul 23).**
`deploy-lab.yml` ran clean end to end at pinned `5af67ab`; ALB ready, CNAME
updated. Caveat: this re-verified the chain against the *old* May signature
on `5af67ab`, not the new `cosign copy` ECR-propagation fix from `37d8e41`
(that fix is only verified in-pipeline so far). Kyverno cleanup CronJob
sub-issue (#1 below) still not re-tested despite two lab-up cycles now.

## Last commit
`a967027 fix(ecr): lifecycle rule 2 tagPrefixList never matched real tags` —
pushed to origin/master (Jul 23). `infra-base` apply ran clean (11 added,
1 changed, 11 destroyed).

## Workflow note
Commits/pushes and running lab start/stop scripts stay with Igor (his
terminal, his SSH keys — the Claude sandbox has no GitHub push access).
Claude does the code edits; Igor commits and runs them.

## Still dirty (uncommitted)
- `bin/stoplab.sh` — mode-bit flip only, no content change.
- `terraform/infra-base/main.tf` — narrowed GitHub Actions OIDC `sub`
  condition from `repo:igorgroz/devseclab:*` (any branch/PR) to exact
  matches: `ref:refs/heads/master`, `ref:refs/heads/main`,
  `environment:lab`. Verified no `pull_request`-triggered job assumes the
  role (push-and-sign/attest/deploy all gate on `refs/heads/master|main`).
  **Needs `terraform apply` on `infra-base`** (separate state from
  `infra-lab`, not touched by `stoplab.sh`) — applied Jul 27, git commit
  still blocked by a local `.git/index.lock` (stale lock from an
  interrupted process, not yet cleared/retried).
- `.github/workflows/security-pipeline.yml` — added `workflow_dispatch`
  trigger (previously push/PR/schedule only) plus `workflow_dispatch` to
  every job-gating `if: github.event_name == ...` condition (8 jobs) so a
  manual run executes the full pipeline. Also added a "Print image
  details" step at the end of `attest` — prints tag/digests + a
  ready-to-paste `deploy-lab.yml` command to the job summary.
- `.github/workflows/deploy-lab.yml` — `image_tag` is now `required: true`
  with no default; removed the "blank = use checked-in manifest pins"
  fallback entirely (that pin went stale silently — see resolved-this-
  session below) and added a 40-char-SHA format guard that fails loudly
  instead of deploying something unexpected.
- `README.md` — rewritten as the start/stop runbook: from-scratch
  bootstrap (`infra-base` → `security-pipeline.yml` → `deploy-lab.yml`
  with the printed tag), normal start, mid-session IP fix, stop, CI/CD
  stage breakdown, Terraform state reference.

## Open issues
1. **Kyverno cleanup CronJob fix (`79b310c`) still NOT runtime-verified.**
   `registry.k8s.io/kubectl` had no shell → swapped to `alpine/k8s:1.30.14`
   (kept `runAsUser/runAsGroup: 65532`). No pod has reached `Completed` yet.
   Next: confirm `kyverno-admission-controller` SA IRSA annotation, then
   `kubectl -n kyverno create job --from=cronjob/kyverno-cleanup-admission-reports verify-1`
   → watch for `Completed`; if it fails, check read-only-rootfs/`$HOME`
   under UID 65532.
2. **`paths-ignore` unverified** — no docs-only commit pushed since it landed.
3. **ALBC vpcId pin** — hop_limit=1 blocks IMDS auto-discovery (pinned via TF output).
4. **Nightly-destroy still DISABLED** post-rename — arm when ready:
   `aws events enable-rule --name dsl-nightly-destroy --region ap-southeast-2`.
5. **Identity/secrets hardening backlog**: GitHub Actions + nightly-destroy
   roles hold `AdministratorAccess`; OIDC `sub` narrowed to exact
   branch/environment claims (Jul 27, pending `terraform apply` — see
   "Still dirty"), full least-privilege policy redesign still deferred to
   next lab; `AUTH_MODE=dast`
   HS256 bypass compiled into prod image (`authJwt.js`, env-var gated only,
   no build-time strip/startup guard); public EKS endpoint; no KMS on etcd
   Secrets; `JWT_AUDIENCE` is the bare API app GUID — unconfirmed against
   the API app's real `accessTokenAcceptedVersion` (may need `api://`
   prefix); no `azuread` Terraform provider — Entra app registrations are
   portal-only, the one identity plane with no IaC source of truth.

## Next actions — start of next session
1. **Restart lab** via deploy-lab.yml (blank image_tag → checked-in 5af67ab pin).
2. **Verify Kyverno cleanup CronJob fix end-to-end** (Open issue #1).
3. **Push a docs-only commit** to confirm `paths-ignore` works (Open issue #2).
4. **Confirm `JWT_AUDIENCE` format** against the API app's real manifest.
5. **NetworkPolicies + PSS** on the `dsl` namespace.
6. **IAM hardening** — narrow GitHub Actions role; tighten OIDC `sub`.
7. **Istio + Kong study** — deploy manually alongside the app, outside pipeline.

## Resolved prior sessions (condensed)
- **Jul 23**: Node 20 EOL broke the backend build (npm@latest engine bump)
  → both Dockerfiles to `node:24-alpine`. `paths-ignore` never actually
  existed despite a commit claiming to add it → added for real. Stray
  `sqlinj-*` naming in `security-pipeline.yml` reverted to `dsl-*`. ECR
  mirror carried image bytes but not cosign `.sig`/`.att` (GHCR-only) →
  `attest` job now `cosign copy`s both to ECR post-attest, verified
  in-pipeline. ECR lifecycle rule 2 `tagPrefixList` never matched real
  tags → `tagPatternList=["*"]`; `infra-base` apply also caught pre-existing
  unapplied `sqlinj-*`→`dsl-*` drift on the nightly-destroy automation —
  applied clean, isolated to `infra-base` state. Full lab redeploy
  succeeded end to end, CNAME updated, then stopped clean via
  `bin/stoplab.sh` (64 resources). Reviewed Entra ID/OAuth2 architecture in
  depth (no code changes) — findings folded into Identity backlog above.
- **May 22**: deploy-lab.yml terraform-init gating bug, stdout-wrapper token
  leak, MANIFEST_UNKNOWN pin bug, attestation JMESPath prefix bug — all
  fixed. Promotion model decided: build≠deploy, paths-ignore prevents
  promote→rebuild loop. ECR sign/attest digest mismatch, Kyverno IRSA
  chain, ClusterPolicy Enforce, webhook TLS/caBundle reinstall — resolved.

## Lab state
**STOPPED (Jul 23, clean `bin/stoplab.sh` teardown — 64 resources).**
Restart via deploy-lab.yml (blank image_tag uses the checked-in 5af67ab pin).

## Key paths
- Start/stop runbook: `README.md` (gh CLI commands, whitelist-me.sh, stoplab.sh)
- Kyverno policy: `k8s/kyverno/clusterpolicy-image-verify.yaml`
- Kyverno IRSA: `terraform/infra-lab/kyverno-irsa.tf` · chart values: `helm/kyverno/values.yaml`
- Runbooks: `KYVERNO_ECR_VERIFY_FIX.md`, `KYVERNO_DEEP_DIVE.md`, `IDENTITY_TRUST_AND_SECRETS.md`
- Phase docs: `PHASE2.md`, `PHASE3B3.md`
- Manifests: `k8s/{backend,frontend,db,eso}/`, `k8s/ingress.yaml`
- IaC: `terraform/infra-lab/`, `terraform/infra-base/`
- Pipeline: `.github/workflows/security-pipeline.yml`, `deploy-lab.yml`
- Attestation schema: `.github/attestations/vuln-signoff.schema.json`
- Entra auth: `frontend/src/auth/authConfig.js`, `backend/authJwt.js`

## AWS / cluster identifiers
- Account `510151297987`, region `ap-southeast-2`
- EKS cluster `dsl-eks` (v1.35.4, AL2023)
- ECR: `510151297987.dkr.ecr.ap-southeast-2.amazonaws.com/dsl-{backend,frontend}`
- Signed image SHA: `5af67ab` (full `5af67ab43c9060b846cb71d16749fc427b63bb55`; ECR digest `07e6aada…`)
- IRSA: `dsl-eks-eso-role`, `dsl-backend-sa`, `dsl-eks-kyverno-ecr-read`
- Secrets (SM): `dsl/backend/db-password`, `dsl/backend/jwt-secret`
- Entra: tenant `487f7bd9-…`, SPA `a6960366-…`, API `af63b7cb-…` (v2 tokens)
- Lab URL: `https://lab.oznetsecure.com.au`
