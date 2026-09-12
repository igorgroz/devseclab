# =============================================================================
# kyverno-irsa.tf — IRSA role for the Kyverno admission controller
#
# WHY THIS EXISTS
#   The Kyverno admission controller verifies cosign signatures on every Pod
#   admission for images covered by ClusterPolicy/dsl-verify-images. The
#   signature artifacts (.sig and .att) live in the SAME private ECR repos
#   as the images. To fetch them, cosign inside the Kyverno Pod must
#   authenticate to ECR — which requires AWS credentials.
#
#   Without IRSA, the amazon credential helper bundled with Kyverno
#   (--registryCredentialHelpers=...,amazon,...) has no credentials to use,
#   falls through to IMDSv2 (hop-limit-blocked from pods on this cluster),
#   and the ECR /v2/ auth challenge loop hangs. The mutating webhook then
#   trips its 10s timeout and the API server cancels the admission request
#   with "context deadline exceeded" — which looks like the webhook is down
#   but is really a stalled cosign verify.
#
#   See docs/KYVERNO_ECR_VERIFY_FIX.md for the full root cause analysis.
#
# SCOPE
#   Read-only ECR access against the two app repositories. This Pod has no
#   business with any other ECR repo or any other AWS service.
#
# REFS
#   Mirrors the trust-policy + role + policy pattern used by
#   alb-controller-iam.tf so anyone reading either file recognises the shape.
# =============================================================================

locals {
  kyverno_namespace = "kyverno"
  kyverno_sa_name   = "kyverno-admission-controller"
}

# -----------------------------------------------------------------------------
# Trust policy — only the kyverno-admission-controller SA in the kyverno
# namespace can assume this role. The aud condition is required by AWS for
# IRSA-via-OIDC tokens.
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "kyverno_ecr_read_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.oidc_provider_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:${local.kyverno_namespace}:${local.kyverno_sa_name}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.oidc_provider_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "kyverno_ecr_read" {
  name               = "${var.cluster_name}-kyverno-ecr-read"
  description        = "IRSA role for Kyverno admission controller - ECR read for cosign signature/attestation fetches"
  assume_role_policy = data.aws_iam_policy_document.kyverno_ecr_read_trust.json

  tags = {
    Project   = "dsl"
    ManagedBy = "terraform"
    Component = "kyverno"
  }
}

# -----------------------------------------------------------------------------
# Permissions policy — minimum surface for cosign verify against ECR.
#
#   ecr:GetAuthorizationToken   issues the Basic auth token used by the
#                               registry V2 API (must be Resource:"*" — ECR's
#                               token is account-scoped, not repo-scoped)
#   ecr:BatchGetImage           fetch image + signature manifests
#   ecr:GetDownloadUrlForLayer  fetch the signed bundle blob
#   ecr:DescribeImages          enumerate .sig / .att tags
#   ecr:BatchCheckLayerAvailability   required by the docker client used by
#                                     cosign during manifest pull
#
# Scoped to the two app repos only. Adding a new app repo here is a
# conscious change — better than wildcarding "dsl-*" and losing the audit
# trail on which repo the role can read.
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "kyverno_ecr_read" {
  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "EcrRead"
    effect = "Allow"
    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:DescribeImages",
      "ecr:BatchCheckLayerAvailability",
    ]
    resources = [
      "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/dsl-backend",
      "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/dsl-frontend",
    ]
  }
}

resource "aws_iam_policy" "kyverno_ecr_read" {
  name        = "${var.cluster_name}-kyverno-ecr-read-policy"
  description = "ECR read for Kyverno cosign verify on dsl-backend and dsl-frontend"
  policy      = data.aws_iam_policy_document.kyverno_ecr_read.json

  tags = {
    Project   = "dsl"
    ManagedBy = "terraform"
    Component = "kyverno"
  }
}

resource "aws_iam_role_policy_attachment" "kyverno_ecr_read" {
  role       = aws_iam_role.kyverno_ecr_read.name
  policy_arn = aws_iam_policy.kyverno_ecr_read.arn
}

# -----------------------------------------------------------------------------
# Output — consumed by .github/workflows/deploy-lab.yml's Install Kyverno
# step, which passes it to helm install as the SA annotation:
#   admissionController.serviceAccount.annotations.eks\.amazonaws\.com/role-arn
# -----------------------------------------------------------------------------

output "kyverno_ecr_read_role_arn" {
  description = "IRSA role ARN for the Kyverno admission controller - annotate the SA with this"
  value       = aws_iam_role.kyverno_ecr_read.arn
}
