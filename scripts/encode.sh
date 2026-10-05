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

# --- Papka nomini ajratish: [<TRIM>_]<xohlagan_nom> ---
# Papka nomining o'zi ixtiyoriy — raqam, so'z, har qanday narsa bo'lishi
# mumkin, faqat TRIM_SEC prefiksi (bor bo'lsa) shu shaklda tanib olinadi.
IFS='_' read -r p1 rest <<< "$FOLDER"
TRIM_SEC=0
if [[ "$p1" =~ ^[0-9]+$ ]] && [ ${#p1} -le 4 ] && [ -n "$rest" ]; then
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

# --- Video kodek: VIDEO_CODEC=h265 bo'lsa libx265, aks holda (standart) libx264 ---
# H.265 sozlamalari "H265 encode" workflow'i bilan bir xil: sof CRF rejimi
# (bitrate chegarasi yo'q, majburiy keyframe yo'q) — fayl hajmi kichik
# bo'lishi uchun. CRF balandlikka qarab: >=1080p BASE | >=720p BASE-1 |
# >=480p BASE-2 | qolgani BASE-3. Audio: >=720p 128k, aks holda 96k.
# VENC/ABR video o'lchami (h) aniqlangach set_venc orqali to'ldiriladi.
set_venc() {
    if [ "${VIDEO_CODEC:-h264}" = "h265" ]; then
        local base="${H265_CRF:-30}" crf
        if   [ "$h" -ge 1080 ]; then crf="$base"
        elif [ "$h" -ge 720  ]; then crf=$(( base - 1 ))
        elif [ "$h" -ge 480  ]; then crf=$(( base - 2 ))
        else                         crf=$(( base - 3 ))
        fi
        [ "$h" -ge 720 ] && ABR="128k" || ABR="96k"
        # hvc1 tegi — Telegram/iOS'da HEVC video to'g'ri ijro etilishi uchun.
        VENC=(-c:v libx265 -preset "${H265_PRESET:-medium}" -crf "$crf"
              -x265-params log-level=error -tag:v hvc1)
        echo "    Kodek : H.265 (libx265, ${h}p, CRF $crf, audio $ABR, bitrate chegarasi yo'q)"
    else
        ABR="128k"
        VENC=(-c:v libx264 -preset medium -crf 18
              -g 48 -keyint_min 48 -sc_threshold 0
              -b:v 1750k -minrate 1200k -maxrate 2000k -bufsize 3000k)
        echo "    Kodek : H.264 (libx264)"
    fi
}

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
                    echo "🎬 [$CLEAN_NAME] ${pct}% | frm:${f:-0} | vaqt:${tm:-00:00:00} | fps:${fps_now:-0} | br:${clean_br}kbps | ${fmt_sz}MB | tezlik:${sp:-?}"
                fi
                ;;
        esac
    done
}

# Filtergraph'ni quradi. TRIM_SEC > 0 bo'lsa kesish INPUT -ss orqali emas,
# filtr ichida (trim/atrim) bajariladi — sabab: "-ss" concat demuxer bilan
# birga ishlatilganda audioga butun davomiylik bo'ylab doimiy keng polosali
# shovqin ("shivirlash") qo'shadi. Bitta faylda -ss zararsiz, aynan concat
# bilan birga muammo tug'diradi, shuning uchun umuman ishlatilmaydi.
build_filter() {
    local vtrim="" atrim="" amain="[0:a]"
    if [ "$TRIM_SEC" -gt 0 ]; then
        vtrim="trim=start=${TRIM_SEC},setpts=PTS-STARTPTS,"
        atrim="[0:a]atrim=start=${TRIM_SEC},asetpts=PTS-STARTPTS[main_a];"
        amain="[main_a]"
    fi
    printf '%s' \
"[1:v]scale=$w:$h:force_original_aspect_ratio=increase,crop=$w:$h,setsar=1,fps=$fps_val[c_v];\
[0:v]${vtrim}scale=$w:$h,setsar=1,fps=$fps_val[main_v];\
[2:v]scale=200:-1[l];\
${atrim}\
[c_v][3:a][main_v]${amain}concat=n=2:v=1:a=1[full_v][full_a];\
[full_v][l]overlay=main_w-overlay_w-20:20:enable='gte(t,3)',format=yuv420p[out_v]"
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

    SRC_BYTES=$(stat -c%s "$SRC_MAIN")
    set_venc
    FILTER="$(build_filter)"
    stdbuf -oL ffmpeg -i "$SRC_MAIN" \
        -loop 1 -t 3 -i "$COVER_IMG" \
        -i "$LOGO" \
        -f lavfi -t 3 -i anullsrc=r=44100:cl=stereo \
        -filter_complex "$FILTER" \
        -map "[out_v]" -map "[full_a]" \
        "${VENC[@]}" \
        -pix_fmt yuv420p -c:a aac -ac 2 -b:a "$ABR" -ar 44100 \
        -movflags +faststart \
        -progress pipe:1 -nostats -y -loglevel error "$OUTPUT" | run_progress "$(( remain_sec + 3 ))"
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

    # Umumiy davomiylik: ffprobe concat ro'yxatidan buni ololmaydi ("N/A"
    # qaytaradi), shuning uchun har bir bo'lakning davomiyligi qo'shiladi.
    total_sec=$(
        for s in "${segs[@]}"; do
            ffprobe -v error -show_entries format=duration -of csv=p=0 "$s" 2>/dev/null
        done | awk '{ if ($1 ~ /^[0-9.]+$/) t += $1 } END { printf "%d", t }'
    )
    [[ "$total_sec" =~ ^[0-9]+$ ]] || total_sec=0
    remain_sec=$(( total_sec - TRIM_SEC ))
    [ "$remain_sec" -lt 1 ] && remain_sec=1

    SRC_BYTES=$(for s in "${segs[@]}"; do stat -c%s "$s"; done | awk '{ t += $1 } END { printf "%d", t }')
    set_venc
    FILTER="$(build_filter)"
    stdbuf -oL ffmpeg -f concat -safe 0 -i list.txt \
        -loop 1 -t 3 -i "$COVER_IMG" \
        -i "$LOGO" \
        -f lavfi -t 3 -i anullsrc=r=44100:cl=stereo \
        -filter_complex "$FILTER" \
        -map "[out_v]" -map "[full_a]" \
        "${VENC[@]}" \
        -pix_fmt yuv420p -c:a aac -ac 2 -b:a "$ABR" -ar 44100 \
        -movflags +faststart \
        -progress pipe:1 -nostats -y -loglevel error "$OUTPUT" | run_progress "$(( remain_sec + 3 ))"
    status=$?
    rm -f list.txt
else
    echo "::error::anime/$FOLDER ichida na seg_*.ts, na *.mp4 topilmadi"
    exit 1
fi

cd "$REPO_ROOT" || exit 1

if [ "$status" -eq 0 ] && [ -s "$OUTPUT" ]; then
    out_bytes=$(stat -c%s "$OUTPUT")
    out_mb=$(awk -v b="$out_bytes" 'BEGIN {printf "%.1f", b/1048576}')
    src_mb=$(awk -v b="${SRC_BYTES:-0}" 'BEGIN {printf "%.1f", b/1048576}')
    out_dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUTPUT" 2>/dev/null | head -n 1)
    out_kbps=$(awk -v b="$out_bytes" -v d="${out_dur:-0}" 'BEGIN { if (d + 0 > 0) printf "%.0f", b*8/d/1000; else printf "?" }')
    pct=$(awk -v o="$out_bytes" -v s="${SRC_BYTES:-0}" 'BEGIN { if (s + 0 > 0) printf "%.0f%%", o/s*100; else printf "?" }')
    echo ">>> $CLEAN_NAME tayyor! (${out_mb} MB) <<<"
    echo "    Hajm   : asl ${src_mb} MB -> ${out_mb} MB (${pct})"
    echo "    Bitrate: ${out_kbps} kbps jami (video+audio) | ${w}x${h}"
    # ::notice:: — run sahifasining "Annotations" bo'limida ham ko'rinadi.
    echo "::notice title=${CLEAN_NAME}::${src_mb} MB -> ${out_mb} MB (${pct}) | ${out_kbps} kbps | ${w}x${h}"
    exit 0
else
    echo "::error::$CLEAN_NAME uchun kodlash muvaffaqiyatsiz tugadi (ffmpeg exit=$status)"
    rm -f "$OUTPUT"
    exit 1
fi
