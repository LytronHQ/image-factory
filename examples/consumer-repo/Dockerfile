# syntax=docker/dockerfile:1.10.0@sha256:0000000000000000000000000000000000000000000000000000000000000000
#
# A consumer application image built on the factory base.
#
# The base is referenced by digest. To move to a newer base, run
# 'pin.sh Dockerfile ghcr.io/FACTORY_OWNER/base:sha-<commit>' and commit the
# result. There is no floating tag to drift underneath you.

FROM ghcr.io/FACTORY_OWNER/base@sha256:0000000000000000000000000000000000000000000000000000000000000000

COPY --chown=65532:65532 app.sh /app/app.sh

USER 65532:65532
ENTRYPOINT ["/bin/sh", "/app/app.sh"]
