#!/usr/bin/env python3
"""Independent receiver for the optical tag, from a PC video source.

Decodes the same packet the tag board transmits:

    SYNC(16) = 0xAAD3 | PASSWORD(16) | CRC8(password)

The reader board can assume four camera rows per bit because it knows its own
sensor. A PC video source has a completely different row period, so nothing here
assumes a rate: samples-per-bit is searched for on every frame together with the
packet phase, and the majority vote, sync word and CRC together decide whether a
candidate is real.

Two ways to feed it:

  webcam pointed at the tag
      Needs a manual exposure well under the bit period, which some cannot reach.
      Start at --exposure -13 and go shorter.

  capture card carrying the reader board's VGA output
      Far easier: the banding is already baked into the image the FPGA draws, so
      no exposure control is needed or possible. The defaults are set up for this.

Defaults suit the capture-card setup, so the only thing normally worth passing is
the reader's serial port, which is what puts its PASS/DENY verdict on screen.

    py occ_webcam_rx.py --list
    py occ_webcam_rx.py --uart COM7

Keys:  q quit   r reset counters   [ ] exposure   - = ROI width
       9 0 preview brightness      f flip readout
"""

import argparse
import threading
import time
from collections import deque

import cv2
import numpy as np

SYNC_WORD = 0xAAD3
SYNC_BITS = np.array([(SYNC_WORD >> (15 - i)) & 1 for i in range(16)], dtype=np.int8)

# ---------------------------------------------------------------- settings
# The reader board's serial port. Both Basys3 boards enumerate as the same FTDI
# part, so which COM number lands on the reader depends on the USB port it went
# into - change this line if it moves, or override it with --uart.
DEFAULT_UART_PORT = "COM7"

# Preview look. BLACK_POINT is the percentile treated as true black: raising it
# darkens the background, lowering it keeps more of the faint detail.
BLACK_POINT = 40
TARGET_MEAN = 110

# Window magnification. 640x480 at 1.5 gives 960x720; raise it for a projector.
DEFAULT_SCALE = 1.5
# ---------------------------------------------------------------------------

# How long a decoded credential or a verdict stays on screen before it is withdrawn.
HOLD_SECONDS = 2.0


def uart_verdicts(port, baud, sink):
    """Feed the reader board's own OPEN/DENY lines to the display.

    The board decides. Re-deriving the verdict here from a locally configured
    credential would create a second source of truth that can disagree with the
    switches on the reader, which is the last thing wanted on a demo screen.
    """
    try:
        import serial
    except ImportError:
        sink.append(("ERR", "no pyserial", time.monotonic()))
        return

    try:
        with serial.Serial(port, baud, timeout=1) as link:
            while True:
                raw = link.readline()
                if not raw:
                    continue
                parts = raw.decode("ascii", errors="replace").strip().split()
                if len(parts) == 2 and parts[0] in ("OPEN", "DENY"):
                    sink.append((parts[0], parts[1], time.monotonic()))
    except Exception as exc:  # port busy, unplugged, wrong name
        sink.append(("ERR", type(exc).__name__, time.monotonic()))

PW_BITS = 16
CRC_BITS = 8
TOTAL_BITS = 16 + PW_BITS + CRC_BITS  # 40


def crc8(values):
    """CRC-8, polynomial 0x07, init 0x00, MSB first - matches occ_pkg.sv."""
    crc = 0
    for byte in values:
        for i in range(8):
            if ((crc >> 7) & 1) ^ ((byte >> (7 - i)) & 1):
                crc = ((crc << 1) ^ 0x07) & 0xFF
            else:
                crc = (crc << 1) & 0xFF
    return crc


def row_profile(frame, x0, x1, flip):
    """Mean red level of each row across the ROI columns."""
    prof = frame[:, x0:x1, 2].mean(axis=1).astype(np.float32)
    return prof[::-1] if flip else prof


def binarize(prof):
    """Remove the vignetting gradient, then slice at the midpoint.

    A moving average must not be used here: a run of identical bits longer than
    the window drags the baseline along with it and erases the band entirely,
    which wipes out exactly the values with the longest runs. A low-order
    polynomial can only follow the lens falloff, never the data.
    """
    x = np.arange(len(prof), dtype=np.float32)
    base = np.polyval(np.polyfit(x, prof, 2), x)
    detrended = prof - base

    lo, hi = np.percentile(detrended, 5), np.percentile(detrended, 95)
    contrast = float(hi - lo)
    if contrast < 1.0:
        return None, contrast
    return (detrended > (lo + hi) / 2).astype(np.int8), contrast


def find_candidates(bits, sp_min, sp_max, sp_step=0.1, min_score=15, limit=400):
    """All (score, samples_per_bit, start) whose sync correlation is good enough.

    Sixteen sync bits do not pin the rate tightly enough to sample the remaining
    bits correctly, so this returns every plausible candidate and lets the full
    packet check decide.
    """
    n = len(bits)
    out = []
    for sp in np.arange(sp_min, sp_max, sp_step):
        span = int(TOTAL_BITS * sp) + 2
        if span >= n:
            break
        starts = np.arange(n - span)
        offsets = ((np.arange(16) + 0.5) * sp).astype(np.int32)
        sampled = bits[starts[:, None] + offsets[None, :]]
        score = (sampled == SYNC_BITS[None, :]).sum(axis=1)
        for j in np.flatnonzero(score >= min_score):
            out.append((int(score[j]), float(sp), int(starts[j])))

    out.sort(key=lambda c: -c[0])
    return out[:limit]


def decode_packet(bits, sp, start, min_conf=0.75):
    """Return (password, fit) for a candidate, or None if it does not hold up.

    The 8-bit CRC alone cannot arbitrate: the search offers hundreds of candidates
    per frame, so at 1/256 false-accept a wrong one gets through on almost every
    frame. Each bit is a majority vote over the middle half of its span, every bit
    must be confident, and the sync word has to reappear exactly.
    """
    if start + TOTAL_BITS * sp >= len(bits):
        return None

    values = np.empty(TOTAL_BITS, dtype=np.int8)
    for i in range(TOTAL_BITS):
        lo = int(np.floor(start + (i + 0.25) * sp))
        hi = max(int(np.ceil(start + (i + 0.75) * sp)), lo + 1)
        segment = bits[lo:hi]
        if segment.size == 0:
            return None
        mean = float(segment.mean())
        if max(mean, 1.0 - mean) < min_conf:
            return None
        values[i] = 1 if mean >= 0.5 else 0

    if not np.array_equal(values[:16], SYNC_BITS):
        return None

    password = int("".join(map(str, values[16:32])), 2)
    crc = int("".join(map(str, values[32:40])), 2)

    if crc != crc8([password >> 8, password & 0xFF]):
        return None

    # How well the decoded bits explain every sample of the span, not just the
    # centres. A parse that drifted by a bit can still satisfy sync and CRC when
    # the payload has long runs, but it cannot match the waveform as a whole.
    lo = int(np.floor(start))
    hi = min(int(np.ceil(start + TOTAL_BITS * sp)), len(bits))
    positions = np.arange(lo, hi)
    owner = np.clip(((positions - start) / sp).astype(np.int32), 0, TOTAL_BITS - 1)
    fit = float((bits[positions] == values[owner]).mean())

    return password, fit


def render_profile(prof, bits, height, width):
    """Small strip showing the row profile and the slicer output."""
    canvas = np.zeros((height, width, 3), dtype=np.uint8)
    if len(prof) < 2:
        return canvas

    xs = np.linspace(0, width - 1, len(prof)).astype(np.int32)
    lo, hi = float(prof.min()), float(prof.max())
    scale = (hi - lo) if hi > lo else 1.0
    ys = (height - 1 - (prof - lo) / scale * (height - 1)).astype(np.int32)
    canvas[ys, xs] = (120, 200, 255)

    if bits is not None:
        canvas[height - 4 :, xs[bits == 1]] = (80, 220, 120)
    return canvas


def preview_image(frame, gain):
    """Brighten the preview for human eyes; decoding never sees this.

    With gain 0 the frame is stretched so its darkest and brightest rows land at
    the ends of the range. A plain multiply cannot do this job: the exposure that
    resolves banding leaves the picture very dark but the bands themselves already
    span a good fraction of it, so scaling up enough to see anything drives the
    bright bands into clipping and flattens exactly what you wanted to look at.
    """
    if gain > 0:
        return cv2.convertScaleAbs(frame, alpha=gain), gain

    # Gamma rather than a linear stretch. The LED itself is already near the top of
    # the range while the banding around it sits in the shadows, so there is nothing
    # left to stretch into - only lifting the low end without touching the high end
    # brings the stripes out.
    #
    # Gamma alone would also lift the noise floor into a grey haze, so the background
    # level is subtracted first. That keeps unlit areas black while the stripes still
    # get their boost.
    #
    # Each channel gets its own floor. The board drives R, G and B identically, but a
    # capture card's channels sit a few levels apart, and a gamma this steep turns a
    # four-level offset into a plainly green picture.
    floors = np.percentile(frame.reshape(-1, 3), BLACK_POINT, axis=0)
    lifted = np.clip(frame.astype(np.int16) - floors.astype(np.int16),
                     0, 255).astype(np.uint8)

    mean = max(float(lifted.mean()), 1.0)
    gamma = float(np.clip(np.log(TARGET_MEAN / 255.0) / np.log(mean / 255.0), 0.3, 1.0))

    levels = np.arange(256, dtype=np.float32) / 255.0
    lut = np.clip(np.power(levels, gamma) * 255.0, 0, 255).astype(np.uint8)
    return cv2.LUT(lifted, lut), gamma


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--camera", type=int, default=0)
    # 640x480 is what the reader board's VGA actually outputs. Asking a capture card
    # for anything else makes it rescale, and interpolating rows blends neighbours -
    # which is precisely the row-to-row difference the banding lives in.
    ap.add_argument("--width", type=int, default=640)
    ap.add_argument("--height", type=int, default=480)
    ap.add_argument("--exposure", type=float, default=-11.0,
                    help="log2 seconds; webcams only, ignored by capture cards")
    ap.add_argument("--roi", type=int, default=120, help="ROI width in pixels")
    ap.add_argument("--flip", action="store_true", help="reverse readout direction")
    ap.add_argument("--gain", type=float, default=0.0,
                    help="preview brightness; 0 picks a gamma per frame, which is "
                         "what makes the banding visible. Decoding always uses the "
                         "raw frame regardless")
    ap.add_argument("--backend", choices=["dshow", "msmf", "any"], default="dshow")
    ap.add_argument("--list", action="store_true",
                    help="probe the first few device indices and exit")
    ap.add_argument("--uart", metavar="COMx", default=DEFAULT_UART_PORT,
                    help=f"reader board's serial port, default {DEFAULT_UART_PORT}; "
                         f"its OPEN/DENY verdict is shown on screen. Pass 'none' to "
                         f"run without it")
    ap.add_argument("--uart-baud", type=int, default=115200)
    ap.add_argument("--scale", type=float, default=DEFAULT_SCALE,
                    help=f"how much to enlarge the window, default {DEFAULT_SCALE}. "
                         f"The window can also be dragged to any size")
    args = ap.parse_args()

    backends = {"dshow": cv2.CAP_DSHOW, "msmf": cv2.CAP_MSMF, "any": cv2.CAP_ANY}
    backend = backends[args.backend]

    if args.list:
        for name, be in backends.items():
            print(f"--backend {name}")
            for i in range(4):
                probe = cv2.VideoCapture(i, be)
                if probe.isOpened():
                    ok, frame = probe.read()
                    w = int(probe.get(cv2.CAP_PROP_FRAME_WIDTH))
                    h = int(probe.get(cv2.CAP_PROP_FRAME_HEIGHT))
                    level = f"{frame.mean():6.1f}" if ok else "  none"
                    print(f"    --camera {i}   {w}x{h}   mean level {level}")
                probe.release()
        return

    cap = cv2.VideoCapture(args.camera, backend)
    if not cap.isOpened():
        raise SystemExit(f"cannot open camera {args.camera} on {args.backend}")

    cap.set(cv2.CAP_PROP_FRAME_WIDTH, args.width)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, args.height)
    # 0.25 selects manual exposure on the DirectShow backend.
    cap.set(cv2.CAP_PROP_AUTO_EXPOSURE, 0.25)
    cap.set(cv2.CAP_PROP_EXPOSURE, args.exposure)

    exposure = args.exposure
    roi_half = max(8, args.roi // 2)
    flip = args.flip
    gain = args.gain

    last_password = None
    last_seen = 0.0
    frames = decoded = 0

    scale = max(0.5, args.scale)
    # Resizable so the window can also just be dragged bigger during a demo.
    cv2.namedWindow("OCC tag receiver", cv2.WINDOW_NORMAL)

    uart_port = None if args.uart.lower() in ("none", "off", "") else args.uart
    verdicts = deque(maxlen=8)
    verdict = None
    if uart_port:
        threading.Thread(target=uart_verdicts,
                         args=(uart_port, args.uart_baud, verdicts),
                         daemon=True).start()

    while True:
        ok, frame = cap.read()
        if not ok:
            break
        frames += 1

        h, w = frame.shape[:2]
        cx = w // 2
        x0, x1 = max(0, cx - roi_half), min(w, cx + roi_half)

        prof = row_profile(frame, x0, x1, flip)
        bits, contrast = binarize(prof)

        score = 0
        sp = 0.0
        if bits is not None:
            # A packet has to fit inside one frame, which bounds the search.
            sp_max = max(4.0, len(bits) / TOTAL_BITS)
            best = None
            for cand_score, cand_sp, cand_start in find_candidates(bits, 3.0, sp_max):
                score = max(score, cand_score)
                hit = decode_packet(bits, cand_sp, cand_start)
                if hit is not None and (best is None or hit[1] > best[0][1]):
                    best = (hit, cand_sp)

            if best is not None:
                (password, _), sp = best
                last_password = password
                last_seen = time.monotonic()
                decoded += 1

        fresh = last_password is not None and (time.monotonic() - last_seen) < HOLD_SECONDS

        while verdicts:
            verdict = verdicts.popleft()

        view, alpha = preview_image(frame, gain)

        # Enlarge before the overlays are drawn so text and boxes stay crisp, and
        # with nearest-neighbour so the row stripes keep their hard edges. Any
        # smoothing here would blur away the very thing the window exists to show.
        if scale != 1.0:
            view = cv2.resize(view, None, fx=scale, fy=scale,
                              interpolation=cv2.INTER_NEAREST)
        vh, vw = view.shape[:2]
        sx0, sx1 = int(x0 * scale), int(x1 * scale)
        font = 0.62 * scale
        strip = int(70 * scale)
        pad = int(20 * scale)

        cv2.rectangle(view, (sx0, 0), (sx1, vh - 1), (0, 220, 120), max(2, int(2 * scale)))
        view[vh - strip - pad : vh - pad, 0:vw] = cv2.addWeighted(
            view[vh - strip - pad : vh - pad, 0:vw], 0.25,
            render_profile(prof, bits, strip, vw), 0.9, 0)

        # The board's credential rides under the banner instead of in this line,
        # which would otherwise grow long enough to run underneath it.
        shown = f"{last_password:04X}" if fresh else "----"
        lines = [
            f"password  {shown}     decoded {decoded} / {frames} frames",
            f"sync  {score}/16   samples/bit {sp:5.2f}   contrast {contrast:6.1f}",
            f"exposure {exposure:.0f}   roi {2 * roi_half}px   flip {int(flip)}"
            f"   {'gamma ' + format(alpha, '.2f') if gain <= 0 else format(alpha, '.0f') + 'x'}",
        ]

        # Always say what the serial link is doing. Without this an absent banner is
        # ambiguous: no port given, port refused, or simply no tag in front of the
        # reader all look identical.
        if not uart_port:
            lines.append("uart  disabled - pass --uart COMx for the board verdict")
        elif verdict is None:
            lines.append(f"uart  {uart_port}  open, waiting for the board")
        elif verdict[0] == "ERR":
            lines.append(f"uart  {uart_port}  failed: {verdict[1]}")
        else:
            age = time.monotonic() - verdict[2]
            lines.append(f"uart  {uart_port}  {verdict[0]} {verdict[1]}  {age:.1f}s ago")
        for i, line in enumerate(lines):
            at = (int(12 * scale), int((28 + 26 * i) * scale))
            cv2.putText(view, line, at, cv2.FONT_HERSHEY_SIMPLEX, font,
                        (0, 0, 0), max(3, int(4 * scale)), cv2.LINE_AA)
            cv2.putText(view, line, at, cv2.FONT_HERSHEY_SIMPLEX, font,
                        (255, 255, 255), max(1, int(scale)), cv2.LINE_AA)

        # The banner is the reader board's verdict, never a locally computed one.
        if verdict is not None and (time.monotonic() - verdict[2]) < HOLD_SECONDS:
            label = {"OPEN": "PASS", "DENY": "DENY"}.get(verdict[0], "UART?")
            colour = (90, 210, 90) if label == "PASS" else (70, 70, 240)
            big = 1.8 * scale
            (tw, th), _ = cv2.getTextSize(label, cv2.FONT_HERSHEY_SIMPLEX, big, 5)
            bx, by = vw - tw - int(46 * scale), int(24 * scale)
            m, drop = int(18 * scale), int(28 * scale)
            cv2.rectangle(view, (bx - m, by), (bx + tw + m, by + th + drop),
                          (20, 20, 20), -1)
            cv2.rectangle(view, (bx - m, by), (bx + tw + m, by + th + drop),
                          colour, max(2, int(3 * scale)))
            cv2.putText(view, label, (bx, by + th + int(10 * scale)),
                        cv2.FONT_HERSHEY_SIMPLEX, big, colour,
                        max(3, int(5 * scale)), cv2.LINE_AA)

            caption = f"board says {verdict[1]}"
            (cw, _), _ = cv2.getTextSize(caption, cv2.FONT_HERSHEY_SIMPLEX, font, 1)
            at = (bx + (tw - cw) // 2, by + th + int(52 * scale))
            cv2.putText(view, caption, at, cv2.FONT_HERSHEY_SIMPLEX, font,
                        (0, 0, 0), max(3, int(4 * scale)), cv2.LINE_AA)
            cv2.putText(view, caption, at, cv2.FONT_HERSHEY_SIMPLEX, font,
                        (235, 235, 235), max(1, int(scale)), cv2.LINE_AA)

        cv2.imshow("OCC tag receiver", view)
        key = cv2.waitKey(1) & 0xFF

        if key == ord("q"):
            break
        if key == ord("r"):
            last_password = None
            decoded = 0
            frames = 0
        elif key in (ord("["), ord("]")):
            exposure += -1 if key == ord("[") else 1
            cap.set(cv2.CAP_PROP_EXPOSURE, exposure)
        elif key in (ord("-"), ord("=")):
            roi_half = max(8, roi_half + (-8 if key == ord("-") else 8))
        elif key in (ord("9"), ord("0")):
            # Leaving auto needs a starting point; take whatever it just chose.
            if gain <= 0:
                gain = alpha
            gain = max(1.0, gain + (-1.0 if key == ord("9") else 1.0))
        elif key == ord("f"):
            flip = not flip

    cap.release()
    cv2.destroyAllWindows()


if __name__ == "__main__":
    main()
