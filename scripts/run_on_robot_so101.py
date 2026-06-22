#!/usr/bin/env python3
"""
Run a SmolVLA (or any LeRobot) policy on the REAL bimanual SO-101, entirely
inside the robot's lerobot 0.5.2 / Python 3.12 venv. No lehome dependency.

Pipeline:
    SO-101 joints + 3 cameras  ->  observation (radians, 12-D + 3 imgs)
        ->  policy.select_action()  ->  action (radians, 12-D)
        ->  [sim<->real calibration]  ->  SO-101 motor targets

The model was trained in SIMULATION (state/action in RADIANS). Your real arm
reports/accepts lerobot's calibrated units. So there is a sim<->real mapping
(units + zero offset + sign, per joint) that must be verified before any motion.

RUN IN THIS ORDER — escalate one stage at a time:
  1) --dryrun     Load policy, feed a dummy observation, print the 12-D action.
                  NO hardware. Proves the 0.4.3-trained checkpoint loads under 0.5.2.
                      python run_on_robot_so101.py --dryrun --device cpu

  2) --preview    Real cameras + joints -> inference -> PRINT what WOULD be sent.
                  NOTHING MOVES. Also prints the raw observation keys the robot
                  exposes, so you can fix CAL / key templates below. (default mode)
                      python run_on_robot_so101.py --preview

  3) --send       Actually command the arms. Slow, clamped, gated behind a typed
                  confirmation. Only after preview looks correct.
                      python run_on_robot_so101.py --send --hz 10 --max-step-rad 0.05
"""
import argparse
import sys
import time

import numpy as np

# ===========================================================================
# JOINT / CAMERA LAYOUT  (must match the training dataset)
# ===========================================================================
# State/action vector order is [left 6, right 6]:
MOTORS = ["shoulder_pan", "shoulder_lift", "elbow_flex", "wrist_flex", "wrist_roll", "gripper"]
SIDES = ["left", "right"]
JOINT_NAMES = [f"{s}_{m}" for s in SIDES for m in MOTORS]  # 12 names, model order

# How a single motor's position appears in robot.get_observation() / send_action().
# lerobot 0.5.x bimanual prefixes each arm; positions are usually "<side>_<motor>.pos".
# PREVIEW prints the real keys — if yours differ, change this template.
POS_KEY = "{side}_{motor}.pos"

# Camera name (as configured on the robot) -> the image key the policy expects.
# Configure your 3 cameras with these names so the obs keys line up.
CAMERAS = {
    "top_rgb":   "observation.images.top_rgb",    # environment cam
    "left_rgb":  "observation.images.left_rgb",   # left-wrist cam
    "right_rgb": "observation.images.right_rgb",  # right-wrist cam
}
CAM_W, CAM_H = 640, 480

# ===========================================================================
# SIM <-> REAL CALIBRATION  (THE safety-critical part — verify in --preview)
# ===========================================================================
# Real joint -> radians:   rad   = sign * scale * real + offset
# Radians -> real joint:   real  = (rad - offset) / (sign * scale)
# Defaults assume the robot runs with use_degrees=True (real = degrees), so
# scale = pi/180, offset = 0, sign = +1. These are PLACEHOLDERS: preview shows
# real-vs-policy values so you can set offset/sign per joint. Gripper almost
# certainly needs its own mapping (lerobot gripper is often a 0-100 range).
DEG2RAD = np.pi / 180.0
CAL = {name: {"scale": DEG2RAD, "offset": 0.0, "sign": 1.0} for name in JOINT_NAMES}
# Example override once you know it:
#   CAL["left_gripper"]  = {"scale": 0.01, "offset": -0.2, "sign": 1.0}

# Absolute safety clamp in RADIANS, from the training data's observed min/max
# (with a small margin). Commanded targets are clamped to these no matter what.
ABS_LIMITS_RAD = {
    "left_shoulder_pan":  (-1.35, 1.35), "left_shoulder_lift": (-1.85, 1.50),
    "left_elbow_flex":    (-1.85, 1.70), "left_wrist_flex":    (0.10, 1.75),
    "left_wrist_roll":    (-1.75, 0.25), "left_gripper":       (-0.30, 1.35),
    "right_shoulder_pan": (-1.60, 1.35), "right_shoulder_lift":(-1.85, 1.50),
    "right_elbow_flex":   (-1.85, 1.70), "right_wrist_flex":   (0.05, 1.80),
    "right_wrist_roll":   (-0.35, 1.85), "right_gripper":      (-0.30, 1.20),
}


def real_to_rad(side_motor: str, real_val: float) -> float:
    c = CAL[side_motor]
    return c["sign"] * c["scale"] * float(real_val) + c["offset"]


def rad_to_real(side_motor: str, rad_val: float) -> float:
    c = CAL[side_motor]
    return (float(rad_val) - c["offset"]) / (c["sign"] * c["scale"])


def clamp_rad(name: str, rad_val: float) -> float:
    lo, hi = ABS_LIMITS_RAD[name]
    return float(np.clip(rad_val, lo, hi))


# ===========================================================================
# POLICY  (faithful port of lehome's LeRobotPolicy onto the lerobot 0.5.x API)
# ===========================================================================
class Policy:
    def __init__(self, policy_path, task, device):
        import torch
        from lerobot.configs.policies import PreTrainedConfig
        from lerobot.policies.factory import get_policy_class, make_pre_post_processors

        self.torch = torch
        self.device = torch.device(device)
        self.task = task

        # The checkpoint is SELF-CONTAINED — no dataset metadata required:
        #   * config.json carries input_features / output_features (shapes)
        #   * policy_*processor.safetensors carry the normalization stats
        # The original lehome wrapper only loaded a dataset because make_policy()
        # *requires* ds_meta to set features. We already have them in cfg, so we
        # bypass make_policy() and load the policy class straight from the dir.
        cfg = PreTrainedConfig.from_pretrained(policy_path, cli_overrides={})
        cfg.pretrained_path = policy_path
        self.input_features = set(cfg.input_features.keys()) if hasattr(cfg, "input_features") else None

        policy_cls = get_policy_class(cfg.type)
        self.policy = policy_cls.from_pretrained(policy_path, config=cfg)
        self.policy.eval()
        self.policy.to(self.device)

        # pretrained_path makes the processors load their stats from the saved
        # *_processor.safetensors — again, no dataset needed.
        self.pre, self.post = make_pre_post_processors(
            policy_cfg=cfg,
            pretrained_path=policy_path,
            preprocessor_overrides={"device_processor": {"device": str(self.device)}},
        )
        self.action_dim = 12
        try:
            self.action_dim = int(cfg.output_features["action"].shape[0])
        except Exception:
            pass

    def reset(self):
        self.policy.reset()

    def select_action(self, obs: dict) -> np.ndarray:
        from lerobot.processor import TransitionKey
        torch = self.torch
        if self.input_features:
            obs = {k: v for k, v in obs.items()
                   if (not k.startswith("observation.")) or k in self.input_features}
        feat = {}
        for k, v in obs.items():
            if not k.startswith("observation."):
                continue
            x = torch.from_numpy(v).float()
            if v.ndim == 3 and v.shape[-1] == 3:          # (H,W,C) image -> (1,C,H,W), [0,1]
                x = x.permute(2, 0, 1).to(self.device) / 255.0
            feat[k] = x.unsqueeze(0)
        transition = {
            TransitionKey.OBSERVATION: feat,
            TransitionKey.ACTION: torch.zeros(1, self.action_dim, device=self.device),
            TransitionKey.COMPLEMENTARY_DATA: {"task": self.task},
        }
        batch = self.pre.to_output(self.pre._forward(transition))
        with torch.inference_mode():
            action = self.policy.select_action(batch)
        if self.post:
            action = self.post(action)
        return action.squeeze(0).cpu().numpy()


# ===========================================================================
# HARDWARE  (lerobot 0.5.2 bimanual SO-101).  Only imported for real runs.
# ===========================================================================
def _cam_index(x):
    """'0' -> 0 (OpenCV index); '/dev/video0' stays a path string."""
    s = str(x)
    return int(s) if s.isdigit() else s


def build_robot(args):
    from lerobot.cameras.opencv import OpenCVCameraConfig
    from lerobot.robots.bi_so_follower import BiSOFollower, BiSOFollowerConfig
    from lerobot.robots.so_follower import SOFollowerConfig

    # IMPORTANT: camera fps/size are INDEPENDENT of the control rate (--hz).
    # lerobot's camera connect() sets these on the device and asserts the device
    # reports them back EXACTLY, else it raises "failed to set fps=...". So request
    # values the camera actually supports. Pass 0 for any of them to leave it unset
    # (lerobot then uses the camera's native value and skips that assertion).
    fps = None if int(args.cam_fps) == 0 else int(args.cam_fps)
    w = None if int(args.cam_width) == 0 else int(args.cam_width)
    h = None if int(args.cam_height) == 0 else int(args.cam_height)
    cams = {name: OpenCVCameraConfig(index_or_path=_cam_index(idx), fps=fps, width=w, height=h)
            for name, idx in zip(CAMERAS.keys(), args.cam_index)}

    cfg = BiSOFollowerConfig(
        id=args.robot_id,
        left_arm_config=SOFollowerConfig(port=args.left_port, use_degrees=True),
        right_arm_config=SOFollowerConfig(port=args.right_port, use_degrees=True),
        cameras=cams,
    )
    return BiSOFollower(cfg)


def read_observation(robot, raw_dump=False) -> dict:
    """Assemble the policy observation (radians + 3 images) from the robot."""
    raw = robot.get_observation()
    if raw_dump:
        print("  raw observation keys:", sorted(raw.keys()))

    state = np.empty(12, dtype=np.float32)
    for i, name in enumerate(JOINT_NAMES):
        side, motor = name.split("_", 1)
        key = POS_KEY.format(side=side, motor=motor)
        if key not in raw:
            raise KeyError(f"obs key '{key}' not found. Real keys: {sorted(raw.keys())}")
        state[i] = real_to_rad(name, raw[key])

    obs = {"observation.state": state}
    for cam_name, policy_key in CAMERAS.items():
        if cam_name not in raw:
            raise KeyError(f"camera '{cam_name}' not in obs. Real keys: {sorted(raw.keys())}")
        img = np.asarray(raw[cam_name])
        obs[policy_key] = img.astype(np.uint8)
    return obs


def to_motor_targets(action_rad: np.ndarray) -> dict:
    """Convert a 12-D radian action to clamped per-motor targets (real units)."""
    targets = {}
    for i, name in enumerate(JOINT_NAMES):
        side, motor = name.split("_", 1)
        rad = clamp_rad(name, action_rad[i])
        targets[POS_KEY.format(side=side, motor=motor)] = rad_to_real(name, rad)
    return targets


# ===========================================================================
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--dryrun", action="store_true", help="load + dummy inference, no hardware")
    mode.add_argument("--preview", action="store_true", help="real obs -> inference, print only (default)")
    mode.add_argument("--send", action="store_true", help="DRIVE the arms (slow, clamped, confirmed)")

    ap.add_argument("--policy_path",
                    default="/home/ashish/ashish/lehome/lehome chg/outputs/train/smolvla_4type/checkpoints/last/pretrained_model",
                    help="local checkpoint dir OR a HF id like AshishRamesh/smolvla-4type-fold-test")
    ap.add_argument("--dataset_root", default=None,
                    help="(deprecated / ignored) the checkpoint is self-contained; no dataset needed")
    ap.add_argument("--task", default="fold the garment on the table")
    ap.add_argument("--device", default="cuda")
    ap.add_argument("--hz", type=float, default=10.0, help="control rate (start LOW for --send)")

    # hardware
    ap.add_argument("--robot_id", default="bimanual", help="must match your calibration id")
    ap.add_argument("--left_port", default="/dev/ttyACM3")
    ap.add_argument("--right_port", default="/dev/ttyACM2")
    ap.add_argument("--cam_index", nargs=3, default=[0, 2, 4],
                    help="OpenCV index (0) or path (/dev/video0) for top, left, right cams")
    ap.add_argument("--cam-fps", type=int, default=30,
                    help="camera fps (NOT the control rate). 0 = camera native + skip the fps check")
    ap.add_argument("--cam-width", type=int, default=640, help="camera width px (0 = native)")
    ap.add_argument("--cam-height", type=int, default=480, help="camera height px (0 = native)")

    # safety for --send
    ap.add_argument("--max-step-rad", type=float, default=0.05,
                    help="max change per joint per step (rad) — rate limiter for --send")
    ap.add_argument("--steps", type=int, default=0, help="stop after N steps (0 = until Ctrl-C)")
    args = ap.parse_args()

    if not (args.dryrun or args.preview or args.send):
        args.preview = True  # safe default

    print(f"[load] policy_path={args.policy_path}")
    print(f"[load] device={args.device}  task={args.task!r}")
    policy = Policy(args.policy_path, args.task, args.device)
    policy.reset()
    print(f"[load] OK — action_dim={policy.action_dim}")

    # ---- Stage 1: dryrun ----
    if args.dryrun:
        dummy = {
            "observation.state": np.zeros(12, dtype=np.float32),
            "observation.images.top_rgb":   np.zeros((CAM_H, CAM_W, 3), dtype=np.uint8),
            "observation.images.left_rgb":  np.zeros((CAM_H, CAM_W, 3), dtype=np.uint8),
            "observation.images.right_rgb": np.zeros((CAM_H, CAM_W, 3), dtype=np.uint8),
        }
        a = policy.select_action(dummy)
        print(f"[dryrun] inference OK -> shape={a.shape} dtype={a.dtype}")
        print(f"[dryrun] action(rad) = {np.round(a, 4)}")
        print("[dryrun] If this printed a 12-D action, the checkpoint loads under lerobot 0.5.2.")
        return

    # ---- Stages 2 & 3 need hardware ----
    robot = build_robot(args)
    print(f"[hw] connecting (left={args.left_port} right={args.right_port} cams={args.cam_index}) ...")
    robot.connect()
    try:
        print("[hw] connected. Reading one observation to show real keys:\n")
        _ = read_observation(robot, raw_dump=True)

        if args.send:
            print("\n*** --send will MOVE the arms. Preview first if you haven't. ***")
            if input("Type 'MOVE' to proceed: ").strip() != "MOVE":
                print("Aborted (no confirmation).")
                return
            prev_real = None  # for per-step rate limiting

        dt = 1.0 / args.hz
        n = 0
        print(f"\n[loop] {'SEND' if args.send else 'PREVIEW'} @ {args.hz} Hz. Ctrl-C to stop.\n")
        while True:
            t0 = time.time()
            obs = read_observation(robot)
            action = policy.select_action(obs)                  # 12-D radians
            targets = to_motor_targets(action)                  # clamped, real units

            if args.send:
                if prev_real is not None:                       # rate limit per joint
                    for i, name in enumerate(JOINT_NAMES):
                        k = POS_KEY.format(side=name.split("_", 1)[0], motor=name.split("_", 1)[1])
                        step_lim = args.max_step_rad / (CAL[name]["sign"] * CAL[name]["scale"])
                        targets[k] = float(np.clip(targets[k], prev_real[k] - abs(step_lim),
                                                   prev_real[k] + abs(step_lim)))
                robot.send_action(targets)
                prev_real = targets
            else:
                print(f"[{n:04d}] action(rad)={np.round(action, 3)}")
                if n == 0:
                    print("        would send (real units):",
                          {k: round(v, 2) for k, v in targets.items()})

            n += 1
            if args.steps and n >= args.steps:
                break
            sleep = dt - (time.time() - t0)
            if sleep > 0:
                time.sleep(sleep)
    except KeyboardInterrupt:
        print("\n[loop] stopped by user.")
    finally:
        try:
            robot.disconnect()
            print("[hw] disconnected.")
        except Exception as e:
            print(f"[hw] disconnect error: {e}", file=sys.stderr)


if __name__ == "__main__":
    main()
