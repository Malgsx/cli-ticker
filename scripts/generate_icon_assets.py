from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, ImageFilter


ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "Assets" / "AppIcon"
ICONSET = ASSETS / "CLITicker.iconset"


def font(size: int, bold: bool = True) -> ImageFont.FreeTypeFont:
    candidates = [
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
    ]
    for path in candidates:
        try:
            return ImageFont.truetype(path, size=size)
        except OSError:
            continue
    return ImageFont.load_default()


def draw_app_icon(size: int) -> Image.Image:
    scale = size / 1024
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)

    # Outer rounded application tile.
    margin = int(78 * scale)
    radius = int(210 * scale)
    tile = [margin, margin, size - margin, size - margin]
    draw.rounded_rectangle(tile, radius=radius, fill=(18, 20, 24, 255))

    # Subtle inner panel.
    inner = [int(164 * scale), int(214 * scale), int(860 * scale), int(720 * scale)]
    draw.rounded_rectangle(inner, radius=int(70 * scale), fill=(30, 34, 41, 255), outline=(73, 83, 96, 255), width=max(1, int(8 * scale)))

    # CLI prompt chevron.
    stroke = max(1, int(46 * scale))
    green = (80, 235, 173, 255)
    blue = (98, 169, 255, 255)
    amber = (255, 205, 73, 255)
    draw.line(
        [
            (int(270 * scale), int(390 * scale)),
            (int(410 * scale), int(512 * scale)),
            (int(270 * scale), int(634 * scale)),
        ],
        fill=green,
        width=stroke,
        joint="curve",
    )

    # Command cursor.
    draw.rounded_rectangle(
        [int(500 * scale), int(596 * scale), int(728 * scale), int(646 * scale)],
        radius=int(25 * scale),
        fill=amber,
    )

    # Update orbit/check ring.
    ring_box = [int(606 * scale), int(292 * scale), int(792 * scale), int(478 * scale)]
    draw.arc(ring_box, start=25, end=310, fill=blue, width=max(1, int(28 * scale)))
    draw.polygon(
        [
            (int(774 * scale), int(308 * scale)),
            (int(818 * scale), int(334 * scale)),
            (int(770 * scale), int(360 * scale)),
        ],
        fill=blue,
    )
    draw.ellipse(
        [int(626 * scale), int(356 * scale), int(676 * scale), int(406 * scale)],
        fill=(18, 20, 24, 255),
        outline=blue,
        width=max(1, int(14 * scale)),
    )

    # Small terminal window controls.
    for idx, color in enumerate([(255, 94, 87, 255), (255, 189, 46, 255), (39, 201, 63, 255)]):
        x = int((230 + idx * 58) * scale)
        y = int(282 * scale)
        draw.ellipse([x, y, x + int(28 * scale), y + int(28 * scale)], fill=color)

    # Soft highlight and shadow.
    highlight = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    hdraw = ImageDraw.Draw(highlight)
    hdraw.rounded_rectangle(
        [margin + int(24 * scale), margin + int(18 * scale), size - margin - int(24 * scale), int(420 * scale)],
        radius=radius,
        fill=(255, 255, 255, 18),
    )
    image.alpha_composite(highlight)

    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    sdraw = ImageDraw.Draw(shadow)
    sdraw.rounded_rectangle(tile, radius=radius, fill=(0, 0, 0, 120))
    shadow = shadow.filter(ImageFilter.GaussianBlur(int(30 * scale)))
    composed = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    composed.alpha_composite(shadow)
    composed.alpha_composite(image)
    return composed


def draw_status_icon(size: int = 36) -> Image.Image:
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    stroke = max(2, size // 9)
    color = (0, 0, 0, 255)

    draw.rounded_rectangle([3, 5, size - 3, size - 5], radius=7, outline=color, width=stroke)
    draw.line([(10, 14), (16, 18), (10, 22)], fill=color, width=stroke, joint="curve")
    draw.rounded_rectangle([20, 22, 29, 25], radius=1, fill=color)
    draw.arc([21, 10, 31, 20], start=25, end=315, fill=color, width=max(1, stroke - 1))
    draw.polygon([(30, 10), (34, 13), (30, 16)], fill=color)
    return image


def main() -> None:
    ASSETS.mkdir(parents=True, exist_ok=True)
    ICONSET.mkdir(parents=True, exist_ok=True)

    preview = draw_app_icon(1024)
    preview.save(ASSETS / "CLITickerIcon-1024.png")

    sizes = [
        (16, "icon_16x16.png"),
        (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"),
        (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"),
        (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"),
        (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"),
        (1024, "icon_512x512@2x.png"),
    ]
    for px, name in sizes:
        preview.resize((px, px), Image.Resampling.LANCZOS).save(ICONSET / name)

    draw_status_icon(36).save(ASSETS / "CLIStatusTemplate.png")


if __name__ == "__main__":
    main()
