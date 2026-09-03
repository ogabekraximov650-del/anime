#!/data/data/com.termux/files/usr/bin/bash
# Termux'dan bitta epizodni "anime" repo'siga yuklaydi.
#
# Ishlatilishi:
#   bash termux/upload.sh <epizod_nomi>
#   masalan: bash termux/upload.sh aybsiz_8
#
# Bu skript:
#   1. anime/<epizod_nomi>/ (seg_*.ts) va anipng/<epizod_nomi>.png + logo.png
#      fayllarini manba papkalardan repo klonига ko'chiradi;
#   2. scripts/workflow-template.yml shablonidan
#      .github/workflows/<epizod_nomi>.yml yasaydi — bu fayl FAQAT shu
#      epizodni kodlaydi, boshqa epizodlarga tegmaydi;
#   3. hammasini bitta commit qilib push qiladi.
#
# Manba papkalar joylashuvini pastdagi o'zgaruvchilarda o'zingizga moslang
# (kerak bo'lsa muhit o'zgaruvchisi bilan ustidan yozib qo'yish ham mumkin:
#   ANIME_SRC=/boshqa/yol ANIPNG_SRC=/boshqa/yol bash termux/upload.sh nomi ).

set -euo pipefail

FOLDER="${1:-}"
if [ -z "$FOLDER" ]; then
    echo "Ishlatilishi: bash termux/upload.sh <epizod_nomi>"
    exit 1
fi

# --- Manba papkalar (telefoningizdagi asl fayllar) ---
ANIME_SRC="${ANIME_SRC:-/storage/emulated/0/anime}"
ANIPNG_SRC="${ANIPNG_SRC:-/storage/emulated/0/anipng}"

# --- Repo klon manzili (bu skript joylashgan repo ildizi) ---
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SRC_FOLDER="$ANIME_SRC/$FOLDER"
SRC_COVER="$ANIPNG_SRC/${FOLDER}.png"
SRC_LOGO="$ANIPNG_SRC/logo.png"

if [ ! -d "$SRC_FOLDER" ]; then
    echo "❌ Topilmadi: $SRC_FOLDER"
    exit 1
fi
if ! ls "$SRC_FOLDER"/seg_*.ts >/dev/null 2>&1; then
    echo "❌ $SRC_FOLDER ichida seg_*.ts fayllar yo'q"
    exit 1
fi
if [ ! -f "$SRC_COVER" ]; then
    echo "❌ Cover topilmadi: $SRC_COVER"
    exit 1
fi
if [ ! -f "$SRC_LOGO" ]; then
    echo "❌ logo.png topilmadi: $SRC_LOGO"
    exit 1
fi

TEMPLATE="$REPO_ROOT/scripts/workflow-template.yml"
if [ ! -f "$TEMPLATE" ]; then
    echo "❌ Shablon topilmadi: $TEMPLATE"
    exit 1
fi

cd "$REPO_ROOT"

echo "🔄 Repo yangilanmoqda..."
git pull --ff-only origin main

echo "📁 $FOLDER ko'chirilmoqda..."
mkdir -p "anime/$FOLDER" "anipng" ".github/workflows"
cp -f "$SRC_FOLDER"/seg_*.ts "anime/$FOLDER/"
cp -f "$SRC_COVER" "anipng/${FOLDER}.png"
cp -f "$SRC_LOGO" "anipng/logo.png"

echo "🛠  Workflow yaratilmoqda: .github/workflows/${FOLDER}.yml"
sed "s/__FOLDER__/$FOLDER/g" "$TEMPLATE" > ".github/workflows/${FOLDER}.yml"

git add "anime/$FOLDER" "anipng/${FOLDER}.png" "anipng/logo.png" ".github/workflows/${FOLDER}.yml"

if git diff --cached --quiet; then
    echo "ℹ️  Yangi o'zgarish yo'q, push qilinmadi."
    exit 0
fi

git commit -m "epizod: $FOLDER"

echo "🚀 Push qilinmoqda..."
attempt=1
until git push origin main; do
    if [ "$attempt" -ge 4 ]; then
        echo "❌ Push muvaffaqiyatsiz tugadi (4 urinishdan keyin)."
        exit 1
    fi
    wait_s=$(( attempt * 5 ))
    echo "⏳ Push muvaffaqiyatsiz, ${wait_s}s dan keyin qayta urinish ($attempt/3)..."
    sleep "$wait_s"
    attempt=$((attempt + 1))
done

echo "✅ $FOLDER push qilindi. GitHub Actions avtomatik ishga tushadi."
