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

The global test rules (never weaken a check, never invent a SHA or digest)
apply. Project specifics:

1. Instead of weakening a check: fix the input, or record a dated exception in
   `.github/image-factory/exceptions.json` with a real reason and owner.
2. Resolve digests and action versions with `crane digest` or `gh api`.
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

There is no UI, so the proof is pasted command output:

- `make test` (or the individual suites) with its real output;
- a real `./verify.sh` run against the published digest for anything touching
  signing, attestation, or verification;
- the GitHub run conclusion (`gh run view <id>`) for anything touching workflows.

**Visual testing: not applicable.** There is no page to screenshot.

## GitHub workflow

Issue → branch → PR → merge yourself, and owner tasks (`needs-owner`): see the
global `~/.claude/CLAUDE.md`.

- CI (`ci.yml`) must be green before merging. Merging to `main` also triggers
  `release.yml` when `images/**`, `scripts/**`, `verify.sh`, or the workflow
  files change — that publishes new, signed image digests, so treat a merge as a
  release.
- Owner tasks here: repo or org settings, package visibility.

## Versioning and releases

- **No sandbox and no production environment, and no deploy command.** The
  global template's `sandbox` → `main` release flow does not apply: `main` is the
  only long-lived branch.
- Images are versioned by **digest**, which is immutable. Builds are deliberately
  not reproducible, so every release produces new digests. There is no `:latest`.
- The pointer consumers use is the **`v1` git tag**
  (`uses: LytronHQ/image-factory/.github/workflows/build-image.yml@v1`). After a
  change that affects consumers, `v1` has to be moved to the new `main`. That is
  a force-push of a lightweight tag: ask once with AskUserQuestion ("Yes — force-push
  tag v1 to <sha> in LytronHQ/image-factory" / "No"), then move it yourself and
  read it back with `git ls-remote origin refs/tags/v1`. No workflow triggers on
  tags, so moving `v1` does not start a release. (2026-10-09: done this way for
  #6; it had sat as a `needs-owner` issue because a force-push was assumed to be
  blocked.)
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

- Five open Dependabot PRs (#1–#5) bumping action versions. Review each against
  the pinning policy; #4 bumps `aquasecurity/setup-trivy` to the v0.3.1 commit
  but leaves the comment above it naming v0.2.6, so that comment needs fixing in
  the same PR.
