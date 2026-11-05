#!/usr/bin/env python3
"""Las cadenas de la interfaz (fase 6). Las claves las da el compilador: el paquete compila con -emit-localized-strings
y deja en .build/cadenas/ un .stringsdata por archivo, con cada clave tal como se busca en ejecución (`%lld`, `%@`…), así
que hace falta un `swift build` antes. La clave es el texto en español; la lengua de desarrollo es el inglés para que un
sistema en otro idioma caiga en inglés, y por eso es.lproj también lleva todas las claves (si falta una, Foundation usa
la tabla de la lengua de desarrollo: saldría en inglés).

  Scripts/cadenas.py revisar               # claves sin traducción y traducciones que sobran (sale con 1 si hay)
  Scripts/cadenas.py sincronizar           # reescribe es.lproj/Localizable.strings (cada clave = ella misma) y ordena en.lproj
  Scripts/cadenas.py faltan                # solo las claves sin inglés, una por línea (para traducirlas)
  Scripts/cadenas.py agregar archivo       # agrega al inglés las parejas del archivo: una línea con la clave y otra con «=> valor»
  Scripts/cadenas.py sueltas [archivos…]   # literales de Swift con pinta de texto que no pasan por la localización
"""
import glob
import json
import os
import re
import subprocess
import sys

APP = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(APP, ".build", "cadenas")
LOC = os.path.join(APP, "Localization")
FUENTES = os.path.join(APP, "Sources", "Glasstube")


def emitidas():
    """{clave: [(archivo, línea)]} de los .stringsdata, sin los de archivos que ya no existen."""
    claves = {}
    for path in glob.glob(os.path.join(DATA, "*.stringsdata")):
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        if not os.path.exists(data["source"]):
            continue
        for entries in data["tables"].values():
            for entry in entries:
                claves.setdefault(entry["key"], []).append((data["source"], entry["location"]["startingLine"]))
    return claves


def leer_strings(path):
    if not os.path.exists(path):
        return {}
    out = subprocess.run(["plutil", "-convert", "json", "-o", "-", path], capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"{path}: {out.stderr}")
    return json.loads(out.stdout)


def leer_plurales(path):
    if not os.path.exists(path):
        return {}
    out = subprocess.run(["plutil", "-convert", "json", "-o", "-", path], capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"{path}: {out.stderr}")
    return json.loads(out.stdout)


def escapar(text):
    return text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t")


def escribir_strings(path, tabla, cabecera):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(f"/* {cabecera} */\n\n")
        for key in sorted(tabla, key=lambda k: (k.casefold(), k)):
            f.write(f'"{escapar(key)}" = "{escapar(tabla[key])}";\n')


def ruta(idioma, nombre):
    return os.path.join(LOC, f"{idioma}.lproj", nombre)


CABECERA_ES = ("La clave es el texto en español. Lo escribe Scripts/cadenas.py sincronizar a partir de lo que emite el "
               "compilador: no hace falta editarlo a mano.")
CABECERA_EN = ("La clave es el texto en español de la app; el valor, en inglés. Scripts/cadenas.py revisar dice qué falta "
               "(y `swift test` también falla).")


def formatos(text):
    """Los especificadores de una cadena, en orden, sin los %% literales."""
    return re.findall(r"%(?:\d+\$)?(?:lld|ld|lf|d|u|f|@|s)", text.replace("%%", ""))


def revisar():
    claves = emitidas()
    if not claves:
        sys.exit(f"No hay nada en {DATA}: corre swift build primero.")
    en, es = leer_strings(ruta("en", "Localizable.strings")), leer_strings(ruta("es", "Localizable.strings"))
    plural_en = leer_plurales(ruta("en", "Localizable.stringsdict"))
    plural_es = leer_plurales(ruta("es", "Localizable.stringsdict"))
    mal = 0
    for key in sorted(claves):
        if key not in en and key not in plural_en:
            mal += 1
            archivo, linea = claves[key][0]
            print(f"sin inglés: {os.path.relpath(archivo, APP)}:{linea}: {key}")
        if key not in es and key not in plural_es:
            mal += 1
            print(f"sin español: {key}")
    for key in sorted(set(en) | set(plural_en)):
        if key not in claves:
            print(f"sobra en inglés: {key}")
    for key, value in en.items():
        if key in claves and sorted(formatos(key)) != sorted(formatos(value)):
            mal += 1
            print(f"formatos distintos: {key} → {value}")
    print(f"{len(claves)} claves, {mal} problemas")
    return 1 if mal else 0


def sincronizar():
    claves = emitidas()
    if not claves:
        sys.exit(f"No hay nada en {DATA}: corre swift build primero.")
    plural_es = leer_plurales(ruta("es", "Localizable.stringsdict"))
    escribir_strings(ruta("es", "Localizable.strings"), {k: k for k in claves if k not in plural_es}, CABECERA_ES)
    en = leer_strings(ruta("en", "Localizable.strings"))
    escribir_strings(ruta("en", "Localizable.strings"), en, CABECERA_EN)
    return revisar()


def faltan():
    en, plural = leer_strings(ruta("en", "Localizable.strings")), leer_plurales(ruta("en", "Localizable.stringsdict"))
    for key in sorted(emitidas()):
        if key not in en and key not in plural:
            print(key.replace("\n", "\\n"))
    return 0


def agregar(path):
    en = leer_strings(ruta("en", "Localizable.strings"))
    key = None
    nuevos = 0
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line.strip() or line.startswith("#"):
                continue
            if line.startswith("=> "):
                if key is None:
                    sys.exit(f"Valor sin clave: {line}")
                en[key] = line[3:].replace("\\n", "\n")
                key = None
                nuevos += 1
            else:
                if key is not None:
                    sys.exit(f"Clave sin valor: {key}")
                key = line.replace("\\n", "\n")
    if key is not None:
        sys.exit(f"Clave sin valor: {key}")
    escribir_strings(ruta("en", "Localizable.strings"), en, CABECERA_EN)
    print(f"{nuevos} parejas")
    return 0


# Un lector mínimo de Swift: los literales de cadena de nivel superior, fuera de los comentarios.
def literales(src):
    out = []
    n = len(src)

    def leer(k):
        hashes = 0
        while src[k] == "#":
            hashes += 1
            k += 1
        multi = src.startswith('"""', k)
        comilla = '"""' if multi else '"'
        k += len(comilla)
        cierre = comilla + "#" * hashes
        while k < n:
            if src.startswith(cierre, k):
                return k + len(cierre)
            c = src[k]
            if c == "\\" and src.startswith("#" * hashes, k + 1):
                j = k + 1 + hashes
                if j < n and src[j] == "(":
                    profundidad = 1
                    j += 1
                    while j < n and profundidad:
                        if src[j] == '"' or re.match(r'#+"', src[j:j + 8]):
                            j = leer(j)
                            continue
                        if src[j] == "(":
                            profundidad += 1
                        elif src[j] == ")":
                            profundidad -= 1
                        j += 1
                    k = j
                    continue
                k = j + 1
                continue
            if c == "\n" and not multi:
                return k
            k += 1
        return k

    i = 0
    while i < n:
        if src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
        elif src.startswith("/*", i):
            profundidad = 1
            i += 2
            while i < n and profundidad:
                if src.startswith("/*", i):
                    profundidad += 1
                    i += 2
                elif src.startswith("*/", i):
                    profundidad -= 1
                    i += 2
                else:
                    i += 1
        elif src[i] == '"' or (src[i] == "#" and re.match(r'#+"', src[i:i + 8])):
            j = leer(i)
            out.append((src.count("\n", 0, i) + 1, src[i:j]))
            i = j
        else:
            i += 1
    return out


# Líneas que son para quien desarrolla, no para quien usa la app.
REGISTRO = re.compile(r"NSLog\(|Log\.|print\(|fatalError\(|log\(|logs[A-Z]|FileHandle\.standardError|UserDefaults|defaults\.|forKey:|save\(|Self\.flag\(|Self\.number\(|URL\(string:")


def sueltas(archivos):
    localizadas = {pos for posiciones in emitidas().values() for pos in posiciones}
    if not archivos:
        archivos = [os.path.join(raiz, nombre) for raiz, _, nombres in os.walk(FUENTES) for nombre in nombres
                    if nombre.endswith(".swift") and nombre != "Automation.swift"]
    for path in sorted(archivos):
        absoluto = os.path.abspath(path)
        with open(path, encoding="utf-8") as f:
            src = f.read()
        lineas = src.split("\n")
        for linea, literal in literales(src):
            if (absoluto, linea) in localizadas or REGISTRO.search(lineas[linea - 1]):
                continue
            cuerpo = re.sub(r"\\\(.*?\)", "", literal).strip('#"')
            if not re.search(r"[A-Za-zÁÉÍÓÚáéíóúñÑ]{2,}", cuerpo):
                continue
            # Identificadores, rutas, símbolos: sin espacios ni acentos y sin mayúscula inicial de palabra corriente.
            if re.fullmatch(r"[\w.\-/:%@?&=+,;~*#\[\]{}()\\ ]*", cuerpo) and not re.search(r"[áéíóúñ¿¡ÁÉÍÓÚ]", cuerpo) \
                    and not re.search(r"\b[A-Z][a-z]+\b|\b[a-z]{3,} [a-z]{2,}\b", cuerpo):
                continue
            print(f"{os.path.relpath(path, APP)}:{linea}: {literal[:150]}")
    return 0


def main():
    orden = sys.argv[1] if len(sys.argv) > 1 else "revisar"
    if orden == "revisar":
        return revisar()
    if orden == "sincronizar":
        return sincronizar()
    if orden == "faltan":
        return faltan()
    if orden == "agregar":
        return agregar(sys.argv[2])
    if orden == "sueltas":
        return sueltas(sys.argv[2:])
    sys.exit(__doc__)


if __name__ == "__main__":
    sys.exit(main())
