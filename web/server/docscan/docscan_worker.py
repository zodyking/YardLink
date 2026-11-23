#!/usr/bin/env python3
"""Persistent document-scan worker (JSON lines on stdin/stdout).

Turns a phone photo of a paper document into the crisp, flat, black-on-white
look of a page that actually went through a scanner: find the page and
square it up, correct a tilted frame, cancel shadows and uneven lighting,
then push the paper to clean white and the ink to clean black. Pure
OpenCV/NumPy — no model weights, no network, CPU-cheap — so it runs the same
way the OpenOCR worker does (server/ocr/openocr_worker.py): one long-lived
process reading requests and replying over stdout, started by
server/services/docscan.ts.

The output is grayscale. A color photo of a paper document never reads as
"a regular PDF" no matter how clean it is — every familiar scanned business
document (BOL, EIR, gate ticket) is black ink on white paper, and getting
there is also what makes the contrast pass below effective. It is still
just a plain image (JPEG) afterward, same as any other photo, so it goes
out over SMS/MMS exactly as it did before.

Two failure modes matter more than fine-tuning the "look": (1) the page-
boundary detector locking onto the wrong rectangle — a shadow, a clipboard
edge, a dashboard — and warping the photo into garbage, and (2) the
contrast pass finding nothing to work with (a near-uniform, out-of-focus,
or otherwise unreadable frame) and returning a flat gray rectangle. Both
are guarded here: boundary detection is gated on the candidate actually
looking like a rectangular page (size and corner angles), and the final
result is checked for implausible flatness before it is accepted —
`restore_document_photo` raises rather than hand back something worse than
the original photo, and the caller (server/services/docscan.ts, then
server/api/documents/index.post.ts) falls back to storing the original
photo untouched on any such failure.

This is deliberately a from-scratch classical pipeline rather than a port
of ZZZHANG-jx/DocRes: DocRes is a real neural restoration model (Restormer,
~CVPR 2024) with its own pretrained checkpoints hosted on OneDrive and a
PyTorch/CUDA-leaning inference path, which is not something that can be
verified or vendored correctly without actually running it against the real
weights — something this environment cannot do (no network to fetch torch
or the checkpoints, no GPU). A DocRes backend can still be dropped in later
behind this exact same `restore` command/response shape, once it can be run
and verified somewhere with the hardware and network it needs.
"""

from __future__ import annotations

import json
import sys
import traceback

import cv2
import numpy as np

ENGINE = 'docscan-classical'
ENGINE_VERSION = '2.0'

# A page this skewed is almost certainly not actually tilted on purpose.
_MAX_DESKEW_DEG = 20.0
_MIN_DESKEW_DEG = 0.3
# Downscale very large phone photos before the expensive steps; a cleaned-up
# document only needs to be sharp enough to read and to send by SMS/MMS.
_MAX_WORKING_DIM = 2200

# A detected quad outside this share of the frame is more likely noise (a
# sticker, a shadow) or the frame's own border than an actual page.
_MIN_QUAD_AREA_FRAC = 0.25
_MAX_QUAD_AREA_FRAC = 0.97
# A real page photographed at a normal angle has corners close to square;
# a far more acute or obtuse "corner" usually means the contour is not
# actually the page (part of a shadow, an overlapping object's edge).
_MIN_CORNER_ANGLE_DEG = 65.0
_MAX_CORNER_ANGLE_DEG = 115.0


class RestoreQualityError(ValueError):
    """The pipeline ran but the result does not look like a usable scan."""


def _version() -> str:
    return ENGINE_VERSION


def _auto_canny(gray: np.ndarray, sigma: float = 0.33) -> np.ndarray:
    """Canny thresholds derived from the image's own brightness instead of
    a fixed pair tuned to one sample photo — real phone photos span very
    different exposures and this needs to hold up across all of them."""
    median = float(np.median(gray))
    lower = int(max(0, (1.0 - sigma) * median))
    upper = int(min(255, (1.0 + sigma) * median))
    return cv2.Canny(gray, lower, upper)


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


def _corner_angles_deg(ordered: np.ndarray) -> list[float]:
    """The interior angle at each of the four ordered corners, in order."""
    angles = []
    n = len(ordered)
    for i in range(n):
        prev_pt, curr_pt, next_pt = ordered[(i - 1) % n], ordered[i], ordered[(i + 1) % n]
        v1, v2 = prev_pt - curr_pt, next_pt - curr_pt
        cos_angle = np.dot(v1, v2) / (np.linalg.norm(v1) * np.linalg.norm(v2) + 1e-6)
        angles.append(float(np.degrees(np.arccos(np.clip(cos_angle, -1.0, 1.0)))))
    return angles


def _find_document_quad(bgr: np.ndarray) -> np.ndarray | None:
    """The page's own four corners, if the photo shows them (a background
    visible around the page) and the candidate actually looks like a page
    seen at a normal angle. Returns None for a close-up edge-to-edge shot,
    a cluttered background with no clean boundary, or anything else that
    does not clearly look like a rectangular page — in all of those cases
    it is safer to leave the frame alone than to warp to a wrong guess."""
    h, w = bgr.shape[:2]
    scale = 1000.0 / max(h, w)
    small = cv2.resize(bgr, (max(1, int(w * scale)), max(1, int(h * scale))))

    gray = cv2.cvtColor(small, cv2.COLOR_BGR2GRAY)
    gray = cv2.bilateralFilter(gray, 9, 60, 60)
    edges = _auto_canny(gray)
    edges = cv2.dilate(edges, np.ones((5, 5), np.uint8), iterations=1)

    contours, _ = cv2.findContours(edges, cv2.RETR_LIST, cv2.CHAIN_APPROX_SIMPLE)
    contours = sorted(contours, key=cv2.contourArea, reverse=True)[:8]

    frame_area = small.shape[0] * small.shape[1]
    for c in contours:
        area = cv2.contourArea(c)
        if area < _MIN_QUAD_AREA_FRAC * frame_area or area > _MAX_QUAD_AREA_FRAC * frame_area:
            continue
        peri = cv2.arcLength(c, True)
        approx = cv2.approxPolyDP(c, 0.02 * peri, True)
        if len(approx) != 4 or not cv2.isContourConvex(approx):
            continue
        ordered = _order_quad(approx)
        angles = _corner_angles_deg(ordered)
        if any(a < _MIN_CORNER_ANGLE_DEG or a > _MAX_CORNER_ANGLE_DEG for a in angles):
            continue
        return (ordered / scale).astype(np.float32)
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


def _denoise(gray: np.ndarray) -> np.ndarray:
    return cv2.bilateralFilter(gray, d=7, sigmaColor=35, sigmaSpace=35)


def _illumination_correct(gray: np.ndarray) -> np.ndarray:
    """Estimate the paper's own shading with a morphological close (a
    structuring element wide enough to erase text strokes but narrow enough
    to leave the page's broad shadow/gradient intact), then divide it out.
    Unlike a Gaussian blur, text does not drag the local background
    estimate down near its own edges, so there is no halo — and dividing a
    (now flat) background by itself leaves it sitting right at white,
    which is what the contrast pass below needs to work with."""
    k = max(21, (min(gray.shape[:2]) // 10) | 1)
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (k, k))
    background = np.maximum(cv2.morphologyEx(gray.astype(np.float32), cv2.MORPH_CLOSE, kernel), 1.0)
    corrected = cv2.divide(gray.astype(np.float32), background, scale=255.0)
    return np.clip(corrected, 0, 255).astype(np.uint8)


def _scan_contrast(flat: np.ndarray) -> np.ndarray:
    """Push the page toward the crisp black-ink-on-white-paper look of an
    actual scan. A percentile-based stretch drives the (now dominant,
    near-white) background to pure white and the darkest ink toward black;
    a gamma above 1 on top of that pulls mid-dark ink further down without
    also crushing a lighter mark — a stamp, a signature, pencil — the way a
    hard black/white threshold would erase it outright."""
    lo, hi = np.percentile(flat, [2, 98])
    span = max(hi - lo, 1.0)
    stretched = np.clip((flat.astype(np.float32) - lo) / span, 0, 1)
    curved = np.power(stretched, 1.25)
    return np.clip(curved * 255.0, 0, 255).astype(np.uint8)


def _sharpen_light(gray: np.ndarray) -> np.ndarray:
    # The contrast pass already does most of the work of making edges
    # crisp, so this is a light touch — just enough to clean up text edges
    # softened by the earlier blur, without the halo a stronger unsharp
    # mask would ring around every letter on top of that much contrast.
    f = gray.astype(np.float32)
    blurred = cv2.GaussianBlur(f, (0, 0), 1.0)
    sharpened = cv2.addWeighted(f, 1.3, blurred, -0.3, 0)
    return np.clip(sharpened, 0, 255).astype(np.uint8)


def _assert_plausible_scan(result: np.ndarray) -> None:
    """Catch the pipeline going badly wrong before handing back something
    worse than the original photo: a mis-detected boundary warped to
    garbage, or a frame (too dark, out of focus, nothing in it) the
    contrast pass had nothing to work with, both tend to come out as a
    near-uniform gray rectangle rather than a page with ink on it."""
    std = float(result.std())
    mean = float(result.mean())
    if std < 8.0:
        raise RestoreQualityError('the result is almost perfectly flat — the page was likely not found')
    if mean < 25.0 or mean > 250.0:
        raise RestoreQualityError('the result is nearly all one tone')


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

    gray = cv2.cvtColor(page, cv2.COLOR_BGR2GRAY)
    gray = _denoise(gray)
    flat = _illumination_correct(gray)
    scanned = _scan_contrast(flat)
    final = _sharpen_light(scanned)
    _assert_plausible_scan(final)
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
