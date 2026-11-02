# syntax=docker/dockerfile:1.10.0@sha256:865e5dd094beca432e8c0a1d5e1c465db5f998dca4e439981029b3b81fb39ed5
#
# A consumer application image built on the factory base.
#
# The base is referenced by digest. To move to a newer base, verify the new
# digest with the factory's verify.sh, then run the factory's
# 'scripts/pin.sh Dockerfile ghcr.io/lytronhq/base@sha256:<digest>' and commit
# the result (see README.md). There is no floating tag to drift underneath you.

FROM ghcr.io/lytronhq/base@sha256:87a258218c5104d17500464175c95cf9553686da1cc614d3c142d2a1a08f46e5

COPY --chown=65532:65532 app.sh /app/app.sh

USER 65532:65532
ENTRYPOINT ["/bin/sh", "/app/app.sh"]
