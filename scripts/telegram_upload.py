#!/usr/bin/env python3
"""
Telegram video/fayl yuklash skripti (Pyrogram + TgCrypto).

Ishlatish:
    python3 telegram_upload.py video.mp4
    python3 telegram_upload.py *.mp4
    python3 telegram_upload.py arxiv.zip        # fayl sifatida
    python3 telegram_upload.py video.mp4 --doc  # majburan fayl
"""

import os, sys, time, asyncio, subprocess, tempfile, json
from pathlib import Path
from pyrogram import Client

API_ID   = int(os.environ.get("TG_API_ID", 0))
API_HASH = os.environ.get("TG_API_HASH", "")
CHAT_ID  = os.environ.get("TG_CHAT_ID", "me")

SESSION  = os.path.join(os.path.dirname(os.path.abspath(__file__)), "pyro_session")

try:
    CHAT_ID = int(CHAT_ID)
except (ValueError, TypeError):
    pass

if not API_ID or not API_HASH:
    print("❌ TG_API_ID va TG_API_HASH kerak.")
    sys.exit(1)

VIDEO_EXTS = {".mp4", ".mkv", ".avi", ".mov", ".webm", ".m4v", ".flv"}


def ffprobe_get(file_path: str, stream_type: str, entry: str) -> str:
    cmd = [
        "ffprobe", "-v", "error",
        "-select_streams", stream_type,
        "-show_entries", f"stream={entry}",
        "-of", "csv=p=0",
        file_path
    ]
    try:
        out = subprocess.check_output(cmd, stderr=subprocess.DEVNULL).decode().strip()
        return out.split("\n")[0].strip()
    except Exception:
        return ""


def get_video_metadata(file_path: str) -> dict:
    """Video eni, bo'yi va uzunligini (sekundda) olish. Noma'lum qiymatlar None."""
    width_s  = ffprobe_get(file_path, "v:0", "width")
    height_s = ffprobe_get(file_path, "v:0", "height")

    duration_s = ""
    try:
        cmd = [
            "ffprobe", "-v", "error",
            "-show_entries", "format=duration",
            "-of", "csv=p=0",
            file_path
        ]
        duration_s = subprocess.check_output(cmd, stderr=subprocess.DEVNULL).decode().strip()
    except Exception:
        pass

    def to_int(val: str):
        try:
            v = int(float(val))
            return v if v > 0 else None
        except (ValueError, TypeError):
            return None

    return {
        "width":    to_int(width_s),
        "height":   to_int(height_s),
        "duration": to_int(duration_s),
    }


def get_thumbnail(video_path: str) -> tuple[str | None, bool]:
    """
    Thumbnail topish.
    Returns: (path_or_None, is_owned_temp)
      is_owned_temp=True => biz yaratdik, yuklagandan keyin o'chiramiz.
    """
    base = Path(video_path).with_suffix("")

    # 1. Bir xil nomli cover rasm
    for ext in (".jpg", ".jpeg", ".png"):
        img = base.with_suffix(ext)
        if img.exists():
            return str(img), False

    # 2. encode.sh uslubi: Final_NOMI.mp4 => NOMI.png
    stem = Path(video_path).stem
    if stem.startswith("Final_"):
        folder_name = stem[len("Final_"):]
        workspace   = Path(video_path).parent
        cover = workspace / f"{folder_name}.png"
        if cover.exists():
            return str(cover), False

    # 3. ffmpeg orqali 1-soniyadan kadr olish (vaqtinchalik fayl)
    try:
        tmp = tempfile.NamedTemporaryFile(suffix=".jpg", delete=False)
        tmp.close()
        cmd = [
            "ffmpeg", "-y", "-ss", "1",
            "-i", video_path,
            "-vframes", "1",
            "-q:v", "2",
            tmp.name
        ]
        subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
        if os.path.exists(tmp.name) and os.path.getsize(tmp.name) > 0:
            return tmp.name, True   # biz yaratdik
        os.unlink(tmp.name)
    except Exception:
        pass

    return None, False


def make_progress(file_size: int):
    start = time.time()
    last_update = [0.0]

    def callback(current, total):
        now = time.time()
        if now - last_update[0] < 0.5 and current < total:
            return
        last_update[0] = now
        elapsed = now - start
        speed = current / elapsed if elapsed > 0 else 0
        pct = current / total * 100
        filled = int(pct // 4)
        bar = "█" * filled + "░" * (25 - filled)
        speed_str = (f"{speed/1024/1024:.2f} MB/s" if speed > 1024*1024
                     else f"{speed/1024:.1f} KB/s")
        eta = int((total - current) / speed) if speed > 0 else 0
        print(
            f"\r[{bar}] {pct:.1f}%  "
            f"{current/1024/1024:.1f}/{total/1024/1024:.1f} MB  "
            f"⚡{speed_str}  ETA:{eta//60}:{eta%60:02d}   ",
            end="", flush=True,
        )

    return callback


async def upload_file(app: Client, chat_id, file_path: str, force_doc: bool = False):
    if not os.path.exists(file_path):
        print(f"❌ Topilmadi: {file_path}")
        return False

    file_name = os.path.basename(file_path)
    file_size = os.path.getsize(file_path)
    ext = os.path.splitext(file_name)[1].lower()
    is_video = (ext in VIDEO_EXTS) and not force_doc

    print(f"\n📤 {file_name}  ({file_size/1024/1024:.2f} MB)  "
          f"{'🎬 streaming video' if is_video else '📁 fayl (dokument)'}")

    start    = time.time()
    progress = make_progress(file_size)
    thumb_path, thumb_owned = None, False

    # --- .meta.json dan ma'lumot olish (mavjud bo'lsa) ---
    tg_meta = {}
    meta_file = os.path.splitext(file_path)[0] + ".meta.json"
    if os.path.exists(meta_file):
        try:
            with open(meta_file, encoding="utf-8") as f:
                tg_meta = json.load(f)
            print(f"   📋 meta.json topildi")
        except Exception:
            tg_meta = {}

    try:
        if is_video:
            # --- Metadata: avval meta.json, keyin ffprobe ---
            if tg_meta:
                meta = {
                    "duration": tg_meta.get("duration") or None,
                    "width":    tg_meta.get("width")    or None,
                    "height":   tg_meta.get("height")   or None,
                }
                saved_thumb = tg_meta.get("thumb", "")
                if saved_thumb and os.path.exists(saved_thumb):
                    thumb_path, thumb_owned = saved_thumb, False
                else:
                    thumb_path, thumb_owned = get_thumbnail(file_path)
            else:
                meta = get_video_metadata(file_path)
                thumb_path, thumb_owned = get_thumbnail(file_path)

            caption_text = tg_meta.get("caption", "").strip() or f"🎬 {file_name}"

            dur = meta["duration"]
            dur_fmt = f"{dur//60}:{dur%60:02d}" if dur else "noma'lum"
            print(f"   🖼  Thumbnail : {thumb_path or 'topilmadi'}")
            print(f"   ⏱  Uzunlik   : {dur_fmt}")
            print(f"   📐 O'lcham   : {meta['width'] or '?'}x{meta['height'] or '?'}")

            extra = {}
            if meta["duration"]: extra["duration"] = meta["duration"]
            if meta["width"]:    extra["width"]    = meta["width"]
            if meta["height"]:   extra["height"]   = meta["height"]
            if thumb_path:       extra["thumb"]    = thumb_path

            await app.send_video(
                chat_id,
                video              = file_path,
                caption            = caption_text,
                supports_streaming = True,
                progress           = progress,
                **extra,
            )
        else:
            caption_text = tg_meta.get("caption", "").strip() or f"📁 {file_name}"
            await app.send_document(
                chat_id,
                document = file_path,
                caption  = caption_text,
                progress = progress,
            )
    finally:
        if thumb_owned and thumb_path and os.path.exists(thumb_path):
            os.unlink(thumb_path)

    elapsed = time.time() - start
    avg_kb  = file_size / elapsed / 1024
    print(f"\n✅ Yuklandi: {file_name}  "
          f"({elapsed:.0f} sek, o'rtacha: {avg_kb:.0f} KB/s)")
    return True


async def main(files: list, force_doc: bool):
    async with Client(SESSION, api_id=API_ID, api_hash=API_HASH) as app:
        me = await app.get_me()
        print(f"✅ Ulandi: {me.first_name} (@{me.username})")
        print(f"   Manzil: {CHAT_ID}")

        # Maxfiy (private) kanal/guruhlar uchun: Pyrogram raqamli ID orqali
        # yuborishdan oldin o'sha peer keshda bo'lishi kerak. Suhbatlar
        # ro'yxatini bir marta o'qib chiqish shuni ta'minlaydi.
        print("🔎 Suhbatlar ro'yxati o'qilmoqda (maxfiy kanallarni aniqlash uchun)...")
        async for _ in app.get_dialogs():
            pass
        print("   Tayyor.\n")

        ok = 0
        for f in files:
            if await upload_file(app, CHAT_ID, f, force_doc):
                ok += 1

        print(f"\n{'─'*45}")
        print(f"Jami: {ok}/{len(files)} fayl yuklandi.")

        if ok != len(files):
            sys.exit(1)


if __name__ == "__main__":
    args      = [a for a in sys.argv[1:] if not a.startswith("--")]
    force_doc = "--doc" in sys.argv

    if not args:
        print(__doc__)
        sys.exit(1)

    asyncio.run(main(args, force_doc))
