#!/usr/bin/env bash
# Ishlatilishi: encode_h265.sh <papka_nomi>
#   <papka_nomi> = [<TRIM_SEC>_]<epizod_nomi>  — masalan: 2-fasl_367-qism,
#     30_2-fasl_367-qism (boshidan 30 soniya kesib tashlanadi).
#
# BU SKRIPT ENCODE.SH'DAN FARQ QILADI — videoga HECH QANDAY RASM YOKI
# LOGOTIP QO'SHILMAYDI:
#   • cover-intro (3 soniyalik rasm) YO'Q
#   • burchakdagi logotip overlay YO'Q
#   • papka ichidagi .png fayllar butunlay e'tiborga olinmaydi.
#
# Manba ikki turdagi bo'lishi mumkin:
#   anime/<papka>/seg_*.ts — video bo'laklari (concat qilinadi)
#   anime/<papka>/*.mp4    — tayyor video (concat'siz, to'g'ridan-to'g'ri)
#
# ─── KO'P SIFATLI (LADDER) KODLASH ───
# Manbaning balandligiga qarab sifatlar ro'yxati avtomatik tanlanadi —
# HECH QACHON upscale qilinmaydi:
#   1080p manba -> 1080p, 720p, 480p, 360p
#    720p manba ->        720p, 480p, 360p
#    480p manba ->              480p, 360p
#    360p manba ->                    360p
# 1080p'dan baland manba (1440p, 2160p) 1080p'ga tushiriladi — undan
# yuqorisi tayyorlanmaydi. Nostandart balandlik (masalan 1070p) eng yuqori
# sifat sifatida o'z holicha, scale'siz kodlanadi.
#
# HAMMA SIFAT BITTA ffmpeg buyrug'ida, BITTA asl manbadan chiqariladi
# (split filtri) — shuning uchun:
#   • manba faqat bir marta decode qilinadi (tezroq),
#   • hech bir sifat boshqasidan qayta siqilmaydi (ikki karra siqilish yo'q),
#   • hamma sifatning DAVOMIYLIGI mikrosekundigacha bir xil bo'ladi.
#
# ─── SIQISH ───
# Bitrate chegaralari YO'Q — maqsad fayl hajmini kichik qilish, shuning
# uchun sifatga asoslangan CRF rejimi ishlatiladi. CRF balandlikka qarab
# tanlanadi (past sifat pleyerda cho'zilib ko'rsatiladi, shuning uchun unga
# biroz past CRF beriladi):
#   >=1080p -> BASE      | >=720p -> BASE-1
#   >=480p  -> BASE-2    | <480p  -> BASE-3
#   H265_CRF    (ixtiyoriy) — BASE qiymati, standart 30. KATTA qiymat =
#                             KICHIK fayl, sifat esa pasayadi.
#   H265_PRESET (ixtiyoriy) — standart medium. "slow" yana kichikroq fayl
#                             beradi, lekin kodlash ancha sekin ishlaydi.
#
# ─── CHIQISH ───
#   <epizod_nomi>_1080p.mp4, <epizod_nomi>_720p.mp4, ...
# Va ikkita meta fayl (process_all_h265.sh o'qiydi):
#   .encode_meta_name  — Telegram sarlavhasi uchun nom (papka nomidan,
#                        TRIM prefiksi olib tashlangan, "_" -> bo'sh joy)
#   .encode_meta_files — "<sifat><TAB><fayl>" qatorlari, kattadan kichikka
#
# Audio har doim standart AAC, 2 kanal (stereo), 44.1kHz.

set -uo pipefail
shopt -s nullglob

FOLDER="${1:-}"
if [ -z "$FOLDER" ]; then
    echo "::error::Ishlatilishi: encode_h265.sh <papka_nomi>"
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

CRF_BASE="${H265_CRF:-30}"
PRESET="${H265_PRESET:-medium}"

# Ladder'ning eng yuqori cho'qqisi va undan pastdagi standart qadamlar
MAX_HEIGHT=1080
STD_STEPS=(720 480 360)

# --- Papka nomini ajratish: [<TRIM>_]<epizod_nomi> ---
IFS='_' read -r p1 rest <<< "$FOLDER"
TRIM_SEC=0
BASE_NAME="$FOLDER"
if [[ "$p1" =~ ^[0-9]+$ ]] && [ ${#p1} -le 4 ] && [ -n "$rest" ]; then
    TRIM_SEC="$p1"
    BASE_NAME="$rest"
fi

# Telegram sarlavhasi: papka nomi, pastki chiziqlar bo'sh joyga aylanadi
CAPTION_BASE="${BASE_NAME//_/ }"

ANIME_DIR="$REPO_ROOT/anime/$FOLDER"
if [ ! -d "$ANIME_DIR" ]; then
    echo "::error::anime/$FOLDER papkasi topilmadi"
    exit 1
fi

cd "$ANIME_DIR" || exit 1

mp4s=(*.mp4)
segs=(seg_*.ts)

probe_duration() {
    ffprobe -v error -show_entries format=duration -of csv=p=0 "$1" 2>/dev/null | cut -d. -f1
}

if [ ${#mp4s[@]} -gt 0 ]; then
    SRC_MAIN="${mp4s[0]}"
    SRC_LABEL="$SRC_MAIN (tayyor video)"
    INPUT_ARGS=(-i "$SRC_MAIN")
    PROBE_FILE="$SRC_MAIN"
    total_sec="$(probe_duration "$SRC_MAIN")"
elif [ ${#segs[@]} -gt 0 ]; then
    SRC_LABEL="${#segs[@]} ta seg_*.ts"
    printf '%s\n' "${segs[@]}" | sort | sed "s/.*/file '&'/" > list.txt
    INPUT_ARGS=(-f concat -safe 0 -i list.txt)
    PROBE_FILE="$(printf '%s\n' "${segs[@]}" | sort | head -n 1)"
    # ffprobe concat ro'yxatidan umumiy davomiylikni ololmaydi ("N/A"),
    # shuning uchun har bir bo'lakning davomiyligi qo'shiladi.
    total_sec=$(
        for s in "${segs[@]}"; do probe_duration "$s"; done \
            | awk '{ if ($1 ~ /^[0-9.]+$/) t += $1 } END { printf "%d", t }'
    )
else
    echo "::error::anime/$FOLDER ichida na seg_*.ts, na *.mp4 topilmadi"
    exit 1
fi

[[ "$total_sec" =~ ^[0-9]+$ ]] || total_sec=0
remain_sec=$(( total_sec - TRIM_SEC ))
[ "$remain_sec" -lt 1 ] && remain_sec=1

# --- Manbaning o'lchami ---
SRC_H=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$PROBE_FILE" | head -n 1 | tr -d '\r')
SRC_W=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$PROBE_FILE" | head -n 1 | tr -d '\r')
if ! [[ "$SRC_H" =~ ^[0-9]+$ ]] || [ "$SRC_H" -lt 1 ]; then
    echo "::error::$FOLDER: video balandligini aniqlab bo'lmadi"
    rm -f list.txt
    exit 1
fi

# --- Audio bor-yo'qligini tekshirish ---
if [ -z "$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_type -of csv=p=0 "$PROBE_FILE" 2>/dev/null)" ]; then
    echo "::error::$FOLDER: audio yo'lakcha topilmadi"
    rm -f list.txt
    exit 1
fi

# --- Ladder'ni qurish: "<balandlik>:<native|scale>" ---
LADDER=()
if [ "$SRC_H" -le "$MAX_HEIGHT" ]; then
    LADDER+=("${SRC_H}:native")
    for s in "${STD_STEPS[@]}"; do
        [ "$s" -lt "$SRC_H" ] && LADDER+=("${s}:scale")
    done
else
    LADDER+=("${MAX_HEIGHT}:scale")
    for s in "${STD_STEPS[@]}"; do
        LADDER+=("${s}:scale")
    done
fi
N=${#LADDER[@]}

crf_for_height() {
    local h="$1"
    if   [ "$h" -ge 1080 ]; then echo "$CRF_BASE"
    elif [ "$h" -ge 720  ]; then echo "$(( CRF_BASE - 1 ))"
    elif [ "$h" -ge 480  ]; then echo "$(( CRF_BASE - 2 ))"
    else                         echo "$(( CRF_BASE - 3 ))"
    fi
}

abr_for_height() {
    [ "$1" -ge 720 ] && echo "128k" || echo "96k"
}

echo "=== $CAPTION_BASE — H.265 ko'p sifatli kodlash ==="
echo "    Manba  : $SRC_LABEL (${SRC_W}x${SRC_H})"
echo "    Kesish : ${TRIM_SEC}s | davomiylik ~${remain_sec}s"
echo "    Preset : $PRESET | CRF BASE: $CRF_BASE | bitrate chegarasi yo'q"
echo "    Rasm/logotip: qo'shilmaydi"
printf '    Sifatlar (%d ta):' "$N"
for e in "${LADDER[@]}"; do printf ' %sp' "${e%%:*}"; done
echo ""

# ─── Filtergraph ───
# Kesish kerak bo'lsa filtr ichida (trim/atrim) bajariladi — input "-ss"
# concat demuxer bilan birga audioga shovqin qo'shadi.
VTRIM=""
ATRIM=""
if [ "$TRIM_SEC" -gt 0 ]; then
    VTRIM="trim=start=${TRIM_SEC},setpts=PTS-STARTPTS,"
    ATRIM="atrim=start=${TRIM_SEC},asetpts=PTS-STARTPTS,"
fi

vsplit=""
asplit=""
for i in $(seq 0 $((N - 1))); do
    vsplit+="[s${i}]"
    asplit+="[a${i}]"
done

FC="[0:v]${VTRIM}split=${N}${vsplit};"
for i in $(seq 0 $((N - 1))); do
    entry="${LADDER[$i]}"
    h="${entry%%:*}"
    mode="${entry##*:}"
    if [ "$mode" = "native" ]; then
        FC+="[s${i}]null[v${i}];"
    else
        FC+="[s${i}]scale=-2:${h}:flags=lanczos[v${i}];"
    fi
done
FC+="[0:a]${ATRIM}asplit=${N}${asplit}"

# ─── Chiqish argumentlari ───
OUT_ARGS=()
OUT_FILES=()
OUT_LABELS=()
for i in $(seq 0 $((N - 1))); do
    entry="${LADDER[$i]}"
    h="${entry%%:*}"
    label="${h}p"
    out="$REPO_ROOT/${BASE_NAME}_${label}.mp4"
    OUT_FILES+=("$out")
    OUT_LABELS+=("$label")
    OUT_ARGS+=(
        -map "[v${i}]" -map "[a${i}]"
        -c:v libx265 -preset "$PRESET" -crf "$(crf_for_height "$h")"
        -x265-params log-level=error
        -pix_fmt yuv420p -tag:v hvc1
        -c:a aac -ac 2 -b:a "$(abr_for_height "$h")" -ar 44100
        -movflags +faststart
        -y "$out"
    )
done

run_progress() {
    local total_ref="$1"
    local last_ms=0 f=0 fps_now=0 sz=0 tm="00:00:00" sp="?" us=0
    while IFS='=' read -r key value; do
        value="${value//$'\r'/}"
        case "$key" in
            frame)        f="$value" ;;
            fps)          fps_now="$value" ;;
            total_size)   sz="$value" ;;
            out_time_us)  us="$value" ;;
            out_time)     tm="${value:0:8}" ;;
            speed)        sp="$value" ;;
            progress)
                now_ms=$(date +%s%3N)
                if [ "$value" = "end" ] || [ $((now_ms - last_ms)) -ge 500 ]; then
                    last_ms=$now_ms
                    if [ "${total_ref:-0}" -gt 0 ] 2>/dev/null; then
                        pct=$(awk "BEGIN {p=(${us:-0}/1000000)/$total_ref*100; if(p>100)p=100; printf \"%.1f\", p}")
                    else
                        pct="?"
                    fi
                    mb=$(awk "BEGIN {printf \"%.1f\", ${sz:-0}/1048576}")
                    echo "🎬 [$CAPTION_BASE] ${pct}% | frm:${f:-0} | vaqt:${tm:-00:00:00} | fps:${fps_now:-0} | jami:${mb}MB | tezlik:${sp:-?}"
                fi
                ;;
        esac
    done
}

stdbuf -oL ffmpeg "${INPUT_ARGS[@]}" \
    -filter_complex "$FC" \
    "${OUT_ARGS[@]}" \
    -progress pipe:1 -nostats -loglevel error | run_progress "$remain_sec"
status="${PIPESTATUS[0]}"

rm -f list.txt
cd "$REPO_ROOT" || exit 1

if [ "$status" -ne 0 ]; then
    echo "::error::$CAPTION_BASE: H.265 kodlash muvaffaqiyatsiz tugadi (ffmpeg exit=$status)"
    rm -f "${OUT_FILES[@]}"
    exit 1
fi

# --- Hamma chiqish fayli bor va bo'sh emasligini tekshirish ---
: > "$REPO_ROOT/.encode_meta_files"
echo ""
for i in $(seq 0 $((N - 1))); do
    out="${OUT_FILES[$i]}"
    label="${OUT_LABELS[$i]}"
    if [ ! -s "$out" ]; then
        echo "::error::$CAPTION_BASE: $label fayli yaratilmadi"
        rm -f "${OUT_FILES[@]}" "$REPO_ROOT/.encode_meta_files"
        exit 1
    fi
    mb=$(awk -v b="$(stat -c%s "$out")" 'BEGIN {printf "%.1f", b/1048576}')
    dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$out")
    res=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x "$out")
    echo "    ✔ $label — $res | ${mb} MB | ${dur}s"
    printf '%s\t%s\n' "$label" "$(basename "$out")" >> "$REPO_ROOT/.encode_meta_files"
done

echo "$CAPTION_BASE" > "$REPO_ROOT/.encode_meta_name"
echo ">>> $CAPTION_BASE tayyor — $N ta sifat (H.265) <<<"
exit 0
