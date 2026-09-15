# syntax=docker/dockerfile:1.10.0@sha256:865e5dd094beca432e8c0a1d5e1c465db5f998dca4e439981029b3b81fb39ed5
#
# Python runtime, built on the factory base image.
#
# BASE_IMAGE must be a digest. The pipeline may override it with a newly built
# base digest, and the gate rejects the override if it is not itself a digest.

ARG BASE_IMAGE=ghcr.io/lytronhq/base@sha256:63f0e734e7391733bc8aa11bc7d7e6fb42de3613716870ebfa499f8995b736a4

FROM ${BASE_IMAGE}

ARG IMAGE_SOURCE="https://github.com/lytronhq/image-factory"

USER root
SHELL ["/bin/sh", "-eux", "-c"]

RUN apt-get update; \
    apt-get install -y --no-install-recommends python3-minimal python3-distutils; \
    apt-get purge -y --auto-remove; \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*; \
    python3 -c 'import sys; print(sys.version)'

LABEL org.opencontainers.image.title="image-factory python" \
      org.opencontainers.image.source="${IMAGE_SOURCE}"

USER 65532:65532
WORKDIR /home/nonroot
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
CMD ["python3"]
