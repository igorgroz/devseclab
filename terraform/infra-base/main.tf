# =============================================================================
# main.tf — infra-base: Nightly destroy infrastructure
#
# Resources managed here are PERMANENT — never run terraform destroy on this
# module unless you want to lose the state backend and the destroyer itself.
#
# Architecture:
#   EventBridge (cron 22:00 AEST)
#     └→ IAM role (allows events.amazonaws.com to start CodeBuild)
#         └→ CodeBuild project
#               └→ IAM role (allows CodeBuild to run terraform + destroy AWS resources)
#               └→ Checks out repo, installs Terraform, runs destroy on infra-lab
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id   = data.aws_caller_identity.current.account_id
  region       = data.aws_region.current.name
  state_bucket = "sqlinj-tfstate-${local.account_id}"  # real bucket name — rename is a separate infra task
}

# =============================================================================
# IAM — CodeBuild execution role
# =============================================================================
#
# Security design note:
#   This role uses AdministratorAccess for the lab. This is a deliberate
#   simplification with acknowledged trade-offs:
#
#   Production pattern would use a least-privilege policy with conditions:
#     - eks:DeleteCluster with condition aws:ResourceTag/ManagedBy = terraform
#     - ec2:TerminateInstances with condition ec2:ResourceTag/AutoDestroy = true
#     - vpc:Delete* scoped to specific VPC IDs via resource ARNs
#     etc.
#
#   The tagging strategy we use (AutoDestroy=true on infra-lab resources) is
#   designed to make this production scope-down straightforward when needed.

data "aws_iam_policy_document" "codebuild_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }

    # Restrict assume to CodeBuild projects in this account only.
    # Prevents other accounts from assuming this role via CodeBuild.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "codebuild_destroy" {
  name               = "dsl-codebuild-nightly-destroy"
  assume_role_policy = data.aws_iam_policy_document.codebuild_assume.json
  description        = "CodeBuild role for nightly terraform destroy of infra-lab"
}

# Lab: AdministratorAccess for simplicity.
# Production: replace with a custom least-privilege policy scoped to tagged resources.
resource "aws_iam_role_policy_attachment" "codebuild_admin" {
  role       = aws_iam_role.codebuild_destroy.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# Explicit S3 + DynamoDB access for Terraform state operations.
# Although AdministratorAccess covers this, making it explicit documents intent
# and makes the production scope-down path clearer.
data "aws_iam_policy_document" "codebuild_tfstate" {
  statement {
    sid    = "TerraformStateBucket"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    resources = [
      "arn:aws:s3:::${local.state_bucket}",
      "arn:aws:s3:::${local.state_bucket}/*",
    ]
  }

  # NOTE: previously a "TerraformStateLock" statement granted dynamodb:*
  # against dsl-tfstate-lock. Removed when both stacks moved to S3-native
  # locking via use_lockfile (see backend.tf). The lock object is now a
  # sibling of the state file inside the same S3 bucket — the
  # TerraformStateBucket statement above already covers it.

  statement {
    sid    = "CloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/codebuild/dsl-nightly-destroy",
      "arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/codebuild/dsl-nightly-destroy:*",
    ]
  }
}

resource "aws_iam_role_policy" "codebuild_tfstate" {
  name   = "tfstate-and-logs"
  role   = aws_iam_role.codebuild_destroy.id
  policy = data.aws_iam_policy_document.codebuild_tfstate.json
}

# =============================================================================
# CloudWatch Log Group — CodeBuild output
# =============================================================================
# Explicit log group with a retention policy.
# Without this, CodeBuild creates the group with infinite retention —
# which accumulates cost and clutters CloudWatch. 14 days is enough to
# diagnose a failed nightly destroy.

resource "aws_cloudwatch_log_group" "codebuild_destroy" {
  name              = "/aws/codebuild/dsl-nightly-destroy"
  retention_in_days = 14
}

# =============================================================================
# CodeBuild project — terraform destroy runner
# Accepted risk (lab): no KMS CMK encryption. See LAB_SECURITY_DECISIONS.md TF-03.
# =============================================================================
resource "aws_codebuild_project" "nightly_destroy" {
  name          = "dsl-nightly-destroy"
  description   = "Nightly terraform destroy of infra-lab — prevents runaway lab costs"
  service_role  = aws_iam_role.codebuild_destroy.arn
  build_timeout = var.codebuild_timeout_minutes

  artifacts {
    type = "NO_ARTIFACTS"
  }

  # Using the standard CodeBuild managed image which ships with common tooling.
  # We download Terraform at build time to control the exact version.
  # Alternative: build a custom Docker image with Terraform pre-installed and
  # push to ECR — faster builds, no external download at runtime.
  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:7.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "TF_VERSION"
      value = var.terraform_version
    }

    environment_variable {
      name  = "TF_IN_AUTOMATION"
      value = "1"   # suppresses interactive prompts and adds context to output
    }

    environment_variable {
      name  = "AWS_DEFAULT_REGION"
      value = local.region
    }
  }

  source {
    type            = "GITHUB"
    location        = "https://github.com/${var.github_repo}.git"
    git_clone_depth = 1   # shallow clone — we only need the latest Terraform configs

    # The buildspec is inline rather than a file in the repo so the destroy
    # logic is self-contained in Terraform and visible in one place.
    # A file-based buildspec (buildspec.yml) is also valid and easier to test.
    buildspec = <<-BUILDSPEC
      version: 0.2

      phases:
        install:
          commands:
            - echo "=== Installing Terraform $${TF_VERSION} ==="
            - curl -sLo /tmp/terraform.zip https://releases.hashicorp.com/terraform/$${TF_VERSION}/terraform_$${TF_VERSION}_linux_amd64.zip
            - unzip -o /tmp/terraform.zip -d /usr/local/bin/
            - terraform version

        pre_build:
          commands:
            - echo "=== Starting nightly destroy at $(date) ==="
            - echo "=== Repo ${var.github_repo} branch ${var.github_branch} ==="
            - cd terraform/infra-lab
            - terraform init -input=false -no-color

        build:
          commands:
            - echo "=== Running terraform destroy ==="
            - terraform destroy -auto-approve -input=false -no-color || true
            - echo "=== Destroy completed at $(date) ==="

        post_build:
          commands:
            - echo "=== Nightly destroy job finished ==="
    BUILDSPEC
  }

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.codebuild_destroy.name
      stream_name = "nightly-destroy"
      status      = "ENABLED"
    }
  }

  depends_on = [aws_cloudwatch_log_group.codebuild_destroy]
}

# =============================================================================
# IAM — EventBridge role (permission to trigger CodeBuild)
# =============================================================================

data "aws_iam_policy_document" "eventbridge_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "eventbridge_codebuild" {
  name               = "dsl-eventbridge-start-codebuild"
  assume_role_policy = data.aws_iam_policy_document.eventbridge_assume.json
  description        = "Allows EventBridge to start the nightly CodeBuild destroy job"
}

data "aws_iam_policy_document" "eventbridge_codebuild" {
  statement {
    sid       = "StartNightlyDestroyBuild"
    effect    = "Allow"
    actions   = ["codebuild:StartBuild"]
    resources = [aws_codebuild_project.nightly_destroy.arn]
  }
}

resource "aws_iam_role_policy" "eventbridge_codebuild" {
  name   = "start-nightly-destroy-build"
  role   = aws_iam_role.eventbridge_codebuild.id
  policy = data.aws_iam_policy_document.eventbridge_codebuild.json
}

# =============================================================================
# EventBridge — Scheduled rule
# =============================================================================

resource "aws_cloudwatch_event_rule" "nightly_destroy" {
  name                = "dsl-nightly-destroy"
  description         = "Trigger terraform destroy of infra-lab at 22:00 AEST nightly"
  schedule_expression = var.destroy_schedule_utc

  # ENABLED by default. Set to DISABLED here to avoid an accidental destroy
  # before you've validated infra-lab. Manually enable via console or
  # `aws events enable-rule --name dsl-nightly-destroy` when ready.
  state = "DISABLED"
}

resource "aws_cloudwatch_event_target" "codebuild_destroy" {
  rule      = aws_cloudwatch_event_rule.nightly_destroy.name
  target_id = "NightlyDestroyCodeBuild"
  arn       = aws_codebuild_project.nightly_destroy.arn
  role_arn  = aws_iam_role.eventbridge_codebuild.arn
}

# =============================================================================
# IAM — GitHub Actions OIDC Role
# =============================================================================
#
# Allows GitHub Actions workflows in igorgroz/devseclab to assume this role
# via OIDC — no long-lived AWS credentials stored in GitHub Secrets.
#
# Permissions: AdministratorAccess for the lab, matching the trade-off already
# made for the CodeBuild destroy role. The pipeline uses this role to push to
# ECR (security-pipeline.yml), run kubectl against EKS (deploy job), and
# optionally run terraform apply (deploy-lab.yml with run_terraform: true).
# Production would split these into three separate least-privilege roles.
#
# After applying:
#   1. Copy the `github_actions_role_arn` output into the GitHub repo secret
#      AWS_GITHUB_ACTIONS_ROLE_ARN (Settings → Secrets → Actions).
#   2. Run `terraform apply` on infra-lab when the cluster is next provisioned
#      so the EKS access entry for this role is created.
#
# If the GitHub OIDC provider already exists in your account (check with:
#   aws iam list-open-id-connect-providers | grep token.actions
# ) import it before applying:
#   terraform import aws_iam_openid_connect_provider.github_actions \
#     arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com
# =============================================================================

resource "aws_iam_openid_connect_provider" "github_actions" {
  url = "https://token.actions.githubusercontent.com"

  # sts.amazonaws.com is the audience GitHub Actions uses when requesting OIDC
  # tokens for AWS — must match the `aud` claim in the token.
  client_id_list = ["sts.amazonaws.com"]

  # AWS validates GitHub's OIDC endpoint via its own CA bundle for well-known
  # providers, so the thumbprint is not actively checked. The field is required
  # by Terraform; this value is the current GitHub OIDC CA root thumbprint.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_policy_document" "github_actions_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github_actions.arn]
    }

    # `aud` must equal the audience we registered above.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Scoped to the exact sub-claim formats the AWS-assuming jobs actually run
    # under (push-and-sign/attest/deploy gate on refs/heads/master|main; the
    # deploy jobs additionally run under the `lab` GitHub environment).
    # No pull_request-triggered job assumes this role, so fork PRs never
    # present a matching sub claim.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:igorgroz/devseclab:ref:refs/heads/master",
        "repo:igorgroz/devseclab:ref:refs/heads/main",
        "repo:igorgroz/devseclab:environment:lab",
      ]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "devseclab-github-actions"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume.json
  description        = "Assumed by GitHub Actions workflows in igorgroz/devseclab via OIDC"

  tags = {
    Project   = "devseclab"
    ManagedBy = "terraform"
  }
}

# Lab: AdministratorAccess for simplicity — same acknowledged trade-off as the
# CodeBuild destroy role. See LAB_SECURITY_DECISIONS.md for the production path.
resource "aws_iam_role_policy_attachment" "github_actions_admin" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# =============================================================================
# ECR — moved here from infra-lab so repos + their images survive the nightly
# destroy of infra-lab. Previously every teardown wiped these (force_delete=
# true on the repo + terraform destroy → empty repos → morning re-mirror
# from GHCR). Now infra-base owns the repos; infra-lab only consumes their
# URLs via k8s manifests (which already hardcode the registry hostname).
# Closes open issue #6.
# =============================================================================
module "ecr" {
  source = "./modules/ecr"

  cluster_name = "dsl-eks"   # tagging only — repos themselves are stack-agnostic

  repositories = {
    "dsl-frontend" = {
      image_tag_mutability = "IMMUTABLE"
      scan_on_push         = true
    }
    "dsl-backend" = {
      image_tag_mutability = "IMMUTABLE"
      scan_on_push         = true
    }
  }

  lifecycle_untagged_days = 1
  lifecycle_tagged_count  = 10
}
