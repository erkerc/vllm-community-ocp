# Usage: make build TAG=vX.Y.Z IMAGE=quay.io/<org>/vllm-openai-ocp
TAG          ?= latest
IMAGE        ?= quay.io/<org>/vllm-openai-ocp
UPSTREAM     ?= docker.io/vllm/vllm-openai
PLATFORM     ?= linux/amd64
REQUIRE_NIXL ?= false
ENGINE       ?= $(shell command -v podman 2>/dev/null || command -v docker)
TEST_UID     ?= 1000680000
TEST_MODEL   ?= Qwen/Qwen3-0.6B

.PHONY: build push test lint

build:
	$(ENGINE) build --platform $(PLATFORM) \
	  --build-arg VLLM_IMAGE=$(UPSTREAM):$(TAG) \
	  --build-arg REQUIRE_NIXL=$(REQUIRE_NIXL) \
	  -t $(IMAGE):$(TAG) .

push:
	$(ENGINE) push $(IMAGE):$(TAG)

# Runs as a random UID with GID 0, like OpenShift restricted-v2.
test:
	$(ENGINE) run --rm --user $(TEST_UID):0 --device nvidia.com/gpu=all \
	  -p 8080:8080 $(IMAGE):$(TAG) --model $(TEST_MODEL)

lint:
	bash -n ocp-entrypoint.sh
	command -v hadolint >/dev/null && hadolint Dockerfile || true
