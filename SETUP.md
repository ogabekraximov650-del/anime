# Sozlash yo'riqnomasi

Bu repo Termux orqali push qilingan video-bo'laklarni GitHub Actions'da
(ffmpeg bilan) tayyorlaydi va tayyor videoni sizning shaxsiy Telegram
akkountingizga (Pyrogram sessiyasi orqali) avtomatik yuboradi.

## 1. Repo tarkibi (Termux'dan push qilishdan oldin)

Repo ildizida quyidagilar bo'lishi kerak:

```
logo.png                 # doim mavjud bo'lishi kerak, videoning burchagiga qo'yiladi
<epizod_nomi>.png        # shu epizodning cover rasmi (folder nomi bilan bir xil)
<epizod_nomi>/           # papka, ichida:
    seg_0001.ts
    seg_0002.ts
    ...
```

Bitta push'da bir nechta epizod papkasini birga yuborishingiz mumkin —
workflow har birini navbat bilan qayta ishlaydi.

**Diqqat — fayl hajmi:** oddiy `git push` orqali bitta fayl 100 MB'dan katta
bo'lsa, GitHub uni rad etadi (Git LFS kerak bo'ladi). `seg_*.ts` bo'laklari
odatda kichik bo'ladi, lekin ularning umumiy hajmi katta bo'lishi mumkin —
bu git push tezligiga (ayniqsa mobil internetda) ta'sir qiladi.

## 2. Kerakli GitHub Actions sekretlari

Repo sahifasida: **Settings → Secrets and variables → Actions → New repository secret**
orqali quyidagi 4 ta sekretni qo'shing:

| Nomi | Qiymati |
|---|---|
| `TG_API_ID` | Telegram API ID (my.telegram.org'dan) |
| `TG_API_HASH` | Telegram API Hash |
| `TG_CHAT_ID` | Video yuboriladigan chat/kanal ID yoki username (masalan `me` — Saved Messages, yoki `-100xxxxxxxxxx`) |
| `PYRO_SESSION_B64` | pastda tushuntirilgan — sizning `pyro_session.session` faylingizning base64 shakli |

### `PYRO_SESSION_B64` ni qanday olish kerak

Bu — sizning shaxsiy Telegram akkountingizga kirish huquqini beruvchi maxfiy
kalit. **Uni hech qachon chatga yozmang yoki boshqa birov bilan
baham ko'rmang.** Buni faqat o'zingizning Termux terminalingizda, sizda
mavjud `pyro_session.session` fayli ustida bajaring:

```sh
cd /path/to/pyro_session.session/joylashgan/papka
base64 -w0 pyro_session.session
```

Chiqqan uzun matnni to'liq nusxalab, GitHub'ning `PYRO_SESSION_B64` sekret
maydoniga joylashtiring (GitHub Secrets shifrlangan holda saqlaydi, ish
jarayonidan tashqarida hech kim, hatto siz ham, uni qayta ko'ra olmaysiz).

Agar Termux'da `gh` (GitHub CLI) o'rnatilgan va login qilingan bo'lsa,
buni bitta buyruq bilan ham qilsa bo'ladi:

```sh
base64 -w0 pyro_session.session | gh secret set PYRO_SESSION_B64 --repo ogabekraximov650-del/anime
```

## 3. Ishlash tartibi

1. Termux'dan yangi epizod papkasi + cover rasm bilan `main` branch'ga push qilasiz.
2. GitHub Actions avtomatik ishga tushadi (`.github/workflows/prepare-and-upload.yml`):
   - `ffmpeg` bilan `Final_<epizod>_H264.mp4` yaratadi (`scripts/encode.sh`);
   - `scripts/telegram_upload.py` orqali videoni `TG_CHAT_ID`ga yuboradi;
   - Muvaffaqiyatli yuklangandan so'ng, manba bo'laklar, cover rasm va
     yaratilgan mp4 repo'dan o'chiriladi va bu tozalash avtomatik commit
     qilinadi (`[skip encode]` belgisi bilan, bu commit workflow'ni qayta
     ishga tushirmaydi).
3. Agar kodlash yoki yuklash muvaffaqiyatsiz tugasa — manba fayllar repo'da
   qoladi, xatoni "Actions" bo'limidan ko'rib, tuzatib qayta push qilishingiz
   yoki muvaffaqiyatsiz "run"ni GitHub Actions sahifasidan qayta ishga
   tushirishingiz (Re-run jobs) mumkin.

## 4. Eslatma

- Workflow faqat `push` orqali ishga tushadi — qo'lda trigger qilish
  (`workflow_dispatch`) qo'shilmagan.
- `pyro_session.session` fayli har ishga tushishda sekretdan vaqtinchalik
  tiklanadi va ish tugagach `rm -f` bilan o'chiriladi — repo'da hech qachon
  saqlanmaydi (`.gitignore`da ham kiritilgan).
