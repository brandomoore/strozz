#!/usr/bin/env python3
"""Regenerate Strozz's logos, layered tvOS icons, and static Top Shelf artwork.

The supplied pixel-art mark in Branding/strozz_logo.svg is the source of truth.
The charcoal radial background follows Plozz's brand treatment, tinted purple.
Existing catalog filenames, dimensions, and parallax layer ordering stay intact.
"""

import io
import json
from pathlib import Path
import shutil
import argparse

import cairosvg
import numpy as np
from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
LOGO = ROOT / "Branding/strozz_logo.svg"
ASSETS = ROOT / "Strozz/Assets.xcassets"
BASE_GRAY = (28, 28, 30)
ACCENT_PURPLE = (143, 82, 246)
GLOW_STRENGTH = 0.09
ICON_LOGO_FRACTION = 0.688
TOP_SHELF_LOGO_FRACTION = 0.635


def render_logo() -> Image.Image:
    """Rasterize at the native pixel grid; enlarge without smoothing the mark."""
    png = cairosvg.svg2png(bytestring=LOGO.read_bytes(), output_width=32, output_height=32)
    with Image.open(io.BytesIO(png)) as image:
        return image.convert("RGBA")


def radial_background(width: int, height: int) -> Image.Image:
    """Opaque charcoal with Plozz's raised-cosine glow, no grain or static."""
    yy, xx = np.ogrid[:height, :width]
    cx, cy = (width - 1) / 2, (height - 1) / 2
    distance = np.clip(
        np.sqrt(((xx - cx) / max(cx, 1)) ** 2 + ((yy - cy) / max(cy, 1)) ** 2)
        / np.sqrt(2),
        0,
        1,
    )
    glow = (1 + np.cos(np.pi * distance)) / 2
    base = np.array(BASE_GRAY)
    rgb = base + GLOW_STRENGTH * glow[..., None] * (np.array(ACCENT_PURPLE) - base)
    return Image.fromarray(np.clip(rgb, 0, 255).astype(np.uint8))


def centered_logo(logo: Image.Image, width: int, height: int, fraction: float) -> Image.Image:
    layer = Image.new("RGBA", (width, height))
    side = int(min(width, height) * fraction)
    mark = logo.resize((side, side), Image.Resampling.NEAREST)
    layer.alpha_composite(mark, ((width - side) // 2, (height - side) // 2))
    return layer


def save_images(imageset: Path, width: int, height: int, render) -> list[Path]:
    """Use catalog entries rather than inventing or renaming asset variants."""
    outputs = []
    contents = json.loads((imageset / "Contents.json").read_text())
    for image in contents["images"]:
        scale = int(image.get("scale", "1x").removesuffix("x"))
        output = imageset / image["filename"]
        render(width * scale, height * scale).save(output)
        outputs.append(output)
    return outputs


def generate(assets: Path = ASSETS) -> list[Path]:
    logo = render_logo()
    vector = assets / "StrozzPixelLogo.imageset/strozz_logo.svg"
    shutil.copyfile(LOGO, vector)
    outputs = [vector]
    brand = assets / "AppIcon.brandassets"

    for stack, width, height in [
        ("App Icon.imagestack", 400, 240),
        ("App Icon - App Store.imagestack", 1280, 768),
    ]:
        # Preserve the existing duplicate-mark Front/Middle parallax treatment.
        for layer in ("Front", "Middle", "Back"):
            imageset = brand / stack / f"{layer}.imagestacklayer/Content.imageset"
            render = (
                radial_background if layer == "Back"
                else lambda w, h: centered_logo(logo, w, h, ICON_LOGO_FRACTION)
            )
            outputs.extend(save_images(imageset, width, height, render))

    def banner(width, height):
        image = radial_background(width, height).convert("RGBA")
        image.alpha_composite(centered_logo(logo, width, height, TOP_SHELF_LOGO_FRACTION))
        return image.convert("RGB")

    for name, width in [("Top Shelf Image", 1920), ("Top Shelf Image Wide", 2320)]:
        outputs.extend(save_images(brand / f"{name}.imageset", width, 720, banner))
    outputs.extend(save_images(
        assets / "SplashScreenLogo.imageset", 200, 200,
        lambda w, h: centered_logo(logo, w, h, 1),
    ))
    outputs.extend(generate_mobile(assets))
    return outputs


def generate_mobile(assets: Path = ASSETS) -> list[Path]:
    image = radial_background(1024, 1024).convert("RGBA")
    image.alpha_composite(centered_logo(render_logo(), 1024, 1024, ICON_LOGO_FRACTION))
    output = assets / "MobileAppIcon.appiconset/mobile-icon.png"
    image.convert("RGB").save(output)
    return [output]


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--mobile-only", action="store_true")
    args = parser.parse_args()
    for output in generate_mobile() if args.mobile_only else generate():
        print(f"wrote {output.relative_to(ROOT)}")
