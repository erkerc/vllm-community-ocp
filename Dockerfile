# syntax=docker/dockerfile:1
#
# Rebuild of the community vLLM image (docker.io/vllm/vllm-openai) so it runs
# under OpenShift's restricted-v2 SCC, as a KServe ServingRuntime
# (InferenceService) and as the "main" container of an LLMInferenceService
# (llm-d) in Red Hat OpenShift AI.
#
# What the upstream image gets wrong for OpenShift:
#   1. Runs as root. restricted-v2 forces a random, non-root UID (e.g. 1000680000)
#      whose only guaranteed group is GID 0.
#   2. Caches (HF, vLLM, Triton, torch.compile/inductor, FlashInfer, numba,
#      outlines) default to /root/... which that random UID cannot write.
#   3. The random UID has no /etc/passwd entry, so getpass.getuser() raises
#      "KeyError: 'getpwuid(): uid not found'" (torch inductor hits this).
#   4. Listens on 8000; RHOAI ServingRuntimes expect 8080. (LLMInferenceService
#      uses 8000 over HTTPS, but sets --port itself, so the image stays neutral.)
#   5. Ubuntu-based: RHEL-style CA bundle paths (/etc/pki/...) don't exist, which
#      breaks Python TLS clients when SSL_CERT_FILE/REQUESTS_CA_BUNDLE point there.
#      Upstream MaaS samples work around this with a dummy cert; we fix the paths.
#   6. LLMInferenceService templates override "command:" (sh -c "vllm serve ..."),
#      so nothing here may depend on the ENTRYPOINT running.
#
# Build:
#   podman build --platform linux/amd64 \
#     --build-arg VLLM_IMAGE=docker.io/vllm/vllm-openai:<tag> \
#     -t quay.io/<org>/vllm-openai-ocp:<tag> .
#
# Pin <tag> to a release (or digest). Don't ship :latest to a customer cluster.

ARG VLLM_IMAGE=docker.io/vllm/vllm-openai:latest
FROM ${VLLM_IMAGE}

# Set to "true" to fail the build if NIXL (P/D disaggregation KV transfer) is
# missing from the base image.
ARG REQUIRE_NIXL=false

USER 0

ENV HOME=/home/vllm \
    USER=vllm \
    LOGNAME=vllm

# Everything that writes at runtime lives under $HOME and is owned by GID 0,
# group-writable (g=u) and setgid, so any UID OpenShift assigns can use it.
ENV XDG_CACHE_HOME=${HOME}/.cache \
    XDG_CONFIG_HOME=${HOME}/.config \
    HF_HOME=${HOME}/.cache/huggingface \
    VLLM_CACHE_ROOT=${HOME}/.cache/vllm \
    VLLM_CONFIG_ROOT=${HOME}/.config/vllm \
    TRITON_CACHE_DIR=${HOME}/.cache/triton \
    TORCHINDUCTOR_CACHE_DIR=${HOME}/.cache/torchinductor \
    FLASHINFER_WORKSPACE_BASE=${HOME}/.cache \
    NUMBA_CACHE_DIR=${HOME}/.cache/numba \
    OUTLINES_CACHE_DIR=${HOME}/.cache/outlines

# Enterprise / air-gapped defaults: no phone-home usage stats.
ENV VLLM_NO_USAGE_STATS=1 \
    DO_NOT_TRACK=1 \
    PYTHONUNBUFFERED=1

COPY --chmod=0755 ocp-entrypoint.sh /usr/local/bin/ocp-entrypoint.sh

RUN set -eux; \
    # Non-root user 1001, primary group 0 (OpenShift convention).
    # Recent upstream images already ship a "vllm" user with another UID, so
    # reuse it and move it to 1001 instead of failing on useradd.
    if id -u vllm >/dev/null 2>&1; then \
        old_uid="$(id -u vllm)"; \
        if [ "${old_uid}" != "1001" ]; then \
            if getent passwd 1001 >/dev/null; then \
                echo "UID 1001 is taken by $(getent passwd 1001 | cut -d: -f1)" >&2; exit 1; \
            fi; \
            usermod -u 1001 vllm; \
            find / -xdev -user "${old_uid}" -exec chown -h 1001 {} + 2>/dev/null || true; \
        fi; \
        usermod -g 0 -d "${HOME}" vllm; \
    elif getent passwd 1001 >/dev/null; then \
        usermod -g 0 -d "${HOME}" "$(getent passwd 1001 | cut -d: -f1)"; \
    else \
        useradd -u 1001 -g 0 -d "${HOME}" -M -s /sbin/nologin -c "vLLM" vllm; \
    fi; \
    id vllm || id 1001; \
    mkdir -p "${HOME}" "${HF_HOME}" "${VLLM_CACHE_ROOT}" "${VLLM_CONFIG_ROOT}" \
             "${TRITON_CACHE_DIR}" "${TORCHINDUCTOR_CACHE_DIR}" "${NUMBA_CACHE_DIR}" \
             "${OUTLINES_CACHE_DIR}" "${HOME}/.cache/flashinfer" /mnt/models /workspace; \
    chown -R 1001:0 "${HOME}" /mnt/models /workspace; \
    chmod -R g=u "${HOME}" /mnt/models /workspace; \
    find "${HOME}" /workspace -type d -exec chmod g+s {} +; \
    # Lets the entrypoint register the random UID in /etc/passwd.
    chmod g=u /etc/passwd; \
    # CA bundle at both Debian and RHEL paths, whichever the base provides.
    deb=/etc/ssl/certs/ca-certificates.crt; \
    rhel=/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem; \
    if [ -f "$deb" ]; then src="$deb"; elif [ -f "$rhel" ]; then src="$rhel"; else src=""; fi; \
    if [ -n "$src" ]; then \
        for p in "$deb" "$rhel" /etc/pki/tls/certs/ca-bundle.crt /etc/pki/tls/cert.pem; do \
            [ -e "$p" ] || { mkdir -p "$(dirname "$p")"; ln -s "$src" "$p"; }; \
        done; \
    fi; \
    # Fail fast on things LLMInferenceService templates call directly.
    command -v vllm; command -v sh; command -v bash; \
    python3 -c "import vllm; print('vllm', vllm.__version__)"; \
    if python3 -c "import nixl" 2>/dev/null; then echo "NIXL: present"; \
    elif [ "${REQUIRE_NIXL}" = "true" ]; then echo "NIXL missing" >&2; exit 1; \
    else echo "NIXL: absent (P/D disaggregation will not work)"; fi

WORKDIR /workspace

LABEL io.k8s.display-name="vLLM OpenAI-compatible server (OpenShift-ready)" \
      io.k8s.description="Community vLLM rebuilt to run as an arbitrary non-root UID on OpenShift / OpenShift AI" \
      io.openshift.tags="vllm,llm,inference,kserve,openshift-ai" \
      io.openshift.expose-services="8080:http" \
      io.openshift.non-scalable="false"

# 8080: ServingRuntime/InferenceService. 8000: LLMInferenceService (HTTPS).
EXPOSE 8080 8000

USER 1001

ENTRYPOINT ["/usr/local/bin/ocp-entrypoint.sh"]
# Same server as the upstream image, bound to 0.0.0.0:8080.
CMD ["--host=0.0.0.0", "--port=8080"]
