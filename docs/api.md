# API

Base URL: `https://api.gluk.tech`. Только HTTPS. Все тела запросов и ответов — JSON.
Валидация входа — zod на каждом endpoint'е. Точные типы ответов — в
`control-server/src/types.ts`.

## Ошибки

Единый формат:

```json
{ "error": { "code": "account_deleted", "message": "This account has been deleted." } }
```

| Код | Когда |
| --- | --- |
| 400 | валидация не прошла (`details` содержит поля), неверный пароль при удалении аккаунта |
| 401 | нет токена, токен истёк, подпись неверна, неверный логин/пароль |
| 403 | аккаунт отключён, заблокирован или удалён, устройство отозвано, нет прав админа, нет подписки |
| 404 | объект не найден или не принадлежит вызывающему |
| 409 | конфликт: лимит устройств, ключ уже занят, лимит сессий |
| 429 | rate limit или троттлинг логина (`retryAfterSec`) |
| 503 | БД недоступна, нода недоступна |

Общий rate limit: 120 запросов/мин на IP. Ниже указаны только переопределённые
лимиты.

### Коды отказа аккаунта

Три статуса отказывают в обслуживании, и говорить о них клиент должен
по-разному. Сообщения сервера всегда английские, поэтому текст выбирается
по коду, а не по сообщению:

| Код (403) | Статус | О чём это |
| --- | --- | --- |
| `account_disabled` | `DISABLED` | аккаунт выключен, поможет поддержка |
| `account_blocked` | `BLOCKED` | аккаунт заблокирован за нарушение |
| `account_deleted` | `DELETED` | аккаунт удалён, восстановить нельзя |

Тот же набор приходит как причина закрытия сессии и в `lastClosedReason`
(`GET /api/vpn/status`), но с префиксом `user_`: `user_disabled`,
`user_blocked`, `user_deleted`. Задано всё это в одном месте —
`src/lib/accountState.ts`.

## Сводная таблица

| Метод | Путь | Доступ | Лимит |
| --- | --- | --- | --- |
| GET | `/api/health` | открыто | — |
| POST | `/api/auth/login` | открыто | 10/мин |
| POST | `/api/auth/refresh` | refresh-токен | 60/мин |
| POST | `/api/auth/logout` | user | — |
| GET | `/api/auth/me` | user | — |
| DELETE | `/api/account` | user | 3/час |
| POST | `/api/devices/register` | user | 20/мин |
| GET | `/api/devices` | user | — |
| DELETE | `/api/devices/:id` | user | — |
| GET | `/api/nodes` | user | — |
| GET | `/api/nodes/:id` | user | — |
| POST | `/api/vpn/connect` | device-scoped | 20/мин |
| POST | `/api/vpn/disconnect` | device-scoped | 30/мин |
| GET | `/api/vpn/status` | device-scoped | — |
| GET | `/api/vpn/sessions` | user | — |
| GET | `/api/user/analytics` | user | 30/мин |
| GET | `/api/billing/plans` | открыто | 60/мин |
| POST | `/api/billing/orders` | user | 10/мин |
| POST | `/api/billing/orders/sync` | user | 20/мин |
| GET | `/api/billing/trial` | открыто | 60/мин |
| POST | `/api/billing/trial/claim` | user | 5/мин |
| POST | `/api/billing/promo/check` | открыто | 20/мин |
| POST | `/api/billing/webhook/:provider` | проверка платёжки | — |
| POST | `/api/node/register` | enrollment-токен | 10 / 10 мин |
| POST | `/api/node/heartbeat` | node-токен | 120/мин |
| POST | `/api/node/report` | node-токен | 60/мин |
| POST | `/api/node/commands/:id/ack` | node-токен | 120/мин |
| POST | `/api/node/token/rotate` | node-токен | 5/час |
| GET | `/api/admin/overview` | admin, support | — |
| GET | `/api/admin/nodes` | admin, support | — |
| POST | `/api/admin/nodes/enrollment-token` | admin | — |
| POST | `/api/admin/nodes/:id/disable` | admin | — |
| POST | `/api/admin/nodes/:id/enable` | admin | — |
| DELETE | `/api/admin/nodes/:id` | admin | — |
| GET | `/api/admin/users` | admin, support | — |
| POST | `/api/admin/users` | admin | — |
| POST | `/api/admin/users/:id/disable` | admin | — |
| POST | `/api/admin/users/:id/enable` | admin | — |
| POST | `/api/admin/users/:id/block` | admin | — |
| POST | `/api/admin/users/:id/unblock` | admin | — |
| DELETE | `/api/admin/users/:id` | admin | — |
| POST | `/api/admin/users/:id/tester` | admin | — |
| POST | `/api/admin/users/:id/admin` | admin | — |
| POST | `/api/admin/users/:id/support` | admin | — |
| POST | `/api/admin/users/:id/speed-limit` | admin | — |
| POST | `/api/admin/users/:id/subscription` | admin, support | — |
| DELETE | `/api/admin/users/:id/subscription` | admin, support | — |
| GET | `/api/admin/devices` | admin, support | — |
| POST | `/api/admin/devices/:id/revoke` | admin | — |
| DELETE | `/api/admin/devices/stale` | admin | — |
| GET | `/api/admin/sessions` | admin, support | — |
| POST | `/api/admin/sessions/:id/close` | admin | — |
| GET | `/api/admin/audit` | admin, support | — |
| GET | `/api/admin/client-errors` | admin, support | — |
| GET | `/api/admin/traffic-budget` | admin, support | — |
| GET | `/api/admin/billing/provider` | admin, support | — |
| POST | `/api/admin/billing/provider` | admin | — |
| GET | `/api/admin/billing/trial` | admin, support | — |
| POST | `/api/admin/billing/trial` | admin | — |
| GET | `/api/admin/billing/promos` | admin, support | — |
| POST | `/api/admin/billing/promos` | admin | — |
| POST | `/api/admin/billing/promos/:id` | admin | — |
| DELETE | `/api/admin/billing/promos/:id` | admin | — |

Уровни доступа: `user` — `Authorization: Bearer <accessToken>`;
`device-scoped` — тот же токен, но обязательно с `deviceId` в claims (выдаётся
после регистрации устройства); `admin` — токен пользователя с `isAdmin`; `admin, support` — токен
с `isAdmin` **или** `isSupport` (саппорт читает всё, включая бюджет egress,
а из мутаций ему разрешена только подписка — см. «Роли admin и support»);
`node-токен` — `Authorization: Bearer <nodeToken>` плюс заголовок `X-Node-Id`.

## Клиентские endpoints

### POST /api/auth/login

```json
{ "username": "testuser", "password": "..." }
```

Ответ:

```json
{
  "tokenType": "Bearer",
  "accessToken": "eyJ...",
  "expiresIn": 900,
  "refreshToken": "...",
  "refreshTokenExpiresAt": "2026-09-02T10:00:00.000Z",
  "user": { "id": "...", "username": "testuser", "status": "ACTIVE",
             "isAdmin": false, "maxDevices": 3, "maxConcurrentSessions": 1 },
  "subscription": { "status": "ACTIVE", "expiresAt": "2027-08-19T..." }
}
```

После 5 неудачных попыток — 429 с `Too many failed login attempts` на 15 минут.
Ответ на неверный логин и на неверный пароль одинаковый
(`Invalid username or password`) — чтобы не давать перебирать имена.

### POST /api/auth/refresh

`{ "refreshToken": "..." }` → новая пара токенов (ротация: старый сразу
недействителен) плюс `deviceId`, если токен был привязан к устройству.

### POST /api/auth/logout

`{ "refreshToken": "..." }` — выйти на одном устройстве;
`{ "allDevices": true }` — аннулировать все refresh-токены пользователя.

### Регистрация

Воронка: почта и пароль → 6-значный код из письма → Telegram. Третий шаг
обязателен, только если `REGISTER_REQUIRE_TELEGRAM=true`. По умолчанию флаг
выключен: там, где бот недоступен, обязательный шаг даёт не меньше
регистраций, а ни одной.

| Действие | Запрос | Тело |
| --- | --- | --- |
| Начать | `POST /api/auth/register/start` | `{ email, password, passwordConfirm?, captchaToken? }` |
| Повторить код | `POST /api/auth/register/resend` | `{ email }` |
| Подтвердить почту | `POST /api/auth/register/verify-email` | `{ email, code }` |
| Статус | `GET /api/auth/register/status?email=…` | — |

`verify-email` и `status` отвечают одним набором полей:

```json
{ "state": "done", "username": "gluk_1a2b", "verified": false,
  "telegramUrl": "", "telegramCode": "" }
```

`state` — `email`, `telegram` или `done`. `telegram` значит, что аккаунта ещё
нет и создаст его бот; `done` — аккаунт есть. `verified` относится именно к
Telegram: аккаунт без привязки рабочий, но неподтверждённый, и пробный
период ему по-прежнему недоступен (`trial_telegram_required`). Привязка
делается позже через `POST /api/auth/telegram/link` — той же ручкой, что и
смена Telegram у старых аккаунтов.

Подтверждение кода идемпотентно. Повторный `verify-email` после создания
аккаунта отвечает `state: "done"`, а не ошибкой: заявка к этому моменту
уже удалена, и «регистрация не начата» было бы неправдой.

`GET /api/auth/config` отдаёт в блоке `telegram` два разных флага:

```json
{ "telegram": { "enabled": true, "required": false, "username": "glukvpnbot",
                "botChannel": "prod", "channel": "prod" } }
```

`enabled` — может ли бот вообще завершить привязку на этом канале,
`required` — заканчивается ли им регистрация. Клиент закрывает форму из-за
неработающего бота только при `required: true`.

### Безопасность аккаунта

Один и тот же набор ручек используют кабинет на сайте, телефон и ПК-версия —
поэтому «безопасность» везде выглядит одинаково.

| Действие | Запрос | Тело |
| --- | --- | --- |
| Смена пароля | `POST /api/auth/password` | `{ currentPassword, password }` → `{ ok, revokedTokens }` |
| Смена почты | `POST /api/auth/email` и `POST /api/auth/email/confirm` | `{ email }`, затем `{ code }` |
| Восстановление | `POST /api/auth/password/forgot` и `/reset` | `{ email }`, затем `{ code, password }` |
| Привязка Telegram | `POST /api/auth/telegram/link` | — → `{ url, code, expiresAt }` |
| Статус Telegram | `GET /api/auth/telegram` | — |

```json
{
  "linked": true,
  "username": "gluk_user",
  "phoneTail": "4729",
  "phoneMask": "+7 *** *** 4729",
  "verifiedAt": "2026-09-01T10:00:00.000Z",
  "botUrl": "https://t.me/…"
}
```

Номер целиком клиентам не отдаётся никогда: `phoneMask` — первая цифра и
последние четыре, остальное закрыто звёздочками. Этого хватает, чтобы владелец
узнал свой номер, и недостаточно, чтобы его узнал сосед через плечо.
`phoneTail` оставлен для старых сборок.

### DELETE /api/account

Владелец удаляет свой аккаунт сам. Тело: `{ "password": "...", "reason": "..." }`,
`reason` необязателен. Лимит — 3 запроса в час: на одну опечатку хватает, на
перебор пароля — нет.

```json
{ "ok": true, "publicId": "10758930", "closedSessions": 1,
  "removedDevices": 2, "revokedTokens": 3 }
```

Неверный пароль — `400`, а не `401`: сессия жива, ошибся только человек.
На `401` сайт и мобильный клиент ротируют токены и повторяют запрос, так что
одна опечатка стоила бы двух попыток из трёх. У аккаунтов, заведённых
через Google, пароля нет — в базе случайный хеш; такому владельцу нужно
сначала задать пароль через восстановление, и текст ошибки об этом
говорит.

Админ себя так не удалит — `409`; админский аккаунт удаляет другой
администратор. Оплаченное время не возвращается, история платежей
остаётся: ручка закрывает доступ, а не проводит возврат. Что именно
стирается — в `docs/security.md`, раздел «Удаление аккаунта».

### POST /api/devices/register

```json
{ "deviceName": "android-a1b2", "publicKey": "<base64, 44 символа>",
  "platform": "android" }
```

Публичный ключ проверяется на формат WireGuard (32 байта, base64) и на
уникальность. При повторном вызове с тем же именем устройства запись
обновляется (`device.reregister` в аудите), а не дублируется. Лимит — 3
устройства на пользователя (409 сверх лимита). В ответе — запись устройства и
перевыпущенные токены, привязанные к `deviceId`. Приватный ключ не передаётся
ни в одну сторону.

### GET /api/nodes

```json
{ "nodes": [ {
  "id": "...", "name": "de-01", "country": "Germany", "countryCode": "DE",
  "host": "203.0.113.10", "port": 51820, "status": "ONLINE", "online": true,
  "connectable": true, "loadPercent": 2, "activePeers": 1, "capacity": 50,
  "cpuPercent": 4.1, "ramPercent": 38.2, "uptimeSeconds": 84213,
  "agentVersion": "0.1.0", "lastHeartbeat": "2026-08-19T11:22:33.000Z"
} ] }
```

Публичный ключ ноды в списке не отдаётся — он приходит только в конфиге
туннеля при успешном connect.

### POST /api/vpn/connect

`{ "nodeId": "..." }` (можно опустить — выберётся менее загруженная нода).

Проверки перед выдачей: пользователь `ACTIVE`, устройство `ACTIVE`, подписка
активна, лимит одновременных сессий не превышен, нода `connectable`.

Ответ 201:

```json
{
  "session": { "id": "...", "status": "PENDING", "assignedVpnIp": "10.8.0.2",
               "connectedAt": "...", "bytesRx": 0, "bytesTx": 0,
               "node": { "id": "...", "name": "de-01", "country": "Germany" } },
  "node": { "...": "PublicNodeView" },
  "tunnel": {
    "sessionId": "...",
    "interfaceAddress": "10.8.0.2/32",
    "dns": ["1.1.1.1", "1.0.0.1"],
    "mtu": 1420,
    "peerPublicKey": "<node public key>",
    "endpoint": "203.0.113.10:51820",
    "allowedIps": ["0.0.0.0/0"],
    "persistentKeepalive": 25
  }
}
```

Повторный connect при живой сессии закрывает старую с `closeReason=reconnect`.

### GET /api/vpn/status

```json
{ "connected": true, "peerReady": true, "subscriptionActive": true,
  "session": { "...": "SessionView" }, "sessions": [], "serverTime": "..." }
```

`peerReady` становится `true` после того, как нода подтвердила `ADD_PEER`.
Клиент ждёт именно этого флага, прежде чем поднять туннель.

Кроме показанных полей ответ содержит `service` (режим обслуживания),
`lastClosedReason` (почему закрылась предыдущая сессия), `nodeMaintenance` и
`quota` — тот же блок лимита тарифа, что и в `/api/user/analytics`
(`usedBytes`, `limitBytes`, `usedPercent`, `resetsAt`, `exceeded`).
Все клиенты рисуют шкалу расхода только из этих серверных цифр.

### POST /api/vpn/disconnect

`{ "sessionId": "..." }`; поле можно опустить — тогда сервер сам найдёт живую
сессию устройства. Ответ: `{ "ok": true, "session": { "...": "SessionView" } }`.
Владелец аккаунта может закрыть сессию любого своего устройства (чужие — 404).

### POST /api/vpn/stats

Пинг живой сессии: `{ "sessionId": "...", "transport": "browser" }`.

```json
{ "ok": true, "countersAccepted": false, "session": { "...": "SessionView" } }
```

Байты (`uploadBytes` / `downloadBytes`) принимаются только от доверенного
репортера — ноды или нашего browser-proxy на loopback. У обычного клиента
они молча игнорируются, а `countersAccepted: false` показывает, что счётчики
не учтены (поле additive — старые клиенты не ломаются). Подробности и
проверочные curl-команды — в `docs/traffic-integrity.md`.

### GET /api/user/analytics

Статистика аккаунта для экранов «Статистика» и «Аналитика трафика».
Параметр один: `period=day|week|month` (по умолчанию `day`). Окна считаются
в UTC: сутки — с начала дня, неделя — с понедельника, месяц — с первого числа.
Шаг бакетов выбирает сервер, не клиент: `hour` для дня, `day` для недели и месяца.

```json
{
  "period": "week",
  "start": "2026-09-07T00:00:00.000Z",
  "end": "2026-09-14T00:00:00.000Z",
  "bucketSize": "day",
  "quota": { "...": "тот же блок, что в /api/vpn/status" },
  "coverage": { "since": "2026-09-05T15:30:00.000Z", "partial": true, "source": "server", "timezone": "UTC" },
  "totals": { "downloadBytes": 7400000000, "uploadBytes": 172000000 },
  "previous": { "start": "2026-08-31T00:00:00.000Z", "end": "2026-09-07T00:00:00.000Z", "downloadBytes": 6600000000, "uploadBytes": 159000000 },
  "trend": { "comparable": true, "downloadPercent": 12, "uploadPercent": 8, "totalPercent": 12 },
  "series": [{ "start": "2026-09-07T00:00:00.000Z", "downloadBytes": 0, "uploadBytes": 0 }],
  "devices": [{ "deviceName": "...", "platform": "windows", "downloadBytes": 0, "uploadBytes": 0 }],
  "domains": { "enabled": true, "windowDays": 7, "items": [] },
  "categories": [],
  "budget": null
}
```

`series` — сплошная сетка бакетов от `start` до текущего момента без пропусков:
для дня — все прошедшие часы суток, для недели — 7 дней, для месяца — все дни
с первого числа. Пустые бакеты приходят нулями, а не отсутствуют, иначе два
часа с трафиком растянулись бы на всю ширину графика и сутки выглядели бы
полностью закрытыми. `coverage.since` на сетку не влияет — он нужен только для
`coverage.partial` и `trend.comparable`.

`previous` — прошлое окно той же длины. Его конец обрезан по прошедшей
части текущего — `min(previous.start + elapsed, start)`, где `elapsed = now - start`.
Иначе два часа сегодняшних суток сравнивались бы с полными вчерашними
и любое утро выглядело бы катастрофой.

`trend` — уже посчитанные сервером целые проценты к `previous`
(`downloadPercent`, `uploadPercent`, `totalPercent`). Клиенты проценты не считают —
только ставят знак и подпись. Процент равен `null`, если в прошлом окне
был ноль байт (деление на ноль — не «+100 %»).

`trend.comparable` — главный флаг честности: `true` только когда история
замеров (`coverage.since`) началась не позже `previous.start`. Если `false`,
все три процента приходят `null`, а клиенты не рисуют бейдж вовсе:
отсутствие истории не есть падение трафика на 100 %.

`previous` и `trend` — additive-поля: старые клиенты их просто игнорируют.
Все цифры расхода — из серверных бакетов `TrafficUsageBucket` (пишет нода),
см. `docs/traffic-integrity.md`. `budget` отдаётся только админам и по решению
сервера (`isAdmin`), обычный пользователь получает `null`.

### DELETE /api/devices/:id

Отзыв устройства: `{ "ok": true, "closedSessions": 1, "revokedTokens": 2 }`.
Побочные эффекты: refresh-токены аннулированы, сессия закрыта, на ноду
поставлен `REMOVE_PEER`.

## Биллинг, пробный период и промокоды

Оплата идёт через внешнюю платёжку. Карта вводится на её странице: мы отдаём
`paymentUrl`, куда клиент перенаправляет пользователя, и ждём вебхук. Своих
форм для карт нет и не будет: PAN не должен проходить через наш сервер.

Платёжек три, и каждая — отдельная папка в `control-server/src/payments/` со
своими ключами: `tabpay`, `mulenpay`, `cashera`. Активную выбирает админка
(`POST /api/admin/billing/provider`), выбор лежит в `billing_settings`; пока
строки нет — решает `BILLING_PROVIDER` из `.env`. Удаление папки отключает
только её: остальные платёжки и весь остальной биллинг продолжают работать.
Сверх них есть два встроенных режима — `manual` (заказ создаётся, админ
помечает оплаченным руками) и `stripe`; пустое значение скрывает оплату.

### GET /api/billing/plans

Открытый каталог. Необязательные `?currency=RUB|KZT|USD|EUR` и `?tz=` перебивают
валюту, выбранную по `CF-IPCountry`.

```json
{
  "billingEnabled": true,
  "provider": "tabpay",
  "currency": "KZT",
  "market": { "country": "KZ", "currency": "KZT", "lang": "ru" },
  "methods": [
    { "id": "all", "label": "Все способы" },
    { "id": "SBP", "label": "СБП" },
    { "id": "CARD", "label": "Банковская карта" }
  ],
  "plans": [{ "code": "basic", "name": "Basic", "priceMinor": 79000, "currency": "KZT" }]
}
```

`methods` — способы оплаты включённой платёжки для этой валюты, универсальная
форма первой. `id` — код самой платёжки (у TabPay `SBP`/`CARD`, у Cashera
`sbp`/`card`/`crypto`), он же уходит обратно в заказ. Список пуст, когда шлюз
эту валюту не берёт, и состоит из одного `all`, когда выбор способа у шлюза
не документирован (MulenPay) — сайт тогда селектор не рисует. `minimumMinor` —
минимум конкретного рельса, если он выше общего: по нему фронт гасит способ,
который откажет (у Cashera карта не проводит платёж в 1 ₽).

### POST /api/billing/orders

Создаёт заказ и ссылку на оплату. `promoCode` необязателен; скидку считает
сервер, цифра из браузера не участвует в расчёте. `method` тоже
необязателен — это `id` из `methods`; без него (или с `all`) способ выбирается
на странице платёжки. Незакрытый заказ переиспользуется только при том же
способе оплаты: смена рельса даёт новую ссылку.

```json
{ "planCode": "basic", "currency": "KZT", "promoCode": "TIKTOK", "method": "SBP" }
```

```json
{
  "order": {
    "id": "…",
    "status": "PENDING",
    "amountMinor": 59250,
    "currency": "KZT",
    "promoCode": "TIKTOK",
    "discountMinor": 19750
  },
  "paymentUrl": "https://tabpay.org/pay/…",
  "manual": false,
  "instructions": null
}
```

Когда выбран режим `manual`, `paymentUrl` отсутствует, `manual: true`, а в
`instructions` лежит текст для ручной оплаты.

### GET /api/billing/trial

Открытый endpoint акции «Пробный период»: баннер на главной и страница
`/trial/` рисуются именно по этому ответу. Если пришёл `Authorization`, ответ
учитывает конкретного пользователя; просроченный токен — это гость, а не ошибка.

```json
{
  "billingEnabled": true,
  "provider": "tabpay",
  "methods": [{ "id": "all", "label": "Все способы" }, { "id": "SBP", "label": "СБП" }],
  "show": false,
  "trial": {
    "enabled": true,
    "planCode": "basic",
    "planName": "Basic",
    "trialPlanCode": "basic_trial",
    "days": 7,
    "eligibilityDays": 14,
    "requireTelegram": true,
    "price": { "currency": "RUB", "minor": 100, "label": "1 ₽" },
    "charge": { "currency": "RUB", "minor": 100, "label": "1 ₽" },
    "equivalents": [
      { "currency": "KZT", "minor": 10000, "label": "100 ₸" },
      { "currency": "USD", "minor": 10, "label": "$0.10" }
    ],
    "timeline": {
      "startsAt": "2026-09-09T14:00:00.000Z",
      "reminderAt": "2026-09-14T14:00:00.000Z",
      "endsAt": "2026-09-16T14:00:00.000Z",
      "reminderDays": 2
    },
    "autoRenew": false,
    "eligibility": {
      "eligible": false,
      "reason": "sign_in_required",
      "registeredAt": null,
      "eligibleUntil": null,
      "daysLeft": null
    }
  }
}
```

`reason`: `ok`, `offer_disabled`, `sign_in_required`, `telegram_required`,
`window_passed`, `already_used`, `already_subscribed`. Первые три — повод показать
акцию (с разными кнопками), остальные — повод её скрыть.

`show` — то же правило, посчитанное сервером: `billingEnabled && trial.enabled`
плюс `reason` из первых трёх. Баннер на главной и полоса над тарифами
показываются только при `show: true`; до ответа сервера они скрыты
атрибутом `hidden`.

### POST /api/billing/trial/claim

Активация акции: тело необязательно, но можно передать `{ "method": "SBP" }` —
тот же `id`, что в `methods`. Ответ `201`; при отказе — `409` с кодом
`trial_<reason>` (например `trial_already_used`, `trial_telegram_required`).

```json
{
  "order": { "id": "…", "status": "PENDING", "amountMinor": 100, "currency": "RUB" },
  "paymentUrl": "https://tabpay.org/pay/…",
  "manual": false,
  "instructions": null,
  "days": 7
}
```

Подписка выдаётся не здесь, а после вебхука со статусом `SUCCESS`.

### POST /api/billing/orders/sync

Спрашивает у платёжного шлюза судьбу последних незакрытых заказов и приводит
базу в соответствие с ним. Нужно ровно для одного случая: карта отклонена,
вебхук ещё не дошёл, а человек уже жмёт «оплатить» снова. Без этого сервер
вернул бы старую ссылку на уже отклонённый платёж.

```json
{
  "synced": [{ "orderId": "…", "status": "FAILED", "changed": true }],
  "orders": [{ "id": "…", "status": "FAILED", "amountMinor": 100, "currency": "RUB" }]
}
```

Теперь `POST /api/billing/orders` переиспользует открытый заказ только тогда,
когда шлюз подтверждает, что платёж жив. Отклонённый или истёкший — закрывается,
и создаётся новый с новой ссылкой.

### POST /api/billing/promo/check

Предварительная проверка кода — чтобы показать сумму до создания заказа.
Ничего не списывает и не расходует лимит кода. Работает и без входа: цена со
скидкой нужна гостю раньше, чем он заведёт аккаунт. Лимит «один раз на
аккаунт» проверяется только для вошедших и всегда — при создании заказа.
В ответе есть `planCode` и `planCodes` — к каким тарифам код применим.

```json
{ "code": "TIKTOK", "planCode": "basic", "currency": "KZT" }
```

```json
{
  "ok": true,
  "code": "TIKTOK",
  "percentOff": 25,
  "discountMinor": 19750,
  "amountMinor": 59250,
  "currency": "KZT"
}
```

Отказ — HTTP-ошибка с кодом `promo_not_found`, `promo_inactive`,
`promo_not_started`, `promo_expired`, `promo_plan_not_eligible`,
`promo_limit_reached`, `promo_already_used` или `promo_amount_too_small`.

### POST /api/billing/webhook/:provider

Вебхук платёжки. `:provider` — id папки: `tabpay`, `mulenpay` или `cashera`
(`stripe` живёт на отдельном маршруте и папкой не является). Адрес всегда
на API-хосте:

| Платёжка | Адрес для кабинета |
| --- | --- |
| TabPay | `https://api.gluk.tech/api/billing/webhook/tabpay` |
| MulenPay | `https://api.gluk.tech/api/billing/webhook/mulenpay?token=<MULENPAY_WEBHOOK_TOKEN>` |
| Cashera | `https://api.gluk.tech/api/billing/webhook/cashera` |

Beta — тот же путь на `beta-api.gluk.tech`. Именно API-хост: `app.gluk.tech` —
статический кабинет (GitHub Pages), он только показывает результат по
`?paid=1` / `?failed=1` и спрашивает API про заказ, но ничего не выдаёт.
Готовый адрес по каждой папке отдаёт `GET /api/admin/billing/provider`
(`gateways[].webhookUrl`).

Адрес не меняется при переключении платёжки, и вебхуки неактивной
платёжки продолжают приниматься — это те самые поздние оплаты, которые
иначе потерялись бы при переключении. Событие по заказу другой платёжки
не применяется. Неизвестный id или удалённая папка — `401`.

Подлинность каждая доказывает по-своему:

- **TabPay** — `X-Signature-V2` = HMAC-SHA256(`${X-Timestamp}.${rawBody}`) с
  `TABPAY_WEBHOOK_SECRET`, hex в нижнем регистре, окно ±300 с. Сравнение
  постоянного времени; тело берётся сырым, до JSON-разбора. Старый
  `X-Signature` тоже принимается.
- **MulenPay** — подписи нет вовсе. Проверяется `?token=` (или заголовок
  `x-webhook-token`) против `MULENPAY_WEBHOOK_TOKEN`, а статус перечитывается
  из `GET /payments/{id}`: подписка выдаётся только если MulenPay сам
  ответил `status: 3`. Пустой токен принимает любую доставку — защищает
  именно перечитывание, а не токен.
- **Cashera** — заголовки `X-Api-Key` и `X-Secret` сравниваются в постоянном
  времени с `CASHERA_API_KEY` (`pk_…`) и `CASHERA_WEBHOOK_SECRET` (`sk_…`).
  Кнопка «тестовый вебхук» в кабинете присылает `event: "webhook.test"` —
  это проба: проверяет URL и оба ключа, но к заказу не относится и ничего
  не выдаёт.

Тела разные. TabPay:

```json
{
  "id": "…",
  "orderId": "…",
  "status": "SUCCESS",
  "amountKopecks": 100,
  "telegramId": "123456789",
  "metadata": { "planCode": "basic_trial" },
  "test": true
}
```

MulenPay — наш `orderId` уезжает как `uuid`, сумма приходит строкой рублей:

```json
{ "id": 4242, "uuid": "…", "amount": "1.00", "currency": "rub", "payment_status": "success" }
```

Cashera — наш `orderId` лежит в `external_id`, сумма в копейках:

```json
{
  "event": "transaction.status_updated",
  "transaction": { "uuid": "…", "external_id": "…", "status": "paid", "amount": 100 }
}
```

Ответ всегда быстрый `{ "received": true, "provider": "tabpay", … }`. Повторная
доставка того же события безопасна: оплаченный заказ не продлевает подписку
дважды. Всё, что не провалило проверку подлинности, получает `200`: шлюз
часами ретраит не-2xx, а чужое или неприменимое событие на пятой попытке
применимым не станет; что именно произошло, видно в `handled` / `ignored`.

### Админские ручки выбора платёжки

`GET /api/admin/billing/provider` — что выбрано и что вообще установлено:

```json
{
  "billingEnabled": true,
  "provider": "mulenpay",
  "active": "mulenpay",
  "envProvider": "tabpay",
  "switchable": true,
  "builtin": ["", "manual", "stripe"],
  "gateways": [
    {
      "id": "tabpay",
      "label": "TabPay",
      "currency": "RUB",
      "installed": true,
      "configured": true,
      "active": false,
      "webhookUrl": "https://api.gluk.tech/api/billing/webhook/tabpay"
    }
  ]
}
```

`active` — что действует сейчас (строка `billing_settings`, а если её нет —
значение из `.env`); `envProvider` — что выбрал бы `BILLING_PROVIDER`, то есть
ответ на случай пропавшей строки; `switchable: false` — на сервере ещё не
применена миграция `billing_settings`: читать можно, сохранить — нет.
По папкам: `installed: false` — папка удалена, выбрать такую нельзя;
`configured: false` — папка есть, ключей нет: в списке видна, но оплата через
неё не пройдёт (состояние показывается намеренно — иначе сломанная касса
выглядела бы как отсутствующая).

`POST /api/admin/billing/provider` (только admin) — переключение:

```json
{ "provider": "cashera" }
```

Ответ: `{ "ok": true, "active": "cashera", "billingEnabled": true, "provider": "cashera" }`.
Принимаются id установленных папок и встроенные `""` (выключить оплату),
`manual`, `stripe`. Неизвестный id или удалённая папка — `400`; сервер без
миграции — `503`. В аудит пишется `admin.billing.provider` с `from`, `to` и
`enabled`. Новая папка появляется в списке после рестарта процесса:
модули кешируются.

### Админские ручки акции

`GET /api/admin/billing/trial` возвращает текущие настройки,
`POST /api/admin/billing/trial` их меняет:

```json
{ "enabled": true, "planCode": "pro", "days": 7, "eligibilityDays": 14, "requireTelegram": true, "priceKopecks": 100 }
```

Промокоды: `GET /api/admin/billing/promos`, `POST /api/admin/billing/promos`
(`code`, `description`, `percentOff`, `startsAt`, `endsAt`, `maxRedemptions`,
`perUserLimit`, `planCodes`), `POST /api/admin/billing/promos/:id` — частичное
обновление, `DELETE /api/admin/billing/promos/:id` — удаление (если кодом уже
воспользовались, он деактивируется, а не теряется).

Все изменения пишутся в аудит: `billing.trial.update`, `billing.trial.claim`,
`admin.promo.create`, `admin.promo.update`, `admin.promo.delete`.

## Endpoints ноды

### POST /api/node/register

Без обычной авторизации, но требует одноразовый enrollment-токен в теле.
Передаёт: имя, страну, публичный IP, hostname, публичный WireGuard-ключ,
порт, подсеть, DNS, MTU, capacity, версию агента.

Ответ 201: `{ nodeId, nodeToken, nodeTokenExpiresAt, heartbeatIntervalSec,
offlineAfterSec, wireguard: { ... } }`. `nodeToken` показывается единственный раз;
в БД остаётся только HMAC.

### POST /api/node/heartbeat

Тело: CPU %, RAM %, uptime, счётчики интерфейса, число peer'ов, версия.
Ответ:

```json
{ "ok": true, "serverTime": "...", "nodeStatus": "ONLINE",
  "heartbeatIntervalSec": 10, "nodeTokenExpiresAt": "...",
  "commands": [ { "id": "...", "type": "ADD_PEER",
    "payload": { "sessionId": "...", "publicKey": "...",
                 "allowedIps": ["10.8.0.2/32"] } } ] }
```

Каждый heartbeat отзывает остальные токены этой ноды — два агента с одним
`node_id` не уживутся.

### POST /api/node/report

Фактические peer'ы с rx/tx и временем handshake. Ответ:
`{ ok, removePeers: ["<pubkey>"], missingPeers: ["<pubkey>"] }`. Статистика
пишется в сессии по правилу максимума — счётчики не уменьшаются.

### POST /api/node/token/rotate

Агент ротирует токен сам за 3 дня до истечения. Старый токен остаётся валиден
до первого успешного heartbeat с новым — иначе обрыв сети в момент ротации
отрезал бы ноду навсегда.

Чего у ноды нет: ни одного endpoint'а, принимающего команды или shell,
доступа к данным пользователей, возможности выдать себе подписку или токен
пользователя.

## Admin endpoints

`GET /api/admin/overview` — сводка для dashboard: число нод по статусам,
пользователи, устройства, живые сессии, суммарный трафик.

`devices` отдаётся как `{ active, revoked, total }`. Отозванное устройство — это
удалённое устройство: строка живёт дальше только для того, чтобы прошлый
трафик остался привязанным, а повторный вход на той же машине заводит
новое. Панель брала `total` знаменателем и получалось «Devices active
3 / 54», где 51 — надгробия; теперь `revoked` показывается отдельной
строкой. Авточистка — `purgeStaleDevices` в мониторе (окно ≥ 30 дней, чтобы
статистика трафика не обнулилась задним числом), ручная —
`DELETE /api/admin/devices/stale?days=N` (`days=0` сносит всё мёртвое сразу,
активные устройства не трогает).

`POST /api/admin/nodes/enrollment-token` — выдаёт одноразовый токен для
регистрации новой ноды (TTL 30 минут).

`POST /api/admin/nodes/:id/disable` — нода больше не выдаётся клиентам, все её
сессии закрываются, peer'ы удаляются. `DELETE /api/admin/nodes/:id` удаляет
запись с токенами, арендами и командами.

`GET /api/admin/users?q=&filter=` — список пользователей. `filter` принимает
`active`, `disabled`, `blocked`, `deleted`, `admins`, `support`, `testers`,
`all`; по умолчанию и при мусоре в query-строке — `active`, а не `all`: панель
не должна открываться списком, где половина строк — надгробия удалённых
аккаунтов. Срезы по ролям (`admins`, `support`, `testers`) исключают `DELETED`,
чтобы снятый аккаунт не всплывал в роли. Ответ — `{ users, filter }`, где
`filter` — фактически применённое значение: селекту в панели есть что показать
после фолбэка. В строках `devices` и `sessions` считают только `ACTIVE` —
REVOKED-надгробия и закрытые сессии в счётчики не идут.

`POST /api/admin/users` — создаёт пользователя и возвращает сгенерированный пароль
один раз. `disable` закрывает сессии и аннулирует токены.

`POST /api/admin/users/:id/block` (`{ "reason": "..." }`) — мгновенная
блокировка: сессии закрываются с `user_blocked`, refresh-токены
аннулируются, VLESS-доступ снимается с нод следующей синхронизацией
политики, а логин отвечает `account_blocked`. Ответ —
`{ ok, closedSessions, revokedTokens }`. `unblock` возвращает статус `ACTIVE`.
Себя заблокировать нельзя (409).

`DELETE /api/admin/users/:id` (`{ "reason": "..." }`) — удаление аккаунта
надгробием: строка пользователя остаётся со статусом `DELETED`, всё личное
стирается. Ответ — `{ ok, userId, publicId, alreadyDeleted, closedSessions,
removedDevices, revokedTokens }`; вызов идемпотентен и при повторе
отвечает `alreadyDeleted: true`. Себя удалить нельзя — для этого есть
`DELETE /api/account` с паролем; у админа сначала снимают флаг.
Аудит: `admin.user.block`, `admin.user.unblock`, `admin.user.delete`,
`account.delete` и `account.delete.rejected` для самоудаления.

`POST /api/admin/users/:id/tester` (`{ "enabled": true | false }`) — флаг
бета-тестера. Клиенты (Android, Windows, расширение) показывают переключатель
PROD/BETA только при `isAdmin || isTester`, поэтому этот endpoint — единственный
способ пустить тестера на бету. В панели это колонка «Tester» и кнопка
«Бета-тестер: выдать» / «Бета-тестер: снять».

`POST /api/admin/users/:id/admin` (`{ "enabled": true | false }`) — выдача и
снятие админки. Себе флаг менять нельзя (409 «You cannot change your own
admin flag»), аккаунту со статусом `DELETED` — тоже (409). Ответ —
`{ ok, isAdmin }`, аудит — `admin.user.admin`.

`POST /api/admin/users/:id/support` (`{ "enabled": true | false }`) — флаг
саппорта (менеджера), устроен как `tester`: булево `isSupport` в таблице
`users`, приходит в `GET /api/admin/users`, в карточке пользователя и в ответе
логина (`userPayload`). Аккаунту `DELETED` не выдаётся (409). Ответ —
`{ ok, isSupport }`, аудит — `admin.user.support`.
Оба endpoint'а де-факто admin-only: гейт роли (ниже) не пускает саппорта ни в
одну мутацию, кроме подписки, поэтому роли раздаёт только админ.

`GET /api/admin/audit` — хвост аудит-лога с пагинацией.

### Роли admin и support

`requireStaff` (`src/middleware/auth.ts`) пускает в `/api/admin/*` владельцев
`isAdmin` **или** `isSupport`, остальным отвечает 403 «Admin privileges
required». Что саппорт может внутри, решает второй `preHandler`:

| Роль | Чтение (GET/HEAD) | Запись |
| --- | --- | --- |
| admin | всё | всё |
| support | всё | только `POST` и `DELETE /api/admin/users/:id/subscription` |

Записи для саппорта — **allow-list** (`SUPPORT_ALLOWED_WRITES`), а не deny-list:
endpoint, добавленный завтра, остаётся admin-only, пока его не внесли в список
руками; обратный порядок раздавал бы ему каждую новую мутацию молча.
Закрытых чтений больше нет: `SUPPORT_DENIED_READS` пуст. Бюджет egress саппорт
тоже видит — это ответ на «почему вчера было медленно», а не только деньги;
границу роли держит allow-list записи, а не спрятанные цифры. Путь сверяется
без query-строки, админ до проверок не доходит.

В токене флаги есть (`adm`, `sup` в `AccessTokenPayload`), но они справочные —
для бейджей и UI. Авторизация всегда перечитывает строку пользователя
(`requireUser`), поэтому снятая роль действует сразу, а не со следующего
refresh; старый токен с `sup: true` доступа не даёт.

Веб-админка (`/admin`) — статика, которая вызывает ровно эти же endpoints с
токеном админа или саппорта. Собственных привилегий у неё нет: саппорту
`applyRoleVisibility()` прячет вкладки «Channels» и «Billing», сервисные кнопки,
создание пользователей, enrollment нод и чистки, а в строках пользователей
оставляет только выдачу и снятие подписки. Блок «Oracle Cloud: Egress & Costs
(PAYG)» саппорту теперь показывается и грузится вместе с журналом клиентских
ошибок: расход трафика нужен ему в работе, а выключить ноду он всё равно не
может. Это косметика поверх серверного гейта: запрос в обход UI всё равно
получит 403.

## Проверка вручную

```sh
API=https://api.gluk.tech
curl -fsS $API/api/health

TOKEN=$(curl -fsS -X POST $API/api/auth/login \
  -H 'content-type: application/json' \
  -d '{"username":"testuser","password":"..."}' | jq -r .accessToken)

curl -fsS $API/api/nodes -H "authorization: Bearer $TOKEN" | jq
curl -fsS $API/api/vpn/status -H "authorization: Bearer $TOKEN" | jq

# ожидаемые отказы
curl -s -o /dev/null -w '%{http_code}\n' $API/api/nodes                  # 401
curl -s -o /dev/null -w '%{http_code}\n' $API/api/admin/overview \
  -H "authorization: Bearer $TOKEN"                                     # 403
```
