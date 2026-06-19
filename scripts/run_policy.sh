#!/usr/bin/env bash
#
# Run the trained policy on the SO-101, inside the robot's lerobot 0.5.2 venv.
# Thin wrapper: activates the venv (via config.sh) then runs run_on_robot_so101.py.
# All arguments pass straight through.
#
# Stage it up:
#   ./run_policy.sh --dryrun --device cpu      # 1) just verify the model loads
#   ./run_policy.sh --preview                  # 2) real obs -> inference, no motion
#   ./run_policy.sh --send --hz 10             # 3) drive the arms (confirmed, clamped)
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$HERE/config.sh"

activate_venv
exec python "$HERE/run_on_robot_so101.py" "$@"
