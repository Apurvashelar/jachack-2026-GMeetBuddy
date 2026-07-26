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

# litellm powers by llm(); on Python 3.14 it must be installed binary-only
# (a source build needs a Rust toolchain). Self-heal fresh clones.
if [ -x .jac/venv/bin/python ] && ! .jac/venv/bin/python -c 'import litellm' 2>/dev/null; then
  echo "installing litellm into .jac/venv (one-time)..."
  .jac/venv/bin/python -m pip install --quiet --only-binary :all: litellm ||     echo "!! litellm install failed - answers will use the keyword fallback"
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
