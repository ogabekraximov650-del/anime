#!/usr/bin/env python3
"""
Telegram video yuklash skripti (Pyrogram + TgCrypto).

Ishlatish:
    python3 -u telegram_upload.py 2-fasl_7-qism.mp4 --chat 1003716499451 --user 12345678 --name 2-fasl_7-qism

  --chat  : video yuboriladigan kanal/guruh ID (papka nomidan olinadi)
  --user  : yuborilgan videoning HAVOLASI jo'natiladigan foydalanuvchi ID
            (anipng/<USER_ID>_logo.png nomidan olinadi)
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
    """Telegram ID'ni to'g'ri shaklga keltiradi.

    Kanal/supergroup ID'lari '-100...' shaklida bo'ladi. Papka nomiga minus
    belgisini yozish noqulay bo'lgani uchun, '100' bilan boshlanadigan uzun
    raqamga minus avtomatik qo'shiladi.
    """
    if raw is None:
        return None
    raw = str(raw).strip()
    if not raw:
        return None
    if raw.startswith("@"):
        return raw
    if raw.startswith("-"):
        return int(raw)
    if raw.startswith("100") and len(raw) >= 13:
        return int("-" + raw)
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
        for img in sorted(anipng.glob(f"*_{name}.png")):
            if not img.name.endswith("_logo.png"):
                return str(img), False
        exact = anipng / f"{name}.png"
        if exact.exists():
            return str(exact), False

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


async def main(video: str, chat_id, user_id, name: str):
    if not os.path.exists(video):
        print(f"❌ Topilmadi: {video}")
        sys.exit(1)

    # Pastki chiziqlar sarlavhada bo'sh joyga aylanadi
    caption = name.replace("_", " ").strip()
    file_size = os.path.getsize(video)

    async with Client(SESSION, api_id=API_ID, api_hash=API_HASH) as app:
        me = await app.get_me()
        print(f"✅ Ulandi: {me.first_name} (@{me.username})", flush=True)
        print(f"   Kanal: {chat_id} | Havola uchun user: {user_id or 'yo‘q'}", flush=True)
        print(f"   Sarlavha: {caption}", flush=True)

        # Maxfiy/kam faol kanal-guruhlarni peer keshiga olish. Telegram kam
        # faol suhbatlarni avtomatik ARXIVLAYDI (folder_id=1) — standart
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
                chat_id,
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

        print(f"\n✅ Kanalga yuborildi (message id: {msg.id})", flush=True)

        # --- Havolani olish ---
        link = None
        try:
            link = msg.link
        except Exception:
            link = None
        if not link:
            cid = str(msg.chat.id)
            if cid.startswith("-100"):
                link = f"https://t.me/c/{cid[4:]}/{msg.id}"
        print(f"🔗 Havola: {link or 'olinmadi'}", flush=True)

        # --- Havolani foydalanuvchiga yuborish ---
        if user_id and link:
            try:
                await app.send_message(user_id, f"{caption}\n{link}")
                print(f"✉️  Havola {user_id} ga yuborildi.", flush=True)
            except Exception as e:
                print(f"⚠️  Havolani {user_id} ga yuborib bo'lmadi: {e}", flush=True)
        elif not user_id:
            print("ℹ️  User ID berilmagan — havola yuborilmadi.", flush=True)


if __name__ == "__main__":
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        sys.exit(1)

    video = args[0]
    chat_raw = user_raw = None
    name = Path(video).stem

    i = 1
    while i < len(args):
        if args[i] == "--chat" and i + 1 < len(args):
            chat_raw = args[i + 1]; i += 2
        elif args[i] == "--user" and i + 1 < len(args):
            user_raw = args[i + 1]; i += 2
        elif args[i] == "--name" and i + 1 < len(args):
            name = args[i + 1]; i += 2
        else:
            i += 1

    if chat_raw is None:
        chat_raw = os.environ.get("TG_CHAT_ID", "me")

    asyncio.run(main(video, norm_id(chat_raw), norm_id(user_raw), name))
