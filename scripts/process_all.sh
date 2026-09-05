#!/usr/bin/env bash
# anime/ ichidagi BARCHA papkalarni BIRIN-KETIN ishlaydi:
#   1) shu papkani kodlaydi (encode.sh)
#   2) tayyor videoni Telegramga (logo.png'dagi USER_ID chatiga) yuklaydi
#   3) muvaffaqiyatli bo'lsa — papkani o'chirib, commit+push qiladi
#   4) shundan keyingina KEYINGI papkaga o'tadi
#
# Birortasida xatolik chiqsa — shu yerda to'xtaydi (keyingilarga o'tilmaydi),
# shunda muammoli papka repo'da qoladi va keyingi ishga tushirishda undan
# davom etiladi.
set -uo pipefail
shopt -s nullglob

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

folders=(anime/*/)
if [ ${#folders[@]} -eq 0 ]; then
    echo "ℹ️  anime/ ichida ishlanadigan papka topilmadi."
    exit 0
fi

# --- Papkalarni haqiqiy epizod raqami bo'yicha tartiblash ---
# (papka nomi "raqam" yoki "TRIM_raqam" bo'lishi mumkin — tartib TRIM'siz
# haqiqiy raqamga qarab olinadi, shunda 30_7 bilan 7 bir xil o'ringa tushadi)
sort_input=""
for f in "${folders[@]}"; do
    name="$(basename "$f")"
    IFS='_' read -r p1 rest <<< "$name"
    if [[ "$p1" =~ ^[0-9]+$ ]] && [ -n "$rest" ] && [[ "$rest" =~ ^[0-9]+$ ]]; then
        order_key="$rest"
    else
        order_key="$p1"
    fi
    sort_input+="$order_key"$'\t'"$name"$'\n'
done

mapfile -t sorted_folders < <(printf '%s' "$sort_input" | sort -n -k1,1 -t $'\t' | cut -f2)

echo "📋 Ishlanadigan papkalar (${#sorted_folders[@]} ta): ${sorted_folders[*]}"

git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"

for FOLDER in "${sorted_folders[@]}"; do
    echo ""
    echo "::group::=== Papka: $FOLDER ==="

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
        echo "::error::User ID topilmadi (anipng/<user_id>_logo.png kerak) — jarayon to'xtatildi."
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

    echo "🧹 $FOLDER tozalanmoqda va commit qilinmoqda..."
    rm -rf "anime/$FOLDER"
    rm -f "${NAME}.mp4" .encode_meta_name

    git add -A
    if ! git diff --cached --quiet; then
        git commit -m "chore: $NAME yuklandi va tozalandi [skip encode]"
        git push
    fi

    echo "✅ $FOLDER ($NAME) tayyor va yuborildi."
    echo "::endgroup::"
done

echo ""
echo "🎉 Barcha papkalar muvaffaqiyatli ishlandi."
