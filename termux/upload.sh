#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
#  Anime papkasidagi BARCHA yangi epizodlarni GitHub'ga yuklaydi,
#  har biri uchun ALOHIDA "faqat shu epizodni kodlaydigan" workflow
#  yaratadi va bittasi push qiladi.
#
#  BIR MARTA (token saqlash):
#      echo 'tokeningiz' > ~/.anime_token && chmod 600 ~/.anime_token
#
#  KEYIN HAR SAFAR — shu bitta qator, boshqa hech narsa kerak emas:
#      bash upload.sh
#          -> anime/ ichidagi hali yuklanmagan BARCHA papkalarni topib,
#             hammasini bitta push bilan yuklaydi.
#
#      bash upload.sh <epizod_nomi>
#          -> faqat shu bitta epizodni yuklaydi.
#
#  ⚠️  TOKEN XAVFSIZLIGI: tokeningizni bu faylning ICHIGA yozmang —
#  bu fayl git tomonidan kuzatiladi va GitHub'ga push bo'ladi (GitHub
#  buni avtomatik aniqlab, tokenni darhol bekor qiladi). Token faqat
#  ~/.anime_token faylida (git repo'dan TASHQARIDA, Termux $HOME'da)
#  saqlanadi — bu fayl hech qachon GitHub'ga yuborilmaydi.
# ============================================================

set -uo pipefail

# ───────────────────────── SOZLAMALAR ─────────────────────────
GITHUB_USERNAME="ogabekraximov650-del"
GITHUB_REPO="anime"
TOKEN_FILE="$HOME/.anime_token"
GITHUB_TOKEN="${GITHUB_TOKEN:-$(cat "$TOKEN_FILE" 2>/dev/null || true)}"

REPO_DIR="$HOME/anime-repo"                 # git klon shu yerda (Termux ichida)
ANIME_SRC="/storage/emulated/0/anime"       # ts fayllar + cover .png shu yerda (har epizod papkasi ichida)
ANIPNG_SRC="/storage/emulated/0/anipng"     # faqat logo.png shu yerda
STATE_FILE="$HOME/.anime_uploaded.log"      # allaqachon yuklangan epizodlar ro'yxati
# ────────────────────────────────────────────────────────────

if [ -z "$GITHUB_TOKEN" ]; then
    echo "❌ Token topilmadi."
    echo "   Bir marta saqlang: echo 'tokeningiz' > ~/.anime_token && chmod 600 ~/.anime_token"
    echo "   Shundan keyin shunchaki: bash upload.sh"
    exit 1
fi

if [ ! -f "$ANIPNG_SRC/logo.png" ]; then
    echo "❌ logo.png topilmadi: $ANIPNG_SRC/logo.png"
    exit 1
fi

touch "$STATE_FILE"

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

REMOTE_URL="https://${GITHUB_USERNAME}:${GITHUB_TOKEN}@github.com/${GITHUB_USERNAME}/${GITHUB_REPO}.git"

LOG="$(mktemp 2>/dev/null || echo "/data/data/com.termux/files/usr/tmp/upload_push.$$.log")"
cleanup() { rm -f "$LOG"; }
trap cleanup EXIT

# Log'da tasodifan token qolib ketmasligi uchun — chop etishdan oldin har doim shu orqali filtrlanadi.
show_log() {
    sed "s#${GITHUB_TOKEN}#***#g" "$LOG"
}

# --- Repo klonlash yoki yangilash ---
echo "🔄 Repo tayyorlanmoqda..."
if [ -d "$REPO_DIR/.git" ]; then
    if ! git -C "$REPO_DIR" remote set-url origin "$REMOTE_URL" >"$LOG" 2>&1; then
        show_log; exit 1
    fi
    if ! git -C "$REPO_DIR" pull --ff-only origin main >"$LOG" 2>&1; then
        echo "❌ 'git pull' muvaffaqiyatsiz tugadi:"
        show_log
        exit 1
    fi
else
    rm -rf "$REPO_DIR"
    if ! git clone "$REMOTE_URL" "$REPO_DIR" >"$LOG" 2>&1; then
        echo "❌ 'git clone' muvaffaqiyatsiz tugadi:"
        show_log
        exit 1
    fi
fi

TEMPLATE="$REPO_DIR/scripts/workflow-template.yml"
if [ ! -f "$TEMPLATE" ]; then
    echo "❌ Shablon topilmadi: $TEMPLATE (repo to'g'ri klonlanganini tekshiring)"
    exit 1
fi

cd "$REPO_DIR"

# --- Har bir epizodni tayyorlash ---
DONE=()
for FOLDER in "${TO_PROCESS[@]}"; do
    SRC_FOLDER="$ANIME_SRC/$FOLDER"

    if [ ! -d "$SRC_FOLDER" ] || ! ls "$SRC_FOLDER"/seg_*.ts >/dev/null 2>&1; then
        echo "⚠️  $FOLDER: seg_*.ts topilmadi, o'tkazib yuborildi"
        continue
    fi
    if ! ls "$SRC_FOLDER"/*.png >/dev/null 2>&1; then
        echo "⚠️  $FOLDER: cover .png topilmadi (ts fayllar bilan bir papkada bo'lishi kerak), o'tkazib yuborildi"
        continue
    fi

    echo "📁 $FOLDER ko'chirilmoqda..."
    mkdir -p "anime/$FOLDER" "anipng" ".github/workflows"
    cp -f "$SRC_FOLDER"/seg_*.ts "anime/$FOLDER/"
    cp -f "$SRC_FOLDER"/*.png "anime/$FOLDER/"
    cp -f "$ANIPNG_SRC/logo.png" "anipng/logo.png"

    echo "🛠  Workflow yaratilmoqda: .github/workflows/${FOLDER}.yml"
    sed "s/__FOLDER__/$FOLDER/g" "$TEMPLATE" > ".github/workflows/${FOLDER}.yml"

    git add "anime/$FOLDER" ".github/workflows/${FOLDER}.yml"
    DONE+=("$FOLDER")
done

git add "anipng/logo.png" 2>/dev/null || true

if [ ${#DONE[@]} -eq 0 ]; then
    echo "ℹ️  Yuklashga yaroqli epizod topilmadi."
    exit 0
fi

if git diff --cached --quiet; then
    echo "ℹ️  Yangi o'zgarish yo'q, push qilinmadi."
    exit 0
fi

git commit -m "epizodlar: ${DONE[*]}" >"$LOG" 2>&1 || { show_log; exit 1; }

# --- Push (tarmoq xatosida 4 martagacha qayta urinish) ---
echo "🚀 Push qilinmoqda..."
attempt=1
until git push origin main >"$LOG" 2>&1; do
    if [ "$attempt" -ge 4 ]; then
        echo "❌ Push muvaffaqiyatsiz tugadi (4 urinishdan keyin):"
        show_log
        exit 1
    fi
    wait_s=$(( attempt * 5 ))
    echo "⏳ Push muvaffaqiyatsiz, ${wait_s}s dan keyin qayta urinish ($attempt/3)..."
    sleep "$wait_s"
    attempt=$((attempt + 1))
done

# --- Muvaffaqiyatli yuklanganlarni mahalliy ro'yxatga yozish ---
printf '%s\n' "${DONE[@]}" >> "$STATE_FILE"

echo "✅ Push qilindi: ${DONE[*]}"
echo "   GitHub Actions har biri uchun alohida ishga tushadi."
echo "   Kuzatish: https://github.com/${GITHUB_USERNAME}/${GITHUB_REPO}/actions"
