#!/usr/bin/env bash
# Ishlatilishi: encode_h265.sh <papka_nomi>
#   <papka_nomi> = [<TRIM_SEC>_]<xohlagan_nom>  — masalan: 7, 30_7
#     TRIM_SEC (ixtiyoriy) — video boshidan necha soniya kesib tashlanadi.
#
# BU SKRIPT ENCODE.SH'DAN FARQ QILADI — videoga HECH QANDAY RASM YOKI
# LOGOTIP QO'SHILMAYDI:
#   • cover-intro (3 soniyalik rasm) YO'Q
#   • burchakdagi logotip overlay YO'Q
#   • shunchaki manba video H.265 (libx265) bilan qayta kodlanadi.
#
# Manba ikki turdagi bo'lishi mumkin:
#   anime/<papka>/seg_*.ts — video bo'laklari (concat qilinadi)
#   anime/<papka>/*.mp4    — tayyor video (concat'siz, to'g'ridan-to'g'ri)
#
# Chiqish fayl nomi: papka ichida .png bo'lsa — shu faylning nomi (faqat NOM
# sifatida, rasm videoga qo'yilmaydi), bo'lmasa — papka nomining o'zi.
#
# Bitrate CHEGARALARI YO'Q — maqsad fayl hajmini imkon qadar kichik qilish.
# Shu sababli qat'iy bitrate (b:v/minrate/maxrate/bufsize) o'rniga sifatga
# asoslangan CRF rejimi ishlatiladi: x265 har bir sahnaga qancha bitrate
# kerak bo'lsa shuncha beradi, sodda sahnalarda esa bitrate juda pastga
# tushadi — natijada fayl ancha kichik chiqadi.
#   H265_CRF    (ixtiyoriy) — standart 30. Qiymat KATTA bo'lsa fayl KICHIK
#                             boladi (masalan 32, 34), sifat esa pasayadi.
#   H265_PRESET (ixtiyoriy) — standart medium. "slow" yana kichikroq fayl
#                             beradi, lekin kodlash ancha sekin ishlaydi.
# Keyframe intervali ham majburan qisqartirilmaydi (x265 o'zi tanlaydi) —
# bu ham fayl hajmini kamaytiradi.
#
# Audio har doim standart AAC, 2 kanal (stereo), 44.1kHz'ga qayta kodlanadi.

set -uo pipefail
shopt -s nullglob

FOLDER="${1:-}"
if [ -z "$FOLDER" ]; then
    echo "::error::Ishlatilishi: encode_h265.sh <papka_nomi>"
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

# --- Siqish sozlamalari: bitrate chegaralari yo'q, CRF ishlatiladi ---
# CRF katta bo'lsa -> fayl kichik. Kerak bo'lsa muhit o'zgaruvchisi bilan
# o'zgartirish mumkin.
CRF="${H265_CRF:-30}"
PRESET="${H265_PRESET:-medium}"

# --- Papka nomini ajratish: [<TRIM>_]<xohlagan_nom> ---
IFS='_' read -r p1 rest <<< "$FOLDER"
TRIM_SEC=0
if [[ "$p1" =~ ^[0-9]+$ ]] && [ ${#p1} -le 4 ] && [ -n "$rest" ]; then
    TRIM_SEC="$p1"
fi

ANIME_DIR="$REPO_ROOT/anime/$FOLDER"
if [ ! -d "$ANIME_DIR" ]; then
    echo "::error::anime/$FOLDER papkasi topilmadi"
    exit 1
fi

# --- Epizod nomi: .png bor bo'lsa uning nomidan, aks holda papka nomidan.
#     Rasmning O'ZI videoga QO'SHILMAYDI — faqat nom uchun o'qiladi. ---
covers=("$ANIME_DIR"/*.png)
if [ ${#covers[@]} -gt 0 ] && [ -f "${covers[0]}" ]; then
    CLEAN_NAME="$(basename "${covers[0]}" .png)"
else
    CLEAN_NAME="$FOLDER"
fi

echo "$CLEAN_NAME" > "$REPO_ROOT/.encode_meta_name"
OUTPUT="$REPO_ROOT/${CLEAN_NAME}.mp4"

echo "=== $CLEAN_NAME H.265 bilan ishlanmoqda (kesish: ${TRIM_SEC}s) ==="
echo "    Kodek : libx265 (rasm/logotip qo'shilmaydi)"
echo "    Siqish: CRF ${CRF} | preset ${PRESET} | bitrate chegarasi yo'q"
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

# Kesish kerak bo'lsa filtr ichida (trim/atrim) bajariladi — input "-ss"
# concat demuxer bilan birga audioga shovqin qo'shadi, shuning uchun
# umuman ishlatilmaydi. Kesish kerak bo'lmasa filtr ham ishlatilmaydi.
build_map_args() {
    if [ "$TRIM_SEC" -gt 0 ]; then
        printf '%s\0' \
            "-filter_complex" \
            "[0:v]trim=start=${TRIM_SEC},setpts=PTS-STARTPTS[v];[0:a]atrim=start=${TRIM_SEC},asetpts=PTS-STARTPTS[a]" \
            "-map" "[v]" "-map" "[a]"
    else
        printf '%s\0' "-map" "0:v:0" "-map" "0:a:0"
    fi
}

encode() {
    local -a map_args=()
    mapfile -d '' -t map_args < <(build_map_args)

    stdbuf -oL ffmpeg "${INPUT_ARGS[@]}" \
        "${map_args[@]}" \
        -c:v libx265 -preset "$PRESET" -crf "$CRF" \
        -pix_fmt yuv420p -tag:v hvc1 \
        -c:a aac -ac 2 -b:a 128k -ar 44100 \
        -movflags +faststart \
        -progress pipe:1 -nostats -y -loglevel error "$OUTPUT" | run_progress "$1"
    return "${PIPESTATUS[0]}"
}

probe_duration() {
    ffprobe -v error -show_entries format=duration -of csv=p=0 "$1" 2>/dev/null | cut -d. -f1
}

if [ ${#mp4s[@]} -gt 0 ]; then
    # ─────────── MP4 REJIMI: tayyor video ───────────
    SRC_MAIN="${mp4s[0]}"
    echo "    Manba : $SRC_MAIN (tayyor video)"

    total_sec="$(probe_duration "$SRC_MAIN")"
    [[ "$total_sec" =~ ^[0-9]+$ ]] || total_sec=0

    INPUT_ARGS=(-i "$SRC_MAIN")

elif [ ${#segs[@]} -gt 0 ]; then
    # ─────────── TS REJIMI: bo'laklar concat qilinadi ───────────
    echo "    Manba : ${#segs[@]} ta seg_*.ts"

    printf '%s\n' "${segs[@]}" | sort | sed "s/.*/file '&'/" > list.txt

    # ffprobe concat ro'yxatidan umumiy davomiylikni ololmaydi ("N/A"),
    # shuning uchun har bir bo'lakning davomiyligi qo'shiladi.
    total_sec=$(
        for s in "${segs[@]}"; do
            probe_duration "$s"
        done | awk '{ if ($1 ~ /^[0-9.]+$/) t += $1 } END { printf "%d", t }'
    )
    [[ "$total_sec" =~ ^[0-9]+$ ]] || total_sec=0

    INPUT_ARGS=(-f concat -safe 0 -i list.txt)
else
    echo "::error::anime/$FOLDER ichida na seg_*.ts, na *.mp4 topilmadi"
    exit 1
fi

remain_sec=$(( total_sec - TRIM_SEC ))
[ "$remain_sec" -lt 1 ] && remain_sec=1

encode "$remain_sec"
status=$?

rm -f list.txt
cd "$REPO_ROOT" || exit 1

if [ "$status" -eq 0 ] && [ -s "$OUTPUT" ]; then
    out_mb=$(awk "BEGIN {printf \"%.1f\", $(stat -c%s "$OUTPUT")/1048576}")
    echo ">>> $CLEAN_NAME tayyor! (${out_mb} MB, H.265) <<<"
    exit 0
else
    echo "::error::$CLEAN_NAME uchun H.265 kodlash muvaffaqiyatsiz tugadi (ffmpeg exit=$status)"
    rm -f "$OUTPUT"
    exit 1
fi
