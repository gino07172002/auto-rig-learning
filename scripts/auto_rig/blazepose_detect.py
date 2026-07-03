"""Standalone BlazePose joint detector for Auto Rig Lab.

Run:  python blazepose_detect.py <image.png> [model.task]

Detects a humanoid pose in the image with MediaPipe BlazePose and prints the
33 landmarks as JSON to stdout:

    {"ok": true, "width": W, "height": H,
     "landmarks": [{"i":0,"name":"nose","x":px,"y":px,"z":rel,"vis":0..1}, ...]}

x,y are in image pixels (origin top-left). z is BlazePose's relative depth
(roughly in image-width units, negative = toward camera). On failure prints
{"ok": false, "error": "..."}.

Requires `mediapipe` (pip install mediapipe). The model .task defaults to a file
next to this script (pose_landmarker.task); if absent it is downloaded once.
"""

import sys
import os
import json
import urllib.request

MODEL_URL = ("https://storage.googleapis.com/mediapipe-models/pose_landmarker/"
             "pose_landmarker_full/float16/latest/pose_landmarker_full.task")

# BlazePose 33-landmark names (subset we care about labelled; rest by index).
LM_NAMES = {
    0: "nose", 7: "left_ear", 8: "right_ear",
    11: "left_shoulder", 12: "right_shoulder",
    13: "left_elbow", 14: "right_elbow",
    15: "left_wrist", 16: "right_wrist",
    23: "left_hip", 24: "right_hip",
    25: "left_knee", 26: "right_knee",
    27: "left_ankle", 28: "right_ankle",
    31: "left_foot_index", 32: "right_foot_index",
}


def fail(msg):
    print(json.dumps({"ok": False, "error": msg}))
    sys.exit(0)  # exit 0 so the caller reads JSON rather than treating as crash


def main():
    if len(sys.argv) < 2:
        fail("usage: blazepose_detect.py <image.png> [model.task]")
    image_path = sys.argv[1]
    if not os.path.exists(image_path):
        fail("image not found: %s" % image_path)

    here = os.path.dirname(os.path.abspath(__file__))
    model_path = sys.argv[2] if len(sys.argv) > 2 else os.path.join(here, "pose_landmarker.task")

    try:
        import numpy as np
        from PIL import Image
        import mediapipe as mp
        from mediapipe.tasks import python as mptask
        from mediapipe.tasks.python import vision
    except Exception as e:  # noqa: BLE001
        fail("missing python deps (need mediapipe, pillow, numpy): %s" % e)

    # Ensure the model exists (download once). Kept next to the script.
    try:
        if not os.path.exists(model_path) or os.path.getsize(model_path) < 1_000_000:
            urllib.request.urlretrieve(MODEL_URL, model_path)
    except Exception as e:  # noqa: BLE001
        fail("could not obtain pose model: %s" % e)

    try:
        with open(model_path, "rb") as f:
            model_bytes = f.read()
        opts = vision.PoseLandmarkerOptions(
            base_options=mptask.BaseOptions(model_asset_buffer=model_bytes),
            running_mode=vision.RunningMode.IMAGE,
            min_pose_detection_confidence=0.25,
            num_poses=1)
        detector = vision.PoseLandmarker.create_from_options(opts)
    except Exception as e:  # noqa: BLE001
        fail("could not load pose model: %s" % e)

    try:
        img = Image.open(image_path).convert("RGB")
        w, h = img.size
        mp_img = mp.Image(image_format=mp.ImageFormat.SRGB, data=np.array(img))
        res = detector.detect(mp_img)
    except Exception as e:  # noqa: BLE001
        fail("detection failed: %s" % e)

    if not res.pose_landmarks:
        fail("no pose detected")

    lms = res.pose_landmarks[0]
    out = []
    for i, lm in enumerate(lms):
        out.append({
            "i": i,
            "name": LM_NAMES.get(i, "lm_%d" % i),
            "x": lm.x * w,
            "y": lm.y * h,
            "z": lm.z * w,  # relative depth, scaled to pixel-ish units
            "vis": float(lm.visibility),
        })
    print(json.dumps({"ok": True, "width": w, "height": h, "landmarks": out}))


if __name__ == "__main__":
    main()
