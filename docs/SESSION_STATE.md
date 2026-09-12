# SESSION_STATE — DevSecOps Platform Lab

> Load this file first at the start of every session. Update it at the end.
> Keep it concise; detailed history and runbooks live in the linked documents.

## Project framing
Security-learning application wrapped in a hardened CI/CD supply-chain pipeline
and an ephemeral AWS EKS runtime. The app deliberately contains insecure routes;
the learning value is identity, authorization, scanning, signing, admission
control, secrets, networking, and infrastructure automation.

## Current state — proven end-to-end (2026-09-08)
- Latest successful pipeline: **#157**, commit
  `719f8a91afb10b859ca22af7037a4731a1d92fc8`.
- Pipeline builds frontend/backend, runs Semgrep, npm audit, Trivy and ZAP,
  mirrors images to private ECR, reads back the actual ECR digests, keyless-signs
  those digests, attaches `vuln-signoff/v1`, and verifies both artifacts in ECR.
- Runtime verification succeeded: Kyverno policy `dsl-verify-images` was
  `Ready=True`, `validationFailureAction=Enforce`; three admission-controller
  replicas were healthy; signed frontend/backend Pods were admitted and ran.
- Negative admission test succeeded: server-side dry-run of
  `dsl-backend:unsigned` was rejected by Kyverno. This also proved Kyverno IRSA
  could authenticate to private ECR and the admission path failed closed.
- Entra authorization is implemented and tested: API roles `Wardrobe.Reader`
  and `Wardrobe.Creator`; Reader can read but not write, Creator can read/write.
  REST and active `/graphql-secure` endpoint enforce OAuth scopes plus roles.
- Lab is currently **stopped**: EKS cluster `dsl-eks` does not exist (checked
  2026-09-12). `infra-base`, IAM, ECR images and Terraform state persist.

## Important implementation details
- ECR images use the full Git commit SHA as a shared frontend/backend release
  tag. Never deploy `latest`; copy the tag from the successful `attest` summary.
- Digest fix: mirror first, query ECR for the stored digest, then sign and attest
  that exact digest. Do not assume GHCR/copy operations preserve a digest.
- Kyverno requires both the Cosign GitHub-OIDC signature and the structured
  attestation. IRSA role `dsl-eks-kyverno-ecr-read` provides ECR read access.
- Entra tenant `487f7bd9-65ec-4967-83e5-94f06e11b6d1`; SPA client
  `a6960366-f171-44e0-9fa1-d0792977a23d`; API client
  `af63b7cb-1958-4029-b50c-3f2c17655120` exposing `user.read`/`user.write`.
- SPA uses Authorization Code + PKCE. Backend validates v2 JWT issuer, API
  audience, Microsoft JWKS, scopes and roles. No Entra client secret is needed.
- `AUTH_MODE=dast` is a CI-only HS256 bypass compiled into the production image;
  it must never be enabled in a real deployment.
- Network: VPC `10.0.0.0/16`, ALB/NAT in public subnets, EKS nodes and VPC-CNI
  Pod IPs in private subnets. ALB uses IP targets and CIDR-restricted ingress.
  No Kubernetes NetworkPolicies currently restrict east-west Pod traffic.

## Start / stop
- Start from GitHub Actions → **Deploy Lab** using a verified 40-char image tag,
  current public IP `/32`, and `run_terraform=true` after a teardown.
- A successful pipeline automatically patches existing deployments when the
  cluster is already running.
- Stop locally with `bin/stoplab.sh`; this destroys `infra-lab`, not `infra-base`.
- DNS `lab.oznetsecure.com.au` is a GoDaddy CNAME to the current ALB and must be
  updated after a fresh ALB is created.

## Open issues / next exercises
1. Add Kubernetes NetworkPolicies: ALB→frontend/backend, frontend→backend,
   backend→database; deny other database access.
2. Restrict the public EKS API endpoint CIDR (currently lab-convenience
   `0.0.0.0/0`) or move to private-only access with an appropriate access path.
3. Review ECR lifecycle retention: images plus `.sig`/`.att` tags consume the
   count cap quickly; always confirm a selected release still exists.
4. Pin GitHub Actions by immutable commit SHA and address flagged shell-context
   interpolation. Node 20 action-runtime warnings are forced onto Node 24 today.
5. Remove or isolate the production-compiled DAST auth bypass; continue IAM
   least-privilege work and consider KMS encryption for EKS secrets.
6. Migrate Create React App and remaining inherited frontend dependencies.

## Key paths
- Operations: `README.md`; pipeline: `.github/workflows/security-pipeline.yml`,
  `.github/workflows/deploy-lab.yml`; stop: `bin/stoplab.sh`
- Admission: `k8s/kyverno/clusterpolicy-image-verify.yaml`,
  `terraform/infra-lab/kyverno-irsa.tf`, `helm/kyverno/values.yaml`
- Auth: `frontend/src/auth/authConfig.js`, `backend/authJwt.js`,
  `backend/secureRoutes.js`, `backend/secureGraphQL.js`
- Deep dives: `KYVERNO_ECR_VERIFY_FIX.md`, `KYVERNO_DEEP_DIVE.md`,
  `IDENTITY_TRUST_AND_SECRETS.md`
