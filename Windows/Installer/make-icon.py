"""Genera Windows/Glasstube.App/Assets/Glasstube.ico a partir de App/Icon/AppIcon.icns (el de la app de Mac).

El .icns trae el icono a sangre completa (macOS le pone su forma) y la variante pequeña de 16 y 32 px
(Glasstube-pequeno.svg). En Windows el icono lleva su propia forma: cuadrado redondeado con un margen transparente,
como los de Windows 11. Tamaños: 16, 20, 24, 32 (variante pequeña), 40, 48, 64, 128 y 256.

Uso: python Windows/Installer/make-icon.py   (necesita Pillow)
"""
from pathlib import Path

from PIL import Image, ImageDraw

REPO = Path(__file__).resolve().parents[2]
ICNS = REPO / "App" / "Icon" / "AppIcon.icns"
ICO = REPO / "Windows" / "Glasstube.App" / "Assets" / "Glasstube.ico"
SMALL = (16, 20, 24, 32)
LARGE = (40, 48, 64, 128, 256)
MARGIN = 0.04   # del lado, en cada borde
RADIUS = 0.22   # del lado de la forma


def frame(icns: Image.Image, size: tuple[int, int, int]) -> Image.Image:
    icns.size = size[:2]
    icns.load(scale=size[2])
    return icns.convert("RGBA")


def shaped(source: Image.Image, side: int) -> Image.Image:
    # Se trabaja a 4× y se reduce al final para que el borde redondeado quede suave.
    big = side * 4
    inset = round(big * MARGIN)
    inner = big - 2 * inset
    art = source.resize((inner, inner), Image.LANCZOS)
    mask = Image.new("L", (inner, inner), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, inner - 1, inner - 1), radius=round(inner * RADIUS), fill=255)
    canvas = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    canvas.paste(art, (inset, inset), mask)
    return canvas.resize((side, side), Image.LANCZOS)


def main() -> None:
    icns = Image.open(ICNS)
    large = frame(icns, (512, 512, 2))
    small = frame(icns, (16, 16, 2))  # 32 px de Glasstube-pequeno.svg
    images = [shaped(small, s) for s in SMALL] + [shaped(large, s) for s in LARGE]
    ICO.parent.mkdir(parents=True, exist_ok=True)
    # Pillow escribe cada tamaño desde la imagen más grande que se le da; con append_images usa cada una tal cual.
    images[-1].save(ICO, format="ICO", sizes=[(i.width, i.height) for i in images], append_images=images[:-1])
    print(ICO.relative_to(REPO))


if __name__ == "__main__":
    main()
