# SESSION_STATE — DevSecOps Platform Lab

> Load this file first at the start of every session. Update it at the end.
> Keep it under ~80 lines. Detailed runbooks live in PHASE*.md.

## Project framing
DevSecOps platform lab: hardened CI/CD supply-chain pipeline and EKS runtime.
Learning exercise — app has no practical value; all value is in DevSecOps and
modern app security concepts built around it.

## Current phase
**Kyverno Enforce — full verify chain GREEN (positive test PASSED, May 22).**
backend + frontend admitted and Running at `5af67ab` in ns `dsl`. Whole chain
verified end to end: registry allowlist → cosign signature → attestation
conditions. Policy was applied via direct kubectl; app pods came up clean.

## Last commit
`7f5b43c ci: security-pipeline paths-ignore to skip promotion/docs/infra
pushes [skip ci]` — pushed to origin/master (Jul 16). Adds `paths-ignore`
(k8s/**, helm/**, terraform/**, **/*.md, deploy-lab.yml) so manifest-bump/
release commits don't retrigger the build pipeline.

## Workflow note
Commits/pushes and running lab start/stop scripts stay with Igor (his
terminal, his SSH keys — this sandbox has no GitHub push access). Claude
does the code edits; Igor commits and runs them.

## Still dirty
- `helm/kyverno/values.yaml` — cleanup-jobs image/securityContext fix
  (alpine/k8s + runAsUser 65532), see Open issue #1. Applied live to the
  cluster, needs commit + push.
- `bin/stoplab.sh` — mode-bit flip (100644→100755) only, no content change.
  Leave for Igor to commit or discard at his discretion.

## Resolved this session (May 22 2026)
- **annotate failure** (`all resources must be specified before annotation
  changes: exited`): two deploy-lab.yml bugs — `terraform init` was gated behind
  run_terraform (uninit S3 backend → empty outputs), and setup-terraform's stdout
  wrapper leaked tokens into `$(terraform output -raw)`. Fixed: ungated init,
  `terraform_wrapper: false`, fail-loud empty-output check, ARN validation.
- **MANIFEST_UNKNOWN on deploy**: pin step defaulted to `github.sha` (workflow
  commit `a0e0ffb`, no image) clobbering signed pin `5af67ab`. Fixed: blank
  `image_tag` keeps checked-in pin.
- **Attestation JMESPath prefix bug**: predicate content is at the JMESPath root,
  so `gates.*.status` not `predicate.gates.*.status`. Same class as the earlier
  `message`-field fix. Predicate shape: {pipeline_run, reviewer, approved_at,
  gates:{sast,sca,trivy,dast}}.
- **Promotion model decided**: build≠deploy. Pipeline signs image tagged with the
  source SHA; promotion = bump the two manifest `image:` lines + commit; deploy-lab
  (blank image_tag) deploys the pinned signed SHA. paths-ignore prevents the loop.

## Resolved prior sessions
- ECR sign/attest digest mismatch fixed in `security-pipeline.yml` (May 21–22).
- Kyverno IRSA chain fixed — admission SA annotated, rollout restart (May 19).
- ClusterPolicy Enforce; registry allowlist; negative test passed.
- Kyverno webhook TLS/caBundle stale cert — clean reinstall pattern in deploy-lab.

## Open issues
1. **Kyverno cleanup cronjobs CreateContainerConfigError — two-stage fix,
   deployed to cluster Jul 16, end-to-end success NOT yet confirmed.**
   Root cause: chart hardcodes `securityContext.runAsNonRoot: true` +
   command `/bin/bash -c ...` (not overridable) on the 5 cleanup CronJobs.
   - Stage 1 (`registry.k8s.io/kubectl:v1.30.0` + `runAsUser: 65532`)
     fixed the runAsNonRoot CreateContainerConfigError, but that image has
     **no shell** — failed with `exec: "/bin/bash": stat /bin/bash: no
     such file or directory` (RunContainerError/StartError).
   - Stage 2: swapped to `docker.io/alpine/k8s:1.30.14` (has bash +
     kubectl, actively maintained, not Bitnami). Kept `runAsUser/
     runAsGroup: 65532` (this image also defaults to root, no USER in its
     Dockerfile). `helm upgrade` applied successfully — confirmed via
     `kubectl get cronjob ... -o jsonpath='{...image}'` → shows
     `docker.io/alpine/k8s:1.30.14` on the live CronJob spec.
   - **Not yet confirmed**: no pod has actually completed with the new
     image — session ended (AWS auto-stop) before a manual
     `create job --from=cronjob/...` finished. Also unconfirmed whether
     the IRSA annotation on `kyverno-admission-controller` SA survived
     this helm upgrade (it survived the prior one; didn't re-check after
     this one — check on next session before assuming cosign/ECR still
     works).
   - **First move next session**: `kubectl -n kyverno create job
     --from=cronjob/kyverno-cleanup-admission-reports verify-1` and watch
     it reach `Completed`. If it fails, check `describe pod` for a new
     error class (possible candidates: read-only-root-fs write attempt,
     `$HOME` unset for UID 65532 breaking kubectl's discovery cache —
     usually non-fatal but worth ruling out).
   - Full values change is in `helm/kyverno/values.yaml` (rationale
     comments #5/#6 at the top of the file) — **NOT YET COMMITTED** (see
     below). Applied live via `helm upgrade` but the working tree still
     needs `git add`/`commit`/`push`.
2. **ALBC vpcId pin** — hop_limit=1 blocks IMDS auto-discovery (pinned via TF output).
3. **Identity/secrets hardening backlog**: GitHub Actions + nightly-destroy roles hold
   `AdministratorAccess`; OIDC `sub` repo-wide; `AUTH_MODE=dast` HS256 bypass ships in
   prod image; public EKS endpoint; no KMS on etcd Secrets.

## Next actions — start of next session
1. **Restart lab** — Igor runs deploy-lab.yml (blank image_tag → checked-in
   5af67ab pin). Fixes are pushed, nothing blocking this now.
2. **Fix Kyverno cleanup cronjob image** in `helm/kyverno/values.yaml`.
3. **NetworkPolicies + PSS** on the `dsl` namespace.
4. **IAM hardening** — narrow GitHub Actions role; tighten OIDC `sub`.
5. **Istio + Kong study** — deploy manually alongside the app, outside pipeline.

## Lab state
**STOPPED (Jul 16, `bin/stoplab.sh` clean teardown — 64 resources
destroyed, ahead of an AWS auto-stop job).** Restart via deploy-lab.yml
(blank image_tag uses the checked-in 5af67ab pin). Kyverno cleanup-jobs
fix (alpine/k8s + runAsUser 65532) is in `helm/kyverno/values.yaml`,
uncommitted — will apply automatically on next Kyverno install via
deploy-lab.yml since that does a clean `helm install` from the values
file. Still needs the end-to-end pod-completion check (Open issue #1).

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
