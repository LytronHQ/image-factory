# Consumer example

A minimal repository that builds an application image on the factory base and
gets the whole supply chain for free.

Copy these three files into your own repository and change `FACTORY_OWNER` to
the owner of the image-factory fork you are consuming.

```
Dockerfile
app.sh
.github/workflows/build.yml
```

## What you have to do

1. Reference the base by digest in your `Dockerfile`. If you use a tag, the
   pipeline stops at the first job and tells you which line is wrong.
2. Call the reusable workflow and grant it four permissions. Fewer will fail:
   `packages: write` to push, `id-token: write` for keyless signing,
   `contents: read` to check out, `actions: read` for the SLSA generator.
3. Set `min-packages` to a number your image comfortably exceeds. It is a
   floor, not a target: it exists so that a scanner or cataloguer that silently
   returns nothing is treated as a broken tool rather than a clean image.

## What you get

A pushed digest, a keyless Cosign signature bound to your workflow identity,
SPDX and CycloneDX SBOM attestations, a SLSA provenance attestation, and a
verification pass that pulled all of it back out of the registry and checked
it. Any of those failing or not running fails your build.

## Moving to a newer base

```sh
scripts/pin.sh Dockerfile ghcr.io/FACTORY_OWNER/base:sha-<commit>
git diff
```

Commit the diff. Nothing updates itself underneath you.

## The second job

`independent-check` re-runs `verify.sh` from the factory repository against
your published digest. It is redundant by design. The factory verifies its own
output, and this job verifies it without taking the factory's word for it. It
costs one runner minute. Keep it.
