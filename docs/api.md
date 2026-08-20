# API

Base URL: `https://api.gluk.tech`. Только HTTPS. Все тела запросов и ответов — JSON.
Валидация входа — zod на каждом endpoint'е. Точные типы ответов — в
`control-server/src/types.ts`.

## Ошибки

Единый формат:

```json
{ "error": { "code": "FORBIDDEN", "message": "User is disabled" } }
```

| Код | Когда |
| --- | --- |
| 400 | валидация не прошла (`details` содержит поля) |
| 401 | нет токена, токен истёк, подпись неверна, неверный логин/пароль |
| 403 | пользователь отключён, устройство отозвано, нет прав админа, нет подписки |
| 404 | объект не найден или не принадлежит вызывающему |
| 409 | конфликт: лимит устройств, ключ уже занят, лимит сессий |
| 429 | rate limit или троттлинг логина (`retryAfterSec`) |
| 503 | БД недоступна, нода недоступна |

Общий rate limit: 120 запросов/мин на IP. Ниже указаны только переопределённые
лимиты.

## Сводная таблица

| Метод | Путь | Доступ | Лимит |
| --- | --- | --- | --- |
| GET | `/api/health` | открыто | — |
| POST | `/api/auth/login` | открыто | 10/мин |
| POST | `/api/auth/refresh` | refresh-токен | 60/мин |
| POST | `/api/auth/logout` | user | — |
| GET | `/api/auth/me` | user | — |
| POST | `/api/devices/register` | user | 20/мин |
| GET | `/api/devices` | user | — |
| DELETE | `/api/devices/:id` | user | — |
| GET | `/api/nodes` | user | — |
| GET | `/api/nodes/:id` | user | — |
| POST | `/api/vpn/connect` | device-scoped | 20/мин |
| POST | `/api/vpn/disconnect` | device-scoped | 30/мин |
| GET | `/api/vpn/status` | device-scoped | — |
| GET | `/api/vpn/sessions` | user | — |
| POST | `/api/node/register` | enrollment-токен | 10 / 10 мин |
| POST | `/api/node/heartbeat` | node-токен | 120/мин |
| POST | `/api/node/report` | node-токен | 60/мин |
| POST | `/api/node/commands/:id/ack` | node-токен | 120/мин |
| POST | `/api/node/token/rotate` | node-токен | 5/час |
| GET | `/api/admin/overview` | admin | — |
| GET | `/api/admin/nodes` | admin | — |
| POST | `/api/admin/nodes/enrollment-token` | admin | — |
| POST | `/api/admin/nodes/:id/disable` | admin | — |
| POST | `/api/admin/nodes/:id/enable` | admin | — |
| DELETE | `/api/admin/nodes/:id` | admin | — |
| GET | `/api/admin/users` | admin | — |
| POST | `/api/admin/users` | admin | — |
| POST | `/api/admin/users/:id/disable` | admin | — |
| POST | `/api/admin/users/:id/enable` | admin | — |
| GET | `/api/admin/devices` | admin | — |
| POST | `/api/admin/devices/:id/revoke` | admin | — |
| GET | `/api/admin/sessions` | admin | — |
| POST | `/api/admin/sessions/:id/close` | admin | — |
| GET | `/api/admin/audit` | admin | — |

Уровни доступа: `user` — `Authorization: Bearer <accessToken>`;
`device-scoped` — тот же токен, но обязательно с `deviceId` в claims (выдаётся
после регистрации устройства); `admin` — токен пользователя с `isAdmin`;
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

### DELETE /api/devices/:id

Отзыв устройства: `{ "ok": true, "closedSessions": 1, "revokedTokens": 2 }`.
Побочные эффекты: refresh-токены аннулированы, сессия закрыта, на ноду
поставлен `REMOVE_PEER`.

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

`POST /api/admin/nodes/enrollment-token` — выдаёт одноразовый токен для
регистрации новой ноды (TTL 30 минут).

`POST /api/admin/nodes/:id/disable` — нода больше не выдаётся клиентам, все её
сессии закрываются, peer'ы удаляются. `DELETE /api/admin/nodes/:id` удаляет
запись с токенами, арендами и командами.

`POST /api/admin/users` — создаёт пользователя и возвращает сгенерированный пароль
один раз. `disable` закрывает сессии и аннулирует токены.

`GET /api/admin/audit` — хвост аудит-лога с пагинацией.

Веб-админка (`/admin`) — статика, которая вызывает ровно эти же endpoints с
токеном админа. Собственных привилегий у неё нет.

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
