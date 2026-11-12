#!/usr/bin/env python3
"""Génère les icônes mobiles (Android / iOS / web) de GeTech-SMS.

Source : l'icône OFFICIELLE du logiciel desktop
(/home/z/my-project/getech-sms-desktop/icon.jpg, 554x549 JPEG RGB — même
source que assets/app_icon.ico).

Étapes :
  1. Recadrage en carré centré (549x549).
  2. Android : mipmap-{mdpi,hdpi,xhdpi,xxhdpi,xxxhdpi}/ic_launcher.png
     (48/72/96/144/192) + ic_launcher_round.png aux mêmes tailles
     (même image, le launcher rogne lui-même en cercle).
  3. iOS : écrase les PNG existants de AppIcon.appiconset aux tailles lues
     dans le Contents.json EXISTANT (20/29/40/58/60/76/80/87/120/152/167/180/
     1024 px) — Contents.json n'est PAS modifié. PNG RGB sans alpha.
  4. Web : favicon.png (32) + icons/Icon-192.png + Icon-512.png, et les
     maskables (contenu réduit à 80 % — zone sûre — sur fond de la couleur
     du bord de l'icône).

Usage :
    python3 generate_mobile_icons.py [icon.jpg] [racine_flutter]

Par défaut : source desktop + /home/z/my-project/getech-sms-mobile.
"""

import json
import sys
from pathlib import Path

from PIL import Image

SRC = Path(
    sys.argv[1] if len(sys.argv) > 1
    else "/home/z/my-project/getech-sms-desktop/icon.jpg"
)
FLUTTER_ROOT = Path(
    sys.argv[2] if len(sys.argv) > 2
    else "/home/z/my-project/getech-sms-mobile"
)

ANDROID_DENSITIES = {
    "mdpi": 48,
    "hdpi": 72,
    "xhdpi": 96,
    "xxhdpi": 144,
    "xxxhdpi": 192,
}


def center_square(img: Image.Image) -> Image.Image:
    """Recadre l'image en carré centré (554x549 -> 549x549)."""
    w, h = img.size
    side = min(w, h)
    left = (w - side) // 2
    top = (h - side) // 2
    return img.crop((left, top, left + side, top + side))


def save_png(img: Image.Image, path: Path, size: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    img.resize((size, size), Image.LANCZOS).save(path, "PNG")
    print(f"  {path.relative_to(FLUTTER_ROOT)}  {size}x{size}")


def generate_android(square: Image.Image) -> None:
    print("Android (mipmap) :")
    res = FLUTTER_ROOT / "android" / "app" / "src" / "main" / "res"
    for density, size in ANDROID_DENSITIES.items():
        for name in ("ic_launcher.png", "ic_launcher_round.png"):
            save_png(square, res / f"mipmap-{density}" / name, size)


def generate_ios(square: Image.Image) -> None:
    print("iOS (AppIcon.appiconset, tailles du Contents.json existant) :")
    appicon = (
        FLUTTER_ROOT / "ios" / "Runner" / "Assets.xcassets"
        / "AppIcon.appiconset"
    )
    contents = json.loads((appicon / "Contents.json").read_text())
    for entry in contents["images"]:
        base, scale = entry["size"], float(entry["scale"].rstrip("x"))
        px = round(float(base.split("x")[0]) * scale)
        save_png(square, appicon / entry["filename"], px)


def generate_web(square: Image.Image) -> None:
    print("Web :")
    save_png(square, FLUTTER_ROOT / "web" / "favicon.png", 32)
    save_png(square, FLUTTER_ROOT / "web" / "icons" / "Icon-192.png", 192)
    save_png(square, FLUTTER_ROOT / "web" / "icons" / "Icon-512.png", 512)

    # Maskables : les launchers rognent en cercle/rectangle — on réduit le
    # contenu à 80 % de la zone sûre sur un fond uni repris du bord.
    corner = square.getpixel((0, 0))
    for size in (192, 512):
        canvas = Image.new("RGB", (size, size), corner)
        inner = round(size * 0.8)
        content = square.resize((inner, inner), Image.LANCZOS)
        canvas.paste(content, ((size - inner) // 2,) * 2)
        path = FLUTTER_ROOT / "web" / "icons" / f"Icon-maskable-{size}.png"
        canvas.save(path, "PNG")
        print(f"  {path.relative_to(FLUTTER_ROOT)}  {size}x{size} (zone sûre 80 %)")


def main() -> None:
    icon = Image.open(SRC).convert("RGB")
    square = center_square(icon)
    print(
        f"Source : {SRC} ({icon.size[0]}x{icon.size[1]}, {icon.mode}) "
        f"-> carré centré {square.size[0]}x{square.size[1]}"
    )
    generate_android(square)
    generate_ios(square)
    generate_web(square)
    print("OK : icônes régénérées.")


if __name__ == "__main__":
    main()
