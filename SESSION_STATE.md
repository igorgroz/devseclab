# SESSION_STATE — DevSecOps Platform Lab

> Load this file first at the start of every session. Update it at the end.
> Keep it under ~80 lines. Detailed runbooks live in PHASE*.md.

## Project framing
DevSecOps platform lab: hardened CI/CD supply-chain pipeline and EKS runtime.
Learning exercise — app has no practical value; all value is in DevSecOps and
modern app security concepts built around it.

## Current phase
**Kyverno Enforce — full verify chain GREEN (positive test PASSED, May 22).**
backend + frontend admitted and Running at `5af67ab` in ns `dsl` when last
live. Whole chain verified end to end: registry allowlist → cosign signature
→ attestation conditions.

## Last commit
`79b310c fix(kyverno): cleanup cronjobs use alpine/k8s (has bash) + explicit
non-root UID, not registry.k8s.io/kubectl` — pushed to origin/master (Jul 17).

## Workflow note
Commits/pushes and running lab start/stop scripts stay with Igor (his
terminal, his SSH keys — the Claude sandbox has no GitHub push access).
Claude does the code edits; Igor commits and runs them.

## Still dirty (uncommitted, Jul 23)
- `bin/stoplab.sh` — mode-bit flip only, no content change.
- `backend/Dockerfile`, `frontend/Dockerfile` — `node:20-alpine` →
  `node:24-alpine`. Node 20 hit EOL 2026-04-30; `npm@latest` refuses to
  install on it (engine requires `^22.22.2||^24.15.0||>=26`), broke the build.
- `.github/workflows/security-pipeline.yml` — added real `paths-ignore`
  (`**.md`, `k8s/**`, `helm/**`, `terraform/**`); reverted stray `sqlinj-*`
  naming back to `dsl-*` everywhere (image env vars, ECR repo names,
  `CLUSTER_NAME`, `kubectl -n`, ingress, DAST container exec) — confirmed
  `dsl-*` against terraform/`k8s/*.yaml`. `NODE_VERSION` `'20'`→`'24'`.
  Root cause: commit `7f5b43c` claimed to add `paths-ignore` but its diff
  only did the `sqlinj-*` rename — trigger block was never touched.

## Open issues
1. **Kyverno cleanup cronjob fix committed (`79b310c`) but NOT
   runtime-verified.** Chain: chart hardcodes `runAsNonRoot: true` + command
   `/bin/bash -c ...` (not overridable) on all 5 cleanup CronJobs.
   `registry.k8s.io/kubectl` fixed the root-UID issue but has no shell →
   swapped to `docker.io/alpine/k8s:1.30.14` (has bash, kept
   `runAsUser/runAsGroup: 65532`). Spec applied before teardown; no pod has
   reached `Completed` yet. **First move next session**:
   - Check `kyverno-admission-controller` SA still has the IRSA role-arn
     annotation (unconfirmed since the last `helm upgrade`, which left the
     release in `failed` state on a post-upgrade-hook timeout — moot after a
     fresh `deploy-lab.yml` install).
   - `kubectl -n kyverno create job --from=cronjob/kyverno-cleanup-admission-reports verify-1`
     → watch for `Completed`. If it still fails, check read-only-rootfs
     writes or `$HOME` issues under UID 65532.
2. **Verify new `paths-ignore` actually skips docs-only pushes** — untested,
   just added (see Still dirty).
3. **ALBC vpcId pin** — hop_limit=1 blocks IMDS auto-discovery (pinned via TF output).
4. **Identity/secrets hardening backlog**: GitHub Actions + nightly-destroy roles hold
   `AdministratorAccess`; OIDC `sub` repo-wide; `AUTH_MODE=dast` HS256 bypass ships in
   prod image; public EKS endpoint; no KMS on etcd Secrets.

## Next actions — start of next session
1. **Commit + push CI fixes** (Dockerfiles, workflow) — first push exercises
   both the Node 24 build and the new `paths-ignore`.
2. **Restart lab** via deploy-lab.yml (blank image_tag → checked-in 5af67ab pin).
3. **Verify Kyverno cleanup cronjob fix end-to-end** (Open issue #1).
4. **NetworkPolicies + PSS** on the `dsl` namespace.
5. **IAM hardening** — narrow GitHub Actions role; tighten OIDC `sub`.
6. **Istio + Kong study** — deploy manually alongside the app, outside pipeline.

## Resolved prior sessions (condensed)
- **May 22**: deploy-lab.yml terraform-init gating bug, stdout-wrapper token
  leak, MANIFEST_UNKNOWN pin bug, attestation JMESPath prefix bug (`gates.*`
  not `predicate.gates.*`) — all fixed. Promotion model decided: build≠deploy,
  paths-ignore prevents promote→rebuild loop. ECR sign/attest digest mismatch,
  Kyverno IRSA chain, ClusterPolicy Enforce, webhook TLS/caBundle reinstall
  pattern — all resolved earlier (May 19–22).

## Lab state
**STOPPED (Jul 17, `bin/stoplab.sh` clean teardown — 64 resources destroyed,
ahead of an AWS auto-stop job; first attempt hit transient local DNS
failures on CloudWatch log reads, no resources touched, re-run succeeded).**
Restart via deploy-lab.yml (blank image_tag uses the checked-in 5af67ab
pin). Kyverno cleanup-jobs fix is committed and applies automatically on
next Kyverno install.

## Key paths
- Kyverno policy: `k8s/kyverno/clusterpolicy-image-verify.yaml`
- Kyverno IRSA: `terraform/infra-lab/kyverno-irsa.tf` · chart values: `helm/kyverno/values.yaml`
- Runbooks: `KYVERNO_ECR_VERIFY_FIX.md`, `KYVERNO_DEEP_DIVE.md`, `IDENTITY_TRUST_AND_SECRETS.md`
- Phase docs: `PHASE2.md`, `PHASE3B3.md`
- Manifests: `k8s/{backend,frontend,db,eso}/`, `k8s/ingress.yaml`
- IaC: `terraform/infra-lab/`, `terraform/infra-base/`
- Pipeline: `.github/workflows/security-pipeline.yml`, `deploy-lab.yml`
- Attestation schema: `.github/attestations/vuln-signoff.schema.json`

## AWS / cluster identifiers
- Account `510151297987`, region `ap-southeast-2`
- EKS cluster `dsl-eks` (v1.35.4, AL2023)
- ECR: `510151297987.dkr.ecr.ap-southeast-2.amazonaws.com/dsl-{backend,frontend}`
- Signed image SHA: `5af67ab` (full `5af67ab43c9060b846cb71d16749fc427b63bb55`; ECR digest `07e6aada…`)
- IRSA: `dsl-eks-eso-role`, `dsl-backend-sa`, `dsl-eks-kyverno-ecr-read`
- Secrets (SM): `dsl/backend/db-password`, `dsl/backend/jwt-secret`
- Entra: tenant `487f7bd9-…`, SPA `a6960366-…`, API `af63b7cb-…` (v2 tokens)
- Lab URL: `https://lab.oznetsecure.com.au`
