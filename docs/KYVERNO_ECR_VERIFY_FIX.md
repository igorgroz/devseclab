# Kyverno admission webhook timeout — root cause and fix

**Date:** 2026-05-19
**Cluster:** `dsl-eks` (EKS 1.35.4, `ap-southeast-2`)
**Image SHA at time of incident:** `d90ba8a` (`af16635` earlier in the day)
**Symptom (surface):** `failed calling webhook "mutate.kyverno.svc-fail": context deadline exceeded`
**Symptom (real):** Kyverno's cosign verification of ECR-stored signatures runs longer than the 10 s admission-webhook budget. The API server cancels the request mid-call.

This document also records the install-side gaps that made this likely to happen, and the changes needed in `.github/workflows/deploy-lab.yml` to prevent recurrence.

---

## 1 — What the logs actually say

The admission-controller pod is `1/1 Running` and `kyverno-svc` has a healthy endpoint (`10.0.32.110:9443`). The API server reached it. The webhook returns late, not because Kyverno is dead, but because cosign is mid-flight when the 10 s deadline fires:

```
00:00:05  verifying image signatures   image=...dkr.ecr.../dsl-backend:af16635...
00:00:16  cosign image verification failed
          error: Get "https://510151297987.dkr.ecr.ap-southeast-2.amazonaws.com/v2/": context canceled
00:00:16  image attestors verification failed   verifiedCount=0 requiredCount=1
00:00:16  blocking admission request   namespace=dsl name=backend
```

Eleven seconds elapsed between "verifying" and "context canceled". The webhook's `timeoutSeconds: 10` is the binding constraint. `context canceled` on the `/v2/` call is the Go HTTP client noticing the parent context expired — not a network error.

This is also why **`validationFailureAction: Audit` did not save you**: the audit/enforce flag governs whether a *failed verify result* blocks admission. Here the result wasn't "failed" — the engine never finished. Kyverno's `verifyImages` defaults to `required: true`, so an *error* during verify is treated as deny regardless of the audit flag (Kyverno ≥ v1.12).

---

## 2 — Why verification is slow

The verify path for each image is:

1. `GET https://<ecr>/v2/` — registry bootstrap. ECR replies `401 WWW-Authenticate: Basic realm="..."`.
2. The amazon credential helper resolves AWS creds, calls `ecr:GetAuthorizationToken` against STS, gets a `Basic` token (12 h-lived).
3. `GET https://<ecr>/v2/dsl-backend/manifests/sha256-<digest>.sig` — fetch the cosign signature artifact (OCI manifest + blob).
4. Same for `.att` (attestation).
5. Parse the bundle, extract the Fulcio leaf cert, validate the chain against the embedded Fulcio root.
6. Validate the OIDC identity (your GH Actions workflow identity) and issuer match the policy `keyless` block.
7. Validate the Rekor entry — bundled inclusion proof + SET, so usually no live call to `rekor.sigstore.dev`.

Step 1–2 is the killer. The `kyverno-admission-controller` ServiceAccount has no IRSA annotation, so the amazon credential helper has no credentials to feed cosign. It falls through to the IMDSv2 endpoint on `169.254.169.254` (often hop-limit-blocked from pods on EKS) and the HTTPS connection sits unauthenticated. By the time the 401 retry loop times out, the API server has already cancelled the parent context.

Quick confirmation:

```bash
kubectl -n kyverno get sa kyverno-admission-controller -o yaml | grep eks.amazonaws.com/role-arn
# (empty output = no IRSA, which is the diagnosis)

kubectl -n kyverno exec deploy/kyverno-admission-controller -- \
  env | grep -E 'AWS_(ROLE_ARN|WEB_IDENTITY_TOKEN_FILE)'
# (empty = no IRSA injected)
```

The image-pull from ECR for the workload pods works fine because that uses the **node** IAM role (`AmazonEC2ContainerRegistryReadOnly`). Cosign in Kyverno runs inside a pod and doesn't inherit node-role credentials.

---

## 3 — Three compounding causes, in priority order

| # | Cause | Fix |
|---|---|---|
| 1 | `kyverno-admission-controller` SA has no IRSA → amazon credential helper has nothing to use → ECR `/v2/` auth challenge loop hangs | IRSA role + SA annotation (§4.2) |
| 2 | Webhook `timeoutSeconds: 10` is too tight even with creds — cosign keyless verify typically needs 15–25 s on a cold cache | `--set admissionController.webhookTimeoutSeconds=30` (§4.3) |
| 3 | Single-replica Kyverno on a fail-closed webhook is a SPOF on the entire admission path | `--set admissionController.replicas=3` (§4.3) |

Cleanup CronJobs are also `ImagePullBackOff` on `bitnami/kubectl:1.28.5` — Bitnami deprecated the legacy free Docker Hub images mid-2025. See §5.

---

## 4 — Fix plan

### 4.1 Immediate unblock (so deploys can proceed today)

Two minimal in-cluster patches, both reversible. Gets pods running while we set up the proper fix.

```bash
# A. Raise the mutate webhook timeout to 30s (cosign keyless typical ceiling).
kubectl patch mutatingwebhookconfigurations kyverno-resource-mutating-webhook-cfg \
  --type='json' \
  -p='[{"op":"replace","path":"/webhooks/0/timeoutSeconds","value":30}]'

# B. Flip failurePolicy on the *resource* webhook to Ignore briefly.
#    Only the resource webhook — leave the policy + verify webhooks alone.
kubectl patch mutatingwebhookconfigurations kyverno-resource-mutating-webhook-cfg \
  --type='json' \
  -p='[{"op":"replace","path":"/webhooks/0/failurePolicy","value":"Ignore"}]'
```

Now deploy:

```bash
kubectl apply -f k8s/backend/deployment.yaml
kubectl apply -f k8s/frontend/deployment.yaml
kubectl -n dsl rollout status deploy/backend  --timeout=10m
kubectl -n dsl rollout status deploy/frontend --timeout=10m
```

With `Ignore`, when verify times out the API server treats the webhook response as success. The pod admits. The mutate-by-digest annotation will be missing — exactly why we want IRSA in place next.

### 4.2 IRSA — give the admission controller credentials for ECR

The cluster already has an OIDC provider (it's used for `external-secrets` and `dsl-backend-sa`, per `SESSION_STATE.md`). Add an IAM role for Kyverno alongside the existing ones in `terraform/infra-lab/`.

Create `terraform/infra-lab/kyverno-irsa.tf`:

```hcl
# =============================================================================
# IRSA — Kyverno admission controller ECR read.
#
# Cosign verification in Kyverno fetches .sig and .att OCI artifacts from the
# ECR repos that hold the app images. ECR is private, so the registry requires
# authentication even for these signature artifacts. Without IRSA the amazon
# credential helper has no creds, falls through to IMDSv2 (hop-limit-blocked
# from pods on this cluster), and the admission webhook times out at 10s.
#
# Scope: read-only against dsl-backend and dsl-frontend repos.
# =============================================================================

data "aws_caller_identity" "kyverno_irsa" {}

locals {
  kyverno_oidc_provider = replace(
    module.eks.cluster_oidc_issuer_url, "https://", ""
  )
}

resource "aws_iam_role" "kyverno_ecr_read" {
  name = "${var.cluster_name}-kyverno-ecr-read"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = {
        Federated = "arn:aws:iam::${data.aws_caller_identity.kyverno_irsa.account_id}:oidc-provider/${local.kyverno_oidc_provider}"
      }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.kyverno_oidc_provider}:sub" = "system:serviceaccount:kyverno:kyverno-admission-controller"
          "${local.kyverno_oidc_provider}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "kyverno_ecr_read" {
  role = aws_iam_role.kyverno_ecr_read.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:DescribeImages",
          "ecr:BatchCheckLayerAvailability"
        ]
        Resource = [
          "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.kyverno_irsa.account_id}:repository/dsl-backend",
          "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.kyverno_irsa.account_id}:repository/dsl-frontend"
        ]
      }
    ]
  })
}

output "kyverno_ecr_read_role_arn" {
  value = aws_iam_role.kyverno_ecr_read.arn
}
```

The role ARN comes out as a Terraform output. The deploy-lab workflow already runs `terraform apply` before installing Kyverno, so it can read this output and pass it into the Helm install.

### 4.3 Update the Kyverno install in `.github/workflows/deploy-lab.yml`

Current install (`deploy-lab.yml:152-160`) is single-replica with no IRSA and default 10 s timeout. Change the `Install Kyverno` step to:

```yaml
      - name: Install Kyverno
        run: |
          helm repo add kyverno https://kyverno.github.io/kyverno/
          helm repo update kyverno

          # Always do a clean Kyverno install to avoid stale TLS certificates.
          # (See preceding cluster-bootstrap.tf rationale block.)
          helm uninstall kyverno -n kyverno 2>/dev/null || true
          kubectl delete mutatingwebhookconfigurations \
            --selector="app.kubernetes.io/part-of=kyverno" --ignore-not-found=true 2>/dev/null || true
          kubectl delete validatingwebhookconfigurations \
            --selector="app.kubernetes.io/part-of=kyverno" --ignore-not-found=true 2>/dev/null || true
          kubectl delete namespace kyverno --ignore-not-found=true 2>/dev/null || true
          kubectl wait --for=delete namespace/kyverno --timeout=3m 2>/dev/null || true

          # Read the Kyverno-ECR IRSA role ARN from terraform output. Required
          # so cosign can authenticate to ECR for signature artifact fetches.
          # See KYVERNO_ECR_VERIFY_FIX.md for the root-cause analysis.
          KYVERNO_ROLE_ARN=$(terraform -chdir=terraform/infra-lab output -raw kyverno_ecr_read_role_arn)

          # 3 replicas — single replica on a fail-closed webhook is a SPOF.
          # webhookTimeoutSeconds=30 — cosign keyless verify needs 15-25s
          # on a cold cache; default 10s is below the floor.
          # memory limit 1Gi — sigstore image-verify cache + Fulcio chain
          # validation blow the default 384Mi on first verify per image.
          helm install kyverno kyverno/kyverno \
            --namespace kyverno \
            --create-namespace \
            --version 3.2.6 \
            --set admissionController.replicas=3 \
            --set admissionController.webhookTimeoutSeconds=30 \
            --set admissionController.serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="${KYVERNO_ROLE_ARN}" \
            --set admissionController.resources.requests.cpu=100m \
            --set admissionController.resources.requests.memory=256Mi \
            --set admissionController.resources.limits.memory=1Gi \
            --set admissionController.podDisruptionBudget.enabled=true \
            --set admissionController.podDisruptionBudget.minAvailable=1 \
            --set backgroundController.replicas=1 \
            --set cleanupController.replicas=1 \
            --set reportsController.replicas=1 \
            --set cleanupJobs.admissionReports.image.repository=registry.k8s.io/kubectl \
            --set cleanupJobs.admissionReports.image.tag=v1.30.0 \
            --set cleanupJobs.clusterAdmissionReports.image.repository=registry.k8s.io/kubectl \
            --set cleanupJobs.clusterAdmissionReports.image.tag=v1.30.0 \
            --set cleanupJobs.ephemeralReports.image.repository=registry.k8s.io/kubectl \
            --set cleanupJobs.ephemeralReports.image.tag=v1.30.0 \
            --set cleanupJobs.clusterEphemeralReports.image.repository=registry.k8s.io/kubectl \
            --set cleanupJobs.clusterEphemeralReports.image.tag=v1.30.0 \
            --set cleanupJobs.updateRequests.image.repository=registry.k8s.io/kubectl \
            --set cleanupJobs.updateRequests.image.tag=v1.30.0 \
            --wait --timeout=10m
          kubectl -n kyverno get pods
```

The dotted-name escape `"eks\.amazonaws\.com/role-arn"` is Helm `--set` syntax for keys that contain dots. If you'd rather move to a values.yaml at this point (which would be cleaner — this list is getting long), drop a file at `helm/kyverno/values.yaml` and use `-f helm/kyverno/values.yaml`.

### 4.4 Once everything is in, switch the policy back to Enforce

In `k8s/kyverno/clusterpolicy-image-verify.yaml` change `validationFailureAction: Audit` → `Enforce`, apply, restart workloads to re-exercise admission:

```bash
kubectl apply -f k8s/kyverno/clusterpolicy-image-verify.yaml
kubectl patch mutatingwebhookconfigurations kyverno-resource-mutating-webhook-cfg \
  --type='json' \
  -p='[{"op":"replace","path":"/webhooks/0/failurePolicy","value":"Fail"}]'
kubectl -n dsl rollout restart deploy/backend deploy/frontend
kubectl -n dsl rollout status   deploy/backend --timeout=5m
kubectl -n dsl rollout status   deploy/frontend --timeout=5m
```

What success looks like in the log:

```
engine.verify  ... verifying image signatures ... attestors=1 attestations=1
engine.verify  ... image attestors verified successfully
engine.verify  ... image attestations verified successfully
webhooks.resource.mutate  ... admission request mutated
```

If `context canceled` still appears after IRSA — second-most-likely cause is egress: the pod can't reach `sts.<region>.amazonaws.com`. Check:

```bash
kubectl -n kyverno exec deploy/kyverno-admission-controller -- \
  wget -qO- --timeout=5 https://sts.ap-southeast-2.amazonaws.com/ 2>&1 | head -5
```

A reachable STS returns an XML error doc. A hang means a missing NAT gateway / VPC endpoint / restrictive SG egress rule on the node subnet.

---

## 5 — Fix the bitnami/kubectl ImagePullBackOff

Unrelated to verify but spamming the events feed:

```
Failed to pull image "bitnami/kubectl:1.28.5":
  docker.io/bitnami/kubectl:1.28.5: not found
```

Bitnami deprecated the legacy free Docker Hub images in mid-2025. The Kyverno 3.2.6 chart still defaults to `bitnami/kubectl`. The `cleanupJobs.*.image.repository` overrides above swap it for the official `registry.k8s.io/kubectl`.

---

## 6 — Why this kept burning time

Three things made this look like a different problem than it is:

- **`context deadline exceeded` at the API server** reads like "webhook unreachable". It actually means "webhook took longer than `timeoutSeconds`". The fix space is verify-latency, not networking-to-pod.
- **Audit mode didn't help** because `verifyImages` errors are deny-by-default regardless of the policy-level audit flag (Kyverno ≥ v1.12). The fail-open behaviour applies to a *failed* verification, not an *unfinished* one.
- **The single replica looks fine by every standard health metric** — the admission timing budget is the only signal that catches the IRSA gap.

Capture for the lab write-up: "single-replica Kyverno + verifyImages over private ECR + no IRSA + 10 s webhook = invisible failure mode". The cluster appears healthy until the first deploy.

---

## 7 — Action list

In order, owner = you:

- [ ] §4.1 — apply the two in-cluster patches, complete the in-flight deploy
- [ ] §4.2 — drop `terraform/infra-lab/kyverno-irsa.tf` in, `terraform apply` to mint the role
- [ ] §4.3 — replace the `Install Kyverno` step in `deploy-lab.yml` with the new helm command
- [ ] §4.4 — flip ClusterPolicy back to `Enforce`, rerun deploy-lab end-to-end, confirm signed image passes and an unsigned one is rejected
- [ ] Update `SESSION_STATE.md` "Known issues" with the IRSA root cause and link to this doc

When §4.4 succeeds, supply-chain enforcement is end-to-end validated on the live cluster.
