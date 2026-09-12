# Lab Security Decisions — Conscious Deviations from Production Posture

This document records every deliberate decision in the devseclab lab that
does not match production best practice, with the rationale and the production
pattern that would replace it.

The goal is to ensure these are *conscious* trade-offs, not oversights — and to
provide a clear upgrade path if any component of this lab is adapted for production use.

---

## Infrastructure (Terraform — Phase 3a)

### TF-01 · Single NAT Gateway
| | |
|---|---|
| **Lab** | One NAT gateway in `ap-southeast-2a` shared by all three private subnet AZs |
| **Production** | One NAT gateway per AZ (three total for ap-southeast-2) |
| **Rationale** | NAT gateways cost ~$0.045/hr each (~$1.08/day). For a nightly-destroyed lab this saves ~$2.16/day |
| **Risk** | If `ap-southeast-2a` fails, nodes in `ap-southeast-2b` and `ap-southeast-2c` lose outbound internet access (no ECR pulls, no AWS API calls) |
| **Production fix** | Set `single_nat_gateway = false` in the vpc module call |

---

### TF-02 · Public EKS API Endpoint (0.0.0.0/0)
| | |
|---|---|
| **Lab** | `endpoint_public_access = true` with `public_access_cidrs = ["0.0.0.0/0"]` |
| **Production** | `endpoint_public_access = false` (private endpoint only, access via VPN or AWS PrivateLink) OR public endpoint restricted to known CIDR(s) |
| **Rationale** | Allows `kubectl` from any machine without a VPN. Authentication still requires valid AWS credentials + kubeconfig, so the attack surface is limited to the K8s API itself rather than unauthenticated access |
| **Risk** | EKS API is reachable from the internet — any K8s API vulnerability is exploitable remotely. Blast radius of a credential compromise is higher |
| **Production fix** | Set `enable_cluster_endpoint_public_access = false` and `cluster_endpoint_public_access_cidrs` to your office/VPN CIDR, or disable entirely and use VPN |

---

### TF-03 · CodeBuild Project Without KMS Encryption
| | |
|---|---|
| **Lab** | `aws_codebuild_project` has no `encryption_key` argument — uses AWS-managed encryption |
| **Production** | Customer-managed KMS key (CMK) on the CodeBuild project |
| **Rationale** | The nightly destroy project has no build artifacts and injects no sensitive environment variables (credentials come from the IAM role, not env vars). AWS-managed encryption still encrypts at rest — you just can't rotate the key or audit access via CloudTrail |
| **Risk** | No key rotation control; cannot use IAM key policy to restrict who can decrypt build artifacts; no CloudTrail audit of key usage |
| **Production fix** | Create `aws_kms_key` with appropriate key policy, reference ARN in `encryption_key` on the CodeBuild project |

---

### TF-04 · CodeBuild IAM Role Uses AdministratorAccess
| | |
|---|---|
| **Lab** | `arn:aws:iam::aws:policy/AdministratorAccess` attached to the CodeBuild nightly-destroy role |
| **Production** | Custom IAM policy scoped to specific services + `aws:ResourceTag` conditions (e.g. `eks:DeleteCluster` with condition `aws:ResourceTag/ManagedBy = terraform`) |
| **Rationale** | Building a complete least-privilege destroy policy requires enumerating every resource type Terraform manages (EKS, VPC, ECR, IAM, Secrets Manager, CloudWatch, etc.) — significant effort for a lab |
| **Risk** | If the CodeBuild role is compromised, the attacker has full account access. The role is only assumable by `codebuild.amazonaws.com` from this account, limiting blast radius |
| **Production fix** | Replace `AdministratorAccess` with a custom policy. Use the tagging strategy (`AutoDestroy=true`) already applied to infra-lab resources to scope IAM actions with `aws:ResourceTag` conditions |

---

### TF-05 · No KMS Envelope Encryption on EKS etcd (Kubernetes Secrets)
| | |
|---|---|
| **Lab** | No `encryption_config` block on `aws_eks_cluster` |
| **Production** | KMS CMK specified in `encryption_config` — encrypts Kubernetes Secrets (stored in etcd) with a customer-managed key |
| **Rationale** | Without encryption config, K8s Secrets in etcd are base64-encoded but not encrypted. In this lab, sensitive values (DB password, JWT secret) come from Secrets Manager via ESO and are never stored as K8s Secrets long-term in plaintext |
| **Risk** | If etcd or the EKS control plane is ever compromised, K8s Secrets are readable without key access |
| **Production fix** | Create `aws_kms_key` + add `encryption_config` block to `aws_eks_cluster`. Note: enabling this on an existing cluster requires a rolling node group update |

---

### TF-06 · No RDS — PostgreSQL Runs in Kubernetes
| | |
|---|---|
| **Lab** | PostgreSQL deployed as a K8s `Deployment` + `PersistentVolumeClaim` (EBS volume) |
| **Production** | Amazon RDS for PostgreSQL (or Aurora PostgreSQL) with Multi-AZ, automated backups, and credentials in Secrets Manager |
| **Rationale** | RDS costs ~$25-50/month minimum. For a lab focused on IRSA, application security, and WAF patterns, in-cluster PostgreSQL achieves the same learning outcomes |
| **Risk** | No automated backups (data lost on `terraform destroy`), no Multi-AZ failover, database pod restart loses connections, EBS volume is AZ-pinned (if AZ fails, DB is unavailable) |
| **Production fix** | Use `aws_db_instance` or `aws_rds_cluster` with `multi_az = true`, `backup_retention_period >= 7`, and inject credentials via Secrets Manager + IRSA |

---

### TF-07 · State Bucket Uses SSE-AES256, Not SSE-KMS
| | |
|---|---|
| **Lab** | `SSEAlgorithm: AES256` (AWS-managed key) on the Terraform state S3 bucket |
| **Production** | `SSEAlgorithm: aws:kms` with a CMK and a key policy restricting decryption to specific IAM roles |
| **Rationale** | AES256 still provides encryption at rest and is free. KMS charges ~$1/month per CMK plus $0.03 per 10,000 API calls — acceptable in production, unnecessary overhead for a lab |
| **Risk** | No per-request CloudTrail audit of state file reads; cannot restrict key access via key policy; no key rotation control |
| **Production fix** | Create `aws_kms_key` with key policy allowing only `terraform-apply` and `codebuild-destroy` roles to `kms:Decrypt`, reference in `put-bucket-encryption` |

---

### TF-08 · VPC Flow Logs and EKS Audit Logs Retained 14 Days
| | |
|---|---|
| **Lab** | CloudWatch Log Groups for VPC flow logs and EKS audit logs set to `retention_in_days = 14` |
| **Production** | 90-365 days in CloudWatch, or export to S3 with S3 Intelligent-Tiering for long-term cost-effective retention. Security standards (PCI DSS, ISO 27001) typically require 12 months minimum |
| **Rationale** | CloudWatch Logs storage cost (~$0.03/GB/month) accumulates. For a nightly-destroyed lab, 14 days is more than enough to review any destroy job failures |
| **Production fix** | Increase `retention_in_days` or create a CloudWatch → S3 export subscription filter for long-term archival |

---

## CI/CD Pipeline (Phase 2)

### CI-01 · Semgrep Free Tier (No Taint Analysis)
| | |
|---|---|
| **Lab** | `semgrep --config=p/sql-injection` (community rules, pattern matching only) |
| **Production** | Semgrep Code (Pro) with taint analysis, or a commercial SAST tool (Checkmarx, Veracode, Snyk Code) |
| **Rationale** | Free rules reliably catch string concatenation SQL injection but miss template literal injection (`${variable}` in JS). Phase 2 demonstrated this gap explicitly — ZAP (DAST) caught what Semgrep missed |
| **Risk** | Template literal injections, multi-step data flows, and cross-function taint paths are not detected by free rules |
| **Production fix** | Enable Semgrep Pro or add a taint-aware scanner. Alternatively, add custom Semgrep rules targeting `${req.params.*}` patterns in SQL context |

---

### CI-02 · DAST Runs Against an Unauthenticated Surface Only
| | |
|---|---|
| **Lab** | ZAP API scan covers unauthenticated endpoints only — no JWT auth configured in the scan |
| **Production** | ZAP (or equivalent) configured with a valid JWT bearer token and scripted authentication to scan authenticated endpoints |
| **Rationale** | Authentication scripting in ZAP requires additional pipeline complexity (token generation step, ZAP auth script). Intentionally deferred to keep Phase 2 focused |
| **Risk** | Authenticated endpoints (any route requiring a valid JWT) are not DAST-scanned. Vulnerabilities behind auth are not detected by the pipeline |
| **Production fix** | Add a ZAP authentication script or use `ZAP_AUTH_HEADER`/`ZAP_AUTH_HEADER_VALUE` env vars in the pipeline to inject a pre-generated JWT |

---

## Application / Kubernetes

### K8S-01 · Self-Signed TLS Certificate (minikube / Phase 1-2)
| | |
|---|---|
| **Lab** | mkcert-generated self-signed certificate, `devseclab.local` in `/etc/hosts` |
| **Production** | ACM certificate with DNS validation, provisioned by Terraform, attached to the ALB. Domain delegated to Route 53 via NS records at registrar (Dodo) |
| **Rationale** | Production TLS requires a real domain and Route 53 hosted zone — addressed in Phase 3b |
| **Production fix** | `aws_acm_certificate` + `aws_route53_record` for DNS validation + ALB listener with HTTPS |

---

### K8S-02 · PostgreSQL Container Runs as Root (runAsNonRoot: false)
| | |
|---|---|
| **Lab** | `k8s/db/deployment.yaml` sets `runAsNonRoot: false` |
| **Production** | PostgreSQL official image (postgres:14+) supports running as a non-root user via `--user` flag or `POSTGRES_USER` env var, combined with correct volume ownership |
| **Rationale** | The official `postgres` image entrypoint requires root to set up `/var/lib/postgresql/data` permissions before dropping to the `postgres` user (uid 999). Requires additional init-container or custom entrypoint to run fully non-root |
| **Risk** | PostgreSQL process initially runs as root inside the container. If the container is escaped, the attacker has root on the node (unless seccomp/AppArmor/Seccomp profiles are in place) |
| **Production fix** | Use a custom postgres image with a non-root entrypoint, or add a `securityContext.runAsUser: 999` with an `initContainer` that sets correct ownership on the data volume |

---

*Last updated: Phase 3a (April 2026)*
*Maintained alongside LEARNING_PATH.md — update this file whenever a new conscious trade-off is introduced*
