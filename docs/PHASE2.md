# Phase 2 — GitHub Actions Security Pipeline

## Pipeline overview

```
PR trigger:      sast ──┬── sca-backend ──┐
                        └── sca-frontend ─┤
                                          └── (build blocked until all pass)

push main:       sast ──┬── sca-backend ──┐
                        └── sca-frontend ─┴── build ── container-scan ── push-and-sign ── dast

schedule (Mon):  sca-backend + sca-frontend (catches new CVEs against pinned deps)
```

Jobs and their security rationale:

**sast (Semgrep)** — static analysis before any code runs. Rules: `p/javascript`, `p/react`, `p/nodejs`, `p/owasp-top-ten`, `p/sql-injection`. Runs inside the official Semgrep container. Uploads SARIF to the GitHub Security → Code Scanning tab. Exits 1 on `ERROR`-severity findings. For a richer ruleset, create a Semgrep account, grab an app token, and add `SEMGREP_APP_TOKEN` as a secret — you'll get the managed pro rules including secrets detection.

**sca-backend / sca-frontend** — software composition analysis via `npm audit`. The built-in `--audit-level` flag is intentionally set to `none` so the full JSON is captured; we parse `metadata.vulnerabilities` ourselves and gate only on HIGH/CRITICAL. This gives you fine-grained control and a complete artifact for audit purposes. The pipeline gates on fixable vulns — if `fixAvailable: true` and severity is HIGH/CRITICAL, it's a blocker.

**build** — multi-stage Docker build with BuildKit GHA cache. Scoped caches (`scope=frontend`, `scope=backend`) avoid cache poisoning between jobs. Images are built but not pushed here — that only happens after scanning passes.

**container-scan (Trivy)** — scans both images for OS and language-level CVEs. `ignore-unfixed: true` means the gate only triggers when a patched version of the vulnerable package exists and you haven't upgraded to it. Accepted-risk CVEs go in `.trivyignore` with documented justification and revisit dates. Results appear in GitHub Security → Code Scanning alongside Semgrep findings.

**push-and-sign (Cosign keyless)** — images are pushed to GHCR then signed using Cosign in keyless mode. There's no private key to manage: GitHub Actions' OIDC token is exchanged with Sigstore's Fulcio CA for a short-lived signing certificate. The certificate and signature are logged permanently to the Rekor transparency log. The self-verify step confirms the signature resolves correctly before DAST proceeds. The signing identity is bound to this specific workflow URL — a compromised image pushed outside this workflow cannot produce a valid signature.

**dast (OWASP ZAP)** — runs against a live stack using the signed images pulled from GHCR. Two scan modes: baseline (spider + passive analysis) and api-scan (active scan against the OpenAPI spec at `/api-docs`). Both produce HTML/JSON reports uploaded as GitHub Actions artifacts. The api-scan is set to `fail_action: false` on first run — flip it to `true` once you've reviewed the initial output and suppressed legitimate false positives in `.zap/rules.tsv`.


## Secrets to configure in GitHub → Settings → Secrets and variables → Actions

| Secret name        | Value                                                                                        |
|--------------------|----------------------------------------------------------------------------------------------|
| `DAST_DB_PASSWORD` | Any strong password (ephemeral DB used only during DAST scan — no real data)                 |
| `DAST_JWT_SECRET`  | 32+ byte random secret; same value your backend uses in `AUTH_MODE=dast` to sign test tokens |
| `SEMGREP_APP_TOKEN`| Optional — from semgrep.dev; enables managed pro rules and findings dashboard                |

`GITHUB_TOKEN` is auto-provisioned by Actions — no manual configuration needed for GHCR push or SARIF upload.


## Backend changes required for AUTH_MODE=dast

The DAST overlay injects `AUTH_MODE=dast` and `JWT_SECRET` into the backend container. Your auth middleware needs to handle this:

```javascript
// backend/src/middleware/auth.js (pseudocode)
if (process.env.AUTH_MODE === 'dast') {
  // Validate against local JWT_SECRET instead of Entra ID JWKS
  const payload = jwt.verify(token, process.env.JWT_SECRET);
  req.user = payload;
  return next();
}
// Normal path: validate against Entra ID JWKS URI
```

To generate a test JWT for ZAP's Authorization header:
```bash
node -e "
  const jwt = require('jsonwebtoken');
  const token = jwt.sign(
    { sub: 'dast-test-user', roles: ['user'] },
    process.env.DAST_JWT_SECRET,
    { expiresIn: '8h' }
  );
  console.log(token);
"
```
Store this token as a ZAP replacer rule in `.zap/rules.tsv` or pass it via the ZAP action's `cmd_options`.


## OpenAPI spec requirement for api-scan

The ZAP api-scan targets `http://localhost:4000/api-docs`. If your backend doesn't yet expose an OpenAPI spec, add `swagger-jsdoc` + `swagger-ui-express`:

```bash
cd backend && npm install swagger-jsdoc swagger-ui-express
```

Annotate your routes with JSDoc `@swagger` comments, mount the UI under `/api-docs`, and set `SWAGGER_ENDPOINT_PUBLIC=true` in the DAST override so ZAP can reach it without auth.


## GitHub Security tab — what you'll see

After the first successful pipeline run:
- **Security → Code Scanning**: Semgrep findings + Trivy CVE findings, all with severity, CWE, and file/line location. You can dismiss individual alerts with justification (tracked in the audit log).
- **Packages → sqlinj-frontend / sqlinj-backend**: Signed container images. The signature can be verified by anyone with the Cosign CLI:

```bash
cosign verify \
  --certificate-identity-regexp="https://github.com/igorgroz/devseclab/.github/workflows/.*" \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
  ghcr.io/igorgroz/sqlinj-backend:latest
```


## ZAP rules tuning workflow

First run will produce noise. The process:

1. Review `zap-baseline-report` and `zap-api-report` artifacts in the Actions run.
2. For alerts that are genuine false positives in this lab context, set them to `PASS` in `.zap/rules.tsv` with a comment explaining why.
3. For alerts that need investigation but shouldn't fail the build yet, set to `WARN`.
4. Once the api-scan output is clean, flip `fail_action: false` → `true` in the workflow.

ZAP alert IDs are in the report's JSON output and in the OWASP ZAP alerts catalogue at https://www.zaproxy.org/docs/alerts/.


## Phase 3 preview

With the pipeline solid, logical next steps:
- **SBOM generation** — add `syft` or `trivy sbom` to produce an SPDX/CycloneDX SBOM and attach it as a build attestation (`cosign attest --type spdxjson`)
- **Supply chain attestations** — SLSA provenance via `slsa-github-generator`
- **Shift-left secrets scanning** — `trufflehog` or `gitleaks` action on PRs
- **Policy enforcement** — OPA/Kyverno in K8s to reject pods running unsigned images
- **Authenticated DAST** — ZAP script-based auth against Entra ID using the device code flow or a test user from an Entra ID dev tenant
