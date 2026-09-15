SHELL := /usr/bin/env bash
IMAGE ?=
REPO  ?=

.PHONY: help test pin gate verify clean

help:
	@echo "make test    - run every self-test (no network, no registry)"
	@echo "make gate    - assert every FROM in this repo is a digest"
	@echo "make pin     - resolve tags to digests in the Dockerfiles, in place"
	@echo "make verify IMAGE=ghcr.io/o/n@sha256:... REPO=o/n"

test:
	shellcheck -x scripts/*.sh verify.sh tests/*.sh
	bash tests/test-policy.sh
	bash tests/test-build-args.sh
	bash tests/test-pin.sh
	bash tests/test-scan.sh
	bash tests/test-verify-guards.sh

gate:
	bash scripts/assert-pinned-digests.sh

pin:
	bash scripts/pin.sh images/base/Dockerfile
	bash scripts/pin.sh images/python/Dockerfile
	@echo "review the diff before committing"

verify:
	@test -n "$(IMAGE)" || { echo "IMAGE= is required"; exit 64; }
	@test -n "$(REPO)"  || { echo "REPO= is required";  exit 64; }
	./verify.sh --image "$(IMAGE)" --repo "$(REPO)" --receipt receipt.json

clean:
	rm -rf scan sbom receipt.json
