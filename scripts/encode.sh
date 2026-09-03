#!/usr/bin/env bash
# Ishlatilishi: encode.sh <epizod_nomi>
#
# Repo tuzilishi:
#   anime/<epizod>/seg_*.ts   — video bo'laklari
#   anipng/<epizod>.png       — shu epizodning cover rasmi
#   anipng/logo.png           — barcha videolarga qo'yiladigan logotip
#
# Faqat BERILGAN <epizod_nomi> uchun anime/<epizod>/ ichidagi bo'laklarni
# cover va logo bilan birlashtirib, repo ildizida
# Final_<epizod>_H264.mp4 yaratadi. Har bir epizod o'zining alohida
# workflow ishida ishlaydi, shuning uchun bu yerda faqat bitta papka bilan
# ishlaymiz — boshqa epizodlarga tegilmaydi.

set -uo pipefail
shopt -s nullglob

FOLDER="${1:-}"
if [ -z "$FOLDER" ]; then
    echo "::error::Ishlatilishi: encode.sh <epizod_nomi>"
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

ANIME_DIR="$REPO_ROOT/anime/$FOLDER"
COVER_IMG="$REPO_ROOT/anipng/${FOLDER}.png"
LOGO="$REPO_ROOT/anipng/logo.png"
OUTPUT="$REPO_ROOT/Final_${FOLDER}_H264.mp4"

if [ ! -f "$LOGO" ]; then
    echo "::error::logo.png topilmadi ($LOGO)"
    exit 1
fi

if [ ! -f "$COVER_IMG" ]; then
    echo "::error::Cover rasm topilmadi ($COVER_IMG)"
    exit 1
fi

if [ ! -d "$ANIME_DIR" ]; then
    echo "::error::anime/$FOLDER papkasi topilmadi"
    exit 1
fi

cd "$ANIME_DIR" || exit 1

segs=(seg_*.ts)
if [ ${#segs[@]} -eq 0 ]; then
    echo "::error::anime/$FOLDER ichida seg_*.ts fayllar topilmadi"
    exit 1
fi

echo "=== $FOLDER ishlanmoqda (${#segs[@]} ta bo'lak) ==="

first_file=$(printf '%s\n' "${segs[@]}" | sort | head -n 1)
w=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$first_file" | head -n 1 | tr -d '\r')
h=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$first_file" | head -n 1 | tr -d '\r')

if [ -z "$w" ] || [ -z "$h" ]; then
    echo "::error::$FOLDER: video o'lchamini aniqlab bo'lmadi"
    exit 1
fi

fps_val=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 "$first_file" | head -n 1 | tr -d '\r')
if [ -z "$fps_val" ] || [ "$fps_val" = "0/0" ]; then
    fps_val=$(ffprobe -v error -select_streams v:0 -show_entries stream=avg_frame_rate -of default=noprint_wrappers=1:nokey=1 "$first_file" | head -n 1 | tr -d '\r')
fi
if [ -z "$fps_val" ] || [ "$fps_val" = "0/0" ]; then
    fps_val="25/1"
fi

printf '%s\n' "${segs[@]}" | sort | sed "s/.*/file '&'/" > list.txt

ffmpeg -f concat -safe 0 -i list.txt \
    -loop 1 -t 3 -i "$COVER_IMG" \
    -i "$LOGO" \
    -f lavfi -t 3 -i anullsrc=r=44100:cl=stereo \
    -filter_complex "[1:v]scale=$w:$h:force_original_aspect_ratio=increase,crop=$w:$h,setsar=1,fps=$fps_val[c_v];[0:v]scale=$w:$h,setsar=1,fps=$fps_val[main_v];[2:v]scale=200:-1[l];[c_v][3:a][main_v][0:a]concat=n=2:v=1:a=1[full_v][full_a];[full_v][l]overlay=main_w-overlay_w-20:20:enable='gte(t,3)',format=yuv420p[out_v]" \
    -map "[out_v]" -map "[full_a]" \
    -c:v libx264 -preset medium -crf 18 \
    -g 48 -keyint_min 48 -sc_threshold 0 \
    -b:v 1750k -minrate 1200k -maxrate 2000k -bufsize 3000k \
    -pix_fmt yuv420p -c:a aac -b:a 128k -ar 44100 \
    -movflags +faststart \
    -y -loglevel error "$OUTPUT"

status=$?
rm -f list.txt
cd "$REPO_ROOT" || exit 1

if [ "$status" -eq 0 ] && [ -s "$OUTPUT" ]; then
    echo ">>> $FOLDER H.264 tayyor! <<<"
    exit 0
else
    echo "::error::$FOLDER uchun kodlash muvaffaqiyatsiz tugadi (ffmpeg exit=$status)"
    rm -f "$OUTPUT"
    exit 1
fi
