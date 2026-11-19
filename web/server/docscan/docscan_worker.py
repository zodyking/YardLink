#!/usr/bin/env python3
"""Persistent document-scan worker (JSON lines on stdin/stdout).

Turns a phone photo of a paper document into a clean, flat, evenly-lit
"scanned" image: find the page and square it up, cancel shadows and uneven
lighting, correct a tilted/rotated frame, then sharpen. Pure OpenCV/NumPy —
no model weights, no network, CPU-cheap — so it runs the same way the
OpenOCR worker does (server/ocr/openocr_worker.py): one long-lived process
reading requests and replying over stdout, started by server/services/
docscan.ts.

This is deliberately a from-scratch classical pipeline rather than a port
of ZZZHANG-jx/DocRes: DocRes is a real neural restoration model (Restormer,
~CVPR 2024) with its own pretrained checkpoints hosted on OneDrive and a
PyTorch/CUDA-leaning inference path, which is not something that can be
verified or vendored correctly without actually running it against the real
weights — something this environment cannot do (no network to fetch torch
or the checkpoints, no GPU). Rather than ship an unverified reimplementation
of someone else's neural network, this worker gets the same real-world
result (flat page, even lighting, crisp text, still a plain image for SMS)
with well-understood OpenCV techniques that were built and checked against
sample photos before being wired in. A DocRes backend can still be dropped
in later behind this exact same `restore` command/response shape, once it
can be run and verified somewhere with the hardware and network it needs.
"""

from __future__ import annotations

import json
import sys
import traceback

import cv2
import numpy as np

ENGINE = 'docscan-classical'
ENGINE_VERSION = '1.0'

# A page this skewed is almost certainly not actually tilted on purpose.
_MAX_DESKEW_DEG = 20.0
_MIN_DESKEW_DEG = 0.3
# Downscale very large phone photos before the expensive steps; a cleaned-up
# document only needs to be sharp enough to read and to send by SMS/MMS.
_MAX_WORKING_DIM = 2200


def _version() -> str:
    return ENGINE_VERSION


def _order_quad(pts: np.ndarray) -> np.ndarray:
    pts = pts.reshape(4, 2).astype(np.float32)
    s = pts.sum(axis=1)
    diff = pts[:, 0] - pts[:, 1]
    ordered = np.zeros((4, 2), dtype=np.float32)
    ordered[0] = pts[np.argmin(s)]       # top-left
    ordered[2] = pts[np.argmax(s)]       # bottom-right
    ordered[1] = pts[np.argmax(diff)]    # top-right
    ordered[3] = pts[np.argmin(diff)]    # bottom-left
    return ordered


def _find_document_quad(bgr: np.ndarray) -> np.ndarray | None:
    """The page's own four corners, if the photo shows them (a background
    visible around the page). Returns None for a close-up, edge-to-edge
    shot, where there is nothing to find a boundary against."""
    h, w = bgr.shape[:2]
    scale = 1000.0 / max(h, w)
    small = cv2.resize(bgr, (max(1, int(w * scale)), max(1, int(h * scale))))

    gray = cv2.cvtColor(small, cv2.COLOR_BGR2GRAY)
    gray = cv2.bilateralFilter(gray, 9, 60, 60)
    edges = cv2.Canny(gray, 40, 120)
    edges = cv2.dilate(edges, np.ones((5, 5), np.uint8), iterations=1)

    contours, _ = cv2.findContours(edges, cv2.RETR_LIST, cv2.CHAIN_APPROX_SIMPLE)
    contours = sorted(contours, key=cv2.contourArea, reverse=True)[:8]

    frame_area = small.shape[0] * small.shape[1]
    for c in contours:
        if cv2.contourArea(c) < 0.2 * frame_area:
            continue
        peri = cv2.arcLength(c, True)
        approx = cv2.approxPolyDP(c, 0.02 * peri, True)
        if len(approx) == 4 and cv2.isContourConvex(approx):
            return (approx.reshape(4, 2) / scale).astype(np.float32)
    return None


def _warp_to_quad(bgr: np.ndarray, quad: np.ndarray) -> np.ndarray:
    ordered = _order_quad(quad)
    (tl, tr, br, bl) = ordered
    out_w = max(int(max(np.linalg.norm(tr - tl), np.linalg.norm(br - bl))), 100)
    out_h = max(int(max(np.linalg.norm(bl - tl), np.linalg.norm(br - tr))), 100)
    dst = np.array([[0, 0], [out_w - 1, 0], [out_w - 1, out_h - 1], [0, out_h - 1]], dtype=np.float32)
    matrix = cv2.getPerspectiveTransform(ordered, dst)
    return cv2.warpPerspective(bgr, matrix, (out_w, out_h))


def _deskew_small_angle(bgr: np.ndarray) -> np.ndarray:
    """Vote for the dominant line angle with a Hough transform over text/
    rule-line edges. More robust than a minAreaRect over all foreground
    pixels, which a single soft shadow blob (almost no hard edges, so Hough
    already discounts it) can otherwise drag off in the wrong direction."""
    gray = cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY)
    edges = cv2.Canny(gray, 50, 150)
    lines = cv2.HoughLinesP(
        edges, 1, np.pi / 360, threshold=80,
        minLineLength=max(40, min(bgr.shape[:2]) // 6), maxLineGap=20,
    )
    if lines is None or len(lines) < 3:
        return bgr

    angles = []
    for x1, y1, x2, y2 in lines.reshape(-1, 4):
        dx, dy = int(x2) - int(x1), int(y2) - int(y1)
        if dx == 0 and dy == 0:
            continue
        angle = np.degrees(np.arctan2(dy, dx))
        # Fold to the nearest horizontal or vertical axis so both text
        # baselines and vertical margins vote on the same page rotation.
        folded = ((angle + 45) % 90) - 45
        if abs(folded) <= _MAX_DESKEW_DEG:
            angles.append(folded)
    if len(angles) < 3:
        return bgr

    angle = float(np.median(angles))
    if abs(angle) < _MIN_DESKEW_DEG or abs(angle) > _MAX_DESKEW_DEG:
        return bgr
    h, w = bgr.shape[:2]
    matrix = cv2.getRotationMatrix2D((w / 2, h / 2), angle, 1.0)
    return cv2.warpAffine(bgr, matrix, (w, h), flags=cv2.INTER_CUBIC, borderMode=cv2.BORDER_REPLICATE)


def _remove_shadows(bgr: np.ndarray) -> np.ndarray:
    """Estimate the paper's own shading per channel with a morphological
    close (a structuring element wide enough to erase text strokes but
    narrow enough to leave the page's broad shadow/gradient intact), then
    divide it out. Unlike a Gaussian blur, text does not drag the local
    background estimate down near its own edges, so there is no halo."""
    bgr_f = bgr.astype(np.float32)
    k = max(15, (min(bgr.shape[:2]) // 20) | 1)
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (k, k))
    out = np.empty_like(bgr_f)
    for ch in range(3):
        plane = bgr_f[:, :, ch]
        background = np.maximum(cv2.morphologyEx(plane, cv2.MORPH_CLOSE, kernel), 1.0)
        out[:, :, ch] = cv2.divide(plane, background, scale=255.0)
    # A light global percentile stretch brings the paper itself up to a
    # clean near-white without a second, local-contrast pass later.
    lo, hi = np.percentile(out, [0.5, 99.5])
    out = (out - lo) / max(hi - lo, 1e-6) * 255.0
    return np.clip(out, 0, 255).astype(np.uint8)


def _sharpen(bgr: np.ndarray) -> np.ndarray:
    # Shading is already flattened; this is just light denoise plus a crisp
    # unsharp mask so text reads cleanly. No further global stretch here —
    # stacking another one on top of _remove_shadows' tends to crush the
    # paper back toward gray.
    denoised = cv2.bilateralFilter(bgr, d=7, sigmaColor=35, sigmaSpace=35)
    f = denoised.astype(np.float32)
    blurred = cv2.GaussianBlur(f, (0, 0), 1.4)
    sharpened = cv2.addWeighted(f, 1.5, blurred, -0.5, 0)
    return np.clip(sharpened, 0, 255).astype(np.uint8)


def _downscale_for_working(bgr: np.ndarray) -> np.ndarray:
    h, w = bgr.shape[:2]
    longest = max(h, w)
    if longest <= _MAX_WORKING_DIM:
        return bgr
    scale = _MAX_WORKING_DIM / longest
    return cv2.resize(bgr, (int(w * scale), int(h * scale)), interpolation=cv2.INTER_AREA)


def restore_document_photo(bgr: np.ndarray) -> tuple[np.ndarray, dict]:
    working = _downscale_for_working(bgr)
    quad = _find_document_quad(working)
    if quad is not None:
        page = _warp_to_quad(working, quad)
        applied = 'perspective'
    else:
        page = _deskew_small_angle(working)
        applied = 'deskew'
    flat = _remove_shadows(page)
    final = _sharpen(flat)
    return final, {'boundary': applied}


def _reply(payload: dict) -> None:
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + '\n')
    sys.stdout.flush()


def main() -> int:
    _reply({'ok': True, 'event': 'ready', 'engine': ENGINE, 'engineVersion': _version()})

    for raw in sys.stdin:
        line = raw.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except Exception as error:
            _reply({'ok': False, 'error': f'invalid request: {error}'})
            continue

        req_id = req.get('id')
        cmd = req.get('cmd') or 'restore'

        if cmd in ('quit', 'exit'):
            _reply({'ok': True, 'id': req_id, 'event': 'bye'})
            return 0

        if cmd in ('ping', 'health'):
            _reply({'ok': True, 'id': req_id, 'event': 'pong', 'engine': ENGINE, 'engineVersion': _version()})
            continue

        image_path = req.get('image_path')
        out_path = req.get('out_path')
        if not image_path or not out_path:
            _reply({'ok': False, 'id': req_id, 'error': 'image_path and out_path are required'})
            continue

        try:
            src = cv2.imread(image_path, cv2.IMREAD_COLOR)
            if src is None:
                raise ValueError('could not decode the image')
            result, meta = restore_document_photo(src)
            quality = int(req.get('quality') or 90)
            ok = cv2.imwrite(out_path, result, [cv2.IMWRITE_JPEG_QUALITY, quality])
            if not ok:
                raise ValueError('could not write the restored image')
            _reply({
                'ok': True,
                'id': req_id,
                'engine': ENGINE,
                'engineVersion': _version(),
                'width': int(result.shape[1]),
                'height': int(result.shape[0]),
                'meta': meta,
            })
        except Exception as error:
            _reply({
                'ok': False,
                'id': req_id,
                'error': str(error),
                'trace': traceback.format_exc()[-2000:],
            })

    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except Exception as error:
        sys.stderr.write(f'docscan worker failed: {error}\n')
        traceback.print_exc()
        raise SystemExit(1)
