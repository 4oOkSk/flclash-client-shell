#!/usr/bin/env python3

import struct
import unittest
from pathlib import Path

from generate_branding_assets import (
    android_monochrome_icon,
    centered_on_transparent_canvas,
    macos_template_icon,
    read_png,
    rounded_square_icon,
    without_light_background,
)


class CenteredCanvasTest(unittest.TestCase):
    def test_centers_content_and_keeps_outer_pixels_transparent(self) -> None:
        source = bytearray([10, 20, 30, 255] * 4)

        result = centered_on_transparent_canvas(source, 2, 2, 6, 2)

        def pixel(x: int, y: int) -> bytes:
            offset = (y * 6 + x) * 4
            return bytes(result[offset : offset + 4])

        self.assertEqual(pixel(0, 0), b"\x00\x00\x00\x00")
        self.assertEqual(pixel(2, 2), b"\x0a\x14\x1e\xff")
        self.assertEqual(pixel(3, 3), b"\x0a\x14\x1e\xff")
        self.assertEqual(pixel(4, 4), b"\x00\x00\x00\x00")

    def test_rejects_content_larger_than_canvas(self) -> None:
        with self.assertRaises(ValueError):
            centered_on_transparent_canvas(bytearray(16), 2, 2, 4, 5)


class RoundedSquareIconTest(unittest.TestCase):
    def test_rounds_corners_without_making_the_center_transparent(self) -> None:
        result = rounded_square_icon(
            bytearray([10, 20, 30, 255] * 100), 10, 10, 10
        )

        self.assertLess(result[3], 128)
        self.assertLess(result[-1], 128)
        self.assertEqual(result[(5 * 10 + 5) * 4 + 3], 255)

    def test_removes_light_background_and_keeps_dark_artwork(self) -> None:
        result = without_light_background(
            bytearray([255, 255, 255, 255, 10, 30, 60, 255])
        )

        self.assertEqual(result[3], 0)
        self.assertEqual(result[7], 255)

    def test_generated_linux_and_macos_icons_share_the_1024_master(self) -> None:
        linux = Path("assets/images/icon.png")
        macos = Path(
            "macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_1024.png"
        )
        self.assertEqual(linux.read_bytes(), macos.read_bytes())
        width, height, rgba = read_png(linux)
        self.assertEqual((width, height), (1024, 1024))
        self.assertEqual(rgba[3], 0)
        self.assertEqual(rgba[-1], 0)
        self.assertEqual(rgba[(512 * 1024 + 512) * 4 + 3], 255)

    def test_generated_windows_ico_has_all_high_dpi_sizes(self) -> None:
        data = Path("windows/runner/resources/app_icon.ico").read_bytes()
        reserved, image_type, count = struct.unpack("<HHH", data[:6])
        self.assertEqual((reserved, image_type, count), (0, 1, 9))
        sizes = []
        for index in range(count):
            width, height = struct.unpack_from("<BB", data, 6 + index * 16)
            sizes.append((256 if width == 0 else width, 256 if height == 0 else height))
        self.assertEqual(
            sizes,
            [
                (16, 16),
                (20, 20),
                (24, 24),
                (32, 32),
                (40, 40),
                (48, 48),
                (64, 64),
                (128, 128),
                (256, 256),
            ],
        )


class AndroidLauncherAssetTest(unittest.TestCase):
    @staticmethod
    def opaque_bounds(path: Path) -> tuple[int, int, int, int]:
        width, height, rgba = read_png(path)
        points = [
            (index % width, index // width)
            for index in range(width * height)
            if rgba[index * 4 + 3] != 0
        ]
        if not points:
            raise AssertionError(f"{path} has no opaque pixels")
        xs, ys = zip(*points)
        return min(xs), min(ys), max(xs), max(ys)

    def test_adaptive_foreground_is_cat_only_inside_safe_area(self) -> None:
        bounds = self.opaque_bounds(
            Path("android/app/src/main/res/drawable-nodpi/ic_launcher_foreground.png")
        )
        self.assertGreaterEqual(bounds[0], 84)
        self.assertGreaterEqual(bounds[1], 84)
        self.assertLessEqual(bounds[2], 347)
        self.assertLessEqual(bounds[3], 347)

    def test_legacy_icons_have_rounded_transparent_corners(self) -> None:
        sizes = {
            "mdpi": 48,
            "hdpi": 72,
            "xhdpi": 96,
            "xxhdpi": 144,
            "xxxhdpi": 192,
        }
        for density, size in sizes.items():
            with self.subTest(density=density):
                path = Path(
                    f"android/app/src/main/res/mipmap-{density}/ic_launcher.png"
                )
                width, height, rgba = read_png(path)
                self.assertEqual((width, height), (size, size))
                self.assertEqual(rgba[3], 0)
                self.assertEqual(rgba[-1], 0)
                self.assertGreater(rgba[((size // 2) * size) * 4 + 3], 0)


class AndroidSystemIconTest(unittest.TestCase):
    def test_monochrome_icon_drops_white_and_keeps_dark_pixels(self) -> None:
        source = bytearray(
            [
                255, 255, 255, 255,
                10, 30, 60, 255,
                230, 230, 230, 255,
                20, 40, 80, 128,
            ]
        )

        result = android_monochrome_icon(source, 2, 2, 2)

        self.assertEqual(result[0:4], b"\xff\xff\xff\x00")
        self.assertEqual(result[4:8], b"\xff\xff\xff\xff")
        self.assertEqual(result[8:12], b"\xff\xff\xff\x00")
        self.assertEqual(result[12:16], b"\xff\xff\xff\x80")

    def test_generated_notification_and_tile_icons_match(self) -> None:
        paths = [
            Path("android/service/src/main/res/drawable-nodpi/ic.png"),
            Path("android/service/src/main/res/drawable-nodpi/ic_service.png"),
        ]
        payloads = [path.read_bytes() for path in paths]
        self.assertEqual(payloads[0], payloads[1])
        for path in paths:
            width, height, rgba = read_png(path)
            self.assertEqual((width, height), (240, 240))
            self.assertEqual(rgba[3], 0)
            self.assertEqual(rgba[-1], 0)
            self.assertGreater(max(rgba[3::4]), 0)


class MacOSTemplateIconTest(unittest.TestCase):
    def test_white_background_becomes_transparent(self) -> None:
        source = bytearray(
            [
                255, 255, 255, 255,
                10, 30, 60, 255,
                255, 255, 255, 255,
                10, 30, 60, 255,
            ]
        )

        result = macos_template_icon(source, 2, 2, 2)

        self.assertEqual(result[3], 0)
        self.assertGreater(result[7], 0)
        self.assertEqual(result[8:12], b"\x00\x00\x00\x00")
        self.assertGreater(result[15], 0)

    def test_generated_template_has_transparent_corners(self) -> None:
        width, height, rgba = read_png(
            Path("assets/images/icon/status_template.png")
        )
        self.assertEqual((width, height), (32, 32))
        self.assertEqual(rgba[3], 0)
        self.assertEqual(rgba[-1], 0)
        self.assertGreater(max(rgba[3::4]), 0)


if __name__ == "__main__":
    unittest.main()
