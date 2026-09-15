#!/usr/bin/env python3
"""Writes events.json + recording-meta.json for the dev fixture.

events.json matches VibeStudio's EventLog Codable schema:
  {"version": 1, "events": [{"t": ..., "kind": ...}, ...]}
Cursor coordinates are global CG points (top-left origin) in a 960x540pt
display at scale 2.0, i.e. video pixels = points * 2 in a 1920x1080 video.
"""

import json
import math
import os
import sys

OUT = sys.argv[1]
STEP = 1.0 / 120.0  # cursor sampling rate

events = []


def add(t, kind, **fields):
    event = {"t": round(t, 6), "kind": kind}
    event.update(fields)
    events.append(event)


add(0.0, "cursorType", name="arrow")
add(0.1, "frontmostWindow",
    frame=[[50, 50], [600, 400]],
    appBundleID="com.apple.dt.Xcode")

# 0-2s: smooth drift (100,100) -> (300,200)
t = 0.0
while t <= 2.0:
    f = t / 2.0
    add(t, "cursorMove", x=round(100 + 200 * f, 3), y=round(100 + 100 * f, 3))
    t += STEP
add(2.0, "click", x=300, y=200, button="left")

# Sharp jump (teleport) to (700,400), then circles around it
add(2.05, "cursorMove", x=700, y=400)
t = 2.1
while t <= 5.0:
    a = (t - 2.1) * 2 * math.pi / 1.5
    add(t, "cursorMove", x=round(700 + 80 * math.cos(a), 3), y=round(400 + 80 * math.sin(a), 3))
    t += STEP
add(5.0, "click", x=700, y=400, button="left")

# 5.1-6.0s: dwell with sub-2px micro-jitter (should collapse under smoothing)
t = 5.1
i = 0
while t <= 6.0:
    jx = 0.8 if i % 2 == 0 else -0.8
    jy = 0.6 if i % 3 == 0 else -0.6
    add(t, "cursorMove", x=round(700 + jx, 3), y=round(400 + jy, 3))
    t += STEP
    i += 1

# 6-10s: slow diagonal drift to exact display center (480,270)
t = 6.0
while t <= 10.0:
    f = (t - 6.0) / 4.0
    add(t, "cursorMove", x=round(700 + (480 - 700) * f, 3), y=round(400 + (270 - 400) * f, 3))
    t += STEP
add(10.0, "click", x=480, y=270, button="left")

# Scroll + keystroke samples
for k in range(5):
    add(10.5 + 0.1 * k, "scroll", dx=0, dy=3)
add(11.0, "key", modifiers=["cmd"], key="c", keyCode=8)
add(11.5, "key", modifiers=["cmd", "shift"], key="z", keyCode=6)

# 12-20s: figure-8 around the center
t = 12.0
while t <= 20.0:
    a = (t - 12.0) * 2 * math.pi / 4.0
    add(t, "cursorMove", x=round(480 + 200 * math.sin(a), 3), y=round(270 + 100 * math.sin(2 * a), 3))
    t += STEP
add(20.0, "click", x=200, y=500, button="left")
add(21.0, "click", x=200, y=500, button="right")

# 21-29.9s: wavy drift toward (600,300)
t = 21.0
while t < 29.9:
    f = (t - 21.0) / 8.9
    add(t, "cursorMove", x=round(200 + 400 * f + 30 * math.sin(t * 3), 3), y=round(500 - 200 * f, 3))
    t += STEP
add(25.0, "click", x=420, y=388, button="left")
add(29.9, "cursorMove", x=600, y=300)

with open(os.path.join(OUT, "events.json"), "w") as f:
    json.dump({"version": 1, "events": events}, f, indent=1, sort_keys=True)

meta = {
    "version": 1,
    "createdAt": "2026-09-15T00:00:00Z",
    "sourceMode": "display",
    "displayID": 1,
    # CGRect encodes as [[x, y], [w, h]]; CGSize as [w, h] (CoreGraphics Codable).
    "displayFrameCGPoints": [[0, 0], [960, 540]],
    "scaleFactor": 2.0,
    "outputPixelSize": [1920, 1080],
    "sourceRectPixels": [[0, 0], [1920, 1080]],
    "frameRate": 60,
    "systemAudioCaptured": False,
    "screenFirstHostSeconds": 100000.0,
    "files": ["recording.mov", "events.json", "recording-meta.json"],
}
with open(os.path.join(OUT, "recording-meta.json"), "w") as f:
    json.dump(meta, f, indent=1, sort_keys=True)

print(f"{len(events)} events -> {OUT}/events.json")
