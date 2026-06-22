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
| [`scripts/record_episodes.sh`](scripts/record_episodes.sh) | Record teleop episodes. Native arrow keys: **→** save+next, **←** drop+re-record, **Esc** stop. Voice cues + **live Rerun viewer** (3 cam feeds + joint states via `--display_data`); 3 cameras recorded into the dataset. `--no-display` / `--no-cameras` to disable. |
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

> **Wayland breaks the arrow keys** during recording (they emit `^[[C`/`^[[D`). Check with
> `echo $XDG_SESSION_TYPE`; if `wayland`, log in on **Ubuntu on Xorg** or use timed episodes.

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
   640×480. Indices, names, color order, and resolution all have to line up.
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

### Troubleshooting — symptom → cause → fix

Editable knobs are constants at the top of
[`run_on_robot_so101.py`](scripts/run_on_robot_so101.py): `POS_KEY`, `CAMERAS`, `CAM_W/CAM_H`,
`CAL`, `ABS_LIMITS_RAD`.

#### Stage 1 — model loading (`--dryrun`)

| Symptom | Likely cause | Fix |
|---|---|---|
| `ModuleNotFoundError: lerobot` / wrong version | venv not active / wrong install | `source ~/lerobot_ws/lerobot312/bin/activate`; verify `python -c "import lerobot;print(lerobot.__version__)"` → `0.5.2`. |
| `ImportError: lerobot.processor.core` (or `make_pre_post_processors`, `PreTrainedConfig`) | API path moved between 0.4.3 and 0.5.2 | `python -c "import lerobot.processor as p; print(dir(p))"` and adjust the imports in the `Policy` class. |
| Config load error — unknown field / unexpected keyword / unknown policy type | `config.json` schema differs between 0.4.3 and 0.5.2 | Try loading in the **lehome 0.4.3 env** to confirm the checkpoint is fine; if so, either (a) hand-edit `config.json` to the 0.5.2 schema, or (b) fall back to the **HTTP policy-server bridge** (run the policy in 0.4.3, robot client in 0.5.2). |
| Processor/normalizer file errors | 0.5.2 expects a different processor layout than the saved `policy_*_processor.*` files | Same fallback as above — load/serve in 0.4.3. |
| Hangs/downloads at load, or offline failure | SmolVLA pulls its VLM base + tokenizer (`lerobot/smolvla_base`, `HuggingFaceTB/SmolVLM2-500M-Video-Instruct`) | Pre-download on a networked machine (`hf download ...`), or set `HF_HOME`/`HF_HUB_OFFLINE=1` with a warm cache. |
| `FileNotFoundError: meta/info.json` / `404 datasets/lehome` | **(fixed)** old code loaded dataset metadata via `make_policy(ds_meta=...)` | Already resolved — the loader now bypasses `make_policy` and reads features from `config.json` + stats from the processor safetensors. No dataset / `--dataset_root` needed. |
| CUDA OOM | GPU too small for the model + autocast | `--device cpu` for dryrun; for real runs use a smaller batch / fp16, or a bigger GPU. |

If Stage 1 cannot be made to pass under 0.5.2, **stop and switch to the HTTP policy-server
bridge** — that decouples the versions cleanly (`lehome/dummy_docker_policy/` already defines the
observation contract this script uses).

#### Stage 2 — observation wiring (`--preview`)

| Symptom | Likely cause | Fix |
|---|---|---|
| `KeyError: obs key 'left_shoulder_pan.pos' not found` (prints real keys) | `POS_KEY` template doesn't match your build | Set `POS_KEY` to the real format shown (e.g. drop `.pos`, or different motor names). |
| `ImportError: BiSOFollower / SOFollowerConfig / OpenCVCameraConfig` | class/module names differ in your 0.5.2 | `python -c "import lerobot.robots as r; print(dir(r))"`; update `build_robot()`. |
| `TypeError: unexpected keyword 'use_degrees'` | that field isn't on `SOFollowerConfig` here | Remove it; then figure out the native unit from preview values and set `CAL` accordingly. |
| "no status packet" / one arm dead | wrong port, loose/unpowered servo, wrong motor id, bad wrist_roll | Check `ls /dev/ttyACM*`, re-run `lerobot-find-port`, reseat cables/power. |
| Robot asks to recalibrate | `--robot_id` ≠ the id used at calibration | Use `--robot_id bimanual` (matches `bimanual_{left,right}.json`). |
| `RuntimeError: ... failed to set fps=...` / `Failed to open OpenCVCamera` (but raw `cv2.VideoCapture(0)` works) | lerobot's `connect()` sets fps/width/height and asserts the device reports them back **exactly** — you requested a value it can't deliver | Use a supported `--cam-fps` (try 30). If it still complains, fall back to native: `--cam-fps 0 --cam-width 0 --cam-height 0` (skips the checks). Probe native values with the cv2 snippet under [Notes](#notes--defaults-to-change-on-the-robot-box). Camera fps is now independent of `--hz`. |
| `KeyError: camera 'top_rgb' not in obs` | camera names / indices wrong | List cams (`ls /dev/video*`); set `--cam_index` (top left right order, accepts `0` or `/dev/video0`) and the `CAMERAS` names to match the dumped keys (top-level cams may be unprefixed, wrist cams prefixed `left_`/`right_`). |
| Images look blue-tinted | double BGR↔RGB conversion | lerobot's `OpenCVCamera` already returns **RGB** (`color_mode` defaults to RGB) — do **not** add your own `cvtColor`. |
| Wrong image size | camera not at 640×480 | Set `--cam-width/--cam-height` (default 640×480, matches training), or `0` for native (the policy preprocessor resizes anyway). |

#### Stage 3 — motion correctness (`--send`)

| Symptom | Likely cause | Fix |
|---|---|---|
| Arms jerk / fight / drive into limits | `CAL` units/offset/sign wrong → policy fed garbage state | Tune `CAL` per joint (procedure below). `ABS_LIMITS_RAD` + `--max-step-rad` keep this safe meanwhile. |
| Gripper behaves wildly | gripper isn't simple deg→rad (often a 0–100 range) | Give `left_gripper`/`right_gripper` their own `CAL` (`scale`/`offset`) from preview. |
| Motion is sluggish / unstable | control rate far from the 30 fps training rate | Raise `--hz` toward 30 once safe; SmolVLA manages its own action queue (don't forget `policy.reset()` per episode — the script does this at start). |
| Everything wired right but the task fails | sim-to-real distribution gap (visuals/dynamics) | Collect a small real dataset and **fine-tune** the policy on it; verify camera viewpoints roughly match the sim cameras. |

### Tuning the sim↔real calibration (`CAL`)

Per joint: `radians = sign * scale * real + offset`. Default is a plain `deg→rad` guess
(`scale=π/180, offset=0, sign=+1`) — fine as a starting point, wrong in the details.

1. Run `--preview` and watch the printed `action(rad)` and "would send (real units)".
2. By hand, move each joint to two known poses (e.g. a sim-defined "home" and a 90° bend) and
   read the real values the robot reports.
3. Solve `scale`/`offset` so the real readings map onto the model's radian frame; flip `sign`
   if the joint moves the opposite way. Set these in `CAL`.
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
