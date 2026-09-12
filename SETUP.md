# Sozlash yo'riqnomasi

Bu repo Termux orqali push qilingan video-bo'laklarni GitHub Actions'da
(ffmpeg bilan) tayyorlaydi va tayyor videoni sizning shaxsiy Telegram
akkountingizga (Pyrogram sessiyasi orqali) avtomatik yuboradi.

## 1. Ishlash mantig'i — HAR EPIZOD O'Z ALOHIDA WORKFLOW'IGA EGA

Bitta umumiy workflow o'rniga, har bir epizod push qilinganda **o'ziga xos**
`.github/workflows/<epizod>.yml` fayli yaratiladi (shablon:
`scripts/workflow-template.yml`). Bu fayl FAQAT o'sha epizodni kodlaydi va
yuklaydi. Natijada:

- Bir nechta epizod bir vaqtda push qilinsa, ular **parallel va bir-biriga
  bog'liq bo'lmagan** alohida workflow run'lar sifatida ishlaydi — bitta katta
  ishning boshqasini bloklashi yoki GitHub tomonidan navbatga
  qo'yilib qolishi xavfi yo'q.
- Muvaffaqiyatli tugagandan so'ng, workflow o'zi ishlatgan manba fayllarni
  (`anime/<epizod>/`, `anipng/<epizod>.png`) VA o'zining `.yml` faylini ham
  repo'dan o'chirib, avtomatik commit qiladi — repo doim toza qoladi.

## 2. Repo tarkibi

```
anime/<epizod_nomi>/                 # video bo'laklari
    seg_0001.ts
    seg_0002.ts
    ...
anipng/<epizod_nomi>.png             # shu epizodning cover rasmi
anipng/logo.png                      # barcha videolarga qo'yiladigan logotip
.github/workflows/<epizod_nomi>.yml  # har push'da avtomatik yaratiladi
scripts/workflow-template.yml        # yuqoridagi faylning shabloni
scripts/encode.sh                    # ffmpeg kodlash (bitta papka nomini oladi)
scripts/telegram_upload.py           # Telegramga yuklash
```

**Diqqat — fayl hajmi:** oddiy `git push` orqali bitta fayl 100 MB'dan katta
bo'lsa, GitHub uni rad etadi (Git LFS kerak bo'ladi).

## 3. Kerakli GitHub Actions sekretlari

Repo sahifasida: **Settings → Secrets and variables → Actions → New repository secret**

| Nomi | Qiymati |
|---|---|
| `TG_API_ID` | Telegram API ID (my.telegram.org'dan) |
| `TG_API_HASH` | Telegram API Hash |
| `TG_CHAT_ID` | Video yuboriladigan chat/kanal ID yoki username (`me` — Saved Messages) |
| `PYRO_SESSION_B64` | pastda tushuntirilgan — `pyro_session.session` faylining base64 shakli |

### `PYRO_SESSION_B64` ni qanday olish kerak

Bu — shaxsiy Telegram akkountingizga kirish huquqini beruvchi maxfiy kalit.
**Uni hech qachon chatga yozmang.** Faqat o'zingizning Termux
terminalingizda:

```sh
base64 -w0 pyro_session.session
```

Chiqqan matnni GitHub'ning `PYRO_SESSION_B64` sekret maydoniga joylashtiring
(yoki `gh secret set PYRO_SESSION_B64 --repo ogabekraximov650-del/anime` bilan,
agar `gh` o'rnatilgan bo'lsa).

## 4. Termux'dan yuklash

`termux/upload.sh` — to'liq mustaqil skript: klonlash/pull/push va har
epizod uchun alohida `.yml` yaratish — barchasi shu bitta faylda.
**Argumentsiz ishga tushirilsa, `anime/` ichidagi hali yuklanmagan BARCHA
papkalarni topib, hammasini bitta push bilan yuklaydi.**

1. **Personal Access Token yarating**: GitHub → Settings → Developer settings
   → Personal access tokens → Fine-grained tokens → faqat shu `anime`
   repo'siga, **Contents: Read and write** huquqi bilan.

   ⚠️ Tokenni hech qachon boshqa birov bilan baham ko'rmang, chatga
   yozmang, yoki skriptning ICHIGA yozib qo'ymang — u faqat buyruq
   ichida, muhit o'zgaruvchisi sifatida beriladi (pastda ko'rsatilgan),
   hech qachon faylga saqlanmaydi.

2. Bir marta repo'ni klonlab oling (yoki quyidagi buyruq birinchi
   ishga tushishda o'zi klonlaydi):

   ```sh
   GITHUB_TOKEN='tokeningiz' bash -c '
     REPO_DIR="$HOME/anime-repo"
     [ -d "$REPO_DIR/.git" ] || git clone "https://ogabekraximov650-del:${GITHUB_TOKEN}@github.com/ogabekraximov650-del/anime.git" "$REPO_DIR"
     bash "$REPO_DIR/termux/upload.sh"
   '
   ```

3. Keyingi safar (repo allaqachon `$HOME/anime-repo`da bo'lsa), shunchaki:

   ```sh
   GITHUB_TOKEN='tokeningiz' bash "$HOME/anime-repo/termux/upload.sh"
   ```

   — barcha yangi (hali yuklanmagan) epizodlarni topib, ularning har biri
   uchun `anime/<nomi>/` + `anipng/<nomi>.png` + `anipng/logo.png`ni
   ko'chiradi, har biriga alohida `.github/workflows/<nomi>.yml` yasaydi
   va hammasini BITTA commit+push bilan yuboradi (tarmoq xatosida 4
   martagacha qayta urinadi). Muvaffaqiyatli yuklangan epizodlar
   `~/.anime_uploaded.log`ga yoziladi — keyingi ishga tushirishda ular
   qayta yuklanmaydi, faqat yangi qo'shilgan papkalar yuboriladi.

   Faqat bitta muayyan epizodni yuklamoqchi bo'lsangiz:

   ```sh
   GITHUB_TOKEN='tokeningiz' bash "$HOME/anime-repo/termux/upload.sh" aybsiz_8
   ```

## 5. Muvaffaqiyatsizlik holati

Agar kodlash yoki yuklash muvaffaqiyatsiz tugasa, manba fayllar va workflow
fayli repo'da qoladi (tozalash qadami ishlamaydi) — "Actions" bo'limidan
xatoni ko'rib, "Re-run jobs" bilan qayta urinib ko'rishingiz mumkin.

## 6. "H265 encode" workflow'i (logotip va rasmsiz, ko'p sifatli)

`.github/workflows/h265-encode.yml` — qo'lda ishga tushiriladigan
(`workflow_dispatch`) alohida workflow. Oddiy `Encode` workflow'idan farqi:

- manba: R2'dagi **`aniraxuz`** bucket (oddiy `Encode` esa `anime` bucket'dan
  oladi);
- video **H.265 / HEVC** (`libx265`) bilan kodlanadi;
- videoga **hech qanday logotip va hech qanday rasm (cover-intro) qo'yilmaydi**;
  papka ichidagi `.png` fayllar butunlay e'tiborga olinmaydi;
- **bitrate chegaralari yo'q** — fayl hajmi kichik bo'lishi uchun sifatga
  asoslangan **CRF** rejimi ishlatiladi;
- tayyor videolar **akkountning o'zining Saqlangan xabarlariga** (Saved
  Messages) yuboriladi — Pyrogram'dagi `me`. Logotip fayli ham,
  `TG_USER_ID` sekreti ham kerak emas;
- audio AAC, stereo, 44.1 kHz (720p va yuqorisi — 128k, pastrog'i — 96k).

### Sifatlar avtomatik tanlanadi

Manbaning balandligiga qarab, **hech qachon upscale qilinmaydi**:

| Manba | Tayyorlanadigan sifatlar |
|---|---|
| 1080p | 1080p, 720p, 480p, 360p |
| 720p | 720p, 480p, 360p |
| 480p | 480p, 360p |
| 360p | faqat 360p |

1080p'dan baland manba (1440p, 2160p) 1080p'ga tushiriladi — undan yuqorisi
tayyorlanmaydi. Nostandart balandlik (masalan 1070p) eng yuqori sifat
sifatida o'z holicha, `scale`'siz kodlanadi.

Har sifat **AYNAN BIR XIL asl manbadan** chiqariladi (hech biri boshqasidan
qayta siqilmaydi), shuning uchun **barcha sifatning davomiyligi
mikrosekundigacha bir xil** bo'ladi.

### Resume — ish o'chib qolsa qayerdan davom etadi

Har sifat uchun tartib qat'iy:

1. sifat kodlanadi,
2. Telegramga **to'liq** yuboriladi,
3. shundan keyingina R2'dagi shu papkaga `<sifat>.md` marker fayli yuklanadi,
4. keyingi sifatga o'tiladi.

Actions limiti tugab ish o'chib qolsa, papka R2'da qoladi va tugagan
sifatlarning markerlari ham qoladi:

```
s3://aniraxuz/1-qism/seg_0001.ts ...
s3://aniraxuz/1-qism/1080p.md     <- tayyor
s3://aniraxuz/1-qism/720p.md      <- tayyor
```

Qayta ishga tushirilganda markeri **bor** sifatlar o'tkazib yuboriladi —
yuqoridagi holatda ish to'g'ridan-to'g'ri 480p'dan davom etadi. Eng oxirgi
sifat ham tugagach, papka va ichidagi hamma narsa (markerlar bilan birga)
R2'dan o'chiriladi.

Shu sababli hamma sifat bitta `ffmpeg` buyrug'ida (`split` filtri bilan)
emas, **har biri alohida** kodlanadi. Bitta buyruqda ~13% tezroq bo'lardi,
lekin ish o'chganda hammasi yo'qolar edi.

Agar papkada faqat markerlar qolsa (o'chirish yarim ishlagan holat), keyingi
run uni "allaqachon tugagan" deb tanib, shunchaki tozalab tashlaydi.

### Bucket ro'yxati har safar qaytadan o'qiladi

Bitta papka to'liq tugab R2'dan o'chirilgach, bucket **qaytadan** ro'yxatga
olinadi. Shuning uchun workflow ishlayotgan paytda telefondan yuklagan yangi
papkalar ham **shu run'da** ishlanadi — workflow'ni qayta ishga tushirish
shart emas.

Buning bitta xavfi bor: workflow siz hali yuklab bo'lmagan papkani olib
ketishi mumkin (284 ta `.ts` dan 50 tasi yuklangan bo'lsa — yarim video).
Shuning uchun papkadagi eng yangi faylning yoshi tekshiriladi: `R2_SETTLE_MIN`
daqiqadan yosh bo'lsa (standart **2**), papka bu aylanishda o'tkazib
yuboriladi va keyingi aylanishda o'z-o'zidan navbatga qaytadi. `0` qilsa
tekshiruv o'chadi.

### Telegram sarlavhasi

Video tagida **bucketdagi papka nomi** va sifat yoziladi. Papka nomidagi
pastki chiziqlar bo'sh joyga aylanadi, `TRIM_SEC` prefiksi esa sarlavhaga
tushmaydi.

Masalan `s3://aniraxuz/30_2-fasl_367-qism/` papkasi uchun:

```
2-fasl 367-qism
1080p
```

Fayllar kattadan kichikka ketma-ket yuboriladi (1080p → 720p → 480p → 360p),
har biri yuborilgach runner diskidan darhol o'chiriladi. Hammasi
muvaffaqiyatli yuborilgandan keyingina papka R2'dan o'chiriladi.

### Fayl hajmini boshqarish

Workflow ichidagi `env:` qiymatlari:

| O'zgaruvchi | Standart | Ta'siri |
|---|---|---|
| `H265_CRF` | `30` | 1080p uchun BASE. Qiymat **katta** bo'lsa fayl **kichik** bo'ladi (32, 34...), sifat pasayadi |
| `H265_PRESET` | `medium` | `slow` — yana kichikroq fayl, lekin kodlash ancha sekin |

Past sifatlar BASE'dan avtomatik pastroq CRF oladi (pleyer ularni cho'zib
ko'rsatadi, shuning uchun artefaktlar kattalashadi):

| Balandlik | CRF |
|---|---|
| ≥1080p | BASE (30) |
| ≥720p | BASE−1 (29) |
| ≥480p | BASE−2 (28) |
| <480p | BASE−3 (27) |

⚠️ `slow` preset'da uzun epizodlar GitHub runner'ining 360 daqiqalik
chekloviga yetib qolishi mumkin — avval bitta epizodda sinab ko'ring.

### Ishlatiladigan skriptlar

- `scripts/process_all_h265.sh` — bosh oqim: R2 → kodlash → Telegram →
  marker → R2'dan tozalash, va papka ro'yxatini qayta o'qish.
- `scripts/encode_h265.sh` — ffmpeg qismi, uchta rejimda:

  ```sh
  scripts/encode_h265.sh --plan   <papka>           # sifatlar ro'yxatini tuzadi
  scripts/encode_h265.sh --render <papka> 720p      # faqat bitta sifatni kodlaydi
  scripts/encode_h265.sh          <papka>           # hammasini ketma-ket (qo'lda sinash)
  ```
