#!/bin/bash
set -e

echo "[entrypoint] Starting LIMITLESS Vanity Grinder Worker..."
echo "[entrypoint] GPU info:"
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>/dev/null || echo "  nvidia-smi not available"

exec uvicorn server:app --host 0.0.0.0 --port 8080 --workers 1 --log-level info
