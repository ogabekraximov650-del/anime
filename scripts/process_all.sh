#!/usr/bin/env bash
# Cloudflare R2 ("anime" bucket) ichidagi BARCHA epizod papkalarni
# BIRIN-KETIN ishlaydi:
#   1) R2'dan shu papkani yuklab oladi
#   2) kodlaydi (encode.sh)
#   3) tayyor videoni Telegramga (logo.png'dagi USER_ID chatiga) yuklaydi
#   4) muvaffaqiyatli bo'lsa — papkani R2'dan o'chirib tashlaydi
#   5) shundan keyingina KEYINGI papkaga o'tadi
#
# Birortasida xatolik chiqsa — shu yerda to'xtaydi (keyingilarga o'tilmaydi),
# shunda muammoli papka R2'da qoladi va keyingi ishga tushirishda undan
# davom etiladi.
#
# R2 bucket tuzilishi (faqat video manba — logo avvalgidek GitHub repo'dagi
# anipng/<USER_ID>_logo.png fayl nomidan olinadi, R2'ga tegishli emas):
#   s3://<BUCKET>/<papka>/seg_*.ts yoki *.mp4  — video manba
#   s3://<BUCKET>/<papka>/*.png                 — cover; FAYL NOMI = epizod nomi
#
# Kerakli muhit o'zgaruvchilari:
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY — R2 API tokeni
#   R2_ENDPOINT                              — https://<account_id>.r2.cloudflarestorage.com
#   R2_BUCKET                                 — bucket nomi (masalan: anime)
set -uo pipefail
shopt -s nullglob

: "${R2_ENDPOINT:?R2_ENDPOINT muhit ozgaruvchisi kerak}"
: "${R2_BUCKET:?R2_BUCKET muhit ozgaruvchisi kerak}"
: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID muhit ozgaruvchisi kerak}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY muhit ozgaruvchisi kerak}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

s3() { aws s3 "$@" --endpoint-url "$R2_ENDPOINT"; }

# --- Logo: GitHub repo'dagi anipng/<USER_ID>_logo.png (checkout'dan
#     allaqachon bor, R2'dan hech narsa yuklanmaydi) ---
if ! ls anipng/*_logo.png >/dev/null 2>&1 && [ ! -f anipng/logo.png ]; then
    echo "::error::Logotip topilmadi (anipng/<user_id>_logo.png repo'da bo'lishi kerak)"
    exit 1
fi

# --- Bucketdagi epizod papkalarini (top-level prefikslar) ro'yxatga olish ---
mapfile -t sorted_folders < <(
    s3 ls "s3://$R2_BUCKET/" | awk '$1 == "PRE" {print $2}' | sed 's#/$##' | sort
)

if [ ${#sorted_folders[@]} -eq 0 ]; then
    echo "ℹ️  R2'da ishlanadigan papka topilmadi."
    exit 0
fi

echo "📋 Ishlanadigan papkalar (${#sorted_folders[@]} ta): ${sorted_folders[*]}"

for FOLDER in "${sorted_folders[@]}"; do
    echo ""
    echo "::group::=== Papka: $FOLDER ==="

    echo "☁️  R2'dan yuklab olinmoqda..."
    rm -rf "anime/$FOLDER"
    mkdir -p "anime/$FOLDER"
    if ! s3 cp "s3://$R2_BUCKET/$FOLDER/" "anime/$FOLDER/" --recursive; then
        echo "::error::$FOLDER: R2'dan yuklab olishda xatolik — jarayon to'xtatildi."
        echo "::endgroup::"
        exit 1
    fi

    if ! bash scripts/encode.sh "$FOLDER"; then
        echo "::error::$FOLDER: kodlashda xatolik — jarayon to'xtatildi."
        echo "::endgroup::"
        exit 1
    fi

    NAME="$(cat .encode_meta_name)"

    logo=$(ls anipng/*_logo.png 2>/dev/null | head -n 1)
    if [ -n "$logo" ]; then
        USER_ID=$(basename "$logo" | sed 's/_logo\.png$//')
    else
        USER_ID=""
    fi
    if [ -z "$USER_ID" ]; then
        echo "::error::User ID topilmadi (_logo/<user_id>_logo.png kerak) — jarayon to'xtatildi."
        echo "::endgroup::"
        exit 1
    fi

    echo "User: $USER_ID | Nom: $NAME"
    if ! python3 -u scripts/telegram_upload.py "${NAME}.mp4" --user "$USER_ID" --name "$NAME"; then
        echo "::error::$FOLDER ($NAME): Telegramga yuklashda xatolik — jarayon to'xtatildi."
        rm -f "${NAME}.mp4" .encode_meta_name
        echo "::endgroup::"
        exit 1
    fi

    echo "🧹 $FOLDER R2'dan o'chirilmoqda..."
    s3 rm "s3://$R2_BUCKET/$FOLDER/" --recursive
    rm -rf "anime/$FOLDER"
    rm -f "${NAME}.mp4" .encode_meta_name

    echo "✅ $FOLDER ($NAME) tayyor va yuborildi."
    echo "::endgroup::"
done

echo ""
echo "🎉 Barcha papkalar muvaffaqiyatli ishlandi."
