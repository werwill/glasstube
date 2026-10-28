#!/usr/bin/env python3
# python3 -I make-smarttube-respaldo.py smarttube-respaldo.zip
# Arma un respaldo de SmartTube de prueba como el de BackupAndRestoreManager (ZipOutputStream de Java: DEFLATE con
# descriptor de datos). Solo contenido Creative Commons de Blender y ids de prueba.
import io, sys, zipfile
from xml.sax.saxutils import escape

class NoSeek(io.RawIOBase):
    def __init__(self): self.buf = bytearray()
    def writable(self): return True
    def write(self, b): self.buf += b; return len(b)
    def seekable(self): return False

def video(title, video_id, channel_id, second):
    f = ["-1", "null", title, video_id, "null", "null", channel_id, "null",
         f"https://i.ytimg.com/vi/{video_id}/hqdefault.jpg", "null", "null", "-1", "null", "-1", second,
         "null", "0.0", "null", "null", "null", "false", "null", "null"]
    return "&vi;".join(f)

def state(v, pos, dur):
    return "&sf;".join([v, str(pos), str(dur), "1.0"])

BLENDER = "UCSMOQeBJ2RAnuFungnQOxLg"
STUDIO = "UCz75RVbH8q2jdBJ4SnwuZZQ"
# Del más viejo al más nuevo (VideoStateService agrega al final). Sintel aparece dos veces: vale la última.
history = "&si;".join([
    state(video("Sintel", "eRsGyueVLvQ", BLENDER, "Blender • 9,6 M de vistas • hace 15 años"), 120000, 888000),
    state("aqz-KE-bpKQ", 30000, -1),  # formato muy viejo: solo el id
    state(video("Spring - Blender Open Movie", "WhWc3b3KhnY", STUDIO, "Blender Studio • 12 M de vistas"), 200000, 464000),
    state(video("Sintel", "eRsGyueVLvQ", BLENDER, "Blender • 9,6 M de vistas • hace 15 años"), 300000, 888000),
    state(video("Roto", "x", BLENDER, "x"), 1, 2),
]) + "%OB%false"

def item(title, channel_id):
    return "&ci;".join([title, f"https://yt3.ggpht.com/{channel_id}", channel_id, "null", "null", "null", "-1"])

def group(gid, title, items):
    return "&sgi;".join([gid, title, "null", "&sga;".join(items), "null"])

groups = "%AR%".join([
    group("1000", "Subscriptions", [item("Blender Studio", STUDIO), item("Blender", BLENDER)]),
    group("1001", "Notifications", [item("Blender", BLENDER)]),
    group("123456", "Animación libre", [item("Blender Studio", STUDIO), item("Roto", "no-es-un-canal")]),
])

blocked = "%AR%".join(["UCpruebaBloqueado0000001&vi;Canal de prueba", "null&vi;Solo nombre"]) + "%OB%" + \
          "UCpruebaBloqueadoViejo01%PR%Canal viejo"

legacy_xml = """<?xml version='1.0' encoding='utf-8' standalone='yes' ?>
<map>
    <string name="Cuenta_de_prueba_channel_group_data">%s</string>
    <boolean name="some_flag" value="true" />
</map>
""" % escape(group("777", "Música & CC", [item("Blender", BLENDER)]))  # Android escapa & como &amp;

out = NoSeek()
pkg = "data/com.teamsmart.videomanager.tv/Backup"
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr(f"{pkg}/shared_prefs/com.teamsmart.videomanager.tv_preferences.xml",
               "<?xml version='1.0' encoding='utf-8' standalone='yes' ?>\n<map>\n    <string name=\"app_settings\">0%OB%1%OB%true</string>\n</map>\n")
    z.writestr(f"{pkg}/shared_prefs/yt_service_prefs.xml", legacy_xml)
    z.writestr(f"{pkg}/files/app_prefs/anonymous_state_updater_data", history)
    z.writestr(f"{pkg}/files/app_prefs/blocked_channel_data", blocked)
    z.writestr(f"{pkg}/files/yt_service_prefs/anonymous_channel_group_data", groups)
open(sys.argv[1], "wb").write(bytes(out.buf))
