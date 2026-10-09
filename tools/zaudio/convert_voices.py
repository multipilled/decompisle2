"""Convert DI2's zombie voice wems (DamLoc, Wwise Vorbis) to Ogg Vorbis for the Godot port and measure each file's
per-audio-frame peak level for the mouth meter (recon/ZOMBIE_AUDIO.md).

  * conversion: tools/zaudio/wwvorbis.py (own ww2ogg-algorithm port) -> game/assets/di2/zombie_vox/<Voice>/<Folder>/
    <Name>.ogg (folder carries a .gdignore; zombie_voice.gd loads them with AudioStreamOggVorbis.load_from_file);
  * peaks: the converted ogg is decoded with the locally installed ffmpeg (standard Ogg Vorbis decode only) and the
    absolute peak of every 1024-sample block is stored in dB x 100 (DI2's Wwise renders 1024-sample frames at
    48 kHz: DefaultGame.ini [/Script/AkAudio.AkWindowsInitializationSettings] SamplesPerFrame=1024,
    SampleRate=48000). The Wwise Meter on the zombie dialogue events (FxShareSet 220051762, Peak mode) consumes the
    same per-frame peak; its ballistics are applied at runtime.

usage: python -I tools/zaudio/convert_voices.py --codebooks <packed_codebooks_aoTuV_603.bin> <Voice> [<Voice> ...]
Inputs: extracted/raw/DeadIsland/Content/StagedData/DamLoc/Windows/English/Main/Voices/<Voice>/<Folder>/*.wem
"""
import glob
import json
import math
import os
import subprocess
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wwvorbis import CodebookLibrary, to_ogg  # noqa: E402

ROOT = r"."
SRC = os.path.join(ROOT, r"extracted\raw\DeadIsland\Content\StagedData\DamLoc\Windows\English\Main\Voices")
OUT = os.path.join(ROOT, r"game\assets\di2\zombie_vox")
FRAME = 1024
FLOOR_DB = -96.0


def ffmpeg_exe() -> str:
    pat = os.path.expandvars(r"%LOCALAPPDATA%\Microsoft\WinGet\Packages\Gyan.FFmpeg*\ffmpeg-*\bin\ffmpeg.exe")
    hits = glob.glob(pat)
    if not hits:
        raise SystemExit("ffmpeg not found (needed only to decode the converted ogg for the peak analysis)")
    return hits[0]


def main(argv):
    cb = argv[argv.index("--codebooks") + 1]
    voices = [a for i, a in enumerate(argv) if a != "--codebooks" and (i == 0 or argv[i - 1] != "--codebooks")]
    cbl = CodebookLibrary(cb)
    ff = ffmpeg_exe()
    os.makedirs(OUT, exist_ok=True)
    open(os.path.join(OUT, ".gdignore"), "w").close()
    peaks_path = os.path.join(OUT, "peaks.json")
    peaks = json.load(open(peaks_path)) if os.path.exists(peaks_path) else {}
    bad = []
    n = 0
    for v in voices:
        for wem in sorted(glob.glob(os.path.join(SRC, v, "*", "*.wem"))):
            folder = os.path.basename(os.path.dirname(wem))
            name = os.path.splitext(os.path.basename(wem))[0]
            key = f"{v}/{folder}/{name}"
            dst = os.path.join(OUT, v, folder, name + ".ogg")
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            try:
                ogg, info = to_ogg(open(wem, "rb").read(), cbl)
            except Exception as ex:  # noqa: BLE001
                bad.append((key, str(ex)))
                continue
            open(dst, "wb").write(ogg)
            pcm = subprocess.run([ff, "-nostdin", "-v", "error", "-i", dst, "-f", "f32le", "-ac", "1", "-"],
                                 capture_output=True, check=True).stdout
            x = np.frombuffer(pcm, dtype=np.float32)
            if len(x) != info["samples"]:
                bad.append((key, f"decoded {len(x)} samples, wem says {info['samples']}"))
            blocks = [float(np.abs(x[i:i + FRAME]).max()) for i in range(0, len(x), FRAME)]
            db = [max(FLOOR_DB, 20.0 * math.log10(p)) if p > 0 else FLOOR_DB for p in blocks]
            peaks[key] = {"samples": int(info["samples"]), "rate": int(info["rate"]),
                          "peak_db100": [int(round(d * 100)) for d in db]}
            n += 1
    json.dump(peaks, open(peaks_path, "w"), separators=(",", ":"))
    print(f"converted {n} files, {len(bad)} problems")
    for k, e in bad[:40]:
        print("  BAD", k, e)


if __name__ == "__main__":
    main(sys.argv[1:])
