# Раунд 8 — регистрация, стабилизация сети, каналы, авто-обновления

Ветка: `desktop/beta`. PROD не тронут.

---

## 0. Что нужно сделать руками — без этого не заработает

### 0.1. Секреты в `.env` (обязательно)

`.env.example` лежит в git, поэтому реальные значения в него **не вписаны**. Их
нужно вставить в настоящий `control-server/.env` на сервере и закрыть файл:
`chmod 600 .env`.

| Переменная | Значение |
| --- | --- |
| `SMTP_HOST` | `smtp.zoho.com` |
| `SMTP_PORT` | `465` |
| `SMTP_SECURE` | `true` |
| `SMTP_USER` | `noreply@gluk.tech` |
| `SMTP_PASSWORD` | пароль Zoho (передан в чате) |
| `SMTP_FROM` | `GlukVPN <noreply@gluk.tech>` |
| `TELEGRAM_BOT_TOKEN` | токен бота (передан в чате) |
| `TELEGRAM_BOT_USERNAME` | можно оставить пустым — бот сам спросит своё имя у Telegram |
| `TELEGRAM_BOT_IN_PROCESS` | `true`, если бот должен жить внутри API |
| `TURNSTILE_SECRET_KEY` | секретный ключ капчи (передан в чате) |
| `TURNSTILE_ENABLED` | `true` |
| `SITE_BASE_URL` | `https://vpn.gluk.tech` |
| `VERIFICATION_CODE_TTL_MIN` | `5` |
| `SELF_REGISTRATION_ENABLED` | `true` |

**Site key** капчи публичный, он уже лежит в `site/assets/js/config.js` — это
нормально, так Turnstile и работает.

### 0.2. Миграция базы (обязательно)

В схеме появилась таблица `pending_registrations` и поля `telegram*` у `users`.
Без миграции TypeScript даже не соберётся:

```bash
cd control-server
npx prisma migrate dev --name round8_registration
npx prisma generate
npm run typecheck
```

### 0.3. Go-воркер туннеля

```bash
cd native/glukvpn-tunnel-service/go/glukvpn-wg
go mod tidy
go build ./...
```

`go mod tidy` обязателен: добавились вызовы `winipcfg` для маршрутов.

### 0.4. Телеграм-бот одним скриптом

```bash
npm run bot:dev     # из исходников, для проверки
npm run bot         # из dist, на сервере
```

Если `TELEGRAM_BOT_IN_PROCESS=true`, отдельно запускать не нужно — бот
поднимается вместе с API.

### 0.5. Манифест версий и установщики

`site/api/version.json` должен отдаваться как `https://vpn.gluk.tech/api/version.json`.
В нём стоит **текущая опубликованная** версия `1.0.0` — писать `1.0.1`, пока
инсталлятора нет, нельзя: все клиенты получат баннер со ссылкой на 404.
Порядок релиза описан внутри файла в поле `_notes`.

### 0.6. Шлюзы расширения на ноде

| Порт | Куда смотрит |
| --- | --- |
| `de-01.gluk.tech:8443` | PROD API `127.0.0.1:8081` |
| `de-01.gluk.tech:8444` | BETA API `127.0.0.1:8082` |

---

## 1. Регистрация, вход и восстановление пароля

Логика одна на все платформы: сайт — единственное место, где вводят пароль.
Windows и расширение открывают сайт по ссылке, телефон получит свой экран.

Последовательность: почта + пароль дважды → 6-значный код на почту →
верификация в Telegram (бот просит контакт и записывает номер) → аккаунт создан.
Вход через Google пропускает код на почту, но **не** пропускает Telegram.

| Файл | Изменение |
| --- | --- |
| `control-server/prisma/schema.prisma` | модель `PendingRegistration`, поля `telegramId/Username/Phone/VerifiedAt` у `User`, `providerName/providerPhone` у `IdentityLink`, цель кода `TELEGRAM_LINK` |
| `control-server/src/services/mailer.ts` | **новый.** SMTP-клиент на `node:net`/`node:tls`: implicit TLS для 465, `AUTH LOGIN`, RFC 2047 в теме, base64 тело. Без внешних зависимостей, пароль никогда не попадает в логи |
| `control-server/src/services/registration.ts` | **новый.** Вся машина регистрации: `startRegistration`, `resendRegistrationCode`, `confirmRegistrationEmail`, `startGoogleRegistration`, `registrationStatus`, `attachTelegram`, `startTelegramRebind`, `sweepExpiredRegistrations`. Заявка живёт 30 минут |
| `control-server/src/services/telegramBot.ts` | **новый.** Long-polling бот одним скриптом: `/start <код>` → кнопка «Отправить контакт» → запись номера. Чужой пересланный контакт отклоняется (`contact.user_id !== from.id`) |
| `control-server/src/services/captcha.ts` | **новый.** Turnstile: явный отказ — блокируем, сетевая ошибка — пропускаем (капча не должна ронять регистрацию) |
| `control-server/src/services/verification.ts` | коды теперь реально доставляются: EMAIL через mailer, TELEGRAM через бота; заглушка `MAILER_IMPLEMENTED` удалена |
| `control-server/src/routes/register.ts` | **новый.** `GET /api/auth/config`, `POST /api/auth/register/start|resend|verify-email`, `GET /api/auth/register/status`, `POST /api/auth/password/forgot|reset`, `POST /api/auth/password`, `POST /api/auth/telegram/link`, `GET /api/auth/telegram`. На `forgot` ответ всегда одинаковый — чтобы нельзя было перебором узнать, есть ли такая почта |
| `control-server/src/config.ts` | Zoho по умолчанию, TTL кода `15 → 5` минут, `SELF_REGISTRATION_ENABLED=true`, переменные бота, капчи и `SITE_BASE_URL` |
| `control-server/src/services/monitor.ts` | каждые ~10 минут подчищает просроченные заявки и коды |
| `control-server/src/app.ts`, `server.ts`, `package.json` | подключение маршрутов, автозапуск бота, скрипты `bot` и `bot:dev` |
| `site/assets/js/register.js` | **новый.** Регистрация и восстановление: шаги, капча, поллинг статуса Telegram каждые 3 с, повтор кода с блокировкой на 30 с |
| `site/register/index.html` | **новая** страница: форма → код → Telegram → готово |
| `site/recover/index.html` | **новая** страница: код на почту или в Telegram → новый пароль |
| `site/login/index.html`, `site/assets/js/login.js` | вкладка «Регистрация» ведёт на `/register/`, «Забыли пароль» — на `/recover/`. Текст про «доступ выдаётся вручную» убран |
| `site/assets/js/config.js` | `selfRegistration: true`, site key капчи, адрес манифеста версий |
| `flutter-client/lib/config.dart` | `selfRegistrationEnabled = true` |

### Коды живут 5 минут

| Файл | Изменение |
| --- | --- |
| `control-server/src/config.ts` | `VERIFICATION_CODE_TTL_MIN = 5` |
| `control-server/src/services/linkAuth.ts` | `TTL_MS = 5 * 60 * 1000` (было 10 минут) |

---

## 2. Блок 1 — критические фиксы сети и авторизации

| № | Файл | Что сделано |
| --- | --- | --- |
| 1.1 | `native/.../glukvpn-wg/main.go` | Петля маршрутизации закрыта. Перед `0.0.0.0/0` определяется физический шлюз (`GetIPForwardTable2`), для каждого IP endpoint ставится `/32` через него с метрикой 0, и только потом монтируется дефолт. При выходе точечные маршруты снимаются |
| 1.2 | `native/.../glukvpn-wg/main.go` | `CreateTUNWithRequestedGUID` с фиксированным GUID — больше никаких `GlukVPN 1..4` |
| 1.3 | `flutter-client/lib/desktop/state/desktop_vpn_controller.dart` | Домен ноды резолвится **до** `_tunnel.up()`: чистый IP уходит и в `endpointIps` (для WFP), и в конфиг WireGuard. Kill Switch больше не блокирует DNS, который сам же и нужен |
| 1.4 | `site/assets/js/login.js` | `?next=` работает. Разрешены только относительные пути — абсолютный URL в параметре это open redirect |
| 1.5 | `glukvpn-extension-1.5.0/extension/{background.js,lib/api.js,ui/popup.js}` | Расширение перешло на `/api/auth/link/*`. Старый мост через content-script заменён: `link/start` → сайт подтверждает → `link/poll` отдаёт токены. `pollSecret` не покидает service worker. Ожидание переживает выгрузку worker'а (состояние в storage + alarm), код показывается в попапе |

---

## 3. Блок 2 — каналы Prod / Beta

| № | Файл | Что сделано |
| --- | --- | --- |
| 2.1 | `extension/background.js` | Порт шлюза выбирает **канал**, а не сохранённое значение: prod → 8443, beta → 8444. Раньше старый `8443` в настройках уезжал вместе с пользователем в beta и шлюз вечно отвечал 407. Нестандартный порт (например 9443) по-прежнему уважается |

---

## 4. Блок 3 — авто-обновления

| № | Файл | Что сделано |
| --- | --- | --- |
| 3.1 | `site/api/version.json` | **новый** манифест. Ссылки на загрузки относительные — файл переживёт смену домена |
| 3.2 | `flutter-client/lib/services/update_checker.dart` | **новый.** Опрос при старте и каждые 4 часа, сравнение semver (`1.10.0` новее `1.9.3`), `minSupportedVersion` даёт баннер, который нельзя закрыть. Ошибка проверки молчит: VPN работает и на старой версии |
| 3.2 | `flutter-client/lib/config.dart` | `appVersion`, `appBuild`, `siteBaseUrl`, `updateManifestUrl`, `updateCheckInterval` |

---

## 5. Блок 4 — бесшовный деплой

| № | Файл | Что сделано |
| --- | --- | --- |
| 4.1 | `flutter-client/lib/desktop/state/desktop_vpn_controller.dart` | Вместо одной тихой попытки — лестница 1s, 2s, 4s, 8s, 16s, 30s (6 шагов ≈ минута). Фаза остаётся `connecting`, то есть «переподключаемся», а не красная ошибка. Ручной `Connect` начинает лестницу заново, автоматический — нет. Если пользователь нажал «Отключить» во время ожидания, реконнект отменяется |

---

## 6. Что ещё не сделано (честно)

| Пункт | Состояние |
| --- | --- |
| Баннер обновления в интерфейсе | **сделано на Windows**: `desktop/widgets/update_banner.dart`, вставлен над всеми экранами в `desktop_shell.dart`, сам опрашивает манифест. На Android и в попапе расширения ещё не нарисован |
| Скрытое меню разработчика (5 кликов по версии) | **сделано на Windows**: `desktop/widgets/dev_channel_switch.dart`. 5 кликов по номеру версии в настройках → симметричный переключатель Prod/Beta, смена канала выходит из аккаунта. Сборка без `ALLOW_BETA_CHANNEL` отказывает в beta жёстко. Выбор пока не сохраняется между запусками (нужно поле в `DesktopSettings`); на Android и в расширении ещё нет |
| Экран регистрации на телефоне | не сделано. Бэкенд и сайт готовы, экран Flutter — следующий шаг |
| Отдельный экран «Аккаунт» на телефоне | не сделано (на Windows уже есть) |
| Смена пароля/почты и перепривязка Telegram в личном кабинете сайта | API готов (`/api/auth/password`, `/api/auth/email`, `/api/auth/telegram/link`), `site/assets/js/account.js` ещё не подключён |
| Английские копии `/register/` и `/recover/` | не сделано |
| Новые CSS-классы страниц регистрации | часть классов (`reg-steps`, `captcha`, `input--code`, `choice`) может отсутствовать в `auth.css` — страницы работают, но выглядят проще, чем задумано |
| Тарифы Free / Basic / Pro | отдельная задача, как договаривались |

---

## 7. Как проверить

1. `.env` заполнен → `npx prisma migrate dev` → `npm run build` → `npm start`.
2. `GET /api/auth/config` возвращает `selfRegistration: true` и `telegram.enabled: true`.
3. `/register/`: почта + пароль → письмо с кодом приходит с `noreply@gluk.tech` →
   код принят → открывается бот → «Отправить контакт» → страница сама
   переключается на «Готово».
4. Код, введённый через 6 минут, отклоняется.
5. `/recover/`: код на почту и код в Telegram, оба меняют пароль.
6. Windows: подключение поднимается, интернет **есть**, в «Сетевых
   подключениях» один адаптер `GlukVPN`, а не четыре.
7. Перезапуск API во время подключения: клиент показывает «переподключаемся» и
   возвращается сам, без нажатий.
8. Расширение: «Войти через сайт» открывает `/link?code=...`, после
   подтверждения попап входит сам; в beta шлюз идёт на `:8444`.
