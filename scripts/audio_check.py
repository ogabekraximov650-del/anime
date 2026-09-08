#!/usr/bin/env python3
"""
DIAGNOSTIKA skripti (vaqtinchalik) — Telegramdagi tayyor videolarni yuklab
olib, audiosidagi shovqinni o'lchaydi.

Ishlatish:
    python3 -u scripts/audio_check.py <chat_id> <msg_id> [<msg_id> ...]

Har bir fayl uchun chiqariladi:
  - oqim parametrlari (kodek, sample rate, kanallar)
  - umumiy RMS
  - 15.2-17 kHz "bo'sh" polosadagi shovqin: minimal / medianа / maksimal
    sekundlik RMS. Manba AAC odatda ~14.7 kHz da kesiladi, shuning uchun bu
    polosa toza faylda deyarli bo'sh bo'ladi. Qayta kodlashda shovqin
    qo'shilsa, MINIMAL daraja ko'tariladi — aynan shu "shivirlash" bo'ladi.
"""
import os, sys, re, asyncio, subprocess, statistics
from pyrogram import Client

API_ID = int(os.environ.get("TG_API_ID", 0))
API_HASH = os.environ.get("TG_API_HASH", "")
SESSION = os.path.join(os.path.dirname(os.path.abspath(__file__)), "pyro_session")


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True).stdout.strip()


def band_profile(path):
    """15.2-17 kHz polosadagi sekundlik RMS ro'yxati (dB)."""
    af = ("highpass=f=15200:poles=2,highpass=f=15200:poles=2,"
          "highpass=f=15200:poles=2,lowpass=f=17000:poles=2,"
          "asetnsamples=n=44100:p=0,astats=metadata=1:reset=1,"
          "ametadata=print:key=lavfi.astats.Overall.RMS_level:file=-")
    p = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-map", "0:a",
                        "-af", af, "-f", "null", "-"],
                       capture_output=True, text=True)
    vals = []
    for m in re.finditer(r"RMS_level=(-?[\d.]+|-inf)", p.stdout + p.stderr):
        v = m.group(1)
        if v != "-inf":
            vals.append(float(v))
    return vals


def analyse(path, label):
    print(f"\n{'='*62}\n### {label}: {os.path.basename(path)}\n{'='*62}", flush=True)
    print(run(["ffprobe", "-v", "error", "-show_entries",
               "stream=codec_type,codec_name,sample_rate,channels,duration",
               "-of", "default=nw=1", path]), flush=True)

    overall = subprocess.run(
        ["ffmpeg", "-hide_banner", "-i", path, "-map", "0:a", "-af", "astats",
         "-f", "null", "-"], capture_output=True, text=True).stderr
    for line in overall.splitlines():
        if "RMS level dB:" in line or "Peak level dB:" in line:
            print("   ", line.split("]", 1)[-1].strip(), flush=True)
            if "RMS" in line:
                break

    vals = band_profile(path)
    if not vals:
        print("    15.2-17kHz: o'lchab bo'lmadi", flush=True)
        return
    vals_sorted = sorted(vals)
    n = len(vals_sorted)
    floor = statistics.median(vals_sorted[:max(1, n // 10)])   # eng jim 10%
    print(f"\n    15.2-17 kHz polosa ({n} sekund o'lchandi):", flush=True)
    print(f"      SHOVQIN POLI (eng jim 10% medianasi): {floor:8.2f} dB   <== ASOSIY KO'RSATKICH", flush=True)
    print(f"      minimal                             : {vals_sorted[0]:8.2f} dB", flush=True)
    print(f"      mediana                             : {statistics.median(vals_sorted):8.2f} dB", flush=True)
    print(f"      maksimal                            : {vals_sorted[-1]:8.2f} dB", flush=True)


async def main(chat_id, msg_ids):
    async with Client(SESSION, api_id=API_ID, api_hash=API_HASH) as app:
        me = await app.get_me()
        print(f"✅ Ulandi: {me.first_name}", flush=True)
        print("🔎 Suhbatlar ro'yxati o'qilmoqda (peer keshi uchun)...", flush=True)
        async for _ in app.get_dialogs():
            pass

        for mid in msg_ids:
            msg = await app.get_messages(chat_id, mid)
            if not msg or not (msg.video or msg.document):
                print(f"⚠️  {mid}: video topilmadi", flush=True)
                continue
            print(f"\n⬇️  {mid}-xabar yuklab olinmoqda...", flush=True)
            path = await app.download_media(msg, file_name=f"tg_{mid}.mp4")
            size = os.path.getsize(path) / 1024 / 1024
            print(f"    {path} ({size:.1f} MB)", flush=True)
            analyse(path, f"{mid}-xabar")
            os.remove(path)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    chat = int(sys.argv[1])
    ids = [int(x) for x in sys.argv[2:]]
    asyncio.run(main(chat, ids))
