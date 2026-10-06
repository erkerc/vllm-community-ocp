# Community vLLM on OpenShift / OpenShift AI

Rebuilds `docker.io/vllm/vllm-openai` so it runs under the `restricted-v2` SCC
(arbitrary UID, GID 0) on both RHOAI serving paths:

- **InferenceService + custom ServingRuntime** (KServe, port 8080, HTTP)
- **LLMInferenceService** (llm-d, `main` container, port 8000, HTTPS)

| File | Purpose |
|---|---|
| `Dockerfile` | Non-root user (1001:0), group-writable `$HOME` + all caches, `/etc/passwd` fix, port 8080, telemetry off |
| `Makefile` | `build`, `push`, `test` (random UID run), `lint` |
| `ocp-entrypoint.sh` | Adds the random UID to `/etc/passwd`; flags-only args → `vllm.entrypoints.openai.api_server` |
| `manifests/servingruntime.yaml` | RHOAI ServingRuntime using the rebuilt image |
| `manifests/llminferenceservice.yaml` | LLMInferenceService that overrides only the `main` image (P/D variant commented) |

## Build and push

```bash
make build push TAG=<vllm release> IMAGE=quay.io/<org>/vllm-openai-ocp
make test  TAG=<vllm release> IMAGE=quay.io/<org>/vllm-openai-ocp   # random-UID local run
```

Or directly:

```bash
TAG=<vllm release, e.g. vX.Y.Z>
podman build --platform linux/amd64 \
  --build-arg VLLM_IMAGE=docker.io/vllm/vllm-openai:${TAG} \
  --build-arg REQUIRE_NIXL=false \
  -t quay.io/<org>/vllm-openai-ocp:${TAG} .
podman push quay.io/<org>/vllm-openai-ocp:${TAG}
```

## Simulate OpenShift locally (random UID, GID 0)

```bash
podman run --rm --user 1000680000:0 --device nvidia.com/gpu=all -p 8080:8080 \
  quay.io/<org>/vllm-openai-ocp:${TAG} --model Qwen/Qwen3-0.6B
# Check: no "Permission denied" under /root/.cache, no "getpwuid(): uid not found"
curl -s localhost:8080/v1/models
```

## Deploy in RHOAI

```bash
oc apply -n <project> -f manifests/servingruntime.yaml
```
```bash
oc apply -f manifests/llminferenceservice.yaml   # llm-d path
```
For the ServingRuntime path, deploy the model from the dashboard choosing **vLLM Community (OCP-ready)**,
or reference `runtime: vllm-community-runtime` in the InferenceService.

## What differs between the two paths

| | ServingRuntime / InferenceService | LLMInferenceService |
|---|---|---|
| Who sets the start command | Image ENTRYPOINT (flags-only `args:`) | Platform config (`sh -c "vllm serve /mnt/models ..."`) |
| Port / scheme | 8080 / HTTP | 8000 / HTTPS (`/var/run/kserve/tls`) |
| `/etc/passwd` fix | Entrypoint | Not run; `USER`/`HOME` env vars cover `getpass.getuser()` |
| Extra vLLM flags | `args:` or `VLLM_ADDITIONAL_ARGS` (entrypoint appends it) | `VLLM_ADDITIONAL_ARGS` |

What makes the image work under LLMInferenceService:
- No reliance on ENTRYPOINT: caches, `HOME`, `USER` are all set by `ENV`.
- `vllm`, `sh` and `bash` exist on `PATH` (the build fails if not).
- CA bundle exists at both Debian and RHEL paths, so you don't need the
  dummy-cert workaround in the upstream MaaS sample.
- P/D disaggregation needs NIXL in the base image; `REQUIRE_NIXL=true` fails
  the build instead of failing at KV transfer on the cluster.

## Notes

- Do **not** set `command:` in the ServingRuntime; it bypasses the entrypoint (the
  passwd fix). The `USER`/`LOGNAME`/`HOME` env vars still cover `getpass.getuser()`,
  so it degrades gracefully if someone does.
- `chmod g=u /etc/passwd` is the standard OpenShift arbitrary-UID pattern; if your
  security team rejects it, delete that line — the env vars handle the known failure.
- Community vLLM is not supported by Red Hat. Use it for new-model day-0 testing;
  move to the Red Hat AI Inference Server image for production.
- If you write your own `command:` for LLMInferenceService, keep `--port 8000`,
  `--ssl-certfile /var/run/kserve/tls/tls.crt --ssl-keyfile /var/run/kserve/tls/tls.key`
  and `$VLLM_ADDITIONAL_ARGS`, or the HTTPS probes and the gateway will fail.
- Platform defaults (the start command, the TLS mount) come from the RHOAI
  release. Re-test after RHOAI upgrades, especially if a newer community vLLM
  renames CLI flags the platform passes.
