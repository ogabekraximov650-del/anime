#!/usr/bin/env python3
"""
Telegram video yuklash skripti (Pyrogram + TgCrypto).

Kanal ishlatilmaydi — video to'g'ridan-to'g'ri belgilangan user'ning
shaxsiy chatiga yuklanadi.

Ishlatish:
    python3 -u telegram_upload.py 2-fasl_7-qism.mp4 --user 12345678 --name 2-fasl_7-qism

  --user  : videoning yuklanadigan foydalanuvchi ID (anipng/<USER_ID>_logo.png
            fayl nomidan olinadi)
  --name  : epizod nomi. Undagi pastki chiziqlar sarlavhada bo'sh joyga
            aylanadi: "2-fasl_7-qism" -> "2-fasl 7-qism"
"""

import os, sys, time, asyncio, subprocess, tempfile
from pathlib import Path
from pyrogram import Client

API_ID   = int(os.environ.get("TG_API_ID", 0))
API_HASH = os.environ.get("TG_API_HASH", "")

SESSION = os.path.join(os.path.dirname(os.path.abspath(__file__)), "pyro_session")

if not API_ID or not API_HASH:
    print("❌ TG_API_ID va TG_API_HASH kerak.")
    sys.exit(1)


def norm_id(raw):
    """Telegram foydalanuvchi ID'sini butun songa aylantiradi."""
    if raw is None:
        return None
    raw = str(raw).strip()
    if not raw:
        return None
    if raw.startswith("@"):
        return raw
    try:
        return int(raw)
    except ValueError:
        return raw


def ffprobe_get(file_path: str, stream_type: str, entry: str) -> str:
    cmd = ["ffprobe", "-v", "error", "-select_streams", stream_type,
           "-show_entries", f"stream={entry}", "-of", "csv=p=0", file_path]
    try:
        out = subprocess.check_output(cmd, stderr=subprocess.DEVNULL).decode().strip()
        return out.split("\n")[0].strip()
    except Exception:
        return ""


def get_video_metadata(file_path: str) -> dict:
    width_s  = ffprobe_get(file_path, "v:0", "width")
    height_s = ffprobe_get(file_path, "v:0", "height")
    duration_s = ""
    try:
        duration_s = subprocess.check_output(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "csv=p=0", file_path],
            stderr=subprocess.DEVNULL).decode().strip()
    except Exception:
        pass

    def to_int(val: str):
        try:
            v = int(float(val))
            return v if v > 0 else None
        except (ValueError, TypeError):
            return None

    return {"width": to_int(width_s), "height": to_int(height_s),
            "duration": to_int(duration_s)}


def get_thumbnail(video_path: str, name: str):
    """(yo'l, biz_yaratdikmi) — cover rasmni topadi yoki videodan kadr oladi."""
    anipng = Path(video_path).resolve().parent / "anipng"
    if anipng.is_dir():
        exact = anipng / f"{name}.png"
        if exact.exists():
            return str(exact), False
        for img in sorted(anipng.glob(f"*_{name}.png")):
            if not img.name.endswith("_logo.png"):
                return str(img), False

    try:
        tmp = tempfile.NamedTemporaryFile(suffix=".jpg", delete=False)
        tmp.close()
        subprocess.run(["ffmpeg", "-y", "-ss", "1", "-i", video_path,
                        "-vframes", "1", "-q:v", "2", tmp.name],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
        if os.path.exists(tmp.name) and os.path.getsize(tmp.name) > 0:
            return tmp.name, True
        os.unlink(tmp.name)
    except Exception:
        pass
    return None, False


def make_progress(label: str):
    """Har 0.5 soniyada yangi qatorda progress chiqaradi (CI logi uchun mos)."""
    start = time.time()
    last = [0.0]

    def callback(current, total):
        now = time.time()
        if now - last[0] < 0.5 and current < total:
            return
        last[0] = now
        elapsed = now - start
        speed = current / elapsed if elapsed > 0 else 0
        pct = current / total * 100 if total else 0
        speed_str = (f"{speed/1024/1024:.2f} MB/s" if speed > 1024 * 1024
                     else f"{speed/1024:.1f} KB/s")
        eta = int((total - current) / speed) if speed > 0 else 0
        print(f"📤 [{label}] {pct:.1f}% | "
              f"{current/1024/1024:.1f}/{total/1024/1024:.1f} MB | "
              f"{speed_str} | ETA {eta//60}:{eta%60:02d}", flush=True)

    return callback


async def main(video: str, user_id, name: str):
    if not os.path.exists(video):
        print(f"❌ Topilmadi: {video}")
        sys.exit(1)

    if not user_id:
        print("❌ --user berilmagan — kanal ishlatilmagani uchun bu shart.")
        sys.exit(1)

    # Pastki chiziqlar sarlavhada bo'sh joyga aylanadi
    caption = name.replace("_", " ").strip()
    file_size = os.path.getsize(video)

    async with Client(SESSION, api_id=API_ID, api_hash=API_HASH) as app:
        me = await app.get_me()
        print(f"✅ Ulandi: {me.first_name} (@{me.username})", flush=True)
        print(f"   Yuboriladigan user: {user_id}", flush=True)
        print(f"   Sarlavha: {caption}", flush=True)

        # Maxfiy/kam faol suhbatlarni peer keshiga olish. Telegram kam faol
        # suhbatlarni avtomatik ARXIVLAYDI (folder_id=1) — standart
        # get_dialogs() (folder_id=0) ularni ko'rmaydi, shuning uchun
        # ikkalasini ham aylanib chiqamiz.
        print("🔎 Suhbatlar ro'yxati o'qilmoqda (asosiy + arxiv)...", flush=True)
        for folder_id in (0, 1):
            async for _ in app.get_dialogs(folder_id=folder_id):
                pass
        print("   Tayyor.", flush=True)

        meta = get_video_metadata(video)
        thumb, thumb_owned = get_thumbnail(video, name)

        dur = meta["duration"]
        dur_txt = (f"{dur//60}:{dur%60:02d}") if dur else "noma'lum"
        print(f"\n📦 {caption}.mp4 | {file_size/1024/1024:.2f} MB | "
              f"{meta['width'] or '?'}x{meta['height'] or '?'} | {dur_txt}", flush=True)
        print(f"🖼  Thumbnail: {os.path.basename(thumb) if thumb else 'yo‘q'}\n", flush=True)

        extra = {}
        if meta["duration"]: extra["duration"] = meta["duration"]
        if meta["width"]:    extra["width"]    = meta["width"]
        if meta["height"]:   extra["height"]   = meta["height"]
        if thumb:            extra["thumb"]    = thumb

        try:
            msg = await app.send_video(
                user_id,
                video=video,
                caption=caption,              # FAQAT toza nom, boshqa hech narsa
                file_name=f"{caption}.mp4",
                supports_streaming=True,
                progress=make_progress(caption),
                **extra,
            )
        finally:
            if thumb_owned and thumb and os.path.exists(thumb):
                os.unlink(thumb)

        print(f"\n✅ {user_id} ga yuborildi (message id: {msg.id})", flush=True)


if __name__ == "__main__":
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        sys.exit(1)

    video = args[0]
    user_raw = None
    name = Path(video).stem

    i = 1
    while i < len(args):
        if args[i] == "--user" and i + 1 < len(args):
            user_raw = args[i + 1]; i += 2
        elif args[i] == "--name" and i + 1 < len(args):
            name = args[i + 1]; i += 2
        else:
            i += 1

    asyncio.run(main(video, norm_id(user_raw), name))
