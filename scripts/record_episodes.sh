#!/usr/bin/env bash
#
# Record SO-101 bimanual teleoperation episodes with LeRobot, plus voice cues.
#
# Episode controls are NATIVE to lerobot-record (work even though output is
# piped, because the key listener hooks X directly, not stdin):
#     →  RIGHT arrow : save the current episode and start the NEXT one
#     ←  LEFT arrow  : DROP the current episode and re-record it
#     Esc            : stop the whole session (then push to hub if enabled)
#
# Usage:
#   ./record_episodes.sh [-n EPISODES] [-t "TASK"] [-r USER/REPO] \
#                        [-e EPISODE_SECS] [-s RESET_SECS] [--no-push] [--no-voice]
#
# Examples:
#   ./record_episodes.sh                       # 30 eps, task "pick up the cup"
#   ./record_episodes.sh -n 50 -t "stack the cups"
#   REPO_ID=me/so101_cups ./record_episodes.sh --no-push   # local only
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$HERE/config.sh"

# ----------------------------------------------------------------------------
# Recording parameters (env overridable; CLI flags below take precedence)
# ----------------------------------------------------------------------------
TASK="${TASK:-pick up the cup}"
NUM_EPISODES="${NUM_EPISODES:-30}"
EPISODE_TIME_S="${EPISODE_TIME_S:-30}"
RESET_TIME_S="${RESET_TIME_S:-5}"
PUSH_TO_HUB="${PUSH_TO_HUB:-true}"
REPO_ID="${REPO_ID:-}"   # resolved after venv activation if empty

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "${BASH_SOURCE[0]}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--episodes)     NUM_EPISODES="$2"; shift 2 ;;
    -t|--task)         TASK="$2"; shift 2 ;;
    -r|--repo)         REPO_ID="$2"; shift 2 ;;
    -e|--episode-time) EPISODE_TIME_S="$2"; shift 2 ;;
    -s|--reset-time)   RESET_TIME_S="$2"; shift 2 ;;
    --no-push)         PUSH_TO_HUB="false"; shift ;;
    --no-voice)        VOICE_ENABLED="0"; shift ;;
    -h|--help)         usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

# ----------------------------------------------------------------------------
# Pre-flight
# ----------------------------------------------------------------------------
activate_venv

# Default the dataset repo to <your-hf-user>/so101_cups if not given.
if [ -z "$REPO_ID" ]; then
  HF_USER="$(hf auth whoami 2>/dev/null | awk 'NR==1{print $NF}')"
  REPO_ID="${HF_USER:-YOUR_HF_USERNAME}/so101_cups"
fi
case "$REPO_ID" in
  YOUR_HF_USERNAME/*) echo "NOTE: set REPO_ID or HF_USER (could not read 'hf auth whoami')." >&2 ;;
esac

check_session
check_ports
check_calibration

cat <<EOF

================ SO-101 bimanual recording ================
  dataset      : $REPO_ID
  task         : $TASK
  episodes     : $NUM_EPISODES   (episode ${EPISODE_TIME_S}s, reset ${RESET_TIME_S}s)
  push to hub  : $PUSH_TO_HUB
  leaders      : L=$LEFT_LEADER_PORT  R=$RIGHT_LEADER_PORT
  followers    : L=$LEFT_FOLLOWER_PORT  R=$RIGHT_FOLLOWER_PORT
-----------------------------------------------------------
  →  RIGHT arrow : save episode, go to NEXT
  ←  LEFT arrow  : DROP episode, re-record it
  Esc            : stop session
===========================================================

EOF

# ----------------------------------------------------------------------------
# Voice cues — read a copy of lerobot's output and speak on key events.
# Recording works fully even if a phrase doesn't match (just no spoken cue).
# ----------------------------------------------------------------------------
speak_events() {
  local line
  while IFS= read -r line; do
    if [[ "$line" =~ [Rr]ecording\ episode\ ([0-9]+) ]]; then
      say "Recording episode ${BASH_REMATCH[1]}"
      continue
    fi
    case "$line" in
      *"Reset the environment"*|*"Reset the scene"*) say "Reset the scene." ;;
      *"Re-record"*|*"re-record"*)                   say "Dropping episode. Re-recording." ;;
      *"Stop recording"*|*"stop recording"*)         say "Stopping." ;;
      *"Pushing"*|*"push_to_hub"*|*"Saving"*)         say "Uploading to the hub." ;;
    esac
  done
}

say "Starting recording. $NUM_EPISODES episodes. Right arrow for next, left arrow to drop."

CMD=(
  lerobot-record
  --teleop.type "$TELEOP_TYPE"
  --teleop.id "$ID"
  --teleop.left_arm_config.port "$LEFT_LEADER_PORT"
  --teleop.right_arm_config.port "$RIGHT_LEADER_PORT"
  --robot.type "$ROBOT_TYPE"
  --robot.id "$ID"
  --robot.left_arm_config.port "$LEFT_FOLLOWER_PORT"
  --robot.right_arm_config.port "$RIGHT_FOLLOWER_PORT"
  --dataset.repo_id "$REPO_ID"
  --dataset.single_task "$TASK"
  --dataset.num_episodes "$NUM_EPISODES"
  --dataset.episode_time_s "$EPISODE_TIME_S"
  --dataset.reset_time_s "$RESET_TIME_S"
  --dataset.push_to_hub "$PUSH_TO_HUB"
)

set +e
"${CMD[@]}" 2>&1 | tee >(speak_events)
status=${PIPESTATUS[0]}
set -e

if [ "$status" -eq 0 ]; then
  say "Recording session complete."
else
  say "Recording exited with an error."
  echo "lerobot-record exited with status $status" >&2
fi
exit "$status"
