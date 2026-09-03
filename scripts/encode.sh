#!/usr/bin/env bash
# Repo ildizidagi <folder>/seg_*.ts bo'laklarini <folder>.png cover va logo.png
# bilan birlashtirib, Final_<folder>_H264.mp4 sifatida kodlaydi.
#
# Har bir muvaffaqiyatli qayta ishlangan papka nomi PROCESSED_LIST fayliga
# yoziladi — workflow keyinchalik shu ro'yxat asosida manba fayllarni tozalaydi.

set -uo pipefail
shopt -s nullglob

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

PROCESSED_LIST="$REPO_ROOT/.build_processed_folders.txt"
: > "$PROCESSED_LIST"

LOGO="$REPO_ROOT/logo.png"
if [ ! -f "$LOGO" ]; then
    echo "::error::logo.png repo ildizida topilmadi ($LOGO)"
    exit 1
fi

any_found=0

for dir in */ ; do
    folder="${dir%/}"
    cover_img="$REPO_ROOT/${folder}.png"
    [ -f "$cover_img" ] || continue

    cd "$REPO_ROOT/$folder" || continue

    segs=(seg_*.ts)
    if [ ${#segs[@]} -eq 0 ]; then
        cd "$REPO_ROOT"
        continue
    fi

    any_found=1
    echo ""
    echo "=== $folder ishlanmoqda (${#segs[@]} ta bo'lak) ==="

    first_file=$(printf '%s\n' "${segs[@]}" | sort | head -n 1)
    w=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$first_file" | head -n 1 | tr -d '\r')
    h=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$first_file" | head -n 1 | tr -d '\r')

    if [ -z "$w" ] || [ -z "$h" ]; then
        echo "!!! $folder: video o'lchamini aniqlab bo'lmadi, o'tkazib yuborildi !!!"
        cd "$REPO_ROOT"
        continue
    fi

    fps_val=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 "$first_file" | head -n 1 | tr -d '\r')
    if [ -z "$fps_val" ] || [ "$fps_val" = "0/0" ]; then
        fps_val=$(ffprobe -v error -select_streams v:0 -show_entries stream=avg_frame_rate -of default=noprint_wrappers=1:nokey=1 "$first_file" | head -n 1 | tr -d '\r')
    fi
    if [ -z "$fps_val" ] || [ "$fps_val" = "0/0" ]; then
        fps_val="25/1"
    fi

    printf '%s\n' "${segs[@]}" | sort | sed "s/.*/file '&'/" > list.txt

    output="$REPO_ROOT/Final_${folder}_H264.mp4"

    ffmpeg -f concat -safe 0 -i list.txt \
        -loop 1 -t 3 -i "$cover_img" \
        -i "$LOGO" \
        -f lavfi -t 3 -i anullsrc=r=44100:cl=stereo \
        -filter_complex "[1:v]scale=$w:$h:force_original_aspect_ratio=increase,crop=$w:$h,setsar=1,fps=$fps_val[c_v];[0:v]scale=$w:$h,setsar=1,fps=$fps_val[main_v];[2:v]scale=200:-1[l];[c_v][3:a][main_v][0:a]concat=n=2:v=1:a=1[full_v][full_a];[full_v][l]overlay=main_w-overlay_w-20:20:enable='gte(t,3)',format=yuv420p[out_v]" \
        -map "[out_v]" -map "[full_a]" \
        -c:v libx264 -preset medium -crf 18 \
        -g 48 -keyint_min 48 -sc_threshold 0 \
        -b:v 1750k -minrate 1200k -maxrate 2000k -bufsize 3000k \
        -pix_fmt yuv420p -c:a aac -b:a 128k -ar 44100 \
        -movflags +faststart \
        -y -loglevel error "$output"

    status=$?
    rm -f list.txt
    cd "$REPO_ROOT" || exit 1

    if [ "$status" -eq 0 ] && [ -s "$output" ]; then
        echo ">>> $folder H.264 tayyor! <<<"
        echo "$folder" >> "$PROCESSED_LIST"
    else
        echo "!!! $folder uchun kodlash muvaffaqiyatsiz tugadi (ffmpeg exit=$status) !!!"
        rm -f "$output"
    fi
done

if [ "$any_found" -eq 0 ]; then
    echo "Qayta ishlanadigan yangi papka topilmadi (cover.png + seg_*.ts talab qilinadi)."
fi
