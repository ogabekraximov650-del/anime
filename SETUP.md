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

`termux/upload.sh <epizod_nomi>` — berilgan epizodni (`anime/<nomi>` va
`anipng/<nomi>.png`) repo klonига ko'chiradi, shablondan
`.github/workflows/<nomi>.yml` yasaydi va hammasini birga push qiladi.

## 5. Muvaffaqiyatsizlik holati

Agar kodlash yoki yuklash muvaffaqiyatsiz tugasa, manba fayllar va workflow
fayli repo'da qoladi (tozalash qadami ishlamaydi) — "Actions" bo'limidan
xatoni ko'rib, "Re-run jobs" bilan qayta urinib ko'rishingiz mumkin.
