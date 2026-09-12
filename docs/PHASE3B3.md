# Phase 3b-3 — External Secrets Operator (ESO)

> Sync AWS Secrets Manager → Kubernetes `Secret` objects via the IRSA-bound
> `sqlinj-eks-eso-role`. End state: the backend Deployment can consume
> `db-password` and `jwt-secret` as ordinary K8s Secrets without any AWS-aware
> code, while the secret values themselves never live in git or the cluster
> control plane longer than ~1 hour without re-validation against AWS.

## 1. Goal & boundaries

**In scope for 3b-3:**
- Install ESO into the `external-secrets` namespace via Helm.
- Create one `ClusterSecretStore` pointing at AWS Secrets Manager.
- Create two `ExternalSecret` objects in `sqlinj` for `db-password` and `jwt-secret`.
- Verify the round-trip: change the AWS value, watch the K8s `Secret` update.

**Out of scope (deferred to 3b-4 / Phase 4):**
- Updating backend/frontend Deployments to consume the synced Secrets.
  The existing `k8s/backend/secret.yaml` is a static literal — it stays in
  place until 3b-4 swaps it for ESO-managed.
- KMS envelope encryption for K8s Secrets at rest in etcd. EKS supports this
  via `cluster.encryption_config` referencing a KMS key; we did NOT enable
  it in our Terraform. Phase 4 hardening item.
- Multi-key JWT rotation with overlap. The current `jwt-secret` is one key,
  one secret — any rotation is a hard cut.

## 2. Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│  AWS account 510151297987 (ap-southeast-2)                           │
│                                                                      │
│   AWS Secrets Manager                                                │
│     ├── sqlinj/backend/db-password    ← human / CI populates         │
│     └── sqlinj/backend/jwt-secret     ← human / CI populates         │
│                                                                      │
│   IAM role: sqlinj-eks-eso-role                                      │
│     trust:    sub = system:serviceaccount:external-secrets:          │
│                       external-secrets-sa                            │
│     policy:   secretsmanager:Get|Describe|List on sqlinj/*           │
│                                                                      │
└────────────┬─────────────────────────────────────────────────────────┘
             │ AssumeRoleWithWebIdentity (JWT exchange)
             ▼
┌──────────────────────────────────────────────────────────────────────┐
│  EKS cluster: sqlinj-eks                                             │
│                                                                      │
│   Namespace: external-secrets                                        │
│     ├── ServiceAccount: external-secrets-sa                          │
│     │     annotation: eks.amazonaws.com/role-arn=...eso-role         │
│     └── Deployment: external-secrets (controller pod)                │
│           reads /var/run/secrets/eks.amazonaws.com/.../token         │
│           AWS SDK swaps it at STS for 1h credentials                 │
│                                                                      │
│   ClusterSecretStore: aws-secrets-manager                            │
│     spec.provider.aws.region: ap-southeast-2                         │
│     spec.provider.aws.auth.jwt.serviceAccountRef →                   │
│       external-secrets:external-secrets-sa                           │
│                                                                      │
│   Namespace: sqlinj                                                  │
│     ├── ExternalSecret: db-password   →   Secret: db-password        │
│     └── ExternalSecret: jwt-secret    →   Secret: jwt-secret         │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

The four cryptographic / identity hops, end-to-end:

1. **Pod → API server** for `TokenRequest`: the ESO controller asks the K8s
   API for a fresh JWT bound to its own SA. The JWT carries `sub`,
   `aud=sts.amazonaws.com`, `exp` (~1h).
2. **K8s API → AWS STS**: ESO calls `AssumeRoleWithWebIdentity` with that
   JWT. STS validates the JWT against the OIDC provider (keys cached from
   the issuer URL) and the role's trust policy. Returns 1h IAM credentials.
3. **ESO → AWS Secrets Manager**: with those creds, ESO calls
   `GetSecretValue` for each `remoteRef.key`.
4. **ESO → K8s API server**: ESO writes/updates the `Secret` object via its
   own SA's RBAC (the chart's ClusterRole grants `secrets: create/update/delete`
   on its own).

No long-lived AWS credentials anywhere; both the ESO-to-AWS and
ESO-to-K8s-API legs use short-lived tokens.

## 3. Files in this phase

| File | What it is |
|------|-----------|
| `helm/external-secrets/values.yaml` | Helm chart values: SA name + IRSA annotation, security context, replicas, log level |
| `k8s/eso/namespace.yaml` | `external-secrets` and `sqlinj` namespaces with PSA labels |
| `k8s/eso/clustersecretstore.yaml` | One `ClusterSecretStore` for AWS Secrets Manager via JWT auth |
| `k8s/eso/externalsecret-db-password.yaml` | Sync `sqlinj/backend/db-password` → K8s Secret `db-password` |
| `k8s/eso/externalsecret-jwt-secret.yaml` | Sync `sqlinj/backend/jwt-secret` → K8s Secret `jwt-secret` |

## 4. Apply order (tomorrow's runbook)

Assumes infra has been re-applied (Phase 3a) and ALBC is installed (3b-2)
with kubectl pointed at `sqlinj-eks`.

```bash
# --- 1. Real secret values into AWS (Terraform seeded placeholders) -----
aws secretsmanager put-secret-value \
  --secret-id sqlinj/backend/db-password \
  --secret-string "$(openssl rand -base64 32)"

aws secretsmanager put-secret-value \
  --secret-id sqlinj/backend/jwt-secret \
  --secret-string "$(openssl rand -base64 64)"

# --- 2. Namespaces + PSA labels ----------------------------------------
kubectl apply -f k8s/eso/namespace.yaml

# --- 3. Helm install ESO -----------------------------------------------
helm repo add external-secrets https://charts.external-secrets.io
helm repo update external-secrets
helm search repo external-secrets/external-secrets --versions | head -10
# pick the chart version whose APP VERSION is the one you want, then:
helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace external-secrets \
  --version <CHART_VER> \
  -f helm/external-secrets/values.yaml \
  --wait --timeout 5m

# --- 4. Verify the controller is up and IRSA-bound ---------------------
kubectl get pods -n external-secrets
kubectl get sa external-secrets-sa -n external-secrets -o yaml | grep role-arn
kubectl logs -n external-secrets deploy/external-secrets --tail 50 | \
  grep -Ei 'AccessDenied|WebIdentityErr|started|ready|leader'

# --- 5. Apply the ClusterSecretStore + ExternalSecrets -----------------
kubectl apply -f k8s/eso/clustersecretstore.yaml
kubectl get clustersecretstore aws-secrets-manager
#  STATUS column should report "Valid" within a few seconds

kubectl apply -f k8s/eso/externalsecret-db-password.yaml
kubectl apply -f k8s/eso/externalsecret-jwt-secret.yaml

# --- 6. Verify round-trip ----------------------------------------------
kubectl get externalsecret -n sqlinj
#  Both should show SYNCED=True, READY=True

kubectl get secret -n sqlinj
#  db-password and jwt-secret should now exist

# Compare values:
kubectl get secret db-password -n sqlinj -o jsonpath='{.data.password}' | base64 -d ; echo
aws secretsmanager get-secret-value --secret-id sqlinj/backend/db-password --query SecretString --output text
#  These two MUST match.
```

## 5. Verification: rotation works

```bash
# Rotate the AWS-side value
aws secretsmanager put-secret-value \
  --secret-id sqlinj/backend/db-password \
  --secret-string "rotated-$(date +%s)"

# Force ESO to re-sync immediately rather than waiting for refreshInterval
kubectl annotate externalsecret db-password -n sqlinj \
  force-sync=$(date +%s) --overwrite

# Re-read the K8s Secret — should match the new AWS value within seconds
kubectl get secret db-password -n sqlinj -o jsonpath='{.data.password}' | base64 -d ; echo
```

If this works, rotation is closed-loop: AWS Secrets Manager is the source
of truth, and K8s consumers see updates without any change to their pod spec.

## 6. Threat model — what this DOES and DOESN'T protect against

**Does protect against:**
- Secrets in git history or container images (they're never written to either).
- Long-lived AWS access keys living in the cluster (only ~1h STS tokens, rotated).
- A compromised non-`external-secrets` namespace stealing ESO's role: the
  IRSA trust policy pins `sub` to the exact (ns, sa) — a different SA in a
  different namespace gets denied at STS.
- A compromised app pod reading AWS Secrets Manager directly: the backend
  has its own narrower IRSA role (`sqlinj/backend/*` only), and the K8s
  Secret it consumes can't be used to derive AWS credentials.

**Does NOT protect against:**
- A user with `kubectl get secret -n sqlinj -o yaml` permission. The K8s
  Secret is the literal cleartext (base64-encoded). Use RBAC + audit logs.
- Secrets at rest in etcd: by default they're only base64. Enable EKS KMS
  envelope encryption (Phase 4) so etcd-on-disk is wrapped.
- A compromised ESO pod: it has read access to all `sqlinj/*` secrets in
  AWS plus write access to all K8s Secrets cluster-wide via its
  ClusterRole. ESO is a high-value target — keep it small, scan its image,
  pin its version, audit its egress (all calls go to STS + Secrets Manager
  regional endpoints; anything else is exfil).
- Memory dumps of the consumer pod: the backend ultimately holds the
  cleartext in process memory. Out of scope.

## 7. Open questions for tomorrow

1. **Refresh interval.** `1h` is the chart default; for higher-rotation
   workloads (e.g., DB creds rotated by an external system every 15min),
   consider 5-15min. Trade-off: more STS + Secrets Manager API calls = more
   cost + more rate-limit headroom needed.
2. **K8s Secret consumers and rotation propagation.** Pods using `envFrom`
   capture the Secret value at start; rotation does NOT propagate without
   a pod restart. Pods using `volumeMount` of the Secret get the new value
   automatically (kubelet syncs ~1min). 3b-4 should pick volumes for the
   backend.
3. **Should the chart's `installCRDs: true` flip to `false`?** In a GitOps
   setup the CRDs are usually applied by a separate tool (kustomize layer,
   another chart). For the lab, leaving `true` is fine. Flag for revisit.

## 8. References

- ESO docs: https://external-secrets.io
- AWS provider auth modes: https://external-secrets.io/latest/provider/aws-secrets-manager/
- Pod Security Admission: https://kubernetes.io/docs/concepts/security/pod-security-admission/
- IRSA design: https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html
