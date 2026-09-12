#!/usr/bin/env bash
# ============================================================
#  Cloudflare R2 "aniraxuz" bucket'idagi epizod papkalarini BIRIN-KETIN
#  H.265 (libx265) bilan kodlaydi va Telegramga yuboradi.
#
#  HAR PAPKA UCHUN:
#    1) R2'dan papkani yuklab oladi
#    2) manbaning sifatiga qarab sifatlar ro'yxatini tuzadi
#       (1080p manba -> 1080p/720p/480p/360p, 720p -> 720p/480p/360p,
#        480p -> 480p/360p, 360p -> faqat 360p; upscale qilinmaydi)
#    3) HAR SIFATNI ALOHIDA: kodlaydi -> Telegramga to'liq yuboradi ->
#       R2'dagi SHU PAPKAGA "<sifat>.md" marker faylini yuklaydi ->
#       keyingi sifatga o'tadi
#    4) hamma sifat tugagach — papkani va ichidagi HAMMA narsani
#       (marker fayllar bilan birga) R2'dan o'chiradi
#
#  RESUME (eng muhim qismi):
#  Actions limiti tugab ish o'chib qolsa, papka R2'da qoladi va tugagan
#  sifatlarning "<sifat>.md" fayllari ham qoladi. Qayta ishga tushirilganda
#  marker fayli BOR sifatlar o'tkazib yuboriladi — faqat qolganlari
#  tayyorlanadi. Ya'ni 1080p va 720p yuborilgandan keyin ish o'chsa,
#  keyingi run to'g'ridan-to'g'ri 480p'dan davom etadi.
#
#  PAPKA RO'YXATI HAR SAFAR QAYTADAN O'QILADI:
#  Bitta papka to'liq tugab R2'dan o'chirilgach, bucket qaytadan ro'yxatga
#  olinadi. Shuning uchun Actions ishlayotgan paytda yuklangan yangi
#  papkalar ham SHU run'da ishlanadi.
#
#  YARIM YUKLANGAN PAPKADAN HIMOYA:
#  Papkadagi eng yangi fayl R2_SETTLE_MIN daqiqadan yosh bo'lsa, papka bu
#  aylanishda o'tkazib yuboriladi (hali yuklab tugatilmagan bo'lishi
#  mumkin). Keyingi aylanishda ro'yxat qaytadan o'qilgani uchun u
#  o'z-o'zidan navbatga qaytadi.
#
#  Birortasida xatolik chiqsa — shu yerda to'xtaydi, papka R2'da qoladi.
#
#  R2 bucket tuzilishi:
#     s3://<BUCKET>/<papka>/seg_*.ts yoki *.mp4  — video manba
#     s3://<BUCKET>/<papka>/<sifat>.md           — tayyor sifat markeri
#  Epizod nomi PAPKA NOMIDAN olinadi (TRIM prefiksi olib tashlanadi,
#  pastki chiziqlar bo'sh joyga aylanadi). .png fayllar e'tiborga olinmaydi.
#
#  Muhit o'zgaruvchilari:
#     AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY — R2 API tokeni
#     R2_ENDPOINT                              — https://<id>.r2.cloudflarestorage.com
#     R2_BUCKET       (ixtiyoriy)              — standart: aniraxuz
#     TG_TARGET       (ixtiyoriy)              — standart "me" (Saqlangan xabarlar)
#     R2_SETTLE_MIN   (ixtiyoriy)              — standart 2 daqiqa, 0 = o'chirilgan
# ============================================================

set -uo pipefail
shopt -s nullglob

: "${R2_ENDPOINT:?R2_ENDPOINT muhit ozgaruvchisi kerak}"
: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID muhit ozgaruvchisi kerak}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY muhit ozgaruvchisi kerak}"
R2_BUCKET="${R2_BUCKET:-aniraxuz}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

s3() { aws s3 "$@" --endpoint-url "$R2_ENDPOINT"; }

# "me" — Pyrogram'da sessiya egasining o'zi, ya'ni Saved Messages.
TG_TARGET="${TG_TARGET:-me}"
SETTLE_MIN="${R2_SETTLE_MIN:-2}"

RUN_URL=""
if [ -n "${GITHUB_SERVER_URL:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_RUN_ID:-}" ]; then
    RUN_URL="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
fi

echo "🪣 R2 bucket: $R2_BUCKET"
echo "📨 Yuboriladigan joy: $TG_TARGET (Saqlangan xabarlar)"
echo "⏳ Yangi fayl kutish vaqti: ${SETTLE_MIN} daqiqa"

# ─── Bucketdagi epizod papkalari (top-level prefikslar) ───
list_folders() {
    s3 ls "s3://$R2_BUCKET/" | awk '$1 == "PRE" {print $2}' | sed 's#/$##' | sort
}

# ─── Papkadagi eng yangi MANBA faylining yoshi (daqiqada) ───
# Marker (.md) fayllari HISOBGA OLINMAYDI: ularni workflow o'zi yozadi, va
# ular hisobga olinsa resume run'i har safar "hali yuklanmoqda" deb papkani
# o'tkazib yuborardi.
newest_age_min() {
    local folder="$1" newest ts now
    newest=$(s3 ls "s3://$R2_BUCKET/$folder/" --recursive 2>/dev/null \
        | awk 'NF >= 4 && $0 !~ /\.md$/ {print $1" "$2}' | sort | tail -n 1)
    if [ -z "$newest" ]; then
        echo 999999
        return
    fi
    ts=$(date -u -d "$newest" +%s 2>/dev/null)
    if [ -z "$ts" ]; then
        echo 999999
        return
    fi
    now=$(date -u +%s)
    echo $(( (now - ts) / 60 ))
}

# ─── Marker faylini R2'ga yuklash (3 martagacha urinadi) ───
upload_marker() {
    local folder="$1" label="$2" body="$3"
    local tmp attempt
    tmp="$(mktemp)"
    printf '%s\n' "$body" > "$tmp"
    # Mahalliy nusxa ham qoldiramiz — yakuniy jamlanma jadval shundan o'qiydi
    cp "$tmp" "anime/$folder/${label}.md" 2>/dev/null || true
    for attempt in 1 2 3; do
        if s3 cp "$tmp" "s3://$R2_BUCKET/$folder/${label}.md"; then
            rm -f "$tmp"
            echo "    📌 marker yuklandi: $folder/${label}.md"
            return 0
        fi
        echo "    ⏳ marker yuklanmadi, qayta urinish ($attempt/3)..."
        sleep $(( attempt * 3 ))
    done
    rm -f "$tmp"
    echo "::warning::$folder/${label}.md marker fayli yuklanmadi — ish o'chib qolsa bu sifat qayta yuborilishi mumkin."
    return 1
}

# ─── Bitta papkani to'liq ishlash ───
process_folder() {
    local FOLDER="$1"
    local label line marker file NAME kbps
    local res size_mb dur body sent_at

    echo "☁️  R2'dan yuklab olinmoqda..."
    rm -rf "anime/$FOLDER"
    mkdir -p "anime/$FOLDER"
    if ! s3 cp "s3://$R2_BUCKET/$FOLDER/" "anime/$FOLDER/" --recursive; then
        echo "::error::$FOLDER: R2'dan yuklab olishda xatolik — jarayon to'xtatildi."
        return 1
    fi

    # Video manba yo'q, lekin markerlar bor -> allaqachon tugagan, tozalanadi.
    # DIQQAT: "ls papka/*.md" bilan tekshirib bo'lmaydi — nullglob yoqilgani
    # uchun mos fayl bo'lmasa glob butunlay yo'qoladi va ls argumentsiz
    # qolib muvaffaqiyat qaytaradi. Shuning uchun massiv ishlatiladi.
    local -a src_ts src_mp4 markers
    src_ts=("anime/$FOLDER"/seg_*.ts)
    src_mp4=("anime/$FOLDER"/*.mp4)
    markers=("anime/$FOLDER"/*.md)
    if [ ${#src_ts[@]} -eq 0 ] && [ ${#src_mp4[@]} -eq 0 ] && [ ${#markers[@]} -gt 0 ]; then
        echo "ℹ️  $FOLDER: video manba yo'q, faqat markerlar bor — allaqachon tugagan, R2'dan tozalanadi."
        s3 rm "s3://$R2_BUCKET/$FOLDER/" --recursive
        rm -rf "anime/$FOLDER"
        return 0
    fi

    if ! bash scripts/encode_h265.sh --plan "$FOLDER"; then
        echo "::error::$FOLDER: rejani tuzishda xatolik — jarayon to'xtatildi."
        return 1
    fi
    NAME="$(cat .encode_meta_name)"

    # Rejani avval massivga o'qiymiz. Fayldan oqim bilan (while read < fayl)
    # o'qish XAVFLI: tsikl ichidagi ffmpeg stdin'ni o'qib, qolgan qatorlarni
    # "yeb" qo'yadi va faqat birinchi sifat ishlanadi.
    local -a plan_lines
    mapfile -t plan_lines < .encode_plan

    # Sifatlarni kattadan kichikka ketma-ket
    for line in "${plan_lines[@]}"; do
        label="${line%%$'\t'*}"
        [ -n "$label" ] || continue

        marker="anime/$FOLDER/${label}.md"
        if [ -f "$marker" ]; then
            echo "⏭  $NAME — $label allaqachon tayyor (${label}.md bor), o'tkazib yuborildi."
            continue
        fi

        if ! bash scripts/encode_h265.sh --render "$FOLDER" "$label"; then
            echo "::error::$FOLDER ($label): kodlashda xatolik — jarayon to'xtatildi."
            return 1
        fi
        file="$(cat .encode_out_file)"

        # Marker uchun ma'lumotni fayl o'chirilishidan OLDIN olamiz
        res=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x "$file")
        dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$file")
        size_mb=$(awk -v b="$(stat -c%s "$file")" 'BEGIN {printf "%.1f", b/1048576}')
        kbps=$(awk -v b="$(stat -c%s "$file")" -v d="$dur" \
            'BEGIN { if (d + 0 > 0) printf "%.0f", b*8/d/1000; else printf "?" }')

        echo "📤 $NAME — $label Telegramga yuborilmoqda..."
        if ! python3 -u scripts/telegram_upload.py "$file" \
                --user "$TG_TARGET" \
                --name "${NAME} ${label}" \
                --caption "$(printf '%s\n%s' "$NAME" "$label")"; then
            echo "::error::$FOLDER ($NAME $label): Telegramga yuklashda xatolik — jarayon to'xtatildi."
            rm -f "$file"
            return 1
        fi

        # Telegramga TO'LIQ yuborilgandan keyingina marker yuklanadi
        sent_at="$(date -u '+%Y-%m-%d %H:%M:%S')"
        body="# ${label} — tayyor

- Epizod: ${NAME}
- Papka: ${FOLDER}
- O'lcham: ${res}
- Hajm: ${size_mb} MB
- Bitrate: ${kbps} kbps
- Davomiylik: ${dur}s
- Telegramga yuborilgan (UTC): ${sent_at}"
        if [ -n "$RUN_URL" ]; then
            body="${body}
- Actions run: ${RUN_URL}"
        fi
        body="${body}

Bu fayl bor bo'lsa, shu sifat qayta tayyorlanmaydi."
        upload_marker "$FOLDER" "$label" "$body" || true

        rm -f "$file"
        echo "✅ $NAME — $label tayyor va yuborildi."
    done

    # ─── Yakuniy jamlanma jadval ───
    # Ma'lumot marker fayllardan o'qiladi, shuning uchun bu run'da o'tkazib
    # yuborilgan (avvalgi run'da tayyorlangan) sifatlar ham jadvalda bo'ladi.
    local s_res s_mb s_kbps s_dur s_codec
    if [ -f .encode_src_stats ]; then
        IFS=$'\t' read -r s_res s_mb s_kbps s_dur s_codec < .encode_src_stats
    fi
    echo ""
    echo "📊 $NAME — yakuniy statistika"
    echo "   Asl manba: ${s_res:-?} | ${s_codec:-?} | ${s_mb:-?} MB | ${s_kbps:-?} kbps | ${s_dur:-?}s"
    printf '   %-7s %-11s %10s %12s %10s\n' "sifat" "o'lcham" "hajm" "bitrate" "manbadan"
    local m_res m_mb m_kbps m_pct
    for line in "${plan_lines[@]}"; do
        label="${line%%$'\t'*}"
        [ -n "$label" ] || continue
        marker="anime/$FOLDER/${label}.md"
        if [ ! -f "$marker" ]; then
            printf '   %-7s %-11s %10s %12s %10s\n' "$label" "?" "?" "?" "?"
            continue
        fi
        m_res=$(sed -n "s/^- O'lcham: //p" "$marker" | head -1)
        m_mb=$(sed -n 's/^- Hajm: \(.*\) MB$/\1/p' "$marker" | head -1)
        m_kbps=$(sed -n 's/^- Bitrate: \(.*\) kbps$/\1/p' "$marker" | head -1)
        m_pct=$(awk -v o="${m_kbps:-0}" -v s="${s_kbps:-0}" \
            'BEGIN { if (s + 0 > 0 && o + 0 > 0) printf "%.0f%%", o/s*100; else printf "?" }')
        printf '   %-7s %-11s %10s %12s %10s\n' \
            "$label" "${m_res:-?}" "${m_mb:-?} MB" "${m_kbps:-?} kbps" "$m_pct"
    done
    echo ""

    echo "🧹 $FOLDER R2'dan o'chirilmoqda (markerlar bilan birga)..."
    if ! s3 rm "s3://$R2_BUCKET/$FOLDER/" --recursive; then
        echo "::warning::$FOLDER R2'dan to'liq o'chirilmadi — keyingi run uni markerlari bilan topib tozalaydi."
    fi
    rm -rf "anime/$FOLDER"
    rm -f .encode_plan .encode_meta_name .encode_out_file .encode_out_stats .encode_src_stats

    echo "🎉 $FOLDER ($NAME) — barcha sifatlar tayyor va yuborildi."
    return 0
}

# ─── Asosiy tsikl: har papkadan keyin ro'yxat QAYTADAN o'qiladi ───
PROCESSED=""
DEFERRED=""

while true; do
    mapfile -t folders < <(list_folders)

    if [ ${#folders[@]} -eq 0 ]; then
        echo ""
        echo "ℹ️  Bucketda ishlanadigan papka qolmadi."
        break
    fi

    echo ""
    echo "📋 Bucketda ${#folders[@]} ta papka: ${folders[*]}"

    PICK=""
    DEFERRED=""
    for f in "${folders[@]}"; do
        # Xavfsizlik: bir papka ikki marta tanlanmasligi kerak
        case " $PROCESSED " in
            *" $f "*)
                echo "::error::$f allaqachon ishlangan, lekin bucketda qoldi — jarayon to'xtatildi (qo'lda tekshirish kerak)."
                exit 1 ;;
        esac

        if [ "$SETTLE_MIN" -gt 0 ]; then
            age="$(newest_age_min "$f")"
            if [ "$age" -lt "$SETTLE_MIN" ]; then
                echo "⏳ $f: eng yangi fayl ${age} daqiqa oldin yuklangan (< ${SETTLE_MIN}) — hali yuklanmoqda bo'lishi mumkin, o'tkazib yuborildi."
                DEFERRED="$DEFERRED $f"
                continue
            fi
        fi

        PICK="$f"
        break
    done

    if [ -z "$PICK" ]; then
        echo ""
        echo "ℹ️  Hamma qolgan papka hali yuklanmoqda:$DEFERRED"
        echo "    Yuklash tugagach workflow'ni qayta ishga tushiring."
        break
    fi

    echo ""
    echo "::group::=== Papka: $PICK ==="
    if ! process_folder "$PICK"; then
        echo "::endgroup::"
        exit 1
    fi
    echo "::endgroup::"

    PROCESSED="$PROCESSED $PICK"
done

echo ""
if [ -n "$PROCESSED" ]; then
    echo "🎉 Tugadi. Ishlangan papkalar:$PROCESSED"
else
    echo "🎉 Tugadi. Hech qanday papka ishlanmadi."
fi
