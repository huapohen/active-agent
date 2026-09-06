"""Generate the Renji rocket artwork and platform icons (requires Pillow)."""
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent / "apps" / "office"
SIZE = 1024


def curve(start, control, end, steps=48):
    return [
        tuple((1-t)**2*a + 2*(1-t)*t*b + t*t*c
              for a, b, c in zip(start, control, end))
        for t in (i / steps for i in range(steps + 1))
    ]


def artwork():
    background = Image.new("RGB", (SIZE, SIZE))
    draw = ImageDraw.Draw(background)
    for y in range(SIZE):
        t = y / (SIZE - 1)
        draw.line((0, y, SIZE, y), fill=tuple(
            round(a + (b-a)*t) for a, b in zip((87, 112, 245), (55, 70, 186))))
    rocket = Image.new("RGBA", (SIZE, SIZE))
    draw = ImageDraw.Draw(rocket)
    # A simple silhouette remains legible at favicon and launcher sizes.
    draw.polygon(curve((455, 648), (405, 760), (512, 858)) +
                 curve((512, 858), (619, 760), (569, 648)), fill="#ffad59")
    draw.polygon(curve((484, 650), (457, 738), (512, 787)) +
                 curve((512, 787), (567, 738), (540, 650)), fill="#fff0c5")
    draw.polygon([(406, 440), (321, 546), (321, 664), (433, 593)], fill="#c9d8ff")
    draw.polygon([(618, 440), (703, 546), (703, 664), (591, 593)], fill="#c9d8ff")
    hull = curve((512, 161), (671, 308), (622, 566))
    hull += [(568, 659), (456, 659)]
    hull += curve((402, 566), (353, 308), (512, 161))
    draw.polygon(hull, fill="white")
    draw.ellipse((447, 335, 577, 465), fill="#405bc5")
    draw.ellipse((467, 355, 557, 445), fill="#91c7ff")
    draw.ellipse((481, 365, 510, 393), fill="#e2f3ff")
    rocket = rocket.rotate(-40, Image.Resampling.BICUBIC)
    background.paste(rocket, mask=rocket.getchannel("A"))
    return background


def main():
    master = artwork()
    asset = ROOT / "assets/branding/rocket.png"
    asset.parent.mkdir(parents=True, exist_ok=True)
    master.save(asset)
    paths = list((ROOT / "ios/Runner/Assets.xcassets/AppIcon.appiconset").glob("*.png"))
    paths += list((ROOT / "macos/Runner/Assets.xcassets/AppIcon.appiconset").glob("*.png"))
    paths += list((ROOT / "android/app/src/main/res").glob("mipmap-*/ic_launcher.png"))
    paths += list((ROOT / "web/icons").glob("*.png"))
    paths += [ROOT / "web/favicon.png"]
    for path in paths:
        with Image.open(path) as previous:
            size = previous.size
        source = master
        if "macos" in path.parts:
            source = Image.new("RGBA", (SIZE, SIZE))
            tile = master.resize((896, 896), Image.Resampling.LANCZOS)
            mask = Image.new("L", (896, 896))
            ImageDraw.Draw(mask).rounded_rectangle((0, 0, 895, 895), radius=196, fill=255)
            source.paste(tile, (64, 64), mask)
        source.resize(size, Image.Resampling.LANCZOS).save(path)
    master.save(ROOT / "windows/runner/resources/app_icon.ico", format="ICO",
                sizes=[(n, n) for n in (16, 24, 32, 48, 64, 128, 256)])
    print(f"Generated rocket artwork and {len(paths) + 1} platform icon files")


if __name__ == "__main__":
    main()
