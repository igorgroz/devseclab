# devseclab — lab start/stop

Operational runbook for bringing the lab up and tearing it down. See
`SESSION_STATE.md` for current status and open issues.

**No implicit pins.** `deploy-lab.yml` always requires an explicit
`image_tag` — there is no "blank = use checked-in manifest" fallback
anymore. That fallback used to silently break whenever ECR's lifecycle
policy expired the pinned tag (see `SESSION_STATE.md`, Jul 27). The image
you deploy always comes from a `security-pipeline.yml` run, copied by hand.
One direction of dependency, no hidden state.

## From scratch (no `infra-base` yet)

Only needed once per AWS account, or after a full account wipe.

```bash
cd terraform/infra-base
terraform init -input=false
terraform plan -out=tfplan
terraform apply "tfplan"
```

This creates the ECR repos, IAM roles (incl. GitHub Actions OIDC role),
and nightly-destroy automation. No cluster yet — none of this needs one.

Once `infra-base` exists, continue below as normal.

## Normal start (base infra already exists)

**Step 1 — build a signed image.** `security-pipeline.yml` builds, scans,
signs, and attests images — this is the only thing that produces something
deployable. It doesn't need a cluster (only its own `deploy` job does, and
that job no-ops gracefully if the cluster isn't up yet):

```bash
gh workflow run security-pipeline.yml
gh run watch
```

At the end of the run, the job summary for the `attest` job prints an
"Image built by this run" table with the exact tag and a ready-to-paste
`deploy-lab.yml` command. Copy the tag from there — don't guess it, don't
assume `github.sha` from your local checkout matches what got built.

**Step 2 — deploy it.** `image_tag` is required, no default:

```bash
gh workflow run deploy-lab.yml \
  -f allowed_cidr="$(curl -s https://icanhazip.com)/32" \
  -f image_tag="<tag from step 1>" \
  -f run_terraform=true
```

- `run_terraform=true` provisions `infra-lab` from scratch (cluster doesn't
  exist yet, or you tore it down with `stoplab.sh`).
- `run_terraform=false` if `infra-lab` is already up and you just want to
  redeploy manifests against it (e.g. rolling out a newer image without a
  full infra cycle).

Watch it:

```bash
gh run list --workflow=deploy-lab.yml --limit=1
gh run watch
```

Confirm it's reachable:

```bash
curl -sI https://lab.oznetsecure.com.au/health
```

### Mid-session IP change

If your public IP rotates while the lab is still up (ISP renewal, network
switch), the ALB will silently stop responding to you. Re-whitelist without
a full redeploy:

```bash
bin/whitelist-me.sh          # interactive
bin/whitelist-me.sh -y       # no prompt
```

### Redeploying after code changes, lab already up

Once `infra-lab` is up, a normal push to `master` (or a manual
`gh workflow run security-pipeline.yml`) runs the full pipeline *and* its
own `deploy` job patches the running Deployments directly via
`kubectl set image` — no need to touch `deploy-lab.yml` again unless the
cluster itself was torn down.

## Stop

**Requires `infra-base` to already exist.** `infra-lab/main.tf` does a live
lookup (`data "aws_iam_role" "github_actions"`) of the `devseclab-github-actions`
role that `infra-base` creates, and wires it into an EKS access entry. Terraform
has to resolve that data source to build the destroy plan — if `infra-base`
were ever torn down first, `stoplab.sh` would fail before doing anything.
In practice this is never an issue since `infra-base` is never destroyed by
this runbook, but it's why the two states aren't fully independent despite
living in separate Terraform state files.

Full clean teardown of `infra-lab` (workloads, ingress, Helm releases,
Terraform-managed infra — 64 resources on a typical run):

```bash
bin/stoplab.sh
```

**Note:** this only tears down `infra-lab`. `infra-base` is a separate
Terraform state and is never touched by `stoplab.sh` — it persists across
every start/stop cycle by design. After a stop, the next start needs both
steps above again (`security-pipeline.yml` if you don't already have a
known-good tag still alive in ECR, then `deploy-lab.yml` with that tag).

## CI/CD — security-pipeline.yml

Triggers: push to `master`/`main` (skips docs-only / `k8s/`, `helm/`,
`terraform/`-only changes via `paths-ignore`), every PR into `master`/`main`,
a weekly Monday 02:00 UTC cron (catches newly-disclosed CVEs), and manual
`workflow_dispatch`.

Stage order, each gated by a manual-review environment when findings are
present (auto-passes clean; `vars.AUTO_APPROVE_GATES` can bypass):

1. **sast** (Semgrep) → `sast-gate`
2. **sca-backend** / **sca-frontend** (npm audit) → `sca-gate`
3. **build** (Docker images, not pushed yet)
4. **container-scan** (Trivy) → `trivy-gate`
5. **push-and-sign** — pushes to GHCR, Cosign keyless-signs, mirrors image
   + signature to ECR (master/main only)
6. **dast** (OWASP ZAP baseline + API scan against a live stack) →
   `dast-gate`
7. **attest** — writes and signs the `vuln-signoff` attestation, copies it
   to ECR, verifies both signature and attestation on the ECR copy, then
   prints the image tag/digests and the `deploy-lab.yml` command to run
8. **deploy** — patches the *already-running* EKS Deployments to the new
   image digests via `kubectl set image` (master/main only, requires
   `attest` success). Only works if the Deployments already exist — after
   a `stoplab.sh` teardown, use `deploy-lab.yml` instead, which creates
   them fresh.

Only `push-and-sign`, `attest`, and `deploy` assume the AWS IAM role — all
three gate on `github.ref == refs/heads/master|main`, so PR runs never
reach AWS credentials.

## Terraform state reference

Two separate states — know which one you're touching.

- **`infra-lab`** — cluster, networking, everything `stoplab.sh` destroys.
  Normally driven by `deploy-lab.yml` (`run_terraform=true`). Manual
  plan/apply: `cd terraform/infra-lab && terraform init -input=false &&
  terraform plan -out=tfplan && terraform apply "tfplan"`.
- **`infra-base`** — IAM roles, OIDC provider, ECR repos, nightly-destroy
  automation. Persists across every lab start/stop. Only touch this for
  IAM/ECR/account-level config changes, not routine lab cycles. Same
  init/plan/apply pattern, from `terraform/infra-base`.

`tfplan` is gitignored; commit only the `.tf` source changes.

## Key identifiers

- Cluster: `dsl-eks` (`ap-southeast-2`)
- Lab URL: `https://lab.oznetsecure.com.au`
- Account: `510151297987`
