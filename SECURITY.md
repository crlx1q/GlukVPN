# SECURITY — модель безопасности GlukVPN

Документ отвечает на практические вопросы: где лежит каждый секрет, кто его
видит, какой трафик куда идёт и что именно ломается при компрометации.

Это прототип. Где есть осознанный компромисс — он назван прямо, а не спрятан.

---

## 1. Где лежат ключи и секреты

| Секрет | Где хранится | Кто читает | Форма хранения |
| --- | --- | --- | --- |
| Приватный WireGuard-ключ устройства | только телефон, `flutter_secure_storage` (Android `EncryptedSharedPreferences`) | только само приложение | сырые 32 байта в base64 |
| Публичный ключ устройства | БД control plane, таблица `devices` | API, агент ноды | открыто (это не секрет) |
| Приватный WireGuard-ключ ноды | нода, `/etc/wireguard/node.key` (root, 0600) | только ядро/`wg` | сырой ключ |
| Публичный ключ ноды | БД, `vpn_nodes.wireguard_public_key` | API, клиенты | открыто |
| Пароль пользователя | БД, `users.password_hash` | только API при логине | **Argon2id**, m=19456 KiB, t=2, p=1, соль внутри хеша |
| Refresh-токен | телефон (secure storage) + БД | API | в БД только **HMAC-SHA256(token, TOKEN_HASH_PEPPER)** |
| Access-токен (JWT) | только память приложения | API проверяет подпись | не хранится нигде |
| `JWT_SECRET` | `/etc/vpn-control/control.env` (root:vpncontrol 0640) | только процесс API | случайные 48 байт |
| `TOKEN_HASH_PEPPER` | там же | только процесс API | случайные 48 байт |
| Пароль PostgreSQL | там же, в `DATABASE_URL` | только процесс API | случайные 24 байта |
| Node token | нода, `/etc/vpn-node-agent/agent.env` (vpnagent 0600) | только агент | в БД — только HMAC-SHA256 с pepper'ом |
| Enrollment token ноды | печатается один раз | владелец сервера | в БД — HMAC, TTL 30 минут, одноразовый |
| Android keystore | локально + GitHub Secrets | GitHub Actions | base64 в secret, в runner только `/tmp`, удаляется после подписи |
| SSH-ключ сервера | только ваша машина | вы | в проекте не используется и не хранится |

Ни один секрет не лежит в Git: `.gitignore` исключает `.env*`, `*.jks`,
`*.keystore`, `key.properties`. В репозитории есть только `.env.example` с
пустыми значениями.

### Почему токены хранятся как HMAC, а не как Argon2

Refresh- и node-токены — это 32 случайных байта, их невозможно перебрать словарём,
поэтому медленный KDF здесь не нужен — нужна быстрая проверка на каждый
heartbeat (раз в 10 секунд). Pepper в env даёт главное свойство: дамп БД без
доступа к env-файлу бесполезен. Пароли пользователей — наоборот, человеческие и
слабые, там Argon2id обязателен.

## 2. Какие данные передаются

**Телефон → control plane (HTTPS):** username и пароль только в `/api/auth/login`;
дальше — access-токен, имя устройства (`android-a1b2`), публичный ключ,
строка платформы (`android`), id ноды при connect.

**Control plane → телефон:** список нод с метриками, статус подписки, свои
устройства, сессии, и при connect — публичный ключ ноды, endpoint,
выделенный IP, DNS, allowed IPs, MTU, keepalive.

**Нода → control plane (HTTPS, `Authorization: Bearer <node_token>` + `X-Node-Id`):**
CPU %, RAM %, uptime, счётчики байт интерфейса, число peer'ов, версия агента,
а в `report` — по peer'ам: публичный ключ, время handshake, rx/tx.

**Control plane → нода:** только две команды, `ADD_PEER` и `REMOVE_PEER`, каждая —
строго типизированный JSON с публичным ключом и `allowed-ips`. Команды с
произвольным shell-содержимым не предусмотрены протоколом: агент валидирует
`type` и base64-формат ключа и игнорирует всё остальное.

**Чего не передаётся никогда:** приватные ключи (ни в одну сторону), URL,
DNS-запросы, содержимое трафика, IMEI, геолокация, списки приложений.

### Логи

В логах никогда нет приватных ключей, паролей и токенов. Агент печатает только
сокращённые публичные ключи (`shortKey`), аудит-лог прогоняет metadata через
`scrub()`, а в клиенте `TunnelConfig.describeForLog()` и `WgKeyPair.toString()`
вырезают ключевой материал — на это есть отдельные тесты.

## 3. Какой трафик идёт через Control Server

Только управляющий, и только HTTPS:

- логин/refresh/logout, регистрация и revoke устройств;
- список нод, connect/disconnect/status;
- heartbeat и метрики ноды, отчёты по peer'ам;
- админка и аудит-лог.

Объём — единицы килобайт в минуту. **Ни один пакет пользовательского VPN-трафика
через control plane не проходит.** Это архитектурное свойство, а не настройка:
API не слушает UDP, не имеет кода для пересылки пакетов и не знает ключей
туннеля ни одной из сторон.

Побочное следствие: control plane видит метаданные — когда и к какой ноде
подключались, сколько байт прошло, с какого IP был запрос к API. Скрыть это от
владельца сервера невозможно — такова любая система с аутентификацией.

## 4. Какой трафик идёт через VPN Node

Весь пользовательский трафик: `AllowedIPs = 0.0.0.0/0`, то есть весь IPv4-трафик
телефона шифруется в WireGuard, выходит на ноде через NAT и уходит в интернет
с её публичного IP. DNS-запросы идут внутри туннеля на `1.1.1.1`.

Что нода **может** видеть технически: IP-адреса назначения и DNS-имена — как
любой exit-узел в мире. Что нода **делает** в этом проекте: считает байты через
`wg show dump` и время последнего handshake. Никакого DPI, логирования соединений,
`tcpdump`, DNS-логов или перехвата URL не устанавливается и не настраивается.

Когда нода живёт на том же сервере, что и control plane, это разделение
логическое, а не физическое: компрометация хоста даёт и то, и другое. Это
главная причина вынести ноду на отдельную VM, когда она появится.

## 5. Аутентификация и авторизация

| Субъект | Механизм | Срок |
| --- | --- | --- |
| Пользователь | username + пароль (Argon2id) → JWT | access 15 минут |
| Устройство | JWT с `deviceId` в claims (device-scoped) | 15 минут |
| Продление | refresh-токен, ротация при каждом использовании | 14 дней |
| Админ | тот же логин + флаг `isAdmin`, проверка на каждом `/api/admin/*` | 15 минут |
| Нода | свой `node_token` + `X-Node-Id`, ротация и revoke | 30 дней, авторотация за 3 дня до конца |
| Новая нода | одноразовый enrollment-токен | 30 минут |

Глобального общего секрета для клиентов или нод нет. У каждой ноды свой токен;
при каждом heartbeat остальные токены этой ноды отзываются — два агента с одним
`node_id` долго сосуществовать не могут.

Лимиты: 5 неудачных логинов → блокировка 15 минут; rate limit 120 запросов/мин
общий плюс поштучные лимиты (login 10/мин, register-device 20/мин, connect
20/мин, node/register 10 за 10 минут, ротация токена 5/час); 3 устройства на
пользователя и 1 одновременная сессия.

## 6. Что произойдёт при компрометации Node

Атакующий с root на ноде получает:

- **трафик в открытом виде после расшифровки** — это главное и неустранимое
  свойство любого VPN: exit-узел — это точка, где туннель заканчивается. HTTPS
  остаётся зашифрованным, но SNI, IP и DNS видны;
- приватный ключ ноды → может выдавать себя за эту ноду;
- `node_token` → может слать ложные метрики и статистику байт;
- публичные ключи и VPN-IP текущих peer'ов.

Атакующий **не** получает: доступ к PostgreSQL (агент его не имеет вообще),
пароли и хеши пользователей, `JWT_SECRET`, refresh-токены других клиентов,
приватные ключи устройств, токены других нод и возможность выполнить команду на
control plane: API принимает от ноды только четыре типизированных запроса
(register/heartbeat/report/ack) и никаких команд.

Реакция:

```sh
R="sudo -u vpncontrol ENV_FILE=/etc/vpn-control/control.env npm run cli --"
$R nodes:disable <node_id>        # новые подключения запрещены, сессии закрыты
$R nodes:revoke-tokens <node_id>  # агент теряет доступ к API
$R nodes:delete <node_id>
```

Затем: пересоздать VM, сгенерировать новые WireGuard-ключи ноды,
зарегистрировать заново. Ключи устройств менять не обязательно (их приватная
часть не утекла), но после компрометации exit-узла разумно считать весь
прошедший через него трафик скомпрометированным.

## 7. Что произойдёт при компрометации device token

**Access-токен (JWT, 15 минут).** Позволяет действовать от имени одного
устройства: смотреть свои устройства/сессии и вызывать connect/disconnect.
Не позволяет: сменить пароль, выйти за пределы своего пользователя, получить
админские endpoint'ы, узнать приватные ключи. **Подключиться к VPN с ним
нельзя**: без приватного ключа, который остался на телефоне, WireGuard-handshake
не состоится, даже если peer на ноде добавлен.

**Refresh-токен (14 дней).** Серьёзнее: даёт бесконечный поток access-токенов.
Но токен ротируется при каждом использовании, и повторное использование старого
видно в аудит-логе: легитимный клиент или атакующий начнёт гетерить 401.

Реакция:

```sh
$R devices:revoke <device_id>   # токены аннулированы, сессия закрыта, peer удалён
$R users:passwd <username>      # перевыпуск пароля
$R users:disable <username>     # полная блокировка аккаунта
```

**Осознанный компромисс прототипа.** Access-JWT проверяется по подписи без
обращения к БД на каждый запрос, поэтому после revoke уже выданный
access-токен живёт до истечения TTL (до 15 минут). При этом VPN-доступ
обрывается сразу — peer удаляется с ноды в течение нескольких секунд.
Следующий шаг — денилист `jti` в Redis или в таблице.

## 8. Компрометация Control Server

Самый тяжёлый сценарий: доступ к `JWT_SECRET`, `TOKEN_HASH_PEPPER` и БД означает
возможность выписать токен любого пользователя и командовать любой нодой
(добавить свой peer). Чего и там нет: приватных ключей устройств и возможности
расшифровать чужой трафик — ключи туннеля там никогда не были.

Поэтому: API не слушает публичный интерфейс (только `127.0.0.1:8081`),
работает под системным пользователем без капабилитисов, с `ProtectSystem=strict`,
а БД доступна только с loopback. Админка не имеет собственных привилегий:
это тот же API и тот же логин с флагом `isAdmin`.

## 9. Аудит

Каждое значимое действие пишется в `audit_logs`: логины (успешные, неудачные,
затроттленные, попытки заблокированного пользователя), регистрация и revoke
устройств, connect/disconnect, регистрация нод и отклонённые попытки,
ротация токенов, переход ноды в offline, все админские действия.

```sh
$R audit:tail 50
```

## 10. Известные ограничения прототипа

1. Access-токен нельзя отозвать до истечения 15 минут (нет денилиста).
2. Нода аутентифицируется bearer-токеном, а не mTLS.
3. Нода и control plane могут жить на одном хосте — тогда изоляции между
   ними нет.
4. Статистика байт приходит с ноды и ей же доверяется.
5. Нет 2FA и нет политики сложности паролей сверх минимума 8 символов.
6. Отсутствуют резервные копии БД и ротация `JWT_SECRET`.
7. IPv6 в туннеле не настроен: если у оператора есть IPv6, часть трафика
   может пойти мимо туннеля. Для теста это приемлемо, для реального
   использования — нет.

## 11. Если нашли уязвимость

Проект личный и не предназначен для чужих пользователей. Порядок действий при
подозрении на компрометацию: `nodes:disable` и `devices:revoke` сразу,
`audit:tail` для анализа, затем ротация секретов в `control.env` и перезапуск
`vpn-control` (перевыпуск `JWT_SECRET` разлогинивает всех, что и требуется).

---

## BETA sprint additions

### Public account numbers are not secrets, but they are not enumerable either

`users.public_id` is a random 8-digit number whose first digit is `1`
(`10000000`-`19999999`, ~10 million values). It is generated by
`gen_user_public_id()` inside Postgres with a uniqueness retry loop, and it is
the only identifier shown in the app or accepted by admin search.

Why it matters: the previous sequential numbering leaked the size of the user
base and let anyone guess a neighbour's identifier. The random number does not.
It is still **not** a credential - it identifies, it does not authenticate, and
nothing in the API grants access on the strength of knowing it.

The internal primary key stays a UUID. Nothing was moved onto the public number;
no foreign key, token, session or audit row references it.

### Staying signed in without weakening revocation

The client keeps its refresh token when the network fails, and only discards it
on an explicit `401`/`403` from the control plane. This is deliberate and it does
not weaken revocation, because:

- refresh tokens are single-use and rotate on every successful refresh;
- reuse of a consumed token revokes the entire family for that user and device;
- an admin revoking a device or disabling a user takes effect on the next
  refresh attempt, which the app makes on every resume, every reconnect and at
  most 15 minutes into any session (the access-token TTL);
- the token lives in Android's `EncryptedSharedPreferences` via
  `flutter_secure_storage`, scoped per channel, and is wiped on sign-out.

A phone that is offline cannot reach any node either, so keeping the token while
there is no connectivity does not extend the window in which a revoked device
can actually move traffic.

### Verification codes

`verification_codes` stores a **hash** of each 6-digit code (never the code),
with `purpose`, `channel`, `destination`, `attempts`, `expires_at`,
`consumed_at` and the requesting IP. Codes expire after 15 minutes, allow 5
attempts, are single-use, and are consumed inside a transaction so a code cannot
be redeemed twice. Email changes only take effect after the code for the new
address is consumed; the old address stays authoritative until then.

While `SMTP_HOST`/`SMTP_FROM` are unset the routes return `503` instead of
silently issuing codes nobody can receive.

### Approximate origin, never GPS

The app asks for no location permission and holds no coordinates. The control
plane resolves the request IP to country/region at most once every 24 hours and
stores `last_country`, `last_country_code`, `last_region`, `geo_updated_at` -
nothing finer. The map marker is drawn from the country centroid, which is why it
now sits in the right place: it is derived from the same data the server
resolved, not from a hard-coded guess in the client.

Geo-IP lookups are off by default (`GEOIP_ENABLED=false`) and time out after
2.5 s; a failed lookup leaves the user with no stored origin and no error.

### Beta lifecycle control is not a shell

Start/Stop/Restart Beta are queued database rows, not commands. The worker maps
an enum value to one of six fixed script paths, runs it with `shell: false`, no
arguments, and a scrubbed environment (`PATH`, `HOME`, `LANG` only). There is no
endpoint that accepts a command, a script name, a path or a flag - adding one
would be the single largest hole this design avoids.

Blast-radius controls:

- the beta scripts reference beta unit names, the beta port and `wg1` only;
- `sessions:drain` refuses to run unless `CHANNEL=beta`;
- lifecycle and deployment routes refuse unless the server answering is the
  production instance, so a compromised beta cannot promote itself;
- every job records the requesting admin, the exit code and the captured output
  (capped at 60 000 characters) in the audit log.

### What the user is allowed to see

The client no longer surfaces transport diagnostics, status codes, endpoint
hosts, node handles or channel labels in release builds. This is a security
property as much as a cosmetic one: error text is a reconnaissance surface, and
`de-01` or `beta-api` in a screenshot tells an attacker how the fleet is named.
