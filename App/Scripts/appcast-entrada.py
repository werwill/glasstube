#!/usr/bin/env python3
# Pone (o reemplaza) la entrada de una versión de la Mac en el appcast de Sparkle. Lo llama Scripts/release.sh; el
# appcast se firma después con sign_update (Sparkle exige la firma: SURequireSignedFeed).
#
#   python3 -I appcast-entrada.py <appcast.xml> <versión> <compilación> <url del dmg> <firma> <tamaño> <página de la
#       versión> <sistema mínimo> [<cambios.md>]
#
# Solo versiones de la Mac (etiquetas v…): las de Windows (windows-v…) no van en este appcast. Las entradas quedan de la
# más nueva a la más vieja. Las notas van dentro del appcast (firmadas con él), en markdown, con un enlace a la página
# de la versión en GitHub.
import email.utils
import html
import re
import sys

appcast_path, version, build, url, signature, length, page, minimum = sys.argv[1:9]
changes_path = sys.argv[9] if len(sys.argv) > 9 else ""

if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?", version):
    sys.exit(f"versión inválida: {version}")
if not re.fullmatch(r"[0-9]+", build):
    sys.exit(f"compilación inválida: {build}")
if not url.startswith("https://") and not url.startswith("http://127.0.0.1"):
    sys.exit(f"la URL del DMG debe ser https: {url}")

HEADER = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Glasstube para macOS</title>
    <description>Versiones de Glasstube para Mac. Lo escribe App/Scripts/release.sh; no lo edites a mano (va firmado).</description>
    <language>es</language>
  </channel>
</rss>
"""

try:
    text = open(appcast_path, encoding="utf-8").read()
except FileNotFoundError:
    text = HEADER

# La firma anterior (y el aviso que pone sign_update) se quitan: sign_update vuelve a firmar el archivo entero.
text = re.sub(r"<!-- sparkle-sign-warning:.*?-->", "", text, flags=re.S)
text = re.sub(r"<!-- sparkle-signatures:.*?-->\s*", "", text, flags=re.S)
if not text.lstrip().startswith("<?xml"):
    text = '<?xml version="1.0" encoding="utf-8"?>\n' + text.lstrip()
text = re.sub(r"\?>\s*<rss", "?>\n<rss", text, count=1)

# Fuera la entrada de esta misma versión, si ya estaba.
items = re.findall(r"\s*<item>.*?</item>", text, flags=re.S)
kept = [item for item in items
        if f"<sparkle:shortVersionString>{version}</sparkle:shortVersionString>" not in item]
for item in items:
    text = text.replace(item, "", 1)

changes = ""
if changes_path:
    changes = open(changes_path, encoding="utf-8").read().strip()
notes = (changes + "\n\n" if changes else "") + f"[Notas completas y descarga en GitHub]({page})"
notes = notes.replace("]]>", "]] >")

item = f"""
    <item>
      <title>Glasstube {html.escape(version)}</title>
      <pubDate>{email.utils.formatdate(localtime=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{html.escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{html.escape(minimum)}</sparkle:minimumSystemVersion>
      <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
      <description sparkle:format="markdown"><![CDATA[{notes}]]></description>
      <enclosure url="{html.escape(url, quote=True)}" type="application/octet-stream" sparkle:edSignature="{html.escape(signature, quote=True)}" length="{int(length)}"/>
    </item>"""


def build_number(entry):
    found = re.search(r"<sparkle:version>([0-9]+)</sparkle:version>", entry)
    return int(found.group(1)) if found else 0


ordered = sorted(kept + [item], key=build_number, reverse=True)
position = text.rindex("</channel>")
text = text[:position].rstrip() + "".join(ordered) + "\n  </channel>" + text[position + len("</channel>"):]
open(appcast_path, "w", encoding="utf-8").write(text)
count = f"{len(ordered)} versión" if len(ordered) == 1 else f"{len(ordered)} versiones"
newest = re.search(r"<sparkle:shortVersionString>([^<]+)</", ordered[0]).group(1)
print(f"{appcast_path}: entrada de {version} ({build}); {count}, la más nueva {newest}")
