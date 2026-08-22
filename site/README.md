# GlukVPN — маркетинговый сайт (vpn.gluk.tech)

Статический сайт: чистый HTML + CSS + JS, без сборщиков, без npm, без внешних CDN.
Любой веб-сервер (nginx, Caddy, Vercel, Cloudflare Pages, GitHub Pages) отдаёт папку как есть.

## Локальный просмотр

```bash
cd site
python3 -m http.server 8080
# открыть http://localhost:8080
```

Сайт не требует VPN API: все данные (регионы, пинги, тарифы) лежат в `assets/js/config.js`
и отрисовываются локально. Если API недоступен — страница выглядит и работает так же.

## Структура

```
index.html            /            главная
features/index.html   /features    возможности
app/index.html        /app         приложение
pricing/index.html    /pricing     тарифы
download/index.html   /download    загрузки
support/index.html    /support     поддержка
privacy/index.html    /privacy     политика конфиденциальности
terms/index.html      /terms       условия использования
404.html                           страница ошибки
robots.txt  sitemap.xml  site.webmanifest  favicon.ico
assets/css/  assets/js/  assets/img/  assets/fonts/
```

## Что и где менять

| Задача | Файл |
|---|---|
| Цены, названия тарифов, валюта | `assets/js/config.js` → `plans` |
| Регионы, пинги, загрузка, «скоро» | `assets/js/config.js` → `regions`, `regionsSoon` |
| Ссылка на APK, Google Play | `assets/js/config.js` → `download` |
| Telegram, e-mail поддержки, домен | `assets/js/config.js` → `contacts` |
| Цвета, радиусы, тайминги | `assets/css/tokens.css` |
| Тексты страниц | соответствующий `*.html` |

`config.js` — единственный источник цен и регионов: HTML содержит те же значения статически
(чтобы страница читалась без JS и была видна поисковикам), а скрипт при загрузке
перерисовывает блоки из конфига. Достаточно поменять config — обе версии совпадут.

## Анимация

- `assets/js/globe.js` — глобус из точек мира (`world-dots.js`), маршруты, пульсы узлов.
- `assets/js/network-map.js` — карта сети с узлами, маршрутами и тултипами.
- `assets/js/sections.js` — reveal-анимации, FAQ, счётчики, демо-статистика телефона.
- Всё уважает `prefers-reduced-motion`: анимации останавливаются, статика остаётся.
- Canvas-сцены останавливаются, когда секция вне вьюпорта (IntersectionObserver).

## Шрифты

См. `assets/fonts/README.txt`. По умолчанию Poppins берётся из системы,
иначе — системный fallback. Положите три `.woff2` в `assets/fonts/`, чтобы захостить локально.

## Деплой (nginx, пример)

```nginx
server {
    server_name vpn.gluk.tech;
    root /var/www/gluk-site;
    index index.html;
    location / { try_files $uri $uri/ $uri/index.html =404; }
    error_page 404 /404.html;
    location /assets/ { expires 30d; add_header Cache-Control "public, immutable"; }
}
```

Сайт — только публичная витрина. Никаких внутренних адресов, портов, имён нод
и диагностики в разметке нет.
