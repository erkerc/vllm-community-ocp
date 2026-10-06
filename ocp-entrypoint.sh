#!/usr/bin/env bash
# OpenShift entrypoint for community vLLM.
#  - Registers the arbitrary UID in /etc/passwd (getpwuid() must succeed).
#  - If only flags are passed (KServe ServingRuntime "args:" style), runs the
#    OpenAI API server and appends $VLLM_ADDITIONAL_ARGS, matching the
#    LLMInferenceService convention.
#  - Otherwise execs the given command unchanged.
# LLMInferenceService templates set "command:", so this script is skipped there;
# the image's ENV covers that case.
set -euo pipefail

uid="$(id -u)"
if ! getent passwd "${uid}" >/dev/null 2>&1 && [ -w /etc/passwd ]; then
    echo "vllm:x:${uid}:0:vLLM:${HOME:-/home/vllm}:/sbin/nologin" >> /etc/passwd
fi

if [ "$#" -eq 0 ] || [ "${1#-}" != "$1" ]; then
    set -- python3 -m vllm.entrypoints.openai.api_server "$@"
    if [ -n "${VLLM_ADDITIONAL_ARGS:-}" ]; then
        # eval keeps quoted values intact, e.g. --kv-transfer-config '{"a":"b"}'
        eval "set -- \"\$@\" ${VLLM_ADDITIONAL_ARGS}"
    fi
fi

exec "$@"
