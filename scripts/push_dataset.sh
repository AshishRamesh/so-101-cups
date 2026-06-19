#!/usr/bin/env bash
#
# Push an already-recorded LeRobot dataset to the Hugging Face Hub.
#
# Finds local datasets in the LeRobot cache, lets you pick one, asks which hub
# repo to push to, then uploads it. Use this when you recorded with --no-push
# (or want to upload under a different repo name).
#
# Usage:
#   ./push_dataset.sh
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$HERE/config.sh"

activate_venv

ROOT="${HF_LEROBOT_HOME:-${LEROBOT_HOME:-$HOME/.cache/huggingface/lerobot}}"
[ -d "$ROOT" ] || { echo "ERROR: no LeRobot data directory at $ROOT" >&2; exit 1; }

# total_episodes from a dataset's meta/info.json (no jq dependency).
get_eps() {
  grep -oE '"total_episodes"[[:space:]]*:[[:space:]]*[0-9]+' "$1/meta/info.json" 2>/dev/null \
    | grep -oE '[0-9]+' | head -1
}

# ----------------------------------------------------------------------------
# Discover recorded datasets (any dir containing meta/info.json; repo_id is its
# path relative to the cache root).
# ----------------------------------------------------------------------------
mapfile -t DATASETS < <(
  find "$ROOT" -type f -path '*/meta/info.json' 2>/dev/null \
    | sed "s#^${ROOT%/}/##; s#/meta/info.json\$##" | sort -u
)
if [ "${#DATASETS[@]}" -eq 0 ]; then
  echo "ERROR: no recorded datasets found under $ROOT" >&2
  exit 1
fi

echo "Recorded datasets found in $ROOT:"
i=1
for d in "${DATASETS[@]}"; do
  n="$(get_eps "$ROOT/$d")"
  printf "  [%d] %-40s (%s episodes)\n" "$i" "$d" "${n:-?}"
  i=$((i + 1))
done
echo

# ----------------------------------------------------------------------------
# Pick which local dataset to push
# ----------------------------------------------------------------------------
if [ "${#DATASETS[@]}" -eq 1 ]; then
  LOCAL_REPO="${DATASETS[0]}"
  echo "Using the only dataset: $LOCAL_REPO"
else
  while :; do
    read -rp "Pick dataset to push [1-${#DATASETS[@]}]: " idx
    if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "${#DATASETS[@]}" ]; then
      LOCAL_REPO="${DATASETS[$((idx - 1))]}"
      break
    fi
    echo "  Enter a number between 1 and ${#DATASETS[@]}."
  done
fi

# ----------------------------------------------------------------------------
# Ask which hub repo to push to
# ----------------------------------------------------------------------------
HF_USER="$(hf auth whoami 2>/dev/null | awk 'NR==1{print $NF}')"
[ -n "$HF_USER" ] || echo "WARNING: not logged in to Hugging Face? Run: hf auth login" >&2

read -rp "Push to which HF repo? [default: $LOCAL_REPO]: " TARGET
TARGET="${TARGET:-$LOCAL_REPO}"
# Bare name -> prepend your HF username (HF repos are namespace/name).
case "$TARGET" in
  */*) ;;
  *)   TARGET="${HF_USER:?cannot derive namespace; type it as user/name}/$TARGET" ;;
esac

read -rp "Make the repo private? [y/N]: " priv
case "$priv" in y|Y) PRIVATE=True ;; *) PRIVATE=False ;; esac

EPS="$(get_eps "$ROOT/$LOCAL_REPO")"
echo
echo "  local dataset : $LOCAL_REPO (${EPS:-?} episodes)"
echo "  push to       : https://huggingface.co/datasets/$TARGET  (private=$PRIVATE)"
read -rp "Proceed? [y/N]: " ok
case "$ok" in y|Y) ;; *) echo "Aborted."; exit 0 ;; esac

say "Uploading $TARGET to the hub."

# ----------------------------------------------------------------------------
# Push via the LeRobot API (tries both 0.5.x import paths)
# ----------------------------------------------------------------------------
set +e
LOCAL_REPO="$LOCAL_REPO" TARGET="$TARGET" ROOT="$ROOT" PRIVATE="$PRIVATE" python - <<'PY'
import os, sys
from importlib import import_module

local   = os.environ["LOCAL_REPO"]
target  = os.environ["TARGET"]
root    = os.path.join(os.environ["ROOT"], local)
private = os.environ["PRIVATE"] == "True"

LeRobotDataset = None
for mod in ("lerobot.datasets.lerobot_dataset",
            "lerobot.common.datasets.lerobot_dataset"):
    try:
        LeRobotDataset = getattr(import_module(mod), "LeRobotDataset")
        break
    except Exception:
        continue
if LeRobotDataset is None:
    sys.exit("ERROR: could not import LeRobotDataset (is the venv's lerobot installed?)")

ds = LeRobotDataset(local, root=root)
if target != local:
    ds.repo_id = target  # upload local files under a different hub name

n = getattr(ds, "num_episodes", None)
if n is None:
    n = getattr(getattr(ds, "meta", None), "total_episodes", "?")
print(f"Pushing {n} episodes -> {target} (private={private}) ...")
ds.push_to_hub(private=private)
print("Push complete.")
PY
status=$?
set -e

if [ "$status" -eq 0 ]; then
  say "Upload complete."
  echo "Done: https://huggingface.co/datasets/$TARGET"
else
  say "Upload failed."
  echo "Push failed (status $status). Check 'hf auth whoami' and that the dataset finished recording." >&2
fi
exit "$status"
