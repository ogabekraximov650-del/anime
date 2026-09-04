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
