# so-101-cups

Tooling for a **bimanual SO-101** rig running **LeRobot 0.5.2**: collect teleoperation
datasets, push them to the Hugging Face Hub, and deploy trained policies — including
**cloth / deformable-manipulation policies trained in Isaac Sim** (the `lehome` setup) — onto
the real robot.

> The dev machine where this repo is edited is **not** the robot. Author here, run on the
> robot box (Ubuntu 22.04, Python 3.12, LeRobot 0.5.2, Feetech servos, 3 cameras).

---

## Scripts

| Script | What it does |
|---|---|
| [`scripts/config.sh`](scripts/config.sh) | Shared config (ports, venv, IDs) + helpers: `say()` (TTS), `activate_venv`, pre-flight checks. Sourced by the others. |
| [`scripts/record_episodes.sh`](scripts/record_episodes.sh) | Record teleop episodes (voice cues + live Rerun viewer + 3 cameras). See [Recording episodes](#recording-episodes). |
| [`scripts/push_dataset.sh`](scripts/push_dataset.sh) | Find a locally recorded dataset, ask which HF repo to push to, upload it. |
| [`scripts/download_model.sh`](scripts/download_model.sh) | Pull a trained policy from HF into the local cache (skips if cached). |
| [`scripts/run_on_robot_so101.py`](scripts/run_on_robot_so101.py) | Run a policy on the SO-101 (lerobot 0.5.2). Stages: `--dryrun` → `--preview` → `--send`. |
| [`scripts/run_policy.sh`](scripts/run_policy.sh) | Wrapper: activates the venv, runs `run_on_robot_so101.py`, passes args through. |

### Verified hardware (confirm with `lerobot-find-port`)

| Arm | Port | | Arm | Port |
|---|---|---|---|---|
| Left Leader | `/dev/ttyACM1` | | Left Follower | `/dev/ttyACM3` |
| Right Leader | `/dev/ttyACM0` | | Right Follower | `/dev/ttyACM2` |

Types/IDs: `--robot.type bi_so_follower`, `--teleop.type bi_so_leader`, `--*.id bimanual`.
Calibration lives under `~/.cache/huggingface/lerobot/calibration/{robots/so_follower,teleoperators/so_leader}/bimanual_{left,right}.json`.

---

## Quick start

```bash
# On the robot box, every terminal:
source ~/lerobot_ws/lerobot312/bin/activate

# Collect data
./scripts/record_episodes.sh -n 30 -t "pick up the cup"
./scripts/push_dataset.sh
```

---

## Recording episodes

[`scripts/record_episodes.sh`](scripts/record_episodes.sh) teleoperates the bimanual SO-101 and
records episodes into a LeRobot dataset, with **voice cues** and a **live Rerun viewer** (3 camera
feeds + joint plots). The 3 cameras are also written into the dataset as
`observation.images.top_rgb / left_rgb / right_rgb`.

```bash
./scripts/record_episodes.sh -n 30 -t "pick up the cup"
```

### Controls during a session (native lerobot keys)
- **→ right arrow** — save the current episode, start the next
- **← left arrow** — drop the current episode and re-record it
- **Esc** — stop the session (then push to hub, unless `--no-push`)

> Arrow keys are **X11 only**. Under Wayland they emit `^[[C`/`^[[D` and don't work — log in on
> **Ubuntu on Xorg**, or rely on the episode timer. Check with `echo $XDG_SESSION_TYPE`.

### Parameters

| Flag | Env var | Default | Meaning |
|---|---|---|---|
| `-n, --episodes` | `NUM_EPISODES` | `30` | number of episodes to record |
| `-t, --task` | `TASK` | `pick up the cup` | task text stored on every frame (`dataset.single_task`) |
| `-r, --repo` | `REPO_ID` | `<hf-user>/so101_cups` | HF dataset repo id (auto-filled from `hf auth whoami`) |
| `-e, --episode-time` | `EPISODE_TIME_S` | `30` | seconds recorded per episode (or until → / ←) |
| `-s, --reset-time` | `RESET_TIME_S` | `5` | seconds **between** episodes to reset the scene (not recorded) |
| `--no-push` | `PUSH_TO_HUB=false` | push on | keep the dataset local; upload later with `push_dataset.sh` |
| `--no-voice` | `VOICE_ENABLED=0` | voice on | disable the spoken cues |
| `--no-display` | `DISPLAY_DATA=false` | viewer on | skip the Rerun viewer (still records) |
| `--no-cameras` | `USE_CAMERAS=0` | cams on | record joints only, no images |
| `--cam-index T L R` | `CAM_TOP`/`CAM_LEFT`/`CAM_RIGHT` | `0 2 4` | OpenCV index or `/dev/videoN` for top, left-wrist, right-wrist cams |
| `--cam-fps N` | `CAM_FPS` | `30` | camera fps — must be a rate the cameras actually support |
| — | `CAM_W` / `CAM_H` | `640` / `480` | camera resolution |

Flags override env vars; both override the defaults. `-h/--help` prints the same.

### How the reset window works
After each episode, teleop stays **live** for `--reset-time` seconds with **nothing recorded** —
your window to physically reset the scene (replace the cup, reposition objects/arms). It's manual
(real robot, no auto-reset). Press **→** to end the reset early and start the next episode; bump
`-s` if 5s is too short.

### Examples
```bash
./scripts/record_episodes.sh                           # 30 eps, cams + viewer, push to hub
./scripts/record_episodes.sh -n 50 -t "stack the cups" -s 15
./scripts/record_episodes.sh --cam-index 0 2 4 --cam-fps 30
./scripts/record_episodes.sh --no-display --no-push     # no viewer, keep dataset local
REPO_ID=me/so101_demo ./scripts/record_episodes.sh
```

### Shirt-folding run
Record 50 shirt-folding episodes (15s reset) to `AshishRamesh/shirt-fold`. Cameras, voice,
`--display_data`, and the Rerun viewer are all ON by default, so no extra flags are needed:

```bash
./scripts/record_episodes.sh -n 50 -t "fold the shirt" -s 15 -r "AshishRamesh/shirt-fold"
```

### Requirements / gotchas
- Run inside the venv: `source ~/lerobot_ws/lerobot312/bin/activate`.
- The Rerun viewer needs `rerun-sdk` (ships with lerobot); otherwise `pip install rerun-sdk`, or use `--no-display`.
- `--cam-fps` must be a rate the camera supports, or `connect()` fails with `failed to set fps=...`. Probe with the cv2 snippet under [Notes](#notes--defaults-to-change-on-the-robot-box).
- Recording requires the leader **and** follower arms connected + calibrated (`bimanual` id).

---

## Deploying cloth / deformable policies trained in Isaac Sim

This covers running a **SmolVLA policy trained in simulation** (the `lehome` Isaac-Sim setup,
e.g. `AshishRamesh/smolvla-4type-fold-test`) on the **real** SO-101.

### Will it run out of the box? No.

`--dryrun` (load + dummy inference, no hardware) is the only thing that *might* work
immediately. Real motion will not, until the items below are checked and fixed. The script is
deliberately built to **surface** these, not hide them — it prints the real observation keys
and previews every action before anything moves.

The four root causes of friction:

1. **Two LeRobot stacks.** The model was trained with `lerobot==0.4.3` (Python 3.11, the
   `lehome` repo). The robot runs `lerobot==0.5.2` (Python 3.12). We chose to run everything in
   the 0.5.2 venv, so the **checkpoint must load under 0.5.2** — the #1 thing to verify.
2. **Units & frame.** The model's state/action are **radians in the simulator's joint frame**
   (zeros, signs, ranges from sim). The real arm uses LeRobot's calibrated units. A per-joint
   `scale + offset + sign` map (`CAL` in the script) bridges them and **must be tuned**.
3. **Cameras.** The model needs 3 RGB streams named `top_rgb`, `left_rgb`, `right_rgb` at
   640×480. Indices, names, and resolution all have to line up.
4. **Sim-to-real gap.** Even with everything wired correctly, a sim-trained policy may behave
   poorly on real hardware (different visuals/dynamics). Expect to need on-robot fine-tuning.

### Bring-up: run these stages in order

```bash
# 0) One-time on the robot box:
#    - install lerobot 0.5.2 with extras (see the bimanual setup guide):
#        pip install -e .  +  lerobot[feetech] lerobot[dataset]  + opencv
#    - copy the checkpoint dir, OR:  ./scripts/download_model.sh AshishRamesh/smolvla-4type-fold-test
#    (NO dataset needed — the checkpoint is self-contained: features in config.json,
#     normalization stats in the policy_*processor.safetensors.)

# 1) Does the 0.4.3-trained checkpoint load under 0.5.2?  (no hardware)
./scripts/run_policy.sh --dryrun --device cpu \
  --policy_path /path/to/checkpoints/last/pretrained_model

# 2) Real cameras + joints -> inference -> PRINTS the action + what it WOULD send.
#    Nothing moves. Prints the raw obs keys so you can fix the mappings.
./scripts/run_policy.sh --preview

# 3) Only after preview looks right: drive the arms. Slow, clamped, asks you to type MOVE.
./scripts/run_policy.sh --send --hz 10 --max-step-rad 0.05
```

### Tuning the sim↔real calibration (`CAL`)

Per joint: `radians = sign * scale * real + offset`. Default is a plain `deg→rad` guess
(`scale=π/180, offset=0, sign=+1`) — fine as a starting point, wrong in the details.

1. Run `--preview` and watch the printed `action(rad)` and "would send (real units)".
2. By hand, move each joint to two known poses (e.g. a sim-defined "home" and a 90° bend) and
   read the real values the robot reports.
3. Solve `scale`/`offset` so the real readings map onto the model's radian frame; flip `sign`
   if the joint moves the opposite way. Set these in `CAL` (top of `run_on_robot_so101.py`).
4. Re-preview until the policy's input state (radians) is sane for a known pose, **then** try
   `--send` at low `--hz` and small `--max-step-rad`.

---

## Notes / defaults to change on the robot box
- `--policy_path` defaults to this dev box's `lehome` checkpoint path — repoint it (or pass the HF id). `--dataset_root` is ignored (checkpoint is self-contained).
- `--cam_index 0 2 4` (top, left, right) and the `CAMERAS` names must match your hardware.
- `--left_port /dev/ttyACM3 --right_port /dev/ttyACM2` per the verified mapping above.

Probe each camera's native fps/resolution (to pick `--cam-fps/--cam-width/--cam-height`, or just use `0`):
```bash
python - <<'PY'
import cv2
for i in (0, 2, 4):
    c = cv2.VideoCapture(i)
    if c.isOpened():
        print(f"cam {i}: fps={c.get(cv2.CAP_PROP_FPS)} {int(c.get(3))}x{int(c.get(4))}")
        c.release()
    else:
        print(f"cam {i}: not opened")
PY
```
