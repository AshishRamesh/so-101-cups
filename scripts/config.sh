#!/usr/bin/env bash
# Shared config + helpers for SO-101 bimanual LeRobot scripts.
# Sourced by record_episodes.sh (and future teleop/calibrate scripts).
#
# Every value below can be overridden from the environment, e.g.:
#   VENV=~/other_venv LEFT_LEADER_PORT=/dev/ttyACM5 ./record_episodes.sh

# ----------------------------------------------------------------------------
# Paths
# ----------------------------------------------------------------------------
LEROBOT_WS="${LEROBOT_WS:-$HOME/lerobot_ws}"
VENV="${VENV:-$LEROBOT_WS/lerobot312}"

# ----------------------------------------------------------------------------
# Verified arm port mapping (confirm with `lerobot-find-port` after re-plugging)
# ----------------------------------------------------------------------------
LEFT_LEADER_PORT="${LEFT_LEADER_PORT:-/dev/ttyACM1}"
RIGHT_LEADER_PORT="${RIGHT_LEADER_PORT:-/dev/ttyACM0}"
LEFT_FOLLOWER_PORT="${LEFT_FOLLOWER_PORT:-/dev/ttyACM3}"
RIGHT_FOLLOWER_PORT="${RIGHT_FOLLOWER_PORT:-/dev/ttyACM2}"

# ----------------------------------------------------------------------------
# Teleop / robot identity (from the bimanual setup guide)
# ----------------------------------------------------------------------------
TELEOP_TYPE="${TELEOP_TYPE:-bi_so_leader}"
ROBOT_TYPE="${ROBOT_TYPE:-bi_so_follower}"
ID="${ID:-bimanual}"

# ----------------------------------------------------------------------------
# Voice (text-to-speech) — pick a backend once
# ----------------------------------------------------------------------------
VOICE_ENABLED="${VOICE_ENABLED:-1}"
if   command -v espeak-ng >/dev/null 2>&1; then _TTS=espeak-ng
elif command -v spd-say   >/dev/null 2>&1; then _TTS=spd-say
elif command -v espeak    >/dev/null 2>&1; then _TTS=espeak
else _TTS=""; fi

# say "message" — print it and speak it (no-op if voice disabled / no backend).
say() {
  local msg="$*"
  printf '🔊 %s\n' "$msg"
  if [ "${VOICE_ENABLED:-1}" = "1" ] && [ -n "${_TTS:-}" ]; then
    case "$_TTS" in
      espeak-ng|espeak) "$_TTS" -s 165 "$msg" >/dev/null 2>&1 || true ;;
      spd-say)          spd-say -r -10 "$msg" >/dev/null 2>&1 || true ;;
    esac
  fi
  return 0
}

# ----------------------------------------------------------------------------
# Pre-flight helpers
# ----------------------------------------------------------------------------
activate_venv() {
  if [ -f "$VENV/bin/activate" ]; then
    # shellcheck disable=SC1091
    source "$VENV/bin/activate"
  else
    echo "ERROR: venv not found at $VENV (set VENV=...)." >&2
    exit 1
  fi
}

check_ports() {
  local p missing=0
  for p in "$LEFT_LEADER_PORT" "$RIGHT_LEADER_PORT" "$LEFT_FOLLOWER_PORT" "$RIGHT_FOLLOWER_PORT"; do
    if [ ! -e "$p" ]; then echo "ERROR: serial port not found: $p" >&2; missing=1; fi
  done
  if [ "$missing" != 0 ]; then
    echo "       Check with: ls /dev/ttyACM*   and re-map with: lerobot-find-port" >&2
    exit 1
  fi
}

check_calibration() {
  local base="$HOME/.cache/huggingface/lerobot/calibration"
  local f missing=0
  for f in \
    "$base/teleoperators/so_leader/${ID}_left.json" \
    "$base/teleoperators/so_leader/${ID}_right.json" \
    "$base/robots/so_follower/${ID}_left.json" \
    "$base/robots/so_follower/${ID}_right.json"; do
    [ -f "$f" ] || { echo "WARN: missing calibration file: $f" >&2; missing=1; }
  done
  [ "$missing" = 0 ] || echo "       Run leader + follower calibration first (lerobot-calibrate ...)." >&2
}

check_session() {
  if [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
    echo "============================================================" >&2
    echo "WARNING: Wayland session detected." >&2
    echo "  Arrow-key episode control will NOT work (keys emit ^[[C / ^[[D)." >&2
    echo "  Log out and choose 'Ubuntu on Xorg', or rely on timed episodes." >&2
    echo "============================================================" >&2
    say "Warning. Wayland detected. Arrow keys may not work."
  fi
}
