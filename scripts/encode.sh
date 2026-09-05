#!/usr/bin/env bash
# Ishlatilishi: encode.sh <papka_nomi>
#   <papka_nomi> = [<TRIM_SEC>_]<raqam>  — masalan: 7, 30_7 (30 soniya kesish bilan)
#     TRIM_SEC (ixtiyoriy) — video boshidan necha soniya kesib tashlanadi.
#
# Epizodning ASL NOMI papka ichidagi cover .png faylning nomidan olinadi
# (masalan anime/7/2-fasl_367-qism.png -> nom: "2-fasl_367-qism"), CHIQISH
# fayli va Telegram sarlavhasi ham shu nom bilan bo'ladi. Papka nomining
# o'zi (raqam) faqat ichki tashkiliy maqsadda ishlatiladi.
#
# Kanal ishlatilmaydi — video anipng/<USER_ID>_logo.png fayl nomidan
# olingan USER_ID'ning shaxsiy chatiga to'g'ridan-to'g'ri yuboriladi.
#
# Manba ikki turdagi bo'lishi mumkin — IKKALASI HAM bir xil natija beradi
# (3 soniyalik cover-intro + TRIM'dan keyingi asosiy video + intro tugagach
# chiqadigan logotip):
#   anime/<papka>/seg_*.ts — video bo'laklari (concat qilinadi)
#   anime/<papka>/*.mp4    — tayyor video (concat'siz, to'g'ridan-to'g'ri)
#   anime/<papka>/*.png    — 3 soniyalik cover-intro rasm; NOMI = epizod nomi
#
# Audio har doim standart AAC, 2 kanal (stereo), 44.1kHz'ga qayta kodlanadi.

set -uo pipefail
shopt -s nullglob

FOLDER="${1:-}"
if [ -z "$FOLDER" ]; then
    echo "::error::Ishlatilishi: encode.sh <papka_nomi>"
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

# --- Papka nomini ajratish: [<TRIM>_]<raqam> ---
IFS='_' read -r p1 rest <<< "$FOLDER"
TRIM_SEC=0
if [[ "$p1" =~ ^[0-9]+$ ]] && [ ${#p1} -le 4 ] && [ -n "$rest" ] && [[ "$rest" =~ ^[0-9]+$ ]]; then
    TRIM_SEC="$p1"
fi

ANIME_DIR="$REPO_ROOT/anime/$FOLDER"

# --- Logotip: anipng/<USER_ID>_logo.png (havola shu ID'ga yuboriladi) ---
logos=("$REPO_ROOT"/anipng/*_logo.png)
if [ ${#logos[@]} -eq 0 ]; then
    logos=("$REPO_ROOT"/anipng/logo.png)
fi
if [ ${#logos[@]} -eq 0 ] || [ ! -f "${logos[0]}" ]; then
    echo "::error::Logotip topilmadi (anipng/<user_id>_logo.png)"
    exit 1
fi
LOGO="${logos[0]}"

if [ ! -d "$ANIME_DIR" ]; then
    echo "::error::anime/$FOLDER papkasi topilmadi"
    exit 1
fi

# --- Cover: anime/<papka>/*.png — FAYL NOMI = epizod nomi ---
covers=("$ANIME_DIR"/*.png)
if [ ${#covers[@]} -eq 0 ] || [ ! -f "${covers[0]}" ]; then
    echo "::error::Cover rasm topilmadi (anime/$FOLDER ichida .png fayl bo'lishi kerak)"
    exit 1
fi
COVER_IMG="${covers[0]}"
CLEAN_NAME="$(basename "$COVER_IMG" .png)"

echo "$CLEAN_NAME" > "$REPO_ROOT/.encode_meta_name"
OUTPUT="$REPO_ROOT/${CLEAN_NAME}.mp4"

echo "=== $CLEAN_NAME ishlanmoqda (kesish: ${TRIM_SEC}s) ==="
echo "    Cover : $(basename "$COVER_IMG")"
echo "    Logo  : $(basename "$LOGO")"
echo "    Natija: ${CLEAN_NAME}.mp4"

cd "$ANIME_DIR" || exit 1

mp4s=(*.mp4)
segs=(seg_*.ts)

run_progress() {
    local total_ref="$1"
    local last_ms=0 f=0 fps_now=0 br="0kbits/s" sz=0 tm="00:00:00" sp="?" us=0
    while IFS='=' read -r key value; do
        value="${value//$'\r'/}"
        case "$key" in
            frame)        f="$value" ;;
            fps)          fps_now="$value" ;;
            bitrate)      br="$value" ;;
            total_size)   sz="$value" ;;
            out_time_us)  us="$value" ;;
            out_time)     tm="${value:0:8}" ;;
            speed)        sp="$value" ;;
            progress)
                now_ms=$(date +%s%3N)
                if [ "$value" = "end" ] || [ $((now_ms - last_ms)) -ge 500 ]; then
                    last_ms=$now_ms
                    fmt_sz=$(awk "BEGIN {printf \"%.1f\", ${sz:-0}/1048576}")
                    clean_br=$(echo "${br:-0kbits/s}" | tr -d 'kbits/s' | xargs)
                    if [ "${total_ref:-0}" -gt 0 ] 2>/dev/null; then
                        pct=$(awk "BEGIN {p=(${us:-0}/1000000)/$total_ref*100; if(p>100)p=100; printf \"%.1f\", p}")
                    else
                        pct="?"
                    fi
                    echo "🎬 [$CLEAN_NAME] ${pct}% | frm:${f:-0} | vaqt:${tm:-00:00:00} | fps:${fps_now:-0} | br:${clean_br}kbps | tezlik:${sp:-?}"
                fi
                ;;
        esac
    done
}

if [ ${#mp4s[@]} -gt 0 ]; then
    # ─────────── MP4 REJIMI: tayyor video, lekin ts rejimi bilan BIR XIL natija ───────────
    SRC_MAIN="${mp4s[0]}"
    echo "    Manba : $SRC_MAIN (tayyor video)"

    w=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$SRC_MAIN" | head -n 1 | tr -d '\r')
    h=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$SRC_MAIN" | head -n 1 | tr -d '\r')
    if [ -z "$w" ] || [ -z "$h" ]; then
        echo "::error::$CLEAN_NAME: video o'lchamini aniqlab bo'lmadi"
        exit 1
    fi

    fps_val=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 "$SRC_MAIN" | head -n 1 | tr -d '\r')
    if [ -z "$fps_val" ] || [ "$fps_val" = "0/0" ]; then
        fps_val=$(ffprobe -v error -select_streams v:0 -show_entries stream=avg_frame_rate -of default=noprint_wrappers=1:nokey=1 "$SRC_MAIN" | head -n 1 | tr -d '\r')
    fi
    [ -z "$fps_val" ] || [ "$fps_val" = "0/0" ] && fps_val="25/1"

    total_sec=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$SRC_MAIN" 2>/dev/null | cut -d. -f1)
    [[ "$total_sec" =~ ^[0-9]+$ ]] || total_sec=0
    remain_sec=$(( total_sec - TRIM_SEC ))
    [ "$remain_sec" -lt 1 ] && remain_sec=1

    stdbuf -oL ffmpeg -ss "$TRIM_SEC" -i "$SRC_MAIN" \
        -loop 1 -t 3 -i "$COVER_IMG" \
        -i "$LOGO" \
        -f lavfi -t 3 -i anullsrc=r=44100:cl=stereo \
        -filter_complex "[1:v]scale=$w:$h:force_original_aspect_ratio=increase,crop=$w:$h,setsar=1,fps=$fps_val[c_v];[0:v]scale=$w:$h,setsar=1,fps=$fps_val[main_v];[2:v]scale=200:-1[l];[c_v][3:a][main_v][0:a]concat=n=2:v=1:a=1[full_v][full_a];[full_v][l]overlay=main_w-overlay_w-20:20:enable='gte(t,3)',format=yuv420p[out_v]" \
        -map "[out_v]" -map "[full_a]" \
        -c:v libx264 -preset medium -crf 18 \
        -g 48 -keyint_min 48 -sc_threshold 0 \
        -b:v 1750k -minrate 1200k -maxrate 2000k -bufsize 3000k \
        -pix_fmt yuv420p -c:a aac -ac 2 -b:a 128k -ar 44100 \
        -movflags +faststart \
        -progress pipe:1 -nostats -y -loglevel error "$OUTPUT" | run_progress "$remain_sec"
    status=$?

elif [ ${#segs[@]} -gt 0 ]; then
    # ─────────── TS REJIMI: bo'laklar concat qilinadi, keyin xuddi shu quvur ───────────
    echo "    Manba : ${#segs[@]} ta seg_*.ts"

    first_file=$(printf '%s\n' "${segs[@]}" | sort | head -n 1)
    w=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$first_file" | head -n 1 | tr -d '\r')
    h=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$first_file" | head -n 1 | tr -d '\r')
    if [ -z "$w" ] || [ -z "$h" ]; then
        echo "::error::$CLEAN_NAME: video o'lchamini aniqlab bo'lmadi"
        exit 1
    fi

    fps_val=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 "$first_file" | head -n 1 | tr -d '\r')
    if [ -z "$fps_val" ] || [ "$fps_val" = "0/0" ]; then
        fps_val=$(ffprobe -v error -select_streams v:0 -show_entries stream=avg_frame_rate -of default=noprint_wrappers=1:nokey=1 "$first_file" | head -n 1 | tr -d '\r')
    fi
    [ -z "$fps_val" ] || [ "$fps_val" = "0/0" ] && fps_val="25/1"

    printf '%s\n' "${segs[@]}" | sort | sed "s/.*/file '&'/" > list.txt

    total_ts_kb=$(du -ck seg_*.ts | grep total | awk '{print $1}')
    total_ts_mb=$(awk "BEGIN {printf \"%.1f\", $total_ts_kb/1024}")

    total_sec=$(ffprobe -v error -f concat -safe 0 -show_entries format=duration -of csv=p=0 list.txt 2>/dev/null | head -n 1 | cut -d. -f1)
    [[ "$total_sec" =~ ^[0-9]+$ ]] || total_sec=0
    remain_sec=$(( total_sec - TRIM_SEC ))
    [ "$remain_sec" -lt 1 ] && remain_sec=1

    stdbuf -oL ffmpeg -ss "$TRIM_SEC" -f concat -safe 0 -i list.txt \
        -loop 1 -t 3 -i "$COVER_IMG" \
        -i "$LOGO" \
        -f lavfi -t 3 -i anullsrc=r=44100:cl=stereo \
        -filter_complex "[1:v]scale=$w:$h:force_original_aspect_ratio=increase,crop=$w:$h,setsar=1,fps=$fps_val[c_v];[0:v]scale=$w:$h,setsar=1,fps=$fps_val[main_v];[2:v]scale=200:-1[l];[c_v][3:a][main_v][0:a]concat=n=2:v=1:a=1[full_v][full_a];[full_v][l]overlay=main_w-overlay_w-20:20:enable='gte(t,3)',format=yuv420p[out_v]" \
        -map "[out_v]" -map "[full_a]" \
        -c:v libx264 -preset medium -crf 18 \
        -g 48 -keyint_min 48 -sc_threshold 0 \
        -b:v 1750k -minrate 1200k -maxrate 2000k -bufsize 3000k \
        -pix_fmt yuv420p -c:a aac -ac 2 -b:a 128k -ar 44100 \
        -movflags +faststart \
        -progress pipe:1 -nostats -y -loglevel error "$OUTPUT" | run_progress "$remain_sec"
    status=$?
    rm -f list.txt
else
    echo "::error::anime/$FOLDER ichida na seg_*.ts, na *.mp4 topilmadi"
    exit 1
fi

cd "$REPO_ROOT" || exit 1

if [ "$status" -eq 0 ] && [ -s "$OUTPUT" ]; then
    out_mb=$(awk "BEGIN {printf \"%.1f\", $(stat -c%s "$OUTPUT")/1048576}")
    echo ">>> $CLEAN_NAME tayyor! (${out_mb} MB) <<<"
    exit 0
else
    echo "::error::$CLEAN_NAME uchun kodlash muvaffaqiyatsiz tugadi (ffmpeg exit=$status)"
    rm -f "$OUTPUT"
    exit 1
fi
