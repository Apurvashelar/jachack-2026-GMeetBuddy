#!/usr/bin/env bash
# Start the Backchannel brain with secrets loaded from .env.
#
#   ./run.sh          dev server (client + HMR) on :8000
#   ./run.sh --api    API only, no client bundling (faster boot)
set -euo pipefail
cd "$(dirname "$0")"

if [ -f .env ]; then
  set -a; . ./.env; set +a
  echo "loaded .env"
else
  echo "no .env found - running with fallbacks (no LLM, dry-run actions)"
fi

if [ "${OPENAI_API_KEY:-}" = "" ]; then
  echo "!! OPENAI_API_KEY unset: answers use keyword-retrieval fallback"
else
  echo "OPENAI_API_KEY set (model: ${BC_MODEL:-gpt-4o-mini})"
fi

# A stale server holding :8000 makes the new one silently grab :8001+ while the
# client proxy still points at the old port. Always clear it first.
pkill -9 -f "jac start" 2>/dev/null || true
sleep 2

if [ "${1:-}" = "--api" ]; then
  exec jac start main.jac --no-client
else
  exec jac start --dev main.jac
fi
