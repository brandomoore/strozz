import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest

import numpy as np
from PIL import Image


SPEC = importlib.util.spec_from_file_location(
    "brand_assets", Path(__file__).parents[1] / "generate_brand_assets.py"
)
brand_assets = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(brand_assets)


class BrandAssetsTests(unittest.TestCase):
    def test_supplied_white_face_and_transparency_are_preserved(self):
        logo = brand_assets.render_logo()
        self.assertEqual(logo.size, (32, 32))
        self.assertEqual(logo.getpixel((0, 0)), (0, 0, 0, 0))
        self.assertEqual(logo.getpixel((2, 7)), (0, 0, 0, 255))
        self.assertEqual(logo.getpixel((12, 10)), (255, 255, 255, 255))
        self.assertEqual(logo.getpixel((14, 17)), (255, 255, 255, 255))
        self.assertEqual(logo.getpixel((16, 14)), (*brand_assets.ACCENT_PURPLE, 255))
        self.assertEqual(set(np.unique(np.array(logo)[..., 3])), {0, 255})

    def test_background_is_opaque_smooth_symmetric_charcoal_with_purple_glow(self):
        image = brand_assets.radial_background(400, 240)
        self.assertEqual(image.mode, "RGB")
        pixels = np.array(image)
        self.assertTupleEqual(tuple(pixels[0, 0]), brand_assets.BASE_GRAY)
        self.assertTupleEqual(tuple(pixels[120, 200]), (38, 32, 49))
        np.testing.assert_array_equal(pixels, pixels[::-1])
        np.testing.assert_array_equal(pixels, pixels[:, ::-1])
        self.assertLessEqual(np.abs(np.diff(pixels.astype(int), axis=1)).max(), 1)
        self.assertLessEqual(np.abs(np.diff(pixels.astype(int), axis=0)).max(), 1)

    def test_enlarged_mark_retains_pixel_palette_and_safe_margins(self):
        logo = brand_assets.render_logo()
        layer = brand_assets.centered_logo(logo, 400, 240, brand_assets.ICON_LOGO_FRACTION)
        palette = set(map(tuple, np.array(logo).reshape(-1, 4)))
        self.assertTrue(set(map(tuple, np.array(layer).reshape(-1, 4))).issubset(palette))
        left, top, right, bottom = layer.getbbox()
        self.assertGreaterEqual(left, 30)
        self.assertGreaterEqual(top, 20)
        self.assertLessEqual(right, 370)
        self.assertLessEqual(bottom, 220)
        self.assertLessEqual(abs((left + right) / 2 - 200), 1)
        self.assertLessEqual(abs((top + bottom) / 2 - 120), 1)

    def test_every_declared_variant_is_regenerated_without_changing_catalog_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            assets = Path(directory)
            for name in ("AppIcon.brandassets", "MobileAppIcon.appiconset", "SplashScreenLogo.imageset", "StrozzPixelLogo.imageset"):
                for source in (brand_assets.ASSETS / name).rglob("Contents.json"):
                    target = assets / source.relative_to(brand_assets.ASSETS)
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(source, target)
            metadata = {path: path.read_bytes() for path in assets.rglob("Contents.json")}
            outputs = brand_assets.generate(assets)
            expected = {}
            for name in ("AppIcon.brandassets", "SplashScreenLogo.imageset"):
                for path in (brand_assets.ASSETS / name).rglob("*.png"):
                    relative = path.relative_to(brand_assets.ASSETS)
                    if "SplashScreenLogo" in str(relative):
                        width, height = 200, 200
                    elif "App Icon - App Store" in str(relative):
                        width, height = 1280, 768
                    elif "App Icon.imagestack" in str(relative):
                        width, height = 400, 240
                    elif "Top Shelf Image Wide" in str(relative):
                        width, height = 2320, 720
                    else:
                        width, height = 1920, 720
                    scale = 3 if "@3x" in path.name else 2 if "@2x" in path.name else 1
                    expected[relative] = (width * scale, height * scale)
            self.assertEqual(len(expected), 18)
            self.assertEqual(len(outputs), 20)
            with Image.open(assets / "MobileAppIcon.appiconset/mobile-icon.png") as image:
                self.assertEqual(image.size, (1024, 1024))
                self.assertEqual(image.mode, "RGB")
            for relative, size in expected.items():
                with Image.open(assets / relative) as image:
                    self.assertEqual(image.size, size, str(relative))
                    if "Back.imagestacklayer" in str(relative) or "Top Shelf Image" in str(relative):
                        self.assertEqual(image.mode, "RGB", str(relative))
                    else:
                        self.assertEqual(set(np.unique(np.array(image)[..., 3])), {0, 255})
            self.assertEqual((assets / "StrozzPixelLogo.imageset/strozz_logo.svg").read_bytes(),
                             brand_assets.LOGO.read_bytes())
            self.assertEqual(metadata, {path: path.read_bytes() for path in metadata})


if __name__ == "__main__":
    unittest.main()
