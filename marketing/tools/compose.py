#!/usr/bin/env python3
"""Composes App Store screenshots: framed device + big caption on a generated backdrop.

The backdrop is one continuous panorama (soft colour glows and faint groove rings that
carry across slide boundaries), cropped per slide, so the strip reads as a single piece when
someone swipes through the listing. Devices are framed with the `frames` CLI, never drawn.
Text is rendered by `text_layer` (CoreText) so every script gets the right system font.
"""
import hashlib
import json
import os
import subprocess
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
TEXT_LAYER = os.environ.get("TEXT_LAYER", "/private/tmp/build/text_layer")
CACHE = os.environ.get("MKT_CACHE", "/private/tmp/build/mkt-cache")
FRAMES = os.path.expanduser("~/.local/bin/frames")

CORAL = (255, 77, 109)
AMBER = (255, 178, 74)
VIOLET = (124, 92, 255)
TEAL = (45, 212, 191)
BLUE = (66, 133, 255)
ROSE = (255, 105, 180)

CAPTION_GAP = 56

SCRIPT_FONTS = {
    "ja": "Hiragino Sans",
    "ko": "Apple SD Gothic Neo",
    "zh-Hans": "PingFang SC",
    "zh-Hant": "PingFang TC",
}


def hexcolor(rgb):
    return "#%02X%02X%02X" % tuple(int(c) for c in rgb)


def frame_device(raw_path, color="Burgundy", device=None):
    """Returns the path of the framed PNG (transparent, bezel included), cached by content."""
    os.makedirs(CACHE, exist_ok=True)
    digest = hashlib.sha1(open(raw_path, "rb").read() + color.encode() + (device or "").encode()).hexdigest()[:16]
    out_dir = os.path.join(CACHE, "frames", digest)
    result = os.path.join(out_dir, os.path.splitext(os.path.basename(raw_path))[0] + "_framed.png")
    if not os.path.exists(result):
        os.makedirs(out_dir, exist_ok=True)
        cmd = [FRAMES, "--json", "-c", color, "-o", out_dir]
        if device:
            cmd += ["-d", device]
        cmd.append(raw_path)
        subprocess.run(cmd, check=True, capture_output=True)
    return result


def render_texts(specs):
    """Batch-renders text layers; returns {out: metrics}."""
    out = subprocess.run([TEXT_LAYER], input=json.dumps(specs), capture_output=True, text=True, check=True).stdout
    return {m["out"]: m for m in json.loads(out)}


def glow(size, center, radius, rgb, strength):
    w, h = size
    ys, xs = np.ogrid[:h, :w]
    d2 = ((xs - center[0]) ** 2 + (ys - center[1]) ** 2) / (2.0 * (radius / 2.2) ** 2)
    field = np.exp(-d2) * strength
    return field[..., None] * np.array(rgb, dtype=np.float32)[None, None, :] / 255.0


def backdrop(index, count, size, blobs, base=((7, 7, 11), (12, 9, 20)), ring_rgb=None, ring_center=None, seed=7):
    """One slide's slice of the shared panorama.

    `blobs` are in slide-local coordinates but may sit outside the slide, so neighbouring
    slides place the same blob at x +/- width and the glow flows across the seam.
    """
    w, h = size
    top = np.array(base[0], dtype=np.float32)
    bottom = np.array(base[1], dtype=np.float32)
    t = np.linspace(0, 1, h, dtype=np.float32)[:, None, None]
    canvas = (top * (1 - t) + bottom * t) / 255.0
    canvas = np.repeat(canvas, w, axis=1)
    for cx, cy, radius, rgb, strength in blobs:
        canvas = canvas + glow(size, (cx, cy), radius, rgb, strength)
    image = Image.fromarray((np.clip(canvas, 0, 1) * 255).astype(np.uint8), "RGB").convert("RGBA")

    if ring_rgb is not None:
        rings = Image.new("RGBA", size, (0, 0, 0, 0))
        draw = ImageDraw.Draw(rings)
        cx, cy = ring_center or (w // 2, int(h * 0.62))
        radius = 520
        while radius < 2600:
            fade = max(0.0, 1.0 - (radius - 520) / 2100.0)
            alpha = int(46 * fade + 6)
            draw.ellipse((cx - radius, cy - radius, cx + radius, cy + radius), outline=ring_rgb + (alpha,), width=3)
            radius += 118
        rings = rings.filter(ImageFilter.GaussianBlur(1.1))
        image = Image.alpha_composite(image, rings)

    rng = np.random.default_rng(seed + index)
    noise = rng.normal(0, 1.6, (h, w, 1)).astype(np.float32)
    arr = np.asarray(image.convert("RGB"), dtype=np.float32) + noise
    return Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGB").convert("RGBA")


def shadowed(framed, offset=(0, 46), blur=58, opacity=0.62):
    alpha = framed.getchannel("A")
    shadow = Image.new("RGBA", framed.size, (0, 0, 0, 0))
    shadow.putalpha(alpha.point(lambda v: int(v * opacity)))
    pad = blur * 3
    canvas = Image.new("RGBA", (framed.width + pad * 2, framed.height + pad * 2), (0, 0, 0, 0))
    canvas.alpha_composite(shadow, (pad + offset[0], pad + offset[1]))
    return canvas.filter(ImageFilter.GaussianBlur(blur)), pad


def place_device(canvas, framed_path, width, top, center_x=None, tilt=0.0, glow_rgb=None):
    framed = Image.open(framed_path).convert("RGBA")
    scale = width / framed.width
    framed = framed.resize((width, int(framed.height * scale)), Image.LANCZOS)
    if tilt:
        framed = framed.rotate(tilt, resample=Image.BICUBIC, expand=True)
    x = int((center_x if center_x is not None else canvas.width / 2) - framed.width / 2)
    shadow, pad = shadowed(framed)
    canvas.alpha_composite(shadow, (x - pad, top - pad))
    canvas.alpha_composite(framed, (x, top))
    return (x, top, framed.width, framed.height)


def caption_specs(prefix, copy, locale, y_budget_width=1180, scale=1.0):
    """Text specs for one slide: kicker, headline, optional sub; `scale` resizes it for wider canvases."""
    font = SCRIPT_FONTS.get(locale)
    base = {"family": font} if font else {}
    specs = []
    if copy.get("kicker"):
        specs.append({**base, "out": f"{prefix}-kicker.png", "text": copy["kicker"], "width": y_budget_width,
                      "size": 46 * scale, "minSize": 30 * scale, "maxLines": 1, "weight": "bold",
                      "tracking": (7 if locale not in SCRIPT_FONTS else 3) * scale,
                      "uppercase": locale not in SCRIPT_FONTS, "color": copy.get("kickerColor", "#FF6B86")})
    specs.append({**base, "out": f"{prefix}-headline.png", "text": copy["headline"], "width": y_budget_width,
                  "size": copy.get("size", 156) * scale, "minSize": 96 * scale, "maxLines": copy.get("maxLines", 2),
                  "weight": "heavy", "tracking": (-3 if locale not in SCRIPT_FONTS else -1) * scale, "lineHeight": 1.02,
                  "accent": copy.get("accent", []), "accentColor": copy.get("accentColor", "#FF4D6D"), "color": "#FFFFFF"})
    if copy.get("sub"):
        specs.append({**base, "out": f"{prefix}-sub.png", "text": copy["sub"], "width": y_budget_width - 80 * scale,
                      "size": 54 * scale, "minSize": 36 * scale, "maxLines": 2, "weight": "medium", "tracking": 0,
                      "lineHeight": 1.18, "color": "#B9B9C6"})
    return specs


def panorama_blobs(slides, index, width=1320):
    """Blobs for slide `index`, taken from it and both neighbours so glows cross the seams.

    Kept low and mostly behind the device: the caption zone stays near-black so the
    highlighted word never has to compete with a coloured field of its own hue.
    """
    blobs = []
    for j in (index - 1, index, index + 1):
        if not 0 <= j < len(slides):
            continue
        dx = (j - index) * width
        accent = slides[j].get("accent", CORAL)
        secondary = slides[j].get("secondary", VIOLET)
        blobs.append((dx + width * 0.12, 1350, 1000, accent, 0.46))
        blobs.append((dx + width * 0.92, 2150, 1150, secondary, 0.34))
        blobs.append((dx + width * 0.50, 120, 900, accent, 0.10))
    return blobs


def lighten(rgb, amount):
    return tuple(int(c + (255 - c) * amount) for c in rgb)


def top_scrim(canvas, height=900, opacity=0.55):
    """Darkens the caption zone so text keeps its contrast whatever glows sit beneath."""
    w, h = canvas.size
    ramp = np.zeros((h, 1), dtype=np.float32)
    n = min(height, h)
    ramp[:n, 0] = np.linspace(opacity, 0.0, n) ** 1.3 * (opacity ** -0.3 if opacity else 1)
    alpha = (np.clip(ramp, 0, 1) * 255).astype(np.uint8)
    layer = Image.new("RGBA", (w, h), (5, 5, 9, 0))
    layer.putalpha(Image.fromarray(np.repeat(alpha, w, axis=1), "L"))
    return Image.alpha_composite(canvas, layer)


def paste_centered(canvas, path, y):
    layer = Image.open(path)
    canvas.alpha_composite(layer, ((canvas.width - layer.width) // 2, y))
    return layer.height


def draw_caption(canvas, copy, locale, prefix, accent, top=150, width=1180, scale=1.0):
    """Stacks kicker, headline and sub centred from `top`; returns the y just below the block."""
    copy = {**copy, "accentColor": hexcolor(lighten(accent, 0.18)), "kickerColor": hexcolor(lighten(accent, 0.30))}
    metrics = render_texts(caption_specs(prefix, copy, locale, width, scale))
    y = top
    if copy.get("kicker"):
        m = metrics[f"{prefix}-kicker.png"]
        paste_centered(canvas, m["out"], y)
        y += m["height"] + int(14 * scale)
    m = metrics[f"{prefix}-headline.png"]
    paste_centered(canvas, m["out"], y)
    y += m["height"] + int(6 * scale)
    if copy.get("sub"):
        m = metrics[f"{prefix}-sub.png"]
        paste_centered(canvas, m["out"], y)
        y += m["height"]
    return y


def compose_slide(slide, copy, locale, raw_dir, out_path, index, slides, work_dir, device_top=780):
    """Single phone, caption on top, device bleeding off the bottom edge."""
    size = (1320, 2868)
    canvas = backdrop(index, len(slides), size, panorama_blobs(slides, index), ring_rgb=slide.get("accent", CORAL),
                      ring_center=(660, 1720))
    canvas = top_scrim(canvas)
    os.makedirs(work_dir, exist_ok=True)
    prefix = os.path.join(work_dir, f"{index:02d}")
    caption_bottom = draw_caption(canvas, copy, locale, prefix, slide.get("accent", CORAL))
    framed = frame_device(os.path.join(raw_dir, slide["raw"] + ".png"), slide.get("bezel", "Burgundy"))
    place_device(canvas, framed, slide.get("device_width", 1236), max(device_top, caption_bottom + CAPTION_GAP))
    canvas.convert("RGB").save(out_path, "PNG", optimize=True)
    return out_path


def compose_pair(slide, copy, locale, raw_dirs, out_path, index, slides, work_dir, device_top=860):
    """Two phones side by side, tilted toward each other: raw_dirs = (left_dir, right_dir)."""
    size = (1320, 2868)
    canvas = backdrop(index, len(slides), size, panorama_blobs(slides, index), ring_rgb=slide.get("accent", CORAL),
                      ring_center=(660, 1700))
    canvas = top_scrim(canvas)
    os.makedirs(work_dir, exist_ok=True)
    prefix = os.path.join(work_dir, f"{index:02d}")
    device_top = max(device_top, draw_caption(canvas, copy, locale, prefix, slide.get("accent", CORAL)) + CAPTION_GAP)
    left = frame_device(os.path.join(raw_dirs[0], slide["raw_left"] + ".png"), slide.get("bezel_left", "Silver"))
    right = frame_device(os.path.join(raw_dirs[1], slide["raw_right"] + ".png"), slide.get("bezel_right", "Burgundy"))
    place_device(canvas, left, 860, device_top + 90, center_x=395, tilt=5.0)
    place_device(canvas, right, 860, device_top, center_x=935, tilt=-5.0)
    canvas.convert("RGB").save(out_path, "PNG", optimize=True)
    return out_path


def compose_watch(slide, copy, locale, raw_dir, watch_raws, out_path, index, slides, work_dir, device_top=980):
    """Two Apple Watch Ultras tilted toward each other, filling the frame: the watch is the whole story here."""
    size = (1320, 2868)
    canvas = backdrop(index, len(slides), size, panorama_blobs(slides, index), ring_rgb=slide.get("accent", CORAL),
                      ring_center=(660, 1800))
    canvas = top_scrim(canvas)
    os.makedirs(work_dir, exist_ok=True)
    prefix = os.path.join(work_dir, f"{index:02d}")
    device_top = max(device_top, draw_caption(canvas, copy, locale, prefix, slide.get("accent", CORAL)) + CAPTION_GAP + 200)
    left = frame_device(watch_raws[0], slide.get("watch_color", "Black"))
    right = frame_device(watch_raws[1], slide.get("watch_color", "Black"))
    place_device(canvas, left, 720, device_top + 560, center_x=372, tilt=5.0)
    place_device(canvas, right, 720, device_top - 40, center_x=948, tilt=-5.0)
    canvas.convert("RGB").save(out_path, "PNG", optimize=True)
    return out_path


MAC_SCREEN = (3456, 2234)
MAC_SLIDE = (2880, 1800)


def rounded_mask(size, radius, supersample=3):
    big = Image.new("L", (size[0] * supersample, size[1] * supersample), 0)
    ImageDraw.Draw(big).rounded_rectangle((0, 0, big.width - 1, big.height - 1), radius * supersample, fill=255)
    return big.resize(size, Image.LANCZOS)


def trimmed(path):
    """Crops a framed PNG to its visible pixels (frames pads the canvas) and returns the cached trimmed path."""
    out = path.replace("_framed.png", "_trim.png")
    if not os.path.exists(out):
        image = Image.open(path).convert("RGBA")
        image.crop(image.getchannel("A").getbbox()).save(out, "PNG")
    return out


def mac_desktop(window_path, accent, secondary, work_dir, prefix, window_top=150):
    """A MacBook-sized desktop: abstract wallpaper, a slim menu bar and the window floating on it."""
    w, h = MAC_SCREEN
    blobs = [(w * 0.18, h * 0.82, 1500, accent, 0.62), (w * 0.86, h * 0.20, 1400, secondary, 0.52),
             (w * 0.55, h * 0.55, 1100, accent, 0.18)]
    desktop = backdrop(3, 10, MAC_SCREEN, blobs, base=((10, 9, 18), (18, 12, 30)), ring_rgb=accent, ring_center=(w // 2, h // 2))
    window = Image.open(window_path).convert("RGBA")
    target_w = min(window.width, w - 2 * int(w * 0.066))
    window = window.resize((target_w, int(window.height * target_w / window.width)), Image.LANCZOS)
    window.putalpha(rounded_mask(window.size, 52))
    shadow, pad = shadowed(window, offset=(0, 40), blur=60, opacity=0.7)
    x = (w - window.width) // 2
    desktop.alpha_composite(shadow, (x - pad, window_top - pad))
    desktop.alpha_composite(window, (x, window_top))
    bar = Image.new("RGBA", (w, 74), (6, 6, 10, 150))
    desktop.alpha_composite(bar, (0, 0))
    os.makedirs(work_dir, exist_ok=True)
    name = render_texts([
        {"out": os.path.join(work_dir, f"{prefix}-menu-app.png"), "text": "Flaccy", "width": 400, "size": 31, "weight": "bold", "color": "#FFFFFF"},
        {"out": os.path.join(work_dir, f"{prefix}-menu-clock.png"), "text": "9:41", "width": 200, "size": 31, "weight": "semibold", "color": "#F2F2F7", "align": "right"},
    ])
    app = Image.open(os.path.join(work_dir, f"{prefix}-menu-app.png"))
    clock = Image.open(os.path.join(work_dir, f"{prefix}-menu-clock.png"))
    desktop.alpha_composite(app, (150, (74 - app.height) // 2))
    desktop.alpha_composite(clock, (w - 150 - clock.width, (74 - clock.height) // 2))
    out = os.path.join(work_dir, f"{prefix}-desktop.png")
    desktop.convert("RGB").save(out, "PNG")
    return out


def compose_mac(slide, copy, locale, window_path, out_path, index, slides, work_dir, laptop_width=2640, laptop_top=420):
    """Caption on top, a MacBook Pro showing the window, bleeding off the bottom edge."""
    accent, secondary = slide.get("accent", CORAL), slide.get("secondary", VIOLET)
    blobs = [(430, 1500, 1500, accent, 0.30), (2500, 1850, 1500, secondary, 0.26), (1440, 0, 1100, accent, 0.05)]
    canvas = backdrop(index, len(slides), MAC_SLIDE, blobs, ring_rgb=accent, ring_center=(1440, 1150))
    canvas = top_scrim(canvas, height=700)
    prefix = os.path.join(work_dir, f"mac{index:02d}")
    os.makedirs(work_dir, exist_ok=True)
    draw_caption(canvas, copy, locale, prefix, slide.get("accent", CORAL), top=84, width=2300, scale=0.86)
    desktop = mac_desktop(window_path, slide.get("accent", CORAL), slide.get("secondary", VIOLET), work_dir, f"mac{index:02d}")
    framed = trimmed(frame_device(desktop, slide.get("mac_color", "Silver"), device=slide.get("mac_device")))
    place_device(canvas, framed, laptop_width, laptop_top)
    canvas.convert("RGB").save(out_path, "PNG", optimize=True)
    return out_path


IPAD_SLIDE = (2752, 2064)


def compose_ipad(slide, copy, locale, raw_path, out_path, index, slides, work_dir, device_width=2250, device_top=330):
    """Caption on top, a landscape iPad Pro 13-inch bleeding off the bottom edge."""
    accent, secondary = slide.get("accent", CORAL), slide.get("secondary", VIOLET)
    blobs = [(420, 1700, 1500, accent, 0.30), (2350, 1950, 1500, secondary, 0.26), (1376, 0, 1100, accent, 0.05)]
    canvas = backdrop(index, len(slides), IPAD_SLIDE, blobs, ring_rgb=accent, ring_center=(1376, 1300))
    canvas = top_scrim(canvas, height=760)
    prefix = os.path.join(work_dir, f"ipad{index:02d}")
    os.makedirs(work_dir, exist_ok=True)
    caption_bottom = draw_caption(canvas, copy, locale, prefix, accent, top=96, width=2300, scale=0.9)
    framed = trimmed(frame_device(raw_path, slide.get("ipad_color", "Space Black")))
    place_device(canvas, framed, device_width, max(device_top, caption_bottom + CAPTION_GAP))
    canvas.convert("RGB").save(out_path, "PNG", optimize=True)
    return out_path


if __name__ == "__main__":
    print(__doc__)
