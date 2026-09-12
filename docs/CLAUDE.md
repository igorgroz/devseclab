# Operating rules for Claude on this project

> Read this and `SESSION_STATE.md` first. Do not read anything else
> unless the task requires it. This project is large; context is scarce.

## Token discipline
- **Never `Glob **/*`** on the project root — it dredges `node_modules`
  and `.git` and returns 100+ useless lines. Use `git ls-files`,
  `find -not -path "*/node_modules/*" -not -path "*/.git/*"`, or
  scope the glob (`*.md`, `k8s/**/*.yaml`, etc.).
- **Read files surgically** — use `Read` with `offset`/`limit`. Don't
  pull a 200-line manifest to change one block.
- **Push exploration into sub-agents** — when the task is "find every
  reference to X" or "audit the repo for Y", spawn an `Agent` with a
  self-contained prompt and ask for a short report. Only the summary
  comes back into main context.
- **Don't re-read `SESSION_STATE.md` or `CLAUDE.md`** mid-session — they
  are already in context once loaded.
- **No preambles, no recaps, no summaries** of work done unless asked.
  Finish the task, link the file, stop.

## Response style
- Prose, not bullets, unless the user asks for a list or the content is
  irreducibly enumerable.
- No "Great question", no "I'll now…", no closing "Let me know if…".
- Match the user's terseness. If they ask in one line, answer in one
  paragraph.

## File handling
- Edits go straight to `/Users/igorgrozdanov/Documents/Learn/devseclab/…` —
  not the outputs scratch dir.
- Never write a `.md` doc unless explicitly requested. The phase docs
  and `SESSION_STATE.md` are the only canonical state files.

## End-of-session hygiene
- Before the user signs off, update `SESSION_STATE.md`: current phase,
  last commit, open issues, next actions. Keep it under ~80 lines.
- Suggest a commit if there are uncommitted changes worth keeping.

## Project shape (do not re-derive)
- DevSecOps platform lab — defensive CI/CD + EKS supply-chain hardening
  built around a black-box target application under test. All work is
  detection, hardening, signing, and remediation.
- React frontend + Node/Express backend + Postgres.
- Deployed to EKS via Helm + raw manifests in `k8s/`.
- Secrets: AWS Secrets Manager → External Secrets Operator → K8s Secret.
- TLS / images signed via cosign. ALB ingress, IRSA identities everywhere.
- Detailed state: `SESSION_STATE.md`. Detailed phase plans: `PHASE*.md`.
