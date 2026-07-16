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
`fc65c8c fix(kyverno): attestation keys use gates.* not predicate.*; deploy-lab
keeps signed manifest pin unless image_tag given [skip ci]` — landed the
JMESPath policy fix, the deploy-lab pin-step redesign, tf wrapper/init fixes,
and ARN validation.

## ⚠️ Still uncommitted at handoff (continuing in a new chat)
- `.github/workflows/security-pipeline.yml` — added `paths-ignore` (k8s/**,
  helm/**, terraform/**, **/*.md, deploy-lab.yml) so manifest-bump/release
  commits don't retrigger the build pipeline (breaks the promote→rebuild loop).
- `SESSION_STATE.md` — this file.
- `bin/stoplab.sh` — unrelated, was already dirty on entry.

Suggested first move in the new chat:
```
git add .github/workflows/security-pipeline.yml SESSION_STATE.md
git commit -m "ci: security-pipeline paths-ignore to skip promotion/docs/infra pushes [skip ci]"
git push
```

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
1. **Kyverno cleanup cronjobs CreateContainerConfigError** — appeared after the
   `kubectl` image swap in `helm/kyverno/values.yaml`. Doesn't block admission but
   cleanup/report reaping is broken. Investigate next.
2. **ALBC vpcId pin** — hop_limit=1 blocks IMDS auto-discovery (pinned via TF output).
3. **Identity/secrets hardening backlog**: GitHub Actions + nightly-destroy roles hold
   `AdministratorAccess`; OIDC `sub` repo-wide; `AUTH_MODE=dast` HS256 bypass ships in
   prod image; public EKS endpoint; no KMS on etcd Secrets.

## Next actions — start of next session
1. **Commit + push** the uncommitted fixes above (`[skip ci]`); redeploy lab.
2. **Fix Kyverno cleanup cronjob image** in `helm/kyverno/values.yaml`.
3. **NetworkPolicies + PSS** on the `dsl` namespace.
4. **IAM hardening** — narrow GitHub Actions role; tighten OIDC `sub`.
5. **Istio + Kong study** — deploy manually alongside the app, outside pipeline.

## Lab state
**STOPPED by user (May 22).** Last live state: Kyverno 3.2.6 HA IRSA, ClusterPolicy
`dsl-verify-images` Enforce (registry allowlist + attestation conditions, gates.*
keys, static messages). backend/frontend ran at `5af67ab`. Restart via deploy-lab.yml
(blank image_tag uses the checked-in 5af67ab pin) — commit the working-tree fixes first.

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
