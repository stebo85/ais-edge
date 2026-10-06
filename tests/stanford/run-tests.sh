#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
PYTHONDONTWRITEBYTECODE=1 python3 tests/stanford/test_pipeline.py
if [ -n "${XNAT_RUNTIME_PYTHON:-}" ]; then
    PYTHONDONTWRITEBYTECODE=1 "$XNAT_RUNTIME_PYTHON" tests/stanford/test_ingest_runtime.py
elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    image=$(python3 -c 'import yaml; v=yaml.safe_load(open("charts/edge/values.yaml"))["ingest"]["image"]; print(v["repository"]+":"+v["tag"])')
    docker run --rm -v "$PWD:/w:ro" -w /w --entrypoint python3 "$image" tests/stanford/test_ingest_runtime.py
else
    echo 'SKIP: Stanford pinned-image runtime test (Docker unavailable; set XNAT_RUNTIME_PYTHON to a release-0.15.6 venv)'
fi
