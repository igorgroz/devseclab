# Kyverno deep dive — concepts, lab usage, best practices

**Audience:** working notes for the DevSecOps platform lab — what Kyverno is, how the lab is using it, the operational lessons baked in so far, and how it slots into upcoming phases. Companion to `COSIGN_SIGNING_DEEP_DIVE.md` (signing side of the supply-chain story) and `KYVERNO_ECR_VERIFY_FIX.md` (forensic record of the IRSA-and-timeout failure mode).

---

## 1. What Kyverno actually is

Kyverno is a Kubernetes-native policy engine. The defining design choice — and the reason it's pleasant to live with — is that policies are themselves Kubernetes resources written in YAML. There's no second language to learn: no Rego like OPA/Gatekeeper, no CEL like ValidatingAdmissionPolicy, no JavaScript like Kyverno-JSON. A `ClusterPolicy` looks structurally like a `Deployment`: `metadata`, `spec`, fields you can pattern-match against with `kubectl get`. This sounds cosmetic but has knock-on effects — you write policies with the same mental model as the workloads they govern, you debug them with `kubectl get policyreport`, and your existing GitOps tooling already knows how to ship them.

Architecturally it is a set of Kubernetes controllers that register themselves as admission webhooks against the API server. When you `kubectl apply` anything, the API server consults the webhook list, sees Kyverno's `mutate.kyverno.svc-fail` and `validate.kyverno.svc-fail` entries match the resource, and forwards the `AdmissionReview` to Kyverno's admission-controller pods. Kyverno evaluates every matching policy in its in-memory cache, returns an allow/deny verdict (plus any mutation patches) within the webhook timeout, and the API server proceeds or rejects.

The webhooks are split by failure strategy — there's a `-fail` set and an `-ignore` set, so individual policies can opt into "block admission if I'm down" vs "let it through" independently. This split is the bit that bit the lab during the cosign timeout incident: the `-fail` webhook ran out of budget before cosign finished verifying, and the API server treated the timeout as a denial.

## 2. The five rule types

Kyverno has five rule types and you'll meet all of them in this lab eventually.

**validate** is the bread-and-butter — assert that submitted resources match a pattern. "Every container must have resource limits." "No `:latest` tags." "Pods must have `runAsNonRoot: true`." Pattern matching uses an `=()`/`!=()`/`?()` overlay syntax which feels weird at first then becomes natural. Modes are `Enforce` (deny non-matching) or `Audit` (record in a PolicyReport without blocking).

**mutate** rewrites incoming resources before they're persisted. "Add `imagePullPolicy: Always` if missing." "Inject the `sidecar.istio.io/inject: true` label on production namespaces." Strategic merge patch or JSON patch, applied in admission. The mutations are visible to everything downstream, including other Kyverno rules in the same admission.

**generate** is the rule type developers most underestimate. It creates other resources triggered by an event. "When a `Namespace` with label `app=foo` is created, generate this `NetworkPolicy`, this `ResourceQuota`, this `RoleBinding` in it." Kyverno owns the lifecycle of the generated resource — if you delete it or mutate it, Kyverno reconciles back to the policy-defined state. It's a lightweight controller-as-policy.

**verifyImages** is the supply-chain rule type. It runs `cosign verify` and `cosign verify-attestation` inline at admission time. Signature verification, attestation predicates with JMESPath conditions over the decoded payload. This is what the lab's `dsl-verify-images` ClusterPolicy is using.

**cleanup** (newer, v1.10+) deletes resources on a schedule that match a pattern. "Delete completed Jobs older than 7 days." "Delete unused ConfigMaps in `dev` namespaces." Implemented as a separate controller because it's not admission-driven.

## 3. The four controllers

The Kyverno install is not one pod, it's four deployments — each is its own concern with different scaling characteristics.

The **admission controller** handles all admission webhooks and evaluates rules synchronously inside the API server's request budget. This is the latency-sensitive one and the SPOF risk — hence the lab's 3 replicas + PDB + 1 Gi memory limit. Anything you do here is on the hot path of every `kubectl apply` to the cluster.

The **background controller** runs `validate` and `mutate` rules in a reconcile loop against existing resources (for policies with `background: true`). Useful for "make sure every Pod that's already running matches my policy" and for generating reports about old workloads when you introduce a new rule.

The **reports controller** consumes `EphemeralReport` and `ClusterEphemeralReport` events emitted by admission, aggregates them, and writes `PolicyReport` / `ClusterPolicyReport` CRDs. These are what you `kubectl get policyreport -n dsl -o yaml` to see. Policy reports are the audit trail and the way you find out which Pods are non-compliant under `Audit` mode without blocking them.

The **cleanup controller** owns the cleanup-rule CronJobs and the housekeeping for stale reports/ephemeral reports. It's the one whose CronJobs were doing the `ImagePullBackOff` dance with the dead `bitnami/kubectl` image until the chart values swapped it for `registry.k8s.io/kubectl`.

## 4. What the lab is doing right now

The `dsl-verify-images` ClusterPolicy is a single `verifyImages` rule. Walk through what happens when you `kubectl apply -f k8s/backend/deployment.yaml`.

The API server creates the Deployment, which spawns a ReplicaSet, which tries to create Pods. Each Pod creation hits the admission chain. Kyverno's mutating webhook fires first — it sees a Pod in the `dsl` namespace with an image matching `510151297987.dkr.ecr.ap-southeast-2.amazonaws.com/dsl-*`, so the policy applies. Cosign authenticates to ECR (now that IRSA gives it an `ecr:GetAuthorizationToken` route via the `dsl-eks-kyverno-ecr-read` role), fetches the `.sig` artifact tagged `sha256-<digest>.sig` and the `.att` artifact tagged `sha256-<digest>.att`. It validates the Fulcio certificate chain on the signature's leaf cert against Sigstore's trusted root (cached in the `/.sigstore` emptyDir as TUF roots), confirms the cert's OIDC identity matches `https://github.com/igorgroz/devseclab/.github/workflows/*` with issuer `https://token.actions.githubusercontent.com`, and validates the Rekor SET (signed entry timestamp) confirming this signature was logged in the public transparency ledger.

Then it does the same dance for the attestation, but with one extra step — after verifying the attestation's signature, it base64-decodes the in-toto statement's payload, JSON-parses it, and evaluates the four JMESPath conditions: `predicate.gates.sast.status`, `predicate.gates.sca.status`, `predicate.gates.trivy.status`, `predicate.gates.dast.status` must all be in `[clean, accepted, skipped]`. If any gate is `failed` or missing, the policy denies and the rejected admission carries a structured error explaining which gate.

This is meaningful security. It means there is no path to running app code in `dsl` that did not (a) pass through your pipeline, (b) have the four gates resolved with documented outcomes, and (c) leave a public, append-only Rekor record of being signed. An attacker who pushes malicious code to the repo still has to traverse a gated pipeline that produces a signed attestation. An attacker who compromises ECR can't replace the image — they'd need to also forge a Fulcio-signed bundle whose OIDC identity matches the workflow URL.

There is also a `background: false` setting which means Kyverno only evaluates at admission, not against already-running Pods. Useful for `verifyImages` because re-running cosign every five minutes against every Pod would be expensive. The `mutateDigest: false` / `verifyDigest: false` pair tells Kyverno to leave the image reference as a tag (the SHA tag the pipeline produces) rather than rewriting to `image@sha256:...`. Less impactful manifests, slightly weaker guarantee — ECR tag immutability via the repo policy is doing the heavy lifting there.

## 5. Best practices, learned the painful way

**Scope your webhooks tight.** By default Kyverno installs cluster-wide. The namespace exclusion list (`kube-system`, `kyverno`) is the bare minimum — anything mission-critical like `cert-manager`, `aws-load-balancer-controller`, `external-secrets` should be excluded too, because if Kyverno is down and those need to admit a pod (e.g., a renewal), you get deadlock. For app-only policies, attach a `namespaceSelector` with `In: [dsl]` rather than relying on the exclusion list.

**Always run new policies in `Audit` first, then flip to `Enforce`.** Even ones you're confident about. The PolicyReports tell you what would have been blocked. Half the time you discover a deployment that's not signed but you forgot about (a Helm hook, a CronJob, a vendor operator) and you would have broken something at 03:00.

**Webhook timeout is a contract, not a default.** The mutating webhook has `timeoutSeconds` and Kubernetes will not extend it. Anything in your policy that does a network call — cosign verify, external data sources, `apiCall` — must complete inside that budget across all matching rules summed. 30 s is the upstream ceiling for verifyImages; past that, the API server itself is in trouble.

**Use `failurePolicy: Fail` only where you mean it.** For `verifyImages` we mean it — admitting an unsigned image because Kyverno is down defeats the entire control. For something like "validate labels exist" you can argue `Ignore` is fine, because the workload still runs and you'll catch it in the report. The decision is: "is this control's purpose to prevent damage, or to require correctness?" Damage-prevention → Fail. Correctness → Ignore + alert on PolicyReport.

**Replicas + PDB. Always.** A single-replica fail-closed webhook is a cluster-wide outage waiting for a node-replacement event. The lab's first Kyverno install was single-replica and that was the underlying reason a single pod hiccup looked like a permanent admission outage.

**Image-verify cache is your friend.** Kyverno caches successful verify results for 1 h (`--imageVerifyCacheTTL=1h`) keyed by image digest. After the first cold verify the latency budget collapses from ~15 s to under 100 ms. Don't blow the cache unnecessarily (avoid restarts and OOMKills) — keep the pod stable. Sizing the memory limit at 1 Gi exists to keep the cache resident.

**`PolicyException`, not ad-hoc edits.** When you find a workload that legitimately can't comply, write a `PolicyException` resource that names exactly which policy and which workload is exempt, and gate that with RBAC so only platform admins can create them. Auditable, time-bounded, recoverable. The alternative — commenting out a `match` block in the policy — leaves your security model in a code review you can't find later.

**Exceptions in their own namespace.** Set `--exceptionNamespace=kyverno-exceptions` then RBAC the namespace so only your platform team has write access. Developers can't quietly grant themselves bypasses.

**Don't conflate `validate` mode and `verifyImages` mode behaviour.** Bit the lab during the IRSA fix: `validationFailureAction: Audit` does NOT cause `verifyImages` errors to fail open. Verify errors are deny-by-default in Kyverno ≥ v1.12. If you want fail-open behaviour on verify failures, that's a separate flag (`required: false` on the rule) and you should think hard before setting it.

## 6. Operational caveats specific to this lab

- The `kyverno-admission-controller` SA is annotated post-install via `kubectl annotate sa --overwrite` rather than via `helm --set`. The dotted annotation key `eks.amazonaws.com/role-arn` doesn't survive Helm 3's path-escape parser reliably across CI shells. The workflow comments and `KYVERNO_ECR_VERIFY_FIX.md` capture the why.
- The cluster runs distroless Kyverno images — no `env`, no `sh`, no coreutils. Any in-cluster verification (e.g. the IRSA env assertion in the deploy workflow) must use `kubectl get pod -o jsonpath` against the pod spec, not `kubectl exec env`.
- The cleanup CronJobs ship with `bitnami/kubectl` by default — Bitnami deprecated those tags mid-2025. `helm/kyverno/values.yaml` overrides every cleanup job to `registry.k8s.io/kubectl` so the cluster doesn't accrue `ImagePullBackOff` noise.
- The OIDC provider for IRSA is created by the EKS module — the same one ALBC and ESO use. Adding a new IRSA role for any future Kyverno consumer (e.g. an external image-verify cache) means a new `aws_iam_role` with `module.eks.oidc_provider_arn` as the federated principal and a `sub` condition pinning the SA. The pattern is in `terraform/infra-lab/kyverno-irsa.tf` and `alb-controller-iam.tf`.

## 7. How Kyverno slots into the next phases

**NetworkPolicies + PSS on `dsl`.** Two relevant patterns. First, use `validate` rules to enforce Pod Security Standards inline at admission — there's an upstream policy library (the `pod-security` set) that codifies the PSS profiles. Drop them into the cluster and you get the same enforcement Kubernetes' built-in PSS admission gives you, but with PolicyReports for visibility and PolicyExceptions for explicit exemptions, which native PSS admission doesn't have. Second, use a `generate` rule to auto-create a baseline `NetworkPolicy` in every namespace as it's created — "default-deny-all egress except DNS and same-namespace" is the typical shape. Combined with `validate` rules that block NetworkPolicies that allow too much, the platform self-administers a zero-trust posture.

**Enterprise platform track — Kong, Istio mTLS, CloudFront + WAF.** Kyverno earns its keep again. For Istio: a `mutate` rule that injects `sidecar.istio.io/inject: "true"` on the `dsl` namespace label, plus a `validate` rule that requires every Service in `dsl` to have a matching `DestinationRule` enforcing `mTLS: STRICT`, plus a `verifyImages` extension covering Istio proxy images (signed by Solo.io and Sigstore). For Kong: validate that every `KongPlugin` has rate-limit + jwt-auth attached. For CloudFront/WAF: validate that every Ingress carries the `alb.ingress.kubernetes.io/wafv2-acl-arn` annotation pointing at the WAF ACL, so it's impossible to expose a service through ALB without WAF in front.

**Reference workload exploration (Online Boutique / Sock Shop).** This is where Kyverno's pattern-matching shines — apply the dsl policy set to a known-good demo workload and see what flags. It's also a great way to test policies' false-positive rates before they hit your real code.

There's also a slightly bigger-picture architectural move worth flagging: once `verifyImages`, `mutate` (sidecar injection), `validate` (PSS), and `generate` (NetworkPolicy bootstrap) are running together, you have effectively replaced four separate admission controllers / operators with one engine. That's the architectural story for the lab write-up — "policy-as-data, declarative governance, single audit surface" is a stronger pitch than "we added Kyverno."

## 8. Useful commands while learning

```bash
# What is admitted/rejected — the audit trail under Audit mode
kubectl get policyreport -A
kubectl get clusterpolicyreport
kubectl describe policyreport -n dsl polr-ns-dsl

# Which policies are loaded
kubectl get clusterpolicy
kubectl get policy -A

# Why was this specific Pod allowed/denied
kubectl describe policyreport -n dsl polr-ns-dsl | grep -A5 <pod-name>

# Webhook configuration in effect
kubectl get mutatingwebhookconfigurations | grep kyverno
kubectl get validatingwebhookconfigurations | grep kyverno
kubectl get mutatingwebhookconfigurations kyverno-resource-mutating-webhook-cfg -o yaml \
  | yq '.webhooks[] | {name, failurePolicy, timeoutSeconds, namespaceSelector}'

# Force a fresh verify (the in-pod cache has 1h TTL)
kubectl -n kyverno rollout restart deployment/kyverno-admission-controller

# Negative test — should be rejected when the policy is Enforce
kubectl run nginx --image=nginx:latest -n dsl --dry-run=server -o yaml

# See exactly what cosign is doing in the admission path
kubectl -n kyverno logs -l app.kubernetes.io/component=admission-controller \
  --tail=100 -f | grep -E 'engine.verify|cosign|webhooks.resource.mutate'
```

## 9. Where to read further

- Upstream docs: https://kyverno.io/docs/
- Policy library: https://kyverno.io/policies/
- `verifyImages` reference: https://kyverno.io/docs/writing-policies/verify-images/
- Sigstore architecture (Fulcio + Rekor + TUF): https://docs.sigstore.dev/
- The lab's own forensic record: `KYVERNO_ECR_VERIFY_FIX.md`
- The lab's signing-side companion: `COSIGN_SIGNING_DEEP_DIVE.md`
