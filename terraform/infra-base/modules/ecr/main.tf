# =============================================================================
# ecr/main.tf — Private ECR repositories for frontend and backend images
#
# ECR vs GHCR (your current registry):
#   Phase 2 pushes to GHCR (GitHub Container Registry) and signs with Cosign.
#   Phase 3c will add ECR as the production registry and update the pipeline.
#   ECR is colocated with your EKS cluster — no cross-internet pulls, lower
#   latency, tighter IAM integration (no registry credentials to manage in K8s).
#
# Security decisions:
#   IMMUTABLE tags — once a tag is pushed, it cannot be overwritten. This is
#   critical for supply chain security: if you deploy tag 1.2.3, you can be
#   sure it's the same image tomorrow. With mutable tags, an attacker who
#   compromises your registry can silently swap the image under a known tag.
#
#   scan_on_push — uses ECR Basic Scanning (powered by Clair) to check images
#   for CVEs on push. Results appear in the ECR console. ECR Enhanced Scanning
#   (Snyk/AWS Inspector) gives continuous scanning but has additional cost.
#   We already have Trivy in the pipeline (Phase 2) — ECR scan is belt and
#   suspenders, catches anything that slipped through.
#
#   Encryption — images are encrypted at rest with AES-256 (default). KMS CMK
#   gives you control over the key and audit logs of every image pull via
#   CloudTrail. For the lab, AES-256 default is sufficient.
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_ecr_repository" "repos" {
  for_each = var.repositories

  name                 = each.key
  image_tag_mutability = each.value.image_tag_mutability

  image_scanning_configuration {
    scan_on_push = each.value.scan_on_push
  }

  # AES-256 encryption at rest (default). To use KMS:
  # encryption_configuration {
  #   encryption_type = "KMS"
  #   kms_key         = aws_kms_key.ecr.arn
  # }

  force_delete = true   # allows destroy even if images exist — needed for terraform destroy

  tags = merge(var.tags, {
    Name = each.key
  })
}

# =============================================================================
# Lifecycle policies — control storage costs
# =============================================================================
# ECR charges ~$0.10/GB/month. Without lifecycle policies, images accumulate
# indefinitely. The policy below:
#   1. Deletes untagged images after 1 day (these are dangling layers from
#      multi-stage builds or tags that were moved elsewhere)
#   2. Keeps only the N most recent tagged images per repo
#
# In a production registry with semver tags, you'd add rules to keep all
# semver-tagged images regardless of count (for rollback safety) and only
# apply the count limit to non-semver tags like branch names.
#
# NOTE (2026-07-23): rule 2 originally scoped itself with tagPrefixList =
# ["v", "sha-"], anticipating tags like "v1.2.3" or "sha-abc1234". The
# actual pipeline tags images with the bare 40-char git SHA (github.sha,
# no prefix) plus "latest" — neither matches "v" or "sha-", so the count
# rule silently matched zero images and never pruned anything (49 images
# had accumulated in dsl-backend before this was caught). tagPatternList
# with a "*" glob matches on tagStatus alone regardless of literal prefix,
# which is what actually needed here.

resource "aws_ecr_lifecycle_policy" "repos" {
  for_each   = aws_ecr_repository.repos
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Remove untagged images after ${var.lifecycle_untagged_days} day(s)"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.lifecycle_untagged_days
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the ${var.lifecycle_tagged_count} most recent tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPatternList = ["*"]   # any tag — real tags are bare git SHAs + "latest", no fixed prefix
          countType     = "imageCountMoreThan"
          countNumber   = var.lifecycle_tagged_count
        }
        action = { type = "expire" }
      }
    ]
  })
}

# =============================================================================
# Repository policy — restrict access to this account only
# =============================================================================
# By default, ECR repos are accessible only within the account.
# An explicit policy makes this intent visible and auditable.
# In multi-account setups, you'd add cross-account access here.

data "aws_iam_policy_document" "ecr_policy" {
  statement {
    sid    = "AllowAccountAccess"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    actions = [
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:BatchCheckLayerAvailability",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeRepositories",
      "ecr:GetRepositoryPolicy",
      "ecr:ListImages",
      "ecr:DeleteRepository",
      "ecr:BatchDeleteImage",
      "ecr:SetRepositoryPolicy",
      "ecr:DeleteRepositoryPolicy",
    ]
  }
}

resource "aws_ecr_repository_policy" "repos" {
  for_each   = aws_ecr_repository.repos
  repository = each.value.name
  policy     = data.aws_iam_policy_document.ecr_policy.json
}
