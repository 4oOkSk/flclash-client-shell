#!/usr/bin/env python3
"""Generate HarborProxy platform icons from the approved PNG master.

This intentionally uses only the Python standard library so branding assets
can be regenerated on a clean CI runner without downloading an image tool.
"""

from __future__ import annotations

import argparse
import binascii
import math
import struct
import zlib
from pathlib import Path


PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def _paeth(left: int, above: int, upper_left: int) -> int:
    prediction = left + above - upper_left
    left_distance = abs(prediction - left)
    above_distance = abs(prediction - above)
    upper_left_distance = abs(prediction - upper_left)
    if left_distance <= above_distance and left_distance <= upper_left_distance:
        return left
    if above_distance <= upper_left_distance:
        return above
    return upper_left


def read_png(path: Path) -> tuple[int, int, bytearray]:
    data = path.read_bytes()
    if not data.startswith(PNG_SIGNATURE):
        raise ValueError(f"{path} is not a PNG")

    offset = len(PNG_SIGNATURE)
    width = height = bit_depth = color_type = interlace = None
    compressed = bytearray()
    while offset < len(data):
        length = struct.unpack(">I", data[offset : offset + 4])[0]
        chunk_type = data[offset + 4 : offset + 8]
        chunk_data = data[offset + 8 : offset + 8 + length]
        offset += 12 + length
        if chunk_type == b"IHDR":
            width, height, bit_depth, color_type, _, _, interlace = struct.unpack(
                ">IIBBBBB", chunk_data
            )
        elif chunk_type == b"IDAT":
            compressed.extend(chunk_data)
        elif chunk_type == b"IEND":
            break

    if None in (width, height, bit_depth, color_type, interlace):
        raise ValueError("PNG has no valid IHDR")
    if bit_depth != 8 or color_type not in (2, 6) or interlace != 0:
        raise ValueError("only non-interlaced 8-bit RGB/RGBA PNG files are supported")

    channels = 3 if color_type == 2 else 4
    stride = width * channels
    raw = zlib.decompress(bytes(compressed))
    expected = height * (stride + 1)
    if len(raw) != expected:
        raise ValueError(f"unexpected PNG payload size: {len(raw)} != {expected}")

    previous = bytearray(stride)
    rgba = bytearray(width * height * 4)
    source_offset = 0
    target_offset = 0
    for _ in range(height):
        filter_type = raw[source_offset]
        source_offset += 1
        scanline = bytearray(raw[source_offset : source_offset + stride])
        source_offset += stride
        for index in range(stride):
            left = scanline[index - channels] if index >= channels else 0
            above = previous[index]
            upper_left = previous[index - channels] if index >= channels else 0
            if filter_type == 1:
                scanline[index] = (scanline[index] + left) & 0xFF
            elif filter_type == 2:
                scanline[index] = (scanline[index] + above) & 0xFF
            elif filter_type == 3:
                scanline[index] = (scanline[index] + ((left + above) // 2)) & 0xFF
            elif filter_type == 4:
                scanline[index] = (
                    scanline[index] + _paeth(left, above, upper_left)
                ) & 0xFF
            elif filter_type != 0:
                raise ValueError(f"unsupported PNG filter: {filter_type}")
        for index in range(0, stride, channels):
            rgba[target_offset : target_offset + 3] = scanline[index : index + 3]
            rgba[target_offset + 3] = scanline[index + 3] if channels == 4 else 255
            target_offset += 4
        previous = scanline
    return width, height, rgba


def resize_rgba(
    source: bytearray,
    source_width: int,
    source_height: int,
    target_width: int,
    target_height: int,
) -> bytearray:
    target = bytearray(target_width * target_height * 4)
    x_scale = source_width / target_width
    y_scale = source_height / target_height
    for target_y in range(target_height):
        source_y = (target_y + 0.5) * y_scale - 0.5
        y0 = max(0, min(source_height - 1, int(source_y)))
        y1 = min(source_height - 1, y0 + 1)
        wy = max(0.0, min(1.0, source_y - y0))
        for target_x in range(target_width):
            source_x = (target_x + 0.5) * x_scale - 0.5
            x0 = max(0, min(source_width - 1, int(source_x)))
            x1 = min(source_width - 1, x0 + 1)
            wx = max(0.0, min(1.0, source_x - x0))
            target_index = (target_y * target_width + target_x) * 4
            for channel in range(4):
                top_left = source[(y0 * source_width + x0) * 4 + channel]
                top_right = source[(y0 * source_width + x1) * 4 + channel]
                bottom_left = source[(y1 * source_width + x0) * 4 + channel]
                bottom_right = source[(y1 * source_width + x1) * 4 + channel]
                top = top_left * (1.0 - wx) + top_right * wx
                bottom = bottom_left * (1.0 - wx) + bottom_right * wx
                target[target_index + channel] = round(
                    top * (1.0 - wy) + bottom * wy
                )
    return target


def centered_on_transparent_canvas(
    source: bytearray,
    source_width: int,
    source_height: int,
    canvas_size: int,
    content_size: int,
) -> bytearray:
    """Center an image inside a transparent square without filling the mask."""
    if content_size <= 0 or content_size > canvas_size:
        raise ValueError("content size must fit inside the canvas")
    resized = resize_rgba(
        source,
        source_width,
        source_height,
        content_size,
        content_size,
    )
    target = bytearray(canvas_size * canvas_size * 4)
    offset = (canvas_size - content_size) // 2
    for y in range(content_size):
        source_offset = y * content_size * 4
        target_offset = ((y + offset) * canvas_size + offset) * 4
        target[target_offset : target_offset + content_size * 4] = resized[
            source_offset : source_offset + content_size * 4
        ]
    return target


def rounded_square_icon(
    source: bytearray,
    source_width: int,
    source_height: int,
    size: int,
) -> bytearray:
    """Resize the artwork and give desktop/legacy icons transparent corners."""
    target = resize_rgba(source, source_width, source_height, size, size)
    radius = size * 0.22
    for y in range(size):
        center_y = y + 0.5
        dy = max(radius - center_y, center_y - (size - radius), 0.0)
        for x in range(size):
            center_x = x + 0.5
            dx = max(radius - center_x, center_x - (size - radius), 0.0)
            coverage = max(0.0, min(1.0, radius + 0.5 - math.hypot(dx, dy)))
            alpha = (y * size + x) * 4 + 3
            target[alpha] = round(target[alpha] * coverage)
    return target


def without_light_background(source: bytearray) -> bytearray:
    """Keep the navy cat while turning its near-white backdrop into alpha."""
    target = bytearray(source)
    for index in range(len(target) // 4):
        offset = index * 4
        red, green, blue, source_alpha = target[offset : offset + 4]
        darkness = 255 - min(red, green, blue)
        foreground_alpha = round(max(0.0, min(1.0, (darkness - 18) / 48)) * 255)
        target[offset + 3] = round(source_alpha * foreground_alpha / 255)
    return target


def macos_template_icon(
    source: bytearray,
    source_width: int,
    source_height: int,
    size: int,
) -> bytearray:
    """Build a monochrome macOS menu-bar template with transparent background."""
    resized = resize_rgba(source, source_width, source_height, size, size)
    target = bytearray(size * size * 4)
    for index in range(size * size):
        offset = index * 4
        red, green, blue, source_alpha = resized[offset : offset + 4]
        darkness = 255 - min(red, green, blue)
        if darkness <= 24 or source_alpha == 0:
            alpha = 0
        else:
            alpha = min(255, round((darkness - 24) * 255 / 231))
            alpha = round(alpha * source_alpha / 255)
        target[offset : offset + 4] = bytes((0, 0, 0, alpha))
    return target


def android_monochrome_icon(
    source: bytearray,
    source_width: int,
    source_height: int,
    size: int,
) -> bytearray:
    """Build a solid alpha-mask icon for notifications and Quick Settings.

    Android ignores RGB and tints these surfaces itself.  Keeping the dark cat
    opaque and the light background/features transparent makes the approved
    face readable at status-bar size without inheriting the old FlClash glyph.
    """
    resized = resize_rgba(source, source_width, source_height, size, size)
    target = bytearray(size * size * 4)
    for index in range(size * size):
        offset = index * 4
        red, green, blue, source_alpha = resized[offset : offset + 4]
        darkness = 255 - min(red, green, blue)
        alpha = source_alpha if darkness > 40 else 0
        target[offset : offset + 4] = bytes((255, 255, 255, alpha))
    return target


def _png_chunk(chunk_type: bytes, payload: bytes) -> bytes:
    checksum = binascii.crc32(chunk_type)
    checksum = binascii.crc32(payload, checksum) & 0xFFFFFFFF
    return (
        struct.pack(">I", len(payload))
        + chunk_type
        + payload
        + struct.pack(">I", checksum)
    )


def png_bytes(width: int, height: int, rgba: bytearray) -> bytes:
    rows = bytearray()
    stride = width * 4
    for y in range(height):
        rows.append(0)
        offset = y * stride
        rows.extend(rgba[offset : offset + stride])
    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return (
        PNG_SIGNATURE
        + _png_chunk(b"IHDR", header)
        + _png_chunk(b"IDAT", zlib.compress(bytes(rows), level=9))
        + _png_chunk(b"IEND", b"")
    )


def write_png(path: Path, width: int, height: int, rgba: bytearray) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(png_bytes(width, height, rgba))


def write_ico(path: Path, images: list[tuple[int, int, bytes]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    header = struct.pack("<HHH", 0, 1, len(images))
    entries = bytearray()
    payload = bytearray()
    image_offset = 6 + 16 * len(images)
    for width, height, png in images:
        entries.extend(
            struct.pack(
                "<BBBBHHII",
                0 if width == 256 else width,
                0 if height == 256 else height,
                0,
                0,
                1,
                32,
                len(png),
                image_offset + len(payload),
            )
        )
        payload.extend(png)
    path.write_bytes(header + entries + payload)


def with_status_badge(
    source: bytearray,
    size: int,
    color: tuple[int, int, int, int],
) -> bytearray:
    target = bytearray(source)
    radius = max(2, round(size * 0.14))
    center_x = size - radius - max(1, round(size * 0.06))
    center_y = size - radius - max(1, round(size * 0.06))
    border = max(1, round(size * 0.035))
    outer_radius = radius + border
    for y in range(max(0, center_y - outer_radius), min(size, center_y + outer_radius + 1)):
        for x in range(max(0, center_x - outer_radius), min(size, center_x + outer_radius + 1)):
            distance_sq = (x - center_x) ** 2 + (y - center_y) ** 2
            pixel = (y * size + x) * 4
            if distance_sq <= radius**2:
                target[pixel : pixel + 4] = bytes(color)
            elif distance_sq <= outer_radius**2:
                target[pixel : pixel + 4] = b"\xff\xff\xff\xff"
    return target


def centered_banner(icon: bytearray, size: int) -> tuple[int, int, bytearray]:
    width, height = 320, 180
    banner = bytearray([255, 255, 255, 255] * width * height)
    x_offset = (width - size) // 2
    y_offset = (height - size) // 2
    for y in range(size):
        source_offset = y * size * 4
        target_offset = ((y + y_offset) * width + x_offset) * 4
        banner[target_offset : target_offset + size * 4] = icon[
            source_offset : source_offset + size * 4
        ]
    return width, height, banner


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--source",
        default="assets/branding/harborproxy-icon-master.png",
        type=Path,
    )
    args = parser.parse_args()

    source_width, source_height, source = read_png(args.source)
    if source_width != source_height:
        raise ValueError("brand master must be square")

    square_cache: dict[int, bytearray] = {}
    icon_cache: dict[int, bytearray] = {}

    def square(size: int) -> bytearray:
        if size not in square_cache:
            square_cache[size] = resize_rgba(
                source, source_width, source_height, size, size
            )
        return square_cache[size]

    def app_icon(size: int) -> bytearray:
        if size not in icon_cache:
            icon_cache[size] = rounded_square_icon(
                source, source_width, source_height, size
            )
        return icon_cache[size]

    write_png(Path("assets/images/icon.png"), 1024, 1024, app_icon(1024))

    macos_dir = Path("macos/Runner/Assets.xcassets/AppIcon.appiconset")
    for size in (16, 32, 64, 128, 256, 512, 1024):
        write_png(macos_dir / f"app_icon_{size}.png", size, size, app_icon(size))

    android_dir = Path("android/app/src/main")
    write_png(android_dir / "ic_launcher-playstore.png", 512, 512, square(512))
    for density, size in {
        "mdpi": 48,
        "hdpi": 72,
        "xhdpi": 96,
        "xxhdpi": 144,
        "xxxhdpi": 192,
    }.items():
        target = android_dir / "res" / f"mipmap-{density}"
        legacy_icon = app_icon(size)
        write_png(target / "ic_launcher.png", size, size, legacy_icon)
        write_png(target / "ic_launcher_round.png", size, size, legacy_icon)
    write_png(
        android_dir / "res/drawable-nodpi/ic_launcher_foreground.png",
        432,
        432,
        # Adaptive launchers provide the rounded outer shape themselves. Keep
        # only the cat on this layer so the old white square cannot show.
        centered_on_transparent_canvas(
            without_light_background(source),
            source_width,
            source_height,
            432,
            300,
        ),
    )
    android_service_icon = android_monochrome_icon(
        source,
        source_width,
        source_height,
        240,
    )
    for name in ("ic", "ic_service"):
        write_png(
            Path(f"android/service/src/main/res/drawable-nodpi/{name}.png"),
            240,
            240,
            android_service_icon,
        )
    banner_size = 160
    banner = centered_banner(app_icon(banner_size), banner_size)
    write_png(
        android_dir / "res/mipmap-xhdpi/ic_banner.png",
        banner[0],
        banner[1],
        banner[2],
    )

    # Windows uses different icon sizes for Explorer, the taskbar, the window
    # caption and high-DPI displays. A one-entry 256px ICO can fall back to a
    # stale/default icon at smaller sizes, so keep a complete multi-size set.
    windows_sizes = (16, 20, 24, 32, 40, 48, 64, 128, 256)
    windows_images = [
        (size, size, png_bytes(size, size, app_icon(size)))
        for size in windows_sizes
    ]
    write_ico(Path("windows/runner/resources/app_icon.ico"), windows_images)
    write_ico(Path("assets/images/icon.ico"), windows_images)

    # The Windows notification-area icon is also displayed on the taskbar.
    # Keep the three connection states, but brand all of them with the approved
    # cat instead of the inherited FlClash glyph.
    status_colors = {
        "status_1": (126, 134, 148, 255),  # stopped
        "status_2": (56, 132, 255, 255),   # system proxy
        "status_3": (34, 197, 94, 255),    # TUN
    }
    for name, color in status_colors.items():
        status_png = with_status_badge(app_icon(108), 108, color)
        write_png(Path(f"assets/images/icon/{name}.png"), 108, 108, status_png)
        status_images = []
        for size in (16, 20, 24, 32, 40, 48, 64):
            badged = with_status_badge(app_icon(size), size, color)
            status_images.append((size, size, png_bytes(size, size, badged)))
        write_ico(Path(f"assets/images/icon/{name}.ico"), status_images)

    # macOS template icons use alpha as the mask. Reusing the opaque brand PNG
    # turns its white background into a solid menu-bar rectangle.
    template_size = 32
    write_png(
        Path("assets/images/icon/status_template.png"),
        template_size,
        template_size,
        macos_template_icon(
            source,
            source_width,
            source_height,
            template_size,
        ),
    )


if __name__ == "__main__":
    main()
