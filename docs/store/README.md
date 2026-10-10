# Материалы для App Store Connect

| Папка | Что внутри | Куда в App Store Connect |
|---|---|---|
| `<язык>/iPhone-17-Pro-Max/` | 6 скриншотов 1320 × 2868 | iPhone 6,9″ |
| `<язык>/iPad-Pro-13-inch-(M5)/` | 6 скриншотов 2064 × 2752 | iPad 13″ |
| `<язык>/Mac/` | 6 скриншотов 2880 × 1800 | Mac |
| `header/` | шапка страницы 3840 × 1646 (PNG и JPG) и пример, как она выглядит на iPhone | обложка страницы приложения |
| `video/` | App Preview: iPhone 886 × 1920 и iPad 1200 × 1600, по 28 с | App Preview для iPhone 6,9″ и iPad 13″ |

Папки языков: `en` — English (U.S.), `ru` — русский, `de`, `fr`, `es`, `it`,
`pt-BR` — Portuguese (Brazil), `ja`, `ko`, `zh-Hans` — Chinese (Simplified),
`th` — тайский. Файлы пронумерованы в порядке загрузки: первые три видны в
поиске.

Как сделаны: `Scripts/store-screenshots.sh <язык>` снимает экраны игры
(статус-бар и даты на языке скриншота), затем проект `SashasPuzzles-Promo`
(`src/StoreShot.tsx`, `node scripts/render-store.mjs`) кладёт их в рамку
устройства с подписью.
