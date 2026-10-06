# image-factory — Claude Code instructions

The owner's global rules in `~/.claude/CLAUDE.md` apply here too. This file adds
what is specific to this project, and records where the global template does not
fit (this is not a Cloudflare Workers app and has no UI).

## Project

- **Purpose:** a reusable GitHub Actions pipeline that builds container images
  which a stranger can check: pinned, scanned, catalogued, signed, attested, and
  then verified by pulling the result back out of the registry.
- **Stack:** bash (4.3+) scripts and GitHub Actions reusable workflows. Images
  are published to `ghcr.io/lytronhq`. Signing is keyless Cosign via GitHub OIDC;
  provenance comes from `slsa-framework/slsa-github-generator`.
- **Not** a Cloudflare Workers project: no `wrangler`, no D1/KV, no web UI, no
  database, no deployment environments. Sections of the global template that
  assume those are marked "not applicable" below rather than invented.
- **Repo:** <https://github.com/LytronHQ/image-factory> — public, default branch
  `main`.
- **Scope is deliberately v1:** one base image, one runtime image, one reusable
  workflow. Do not add features. If something is missing, say so rather than
  building it.

## Commands

- **Install:** nothing for the repo itself. Tools used: `shellcheck` to lint;
  `cosign`, `syft`, `jq` for `verify.sh`; `crane` (or `docker`) for `make pin`;
  `trivy` is only ever run by CI.
- **Build:** no build step. The artefacts are container images, built on GitHub
  by `.github/workflows/release.yml`.
- **Test:** `make test` — shellcheck plus six self-test suites (policy gate,
  build-arg gate, pin.sh, scan policy, verify.sh guardrails, verify.sh signer
  binding). No network, no registry.
- **Lint:** `shellcheck -x scripts/*.sh verify.sh tests/*.sh`. Lint with the same
  version as the runner (shellcheck 0.9.0 on ubuntu-24.04 at the last check) —
  newer versions report findings CI will not, and older ones miss findings CI
  will.
- **Gate:** `make gate` — every image reference in the repo must be a digest.
- **Pin digests:** `make pin`, or
  `scripts/pin.sh <Dockerfile> [image-ref]` to move one reference. Read the diff
  and commit it; pinning is a deliberate, reviewable act.
- **Verify a published image:**
  `./verify.sh --image ghcr.io/lytronhq/base@sha256:<digest> --repo LytronHQ/image-factory --expect-packages <n> --strict`
  (add `--factory` when the image was built by another repo using this pipeline).
  `--repo` and `--factory` are matched case-insensitively; `--expect-packages` is
  what makes the twelfth check run.
- **Local dev:** not applicable — nothing here runs a server or a UI.

## Ground rules for this project

These override any instinct to make CI green:

1. Never weaken a check, threshold, or assertion to make something pass. The
   options are: fix the input, or record a dated exception in
   `.github/image-factory/exceptions.json` with a real reason and owner.
2. Never invent a commit SHA, digest, or action version. Resolve it for real
   (`crane digest`, `gh api`) or stop and say it could not be resolved.
3. The exit codes in `scripts/lib.sh` and the README table are a contract. A new
   code must be added in both places, and must not collide with `1` (policy
   failure, and also the shell's generic failure) or a code a tool already
   returns.
4. The README's "What is not guaranteed" section is deliberate. Do not soften it.
   If a new gap appears, add it there.
5. Every gate needs a test that proves it rejects bad input with an exact exit
   code. A gate only ever seen passing is indistinguishable from one that cannot
   fail.

## Proof of work

The global rule "never claim done without proof" applies with no UI, so the
proof is pasted command output:

- `make test` (or the individual suites) with its real output;
- a real `./verify.sh` run against the published digest for anything touching
  signing, attestation, or verification;
- the GitHub run conclusion (`gh run view <id>`) for anything touching workflows.

**Visual testing: not applicable.** There is no page to screenshot.

## GitHub workflow

- For every feature, bug, or problem, create a GitHub issue first.
- Create a branch and a PR that references the issue. When the work is done,
  tests pass, and CI is green, merge the PR yourself.
- CI (`ci.yml`) must be green before merging. Merging to `main` also triggers
  `release.yml` when `images/**`, `scripts/**`, `verify.sh`, or the workflow
  files change — that publishes new, signed image digests, so treat a merge as a
  release.
- If a task must be done by the owner (a repo or org setting, package
  visibility, anything needing a force-push), create an issue, assign it to
  `margani`, and label it `needs-owner`. Do not try to do it yourself.

## Writing owner issues — accuracy rule

- Never invent UI steps for an external service (GitHub, Cloudflare, Stripe,
  etc.). Before writing step-by-step instructions, read the official current docs
  for that exact service and base the steps on them.
- If a step cannot be verified from docs, do not write a confident fake step. Say
  plainly: "Could not verify this step — please check," and link the docs page.
- Steps the owner follows must match the real current interface.

## Versioning and releases

- **No sandbox and no production environment, and no deploy command.** The
  global template's `sandbox` → `main` release flow does not apply: `main` is the
  only long-lived branch.
- Images are versioned by **digest**, which is immutable. Builds are deliberately
  not reproducible, so every release produces new digests. There is no `:latest`.
- The pointer consumers use is the **`v1` git tag**
  (`uses: LytronHQ/image-factory/.github/workflows/build-image.yml@v1`). After a
  change that affects consumers, `v1` has to be moved to the new `main`. That is
  a force-push, so it is an owner task — raise a `needs-owner` issue.
- After a release, the digest in `images/python/Dockerfile` (`ARG BASE_IMAGE`)
  and in `examples/consumer-repo/Dockerfile` may need re-pinning to a verified
  base digest.
- **PWA: not applicable.**

## Environments and data safety

- No database, no test data, nothing to keep separate between environments.
- The external state this project writes to is real and public: ghcr.io packages
  under the repo owner, and the Sigstore transparency log, which records the
  repository name, workflow path, and image reference **permanently**. Never sign
  anything that should not be public.
- New ghcr packages are private until the owner makes them public; external
  verification fails until then (`needs-owner` issue).
- Never run a release against a registry or repository other than this one.

## Open tasks

- Move the `v1` tag to current `main` — issue #6, `needs-owner`.
- Five open Dependabot PRs (#1–#5) bumping action versions. Review each against
  the pinning policy; #4 bumps `aquasecurity/setup-trivy` to the v0.3.1 commit
  but leaves the comment above it naming v0.2.6, so that comment needs fixing in
  the same PR.
