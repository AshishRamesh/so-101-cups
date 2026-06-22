#!/usr/bin/env bash
#
# Record SO-101 bimanual teleoperation episodes with LeRobot, plus voice cues
# and a live Rerun viewer (3 camera feeds + joint states) via --display_data.
#
# Episode controls are NATIVE to lerobot-record (work even though output is
# piped, because the key listener hooks X directly, not stdin):
#     →  RIGHT arrow : save the current episode and start the NEXT one
#     ←  LEFT arrow  : DROP the current episode and re-record it
#     Esc            : stop the whole session (then push to hub if enabled)
#
# Cameras + Rerun viewer are ON by default (top/left/right at indices 0/2/4).
# Needs the `rerun-sdk` package (ships with lerobot). Pass --no-display to skip
# the viewer, --no-cameras to record joints only.
#
# Usage:
#   ./record_episodes.sh [-n EPISODES] [-t "TASK"] [-r USER/REPO] \
#                        [-e EPISODE_SECS] [-s RESET_SECS] [--no-push] [--no-voice] \
#                        [--no-display] [--no-cameras] [--cam-index T L R] [--cam-fps N]
#
# Examples:
#   ./record_episodes.sh                       # 30 eps, cams + Rerun viewer on
#   ./record_episodes.sh -n 50 -t "stack the cups"
#   ./record_episodes.sh --cam-index 0 2 4 --cam-fps 30
#   ./record_episodes.sh --no-display         # record (with cams) but no viewer
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

# Cameras + live Rerun viewer (camera names match the policy: top/left/right_rgb)
DISPLAY_DATA="${DISPLAY_DATA:-true}"   # --display_data -> Rerun viewer
USE_CAMERAS="${USE_CAMERAS:-1}"
CAM_TOP="${CAM_TOP:-0}"                # environment cam   -> top_rgb
CAM_LEFT="${CAM_LEFT:-2}"             # left-wrist cam    -> left_rgb
CAM_RIGHT="${CAM_RIGHT:-4}"           # right-wrist cam   -> right_rgb
CAM_FPS="${CAM_FPS:-30}"              # must be a fps the cameras actually support
CAM_W="${CAM_W:-640}"
CAM_H="${CAM_H:-480}"

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
    --no-display)      DISPLAY_DATA="false"; shift ;;
    --no-cameras)      USE_CAMERAS="0"; shift ;;
    --cam-index)       CAM_TOP="$2"; CAM_LEFT="$3"; CAM_RIGHT="$4"; shift 4 ;;
    --cam-fps)         CAM_FPS="$2"; shift 2 ;;
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

if [ "$DISPLAY_DATA" = "true" ] && ! python -c "import rerun" >/dev/null 2>&1; then
  echo "NOTE: rerun not importable — 'pip install rerun-sdk', or run with --no-display." >&2
fi

if [ "$USE_CAMERAS" = "1" ]; then
  CAM_SUMMARY="top=$CAM_TOP left=$CAM_LEFT right=$CAM_RIGHT @ ${CAM_W}x${CAM_H} ${CAM_FPS}fps"
else
  CAM_SUMMARY="(disabled)"
fi

cat <<EOF

================ SO-101 bimanual recording ================
  dataset      : $REPO_ID
  task         : $TASK
  episodes     : $NUM_EPISODES   (episode ${EPISODE_TIME_S}s, reset ${RESET_TIME_S}s)
  push to hub  : $PUSH_TO_HUB
  leaders      : L=$LEFT_LEADER_PORT  R=$RIGHT_LEADER_PORT
  followers    : L=$LEFT_FOLLOWER_PORT  R=$RIGHT_FOLLOWER_PORT
  cameras      : $CAM_SUMMARY
  Rerun viewer : $DISPLAY_DATA
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

# Attach the 3 cameras to the follower robot so they show in Rerun and get
# recorded into the dataset. draccus dict syntax; equals-form keeps it one token.
if [ "$USE_CAMERAS" = "1" ]; then
  CAMS="{ top_rgb: {type: opencv, index_or_path: ${CAM_TOP}, width: ${CAM_W}, height: ${CAM_H}, fps: ${CAM_FPS}},"
  CAMS+=" left_rgb: {type: opencv, index_or_path: ${CAM_LEFT}, width: ${CAM_W}, height: ${CAM_H}, fps: ${CAM_FPS}},"
  CAMS+=" right_rgb: {type: opencv, index_or_path: ${CAM_RIGHT}, width: ${CAM_W}, height: ${CAM_H}, fps: ${CAM_FPS}} }"
  CMD+=( "--robot.cameras=$CAMS" )
fi
CMD+=( --display_data "$DISPLAY_DATA" )

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
