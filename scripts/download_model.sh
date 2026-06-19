#!/usr/bin/env bash
#
# Download a trained policy from the Hugging Face Hub (skips if already cached).
# Safe to run on the dev box or the robot box; only needs `hf` + (for private
# models) a login token. The model id can be passed as an argument.
#
# Usage:
#   ./download_model.sh                                    # default model below
#   ./download_model.sh AshishRamesh/smolvla-4type-fold-test
#   MODEL_ID=user/model ./download_model.sh
#
set -euo pipefail

MODEL_ID="${1:-${MODEL_ID:-AshishRamesh/smolvla-4type-fold-test}}"

# Pick an HF CLI (ships with huggingface_hub; lives in your lerobot venv).
if   command -v hf >/dev/null 2>&1;              then HF=(hf)
elif command -v huggingface-cli >/dev/null 2>&1; then HF=(huggingface-cli)
else
  echo "ERROR: 'hf' / 'huggingface-cli' not found — activate your lerobot venv first:" >&2
  echo "       source ~/lerobot_ws/lerobot312/bin/activate" >&2
  exit 1
fi

# Warn if not authenticated (the model may be private).
if ! "${HF[@]}" auth whoami >/dev/null 2>&1; then
  echo "WARNING: not logged in to Hugging Face. If '$MODEL_ID' is private, run: hf auth login" >&2
fi

# Where the hub cache lives, and the folder hf uses for this repo.
CACHE="${HUGGINGFACE_HUB_CACHE:-${HF_HOME:+$HF_HOME/hub}}"
CACHE="${CACHE:-$HOME/.cache/huggingface/hub}"
REPO_DIR="$CACHE/models--${MODEL_ID//\//--}"

if [ -d "$REPO_DIR/snapshots" ] && [ -n "$(ls -A "$REPO_DIR/snapshots" 2>/dev/null)" ]; then
  echo "Already downloaded: $MODEL_ID"
else
  echo "Downloading $MODEL_ID ..."
fi

# `hf download` is idempotent: re-downloads nothing if cached, and prints the
# resolved local snapshot path on stdout.
LOCAL_PATH="$("${HF[@]}" download "$MODEL_ID")"

echo
echo "Model ready at:"
echo "  $LOCAL_PATH"
echo
echo "Run it with run_on_robot.py using either:"
echo "  --policy_path $MODEL_ID      # HF id (auto-resolves to this cache)"
echo "  --policy_path $LOCAL_PATH    # explicit local path"
