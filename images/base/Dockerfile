# syntax=docker/dockerfile:1.10.0@sha256:0000000000000000000000000000000000000000000000000000000000000000
#
# Base image. Debian slim, patched, with a non-root user and no package
# manager state left behind.
#
# The digests below are placeholders. Run 'make pin' once after cloning, read
# the diff, and commit it. The pipeline refuses to build until they are real.

FROM debian:12-slim@sha256:0000000000000000000000000000000000000000000000000000000000000000

ARG IMAGE_TITLE="image-factory base"
ARG IMAGE_SOURCE="https://github.com/lytronhq/image-factory"

SHELL ["/bin/sh", "-eux", "-c"]

RUN apt-get update; \
    apt-get upgrade -y; \
    apt-get install -y --no-install-recommends ca-certificates tzdata; \
    apt-get purge -y --auto-remove; \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*; \
    groupadd --gid 65532 nonroot; \
    useradd --uid 65532 --gid 65532 --home-dir /home/nonroot --create-home --shell /usr/sbin/nologin nonroot

# Remove setuid/setgid bits. Nothing in this image needs privilege escalation.
RUN find / -xdev -type f \( -perm -4000 -o -perm -2000 \) -exec chmod a-s {} + || true

LABEL org.opencontainers.image.title="${IMAGE_TITLE}" \
      org.opencontainers.image.source="${IMAGE_SOURCE}" \
      org.opencontainers.image.base.name="debian:12-slim"

USER 65532:65532
WORKDIR /home/nonroot
CMD ["/bin/sh"]
