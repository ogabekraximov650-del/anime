#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
#  Anime papkasidagi BARCHA yangi epizodlarni Cloudflare R2'ga yuklaydi
#  (GitHub'ga endi hech qanday video/rasm push qilinmaydi).
#
#  Kodlash GitHub'dagi BITTA ".github/workflows/encode.yml" workflow
#  orqali amalga oshiriladi — u R2'dagi papkalarni BIRIN-KETIN yuklab
#  olib kodlaydi, Telegramga yuklaydi, so'ng o'sha papkani R2'dan
#  o'chirib KEYINGISIGA o'tadi (bittasi tugamasdan ikkinchisiga o'tmaydi).
#
#  Papka nomi ixtiyoriy — raqam yoki har qanday matn (masalan: 7, ep1,
#  anything). Epizodning haqiqiy nomi — papka ichidagi cover .png faylning
#  nomidan olinadi (masalan: anime/7/2-fasl_367-qism.png). Kesish kerak
#  bo'lsa papka nomi oldiga "<TRIM_SEC>_" qo'shiladi (masalan: 30_7).
#
#  BIR MARTA kerak bo'ladigan tayyorgarlik:
#    1) aws-cli o'rnatish (Termux'da):
#         pkg install python -y && pip install awscli
#    2) R2 ma'lumotlarini saqlash — ~/.r2_credentials fayliga:
#         echo 'ACCESS_KEY_ID=xxxxxxxx'                                > ~/.r2_credentials
#         echo 'SECRET_ACCESS_KEY=xxxxxxxx'                           >> ~/.r2_credentials
#         echo 'ENDPOINT=https://<ACCOUNT_ID>.r2.cloudflarestorage.com' >> ~/.r2_credentials
#         chmod 600 ~/.r2_credentials
#
#  KEYIN HAR SAFAR — shu bitta qator, boshqa hech narsa kerak emas:
#      bash upload.sh
#          -> anime/ ichidagi hali yuklanmagan BARCHA papkalarni topib,
#             hammasini R2'ga yuklaydi.
#
#      bash upload.sh <papka_nomi>
#          -> faqat shu bitta papkani yuklaydi.
#
#  Yuklangandan keyin GitHub'da "Actions" bo'limidan "Encode" workflow'ini
#  qo'lda ishga tushiring ("Run workflow") — u R2'dagi HAMMA papkalarni
#  birin-ketin ishlab chiqadi.
#
#  ⚠️  ~/.r2_credentials git repo'dan TASHQARIDA (Termux $HOME'da)
#  saqlanadi — hech qachon GitHub'ga yuborilmaydi.
# ============================================================

set -uo pipefail

# ───────────────────────── SOZLAMALAR ─────────────────────────
R2_CREDS_FILE="$HOME/.r2_credentials"
BUCKET="anime"

ANIME_SRC="/storage/emulated/0/anime"       # ts/mp4 fayllar + cover .png shu yerda (har epizod papkasi ichida)
ANIPNG_SRC="/storage/emulated/0/anipng"     # faqat logo.png / <user_id>_logo.png shu yerda
STATE_FILE="$HOME/.anime_uploaded.log"      # allaqachon yuklangan epizodlar ro'yxati
# ────────────────────────────────────────────────────────────

if [ ! -f "$R2_CREDS_FILE" ]; then
    echo "❌ $R2_CREDS_FILE topilmadi. Namuna uchun yuqoridagi izohga qarang."
    exit 1
fi
set -a
# shellcheck disable=SC1090
source "$R2_CREDS_FILE"
set +a

: "${ACCESS_KEY_ID:?$R2_CREDS_FILE ichida ACCESS_KEY_ID topilmadi}"
: "${SECRET_ACCESS_KEY:?$R2_CREDS_FILE ichida SECRET_ACCESS_KEY topilmadi}"
: "${ENDPOINT:?$R2_CREDS_FILE ichida ENDPOINT topilmadi}"

export AWS_ACCESS_KEY_ID="$ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$SECRET_ACCESS_KEY"

s3() { aws s3 "$@" --endpoint-url "$ENDPOINT"; }

if ! command -v aws >/dev/null 2>&1; then
    echo "❌ aws-cli topilmadi. O'rnating: pkg install python -y && pip install awscli"
    exit 1
fi

if ! ls "$ANIPNG_SRC"/*_logo.png >/dev/null 2>&1 && [ ! -f "$ANIPNG_SRC/logo.png" ]; then
    echo "❌ Logo topilmadi: $ANIPNG_SRC/<user_id>_logo.png (yoki logo.png)"
    exit 1
fi

touch "$STATE_FILE"

# --- Logo(lar)ni har doim R2'ga sinxronlash (arzon, tez) ---
echo "☁️  Logo yuklanmoqda..."
for logo in "$ANIPNG_SRC"/*_logo.png "$ANIPNG_SRC/logo.png"; do
    [ -f "$logo" ] || continue
    s3 cp "$logo" "s3://$BUCKET/_logo/$(basename "$logo")" --only-show-errors
done

# --- Yuklanadigan epizodlar ro'yxatini aniqlash ---
TO_PROCESS=()
ONLY_FOLDER="${1:-}"

if [ -n "$ONLY_FOLDER" ]; then
    TO_PROCESS=("$ONLY_FOLDER")
else
    for dir in "$ANIME_SRC"/*/ ; do
        [ -d "$dir" ] || continue
        name="$(basename "$dir")"
        grep -qxF "$name" "$STATE_FILE" && continue   # allaqachon yuklangan
        TO_PROCESS+=("$name")
    done
fi

if [ ${#TO_PROCESS[@]} -eq 0 ]; then
    echo "ℹ️  Yuklanadigan yangi epizod topilmadi."
    exit 0
fi

echo "📋 Yuklanadigan epizodlar (${#TO_PROCESS[@]} ta): ${TO_PROCESS[*]}"

DONE=()
for FOLDER in "${TO_PROCESS[@]}"; do
    SRC_FOLDER="$ANIME_SRC/$FOLDER"

    if [ ! -d "$SRC_FOLDER" ]; then
        echo "⚠️  $FOLDER: papka topilmadi, o'tkazib yuborildi"
        continue
    fi
    if ! ls "$SRC_FOLDER"/seg_*.ts >/dev/null 2>&1 && ! ls "$SRC_FOLDER"/*.mp4 >/dev/null 2>&1; then
        echo "⚠️  $FOLDER: seg_*.ts yoki *.mp4 topilmadi, o'tkazib yuborildi"
        continue
    fi
    if ! ls "$SRC_FOLDER"/*.png >/dev/null 2>&1; then
        echo "⚠️  $FOLDER: cover .png topilmadi (epizod nomi shundan olinadi), o'tkazib yuborildi"
        continue
    fi

    echo "☁️  $FOLDER R2'ga yuklanmoqda (papkadagi BARCHA fayllar)..."
    attempt=1
    ok=0
    while [ "$attempt" -le 4 ]; do
        if s3 cp "$SRC_FOLDER" "s3://$BUCKET/$FOLDER/" --recursive; then
            ok=1
            break
        fi
        [ "$attempt" -ge 4 ] && break
        wait_s=$(( attempt * 5 ))
        echo "⏳ $FOLDER: muvaffaqiyatsiz, ${wait_s}s dan keyin qayta urinish ($attempt/3)..."
        sleep "$wait_s"
        attempt=$((attempt + 1))
    done

    if [ "$ok" -ne 1 ]; then
        echo "❌ $FOLDER: yuklashda xatolik (4 urinishdan keyin), o'tkazib yuborildi"
        continue
    fi

    # --- R2'da haqiqatan ham borligini tasdiqlash (yuklash "tugadi" deb
    #     faqat shundan keyin hisoblanadi) ---
    remote_count=$(s3 ls "s3://$BUCKET/$FOLDER/" --recursive 2>/dev/null | wc -l)
    local_count=$(ls -1 "$SRC_FOLDER" | wc -l)
    if [ "$remote_count" -lt "$local_count" ]; then
        echo "❌ $FOLDER: R2'da tasdiqlanmadi (mahalliy: $local_count, R2: $remote_count), o'tkazib yuborildi"
        continue
    fi

    echo "✅ $FOLDER tasdiqlandi (R2'da $remote_count fayl)."
    DONE+=("$FOLDER")
done

if [ ${#DONE[@]} -eq 0 ]; then
    echo "ℹ️  Yuklashga yaroqli/yuklangan epizod yo'q."
    exit 0
fi

# --- Muvaffaqiyatli yuklanganlarni mahalliy ro'yxatga yozish ---
printf '%s\n' "${DONE[@]}" >> "$STATE_FILE"

echo "✅ Yuklandi: ${DONE[*]}"
echo "   Endi GitHub'dagi 'Actions' -> 'Encode' -> 'Run workflow' tugmasini bosing —"
echo "   u R2'dagi HAMMA papkalarni birin-ketin kodlab, Telegramga yuklaydi."
