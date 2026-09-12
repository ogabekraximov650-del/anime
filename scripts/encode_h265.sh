#!/usr/bin/env bash
# ============================================================
#  H.265 kodlash — HAR BIR SIFAT ALOHIDA (resume qilish uchun)
#
#  Ishlatilishi:
#     encode_h265.sh --plan   <papka>            — sifatlar ro'yxatini tuzadi
#     encode_h265.sh --render <papka> <sifat>    — FAQAT shu sifatni kodlaydi
#     encode_h265.sh          <papka>            — rejani tuzib, hammasini
#                                                  ketma-ket kodlaydi (qo'lda
#                                                  sinash uchun)
#
#  <papka> = [<TRIM_SEC>_]<epizod_nomi>  — masalan: 2-fasl_367-qism,
#     30_2-fasl_367-qism (boshidan 30 soniya kesib tashlanadi).
#  <sifat> = 1080p / 720p / 480p / 360p ...
#
#  NEGA HAR SIFAT ALOHIDA KODLANADI?
#  Hammasini bitta ffmpeg buyrug'ida (split filtri bilan) chiqarish ~13%
#  tezroq, LEKIN Actions limiti tugab ish o'chib qolsa — hammasi yo'qoladi.
#  Alohida kodlanganda esa tugagan sifatlar R2'da marker fayl bilan
#  belgilanadi va qayta ishga tushirilganda faqat qolganlari tayyorlanadi.
#  Davomiylik baribir bir xil bo'ladi, chunki har sifat AYNAN BIR XIL asl
#  manbadan, bir xil kesish bilan chiqariladi.
#
#  VIDEOGA HECH QANDAY RASM YOKI LOGOTIP QO'SHILMAYDI — papka ichidagi
#  .png va .md fayllar e'tiborga olinmaydi.
#
#  Manba ikki turdagi bo'lishi mumkin:
#     anime/<papka>/seg_*.ts — video bo'laklari (concat qilinadi)
#     anime/<papka>/*.mp4    — tayyor video
#
#  ─── SIFATLAR (upscale QILINMAYDI) ───
#     1080p manba -> 1080p, 720p, 480p, 360p
#      720p manba ->        720p, 480p, 360p
#      480p manba ->              480p, 360p
#      360p manba ->                    360p
#  1080p'dan baland manba 1080p'ga tushiriladi. Nostandart balandlik
#  (masalan 1070p) eng yuqori sifat sifatida scale'siz kodlanadi.
#
#  ─── SIQISH ───
#  Bitrate chegaralari YO'Q, CRF rejimi (fayl hajmi kichik bo'lishi uchun).
#  CRF balandlikka qarab: >=1080p BASE | >=720p BASE-1 | >=480p BASE-2 |
#  <480p BASE-3.
#     H265_CRF    (ixtiyoriy) — BASE, standart 30. Katta qiymat = kichik fayl.
#     H265_PRESET (ixtiyoriy) — standart medium. "slow" kichikroq, lekin sekin.
#
#  ─── YOZIB QOLDIRADIGAN FAYLLAR ───
#     .encode_plan      — "<sifat><TAB><balandlik><TAB>native|scale", kattadan
#     .encode_meta_name — Telegram sarlavhasi uchun nom (papka nomidan)
#     .encode_out_file  — --render yasagan faylning yo'li
#
#  Audio: AAC, stereo, 44.1kHz (720p va yuqorisi 128k, pastrog'i 96k).
# ============================================================

set -uo pipefail
shopt -s nullglob

MODE="all"
FOLDER=""
WANT_LABEL=""

case "${1:-}" in
    --plan)
        MODE="plan"; FOLDER="${2:-}" ;;
    --render)
        MODE="render"; FOLDER="${2:-}"; WANT_LABEL="${3:-}" ;;
    "")
        echo "::error::Ishlatilishi: encode_h265.sh [--plan|--render] <papka> [<sifat>]"
        exit 1 ;;
    *)
        FOLDER="$1" ;;
esac

if [ -z "$FOLDER" ]; then
    echo "::error::Papka nomi berilmadi"
    exit 1
fi
if [ "$MODE" = "render" ] && [ -z "$WANT_LABEL" ]; then
    echo "::error::--render uchun sifat nomi kerak (masalan 720p)"
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

CRF_BASE="${H265_CRF:-30}"
PRESET="${H265_PRESET:-medium}"
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
CAPTION_BASE="${BASE_NAME//_/ }"

ANIME_DIR="$REPO_ROOT/anime/$FOLDER"
if [ ! -d "$ANIME_DIR" ]; then
    echo "::error::anime/$FOLDER papkasi topilmadi"
    exit 1
fi

probe_duration() {
    ffprobe -v error -show_entries format=duration -of csv=p=0 "$1" 2>/dev/null | cut -d. -f1
}

# ─── Manbani aniqlash ───
cd "$ANIME_DIR" || exit 1
mp4s=(*.mp4)
segs=(seg_*.ts)

if [ ${#mp4s[@]} -gt 0 ]; then
    SRC_MAIN="${mp4s[0]}"
    SRC_LABEL="$SRC_MAIN (tayyor video)"
    SRC_KIND="mp4"
    PROBE_FILE="$SRC_MAIN"
    total_sec="$(probe_duration "$SRC_MAIN")"
elif [ ${#segs[@]} -gt 0 ]; then
    SRC_LABEL="${#segs[@]} ta seg_*.ts"
    SRC_KIND="ts"
    PROBE_FILE="$(printf '%s\n' "${segs[@]}" | sort | head -n 1)"
    total_sec=$(
        for s in "${segs[@]}"; do probe_duration "$s"; done \
            | awk '{ if ($1 ~ /^[0-9.]+$/) t += $1 } END { printf "%d", t }'
    )
else
    echo "::error::anime/$FOLDER ichida na seg_*.ts, na *.mp4 topilmadi"
    exit 1
fi

[[ "$total_sec" =~ ^[0-9]+$ ]] || total_sec=0

# Kesish vaqti videoning o'zidan uzun bo'lsa — bo'sh video chiqadi. Buni
# oldindan to'xtatamiz, aks holda "tayyor" deb belgilanib qolishi mumkin.
if [ "$total_sec" -gt 0 ] && [ "$TRIM_SEC" -ge "$total_sec" ]; then
    echo "::error::$FOLDER: kesish vaqti (${TRIM_SEC}s) videoning davomiyligidan (${total_sec}s) uzun yoki teng — papka nomidagi TRIM prefiksini tekshiring."
    exit 1
fi

remain_sec=$(( total_sec - TRIM_SEC ))
[ "$remain_sec" -lt 1 ] && remain_sec=1

SRC_H=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$PROBE_FILE" | head -n 1 | tr -d '\r')
SRC_W=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$PROBE_FILE" | head -n 1 | tr -d '\r')
if ! [[ "$SRC_H" =~ ^[0-9]+$ ]] || [ "$SRC_H" -lt 1 ]; then
    echo "::error::$FOLDER: video balandligini aniqlab bo'lmadi"
    exit 1
fi
if [ -z "$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_type -of csv=p=0 "$PROBE_FILE" 2>/dev/null)" ]; then
    echo "::error::$FOLDER: audio yo'lakcha topilmadi"
    exit 1
fi

# ─── Manbaning ASL hajmi va bitrate'i (statistika uchun) ───
# ts rejimida hamma bo'lakning hajmi qo'shiladi. Bitrate = hajm*8/davomiylik,
# ya'ni video+audio birgalikda (umumiy bitrate).
if [ "$SRC_KIND" = "mp4" ]; then
    SRC_BYTES=$(stat -c%s "$SRC_MAIN")
else
    SRC_BYTES=$(for s in "${segs[@]}"; do stat -c%s "$s"; done \
        | awk '{ t += $1 } END { printf "%d", t }')
fi
[[ "$SRC_BYTES" =~ ^[0-9]+$ ]] || SRC_BYTES=0
SRC_MB=$(awk -v b="$SRC_BYTES" 'BEGIN {printf "%.1f", b/1048576}')
if [ "$total_sec" -gt 0 ] && [ "$SRC_BYTES" -gt 0 ]; then
    SRC_KBPS=$(awk -v b="$SRC_BYTES" -v d="$total_sec" 'BEGIN {printf "%.0f", b*8/d/1000}')
else
    SRC_KBPS="?"
fi
SRC_CODEC=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$PROBE_FILE" 2>/dev/null | head -n 1 | tr -d '\r')
SRC_FPS=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 "$PROBE_FILE" 2>/dev/null | head -n 1 | tr -d '\r' \
    | awk -F/ '{ if ($2 > 0) printf "%.3g", $1/$2; else print "?" }')

# ─── Ladder ───
LADDER=()
if [ "$SRC_H" -le "$MAX_HEIGHT" ]; then
    LADDER+=("${SRC_H}:native")
    for s in "${STD_STEPS[@]}"; do
        [ "$s" -lt "$SRC_H" ] && LADDER+=("${s}:scale")
    done
else
    LADDER+=("${MAX_HEIGHT}:scale")
    for s in "${STD_STEPS[@]}"; do LADDER+=("${s}:scale"); done
fi

crf_for_height() {
    if   [ "$1" -ge 1080 ]; then echo "$CRF_BASE"
    elif [ "$1" -ge 720  ]; then echo "$(( CRF_BASE - 1 ))"
    elif [ "$1" -ge 480  ]; then echo "$(( CRF_BASE - 2 ))"
    else                         echo "$(( CRF_BASE - 3 ))"
    fi
}
abr_for_height() { [ "$1" -ge 720 ] && echo "128k" || echo "96k"; }

write_plan() {
    : > "$REPO_ROOT/.encode_plan"
    local e h m
    for e in "${LADDER[@]}"; do
        h="${e%%:*}"; m="${e##*:}"
        printf '%s\t%s\t%s\n' "${h}p" "$h" "$m" >> "$REPO_ROOT/.encode_plan"
    done
    echo "$CAPTION_BASE" > "$REPO_ROOT/.encode_meta_name"
    # Manba statistikasi — yakuniy jamlanma jadval uchun
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "${SRC_W}x${SRC_H}" "$SRC_MB" "$SRC_KBPS" "$total_sec" "${SRC_CODEC:-?}" \
        > "$REPO_ROOT/.encode_src_stats"
}

print_header() {
    echo "    Nom       : $CAPTION_BASE"
    echo "    Manba     : $SRC_LABEL"
    echo "    Asl video : ${SRC_W}x${SRC_H} | ${SRC_CODEC:-?} | ${SRC_FPS:-?} fps"
    echo "    Asl hajm  : ${SRC_MB} MB | ${SRC_KBPS} kbps (video+audio) | ${total_sec}s"
    echo "    Kesish    : ${TRIM_SEC}s | kodlanadigan davomiylik ~${remain_sec}s"
    echo "    Preset    : $PRESET | CRF BASE: $CRF_BASE | bitrate chegarasi yo'q"
    printf '    Sifatlar  :'
    local e
    for e in "${LADDER[@]}"; do printf ' %sp' "${e%%:*}"; done
    echo ""
}

run_progress() {
    local total_ref="$1" label="$2"
    local last_ms=0 f=0 fps_now=0 br="0kbits/s" sz=0 tm="00:00:00" sp="?" us=0
    while IFS='=' read -r key value; do
        value="${value//$'\r'/}"
        case "$key" in
            frame)       f="$value" ;;
            fps)         fps_now="$value" ;;
            bitrate)     br="$value" ;;
            total_size)  sz="$value" ;;
            out_time_us) us="$value" ;;
            out_time)    tm="${value:0:8}" ;;
            speed)       sp="$value" ;;
            progress)
                now_ms=$(date +%s%3N)
                # ffmpeg'ning eng birinchi hisoboti bo'sh bo'ladi
                # (out_time=N/A, bitrate=N/A) — uni chiqarmaymiz.
                if [ "$tm" = "N/A" ] || [ -z "${us//[!0-9]/}" ]; then
                    continue
                fi
                if [ "$value" = "end" ] || [ $((now_ms - last_ms)) -ge 500 ]; then
                    last_ms=$now_ms
                    if [ "${total_ref:-0}" -gt 0 ] 2>/dev/null; then
                        pct=$(awk "BEGIN {p=(${us:-0}/1000000)/$total_ref*100; if(p>100)p=100; printf \"%.1f\", p}")
                    else
                        pct="?"
                    fi
                    mb=$(awk "BEGIN {printf \"%.1f\", ${sz:-0}/1048576}")
                    clean_br=$(echo "${br:-0kbits/s}" | tr -d 'kbits/s' | xargs)
                    echo "🎬 [$CAPTION_BASE $label] ${pct}% | frm:${f:-0} | vaqt:${tm:-00:00:00} | fps:${fps_now:-0} | br:${clean_br}kbps | ${mb}MB | tezlik:${sp:-?}"
                fi
                ;;
        esac
    done
}

render_one() {
    local label="$1" h="" mode="" e
    for e in "${LADDER[@]}"; do
        if [ "${e%%:*}p" = "$label" ]; then h="${e%%:*}"; mode="${e##*:}"; fi
    done
    if [ -z "$h" ]; then
        echo "::error::$FOLDER: '$label' sifati bu manba uchun ro'yxatda yo'q (manba ${SRC_H}p)"
        return 1
    fi

    local out="$REPO_ROOT/${BASE_NAME}_${label}.mp4"
    local crf abr
    crf="$(crf_for_height "$h")"
    abr="$(abr_for_height "$h")"

    # Kesish filtr ichida (trim/atrim) bajariladi — input "-ss" concat
    # demuxer bilan birga audioga shovqin qo'shadi.
    local vtrim="" atrim=""
    if [ "$TRIM_SEC" -gt 0 ]; then
        vtrim="trim=start=${TRIM_SEC},setpts=PTS-STARTPTS,"
        atrim="atrim=start=${TRIM_SEC},asetpts=PTS-STARTPTS,"
    fi
    local vchain
    if [ "$mode" = "native" ]; then
        vchain="${vtrim}null"
    else
        vchain="${vtrim}scale=-2:${h}:flags=lanczos"
    fi
    local fc="[0:v]${vchain}[v];[0:a]${atrim}anull[a]"

    local -a input_args
    cd "$ANIME_DIR" || return 1
    if [ "$SRC_KIND" = "ts" ]; then
        printf '%s\n' "${segs[@]}" | sort | sed "s/.*/file '&'/" > list.txt
        input_args=(-f concat -safe 0 -i list.txt)
    else
        input_args=(-i "$SRC_MAIN")
    fi

    # -nostdin SHART: aks holda ffmpeg stdin'ni o'qib, chaqiruvchi tsiklning
    # reja faylini "yeb" qo'yadi (faqat birinchi sifat ishlanib qoladi).
    echo "🎯 $CAPTION_BASE — $label kodlanmoqda (CRF $crf, audio $abr)..."
    stdbuf -oL ffmpeg -nostdin "${input_args[@]}" \
        -filter_complex "$fc" \
        -map "[v]" -map "[a]" \
        -c:v libx265 -preset "$PRESET" -crf "$crf" \
        -x265-params log-level=error \
        -pix_fmt yuv420p -tag:v hvc1 \
        -c:a aac -ac 2 -b:a "$abr" -ar 44100 \
        -movflags +faststart \
        -progress pipe:1 -nostats -loglevel error -y "$out" | run_progress "$remain_sec" "$label"
    local st="${PIPESTATUS[0]}"
    rm -f list.txt
    cd "$REPO_ROOT" || return 1

    if [ "$st" -ne 0 ] || [ ! -s "$out" ]; then
        echo "::error::$CAPTION_BASE $label: kodlash muvaffaqiyatsiz (ffmpeg exit=$st)"
        rm -f "$out"
        return 1
    fi

    # Chiqishni tekshiramiz: haqiqiy video yo'lakcha va davomiylik bo'lishi
    # SHART. Aks holda buzuq fayl Telegramga ketib, "tayyor" deb
    # belgilanib qolishi mumkin.
    local mb res dur ok=1
    mb=$(awk -v b="$(stat -c%s "$out")" 'BEGIN {printf "%.1f", b/1048576}')
    res=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x "$out")
    dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$out")
    [[ "$res" =~ ^[0-9]+x[0-9]+$ ]] || ok=0
    [[ "$dur" =~ ^[0-9]+(\.[0-9]+)?$ ]] || ok=0
    if [ "$ok" -eq 1 ]; then
        awk -v d="$dur" 'BEGIN {exit (d > 0.5) ? 0 : 1}' || ok=0
    fi
    if [ "$ok" -ne 1 ]; then
        echo "::error::$CAPTION_BASE $label: chiqish fayli buzuq (o'lcham='${res}', davomiylik='${dur}')"
        rm -f "$out"
        return 1
    fi

    # ─── Statistika: chiqish bitrate'i va manbaga nisbati ───
    # Bitrate'ni solishtirish kesishdan mustaqil (hajmni solishtirish esa
    # kesish bo'lganda adashtiradi), shuning uchun foiz bitrate bo'yicha.
    local out_bytes out_kbps vid_kbps abr_num pct_src
    out_bytes=$(stat -c%s "$out")
    out_kbps=$(awk -v b="$out_bytes" -v d="$dur" 'BEGIN {printf "%.0f", b*8/d/1000}')
    abr_num="${abr%k}"
    vid_kbps=$(( out_kbps - abr_num ))
    [ "$vid_kbps" -lt 0 ] && vid_kbps=0
    pct_src=$(awk -v o="$out_kbps" -v s="$SRC_KBPS" \
        'BEGIN { if (s + 0 > 0) printf "%.0f%%", o/s*100; else printf "?" }')

    echo "    ✔ $label — $res | ${mb} MB | ${dur}s"
    echo "      bitrate : ${out_kbps} kbps jami (video ~${vid_kbps} + audio ${abr}) | CRF $crf"
    echo "      manbaga : ${SRC_KBPS} kbps -> ${out_kbps} kbps (${pct_src}) | asl hajm ${SRC_MB} MB -> ${mb} MB"

    printf '%s\t%s\t%s\t%s\t%s\n' "$label" "$res" "$mb" "$out_kbps" "$dur" \
        > "$REPO_ROOT/.encode_out_stats"
    echo "$out" > "$REPO_ROOT/.encode_out_file"
    return 0
}

cd "$REPO_ROOT" || exit 1

case "$MODE" in
    plan)
        echo "=== $CAPTION_BASE — reja ==="
        print_header
        write_plan
        exit 0
        ;;
    render)
        render_one "$WANT_LABEL" || exit 1
        exit 0
        ;;
    all)
        echo "=== $CAPTION_BASE — hamma sifat ketma-ket ==="
        print_header
        write_plan
        # Rejani avval massivga o'qiymiz — fayldan oqim bilan o'qish xavfli
        # (ichki buyruqlar stdin'ni o'zgartirib qo'yishi mumkin).
        mapfile -t plan_lines < "$REPO_ROOT/.encode_plan"
        for line in "${plan_lines[@]}"; do
            label="${line%%$'\t'*}"
            [ -n "$label" ] || continue
            render_one "$label" || exit 1
        done
        echo ">>> $CAPTION_BASE tayyor <<<"
        exit 0
        ;;
esac
