#!/usr/bin/env bash
# Cloudflare R2 "aniraxuz" bucket'i ichidagi BARCHA epizod papkalarni
# BIRIN-KETIN H.265 (libx265) bilan kodlaydi:
#   1) R2'dan (aniraxuz bucket) shu papkani yuklab oladi
#   2) kodlaydi (encode_h265.sh) — videoga rasm/logotip QO'SHILMAYDI va
#      manbaning sifatiga qarab bir nechta sifat tayyorlanadi
#      (1080p manba -> 1080p/720p/480p/360p, 720p manba -> 720p/480p/360p,
#       480p -> 480p/360p, 360p -> faqat 360p)
#   3) tayyor videolarni KATTADAN KICHIKKA ketma-ket akkountning O'ZINING
#      Saqlangan xabarlariga (Saved Messages) yuboradi. Video tagidagi
#      sarlavha — BUCKETDAGI PAPKA NOMI va sifat.
#   4) hammasi muvaffaqiyatli yuborilgach — papkani R2'dan o'chirib tashlaydi
#   5) shundan keyingina KEYINGI papkaga o'tadi
#
# Birortasida xatolik chiqsa — shu yerda to'xtaydi (keyingilarga o'tilmaydi),
# shunda muammoli papka R2'da qoladi va keyingi ishga tushirishda undan
# davom etiladi.
#
# R2 bucket tuzilishi:
#   s3://<BUCKET>/<papka>/seg_*.ts yoki *.mp4  — video manba
# Epizod nomi PAPKA NOMIDAN olinadi (TRIM prefiksi hisobga olinmaydi,
# pastki chiziqlar bo'sh joyga aylanadi). Papka ichidagi .png fayllar
# butunlay e'tiborga olinmaydi.
#
# Kerakli muhit o'zgaruvchilari:
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY — R2 API tokeni
#   R2_ENDPOINT                              — https://<account_id>.r2.cloudflarestorage.com
#   R2_BUCKET (ixtiyoriy)                    — bucket nomi, standart: aniraxuz
#   TG_TARGET (ixtiyoriy)                    — qabul qiluvchi. Standart "me" —
#       ya'ni sessiya egasining O'ZINING Saqlangan xabarlari (Saved Messages).
#       Logotip fayli endi umuman kerak emas.
set -uo pipefail
shopt -s nullglob

: "${R2_ENDPOINT:?R2_ENDPOINT muhit ozgaruvchisi kerak}"
R2_BUCKET="${R2_BUCKET:-aniraxuz}"
: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID muhit ozgaruvchisi kerak}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY muhit ozgaruvchisi kerak}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

s3() { aws s3 "$@" --endpoint-url "$R2_ENDPOINT"; }

# --- Qabul qiluvchi: akkountning o'zining Saqlangan xabarlari ---
# "me" — Pyrogram'da sessiya egasining o'zi, ya'ni Saved Messages.
TG_TARGET="${TG_TARGET:-me}"
echo "📨 Yuboriladigan joy: $TG_TARGET (Saqlangan xabarlar)"
echo "🪣 R2 bucket: $R2_BUCKET"

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
    echo "::group::=== Papka: $FOLDER (H.265) ==="

    echo "☁️  R2'dan yuklab olinmoqda..."
    rm -rf "anime/$FOLDER"
    mkdir -p "anime/$FOLDER"
    if ! s3 cp "s3://$R2_BUCKET/$FOLDER/" "anime/$FOLDER/" --recursive; then
        echo "::error::$FOLDER: R2'dan yuklab olishda xatolik — jarayon to'xtatildi."
        echo "::endgroup::"
        exit 1
    fi

    if ! bash scripts/encode_h265.sh "$FOLDER"; then
        echo "::error::$FOLDER: H.265 kodlashda xatolik — jarayon to'xtatildi."
        echo "::endgroup::"
        exit 1
    fi

    NAME="$(cat .encode_meta_name)"
    echo "Qabul qiluvchi: $TG_TARGET | Nom: $NAME"

    # Tayyor sifatlarni kattadan kichikka ketma-ket yuklaymiz. Har biri
    # yuborilgach darhol o'chiriladi (runner diskini bo'shatish uchun).
    upload_failed=0
    while IFS=$'\t' read -r LABEL FILE; do
        [ -n "$FILE" ] || continue
        echo "── $NAME ($LABEL) yuklanmoqda..."
        if ! python3 -u scripts/telegram_upload.py "$FILE" \
                --user "$TG_TARGET" \
                --name "${NAME} ${LABEL}" \
                --caption "$(printf '%s\n%s' "$NAME" "$LABEL")"; then
            echo "::error::$FOLDER ($NAME $LABEL): Telegramga yuklashda xatolik — jarayon to'xtatildi."
            upload_failed=1
            break
        fi
        rm -f "$FILE"
    done < .encode_meta_files

    if [ "$upload_failed" -ne 0 ]; then
        while IFS=$'\t' read -r _ FILE; do
            [ -n "$FILE" ] && rm -f "$FILE"
        done < .encode_meta_files
        rm -f .encode_meta_name .encode_meta_files
        echo "::endgroup::"
        exit 1
    fi

    echo "🧹 $FOLDER R2'dan o'chirilmoqda..."
    s3 rm "s3://$R2_BUCKET/$FOLDER/" --recursive
    rm -rf "anime/$FOLDER"
    rm -f .encode_meta_name .encode_meta_files

    echo "✅ $FOLDER ($NAME) — barcha sifatlar tayyor va yuborildi."
    echo "::endgroup::"
done

echo ""
echo "🎉 Barcha papkalar muvaffaqiyatli H.265 bilan ishlandi."
