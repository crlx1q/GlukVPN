# GlukVPN — прототип личного VPN-сервиса

Control plane на существующем сервере Oracle Cloud (Ubuntu 24.04 ARM64 +
aaPanel), VPN-нода на WireGuard, Android-клиент на Flutter.

Трафик пользователя идёт **напрямую**: телефон → VPN-нода → Internet.
Control plane его никогда не проксирует — он только выдаёт и отзывает доступ.

> Это экспериментальный тестовый проект, не production. Один тестовый
> пользователь, без платежей, без регистрации по email/телефону.

---

## 1. Что это

Три компонента:

| Компонент | Где живёт | Что делает |
| --- | --- | --- |
| `control-server/` | `/opt/vpn-control` на основном сервере | REST API: аутентификация, users, devices, node registry, sessions, subscriptions, audit log, статистика, web-админка |
| `node-agent/` | `/opt/vpn-node-agent` на VPN-ноде | регистрируется в control plane, heartbeat + метрики, добавляет/удаляет WireGuard peer по команде |
| `flutter-client/` | Android-телефон | логин, генерация ключей, поднятие системного VPN-туннеля, live-пинг и статистика |

Стек: Node.js 20 + TypeScript + Fastify + Prisma + PostgreSQL, WireGuard,
Flutter 3.24.5.

Почему Node.js, а не FastAPI: один язык на API, агент и тесты; Prisma даёт
миграции и типизированную схему; Fastify — это готовые плагины `helmet`,
`rate-limit`, `jwt`, `cors` без ручной сборки middleware.

Чего в проекте намеренно нет: обхода блокировок, скрытого прокси, DPI,
перехвата URL/DNS, backdoor'ов и любого endpoint'а, выполняющего произвольные
команды на сервере.

## 2. Архитектура

```
   Android (Flutter)
        │  HTTPS  api.gluk.tech            только управление:
        │  ─────────────────────────────▶  login, devices, connect, status
        │
        │                              ┌──────────────────────────────┐
        │                              │ CONTROL SERVER (Oracle)      │
        │                              │ aaPanel nginx :443           │
        │                              │   └─▶ 127.0.0.1:8081 API     │
        │                              │ PostgreSQL 127.0.0.1:5432    │
        │                              └──────────────┬───────────────┘
        │                                             │ HTTPS
        │                                             │ node token
        │                              ┌──────────────┴───────────────┐
        │   WireGuard UDP 51820        │ VPN NODE (Germany, позже)    │
        └─────────────────────────────▶│ node-agent + wg0 10.8.0.1/24 │
                                       └──────────────┬───────────────┘
                                                      │ NAT
                                                      ▼
                                                  Internet
```

Сейчас, пока немецкой VM нет, ноду разворачиваем **на том же сервере** — это
работает, но география будет Oracle, а не Германия. Флаг 🇩🇪 появится только
тогда, когда нода реально встанет в Германии (`NODE_COUNTRY=Germany`).

Добавление DE-02 / US-01 / FR-01 позже не требует правок backend: нода сама
регистрируется по enrollment-токену и появляется в `GET /api/nodes`.

Подробности — в `docs/architecture.md`, API — в `docs/api.md`, модель угроз —
в `SECURITY.md`.

## Порты

| Порт | Где | Доступ |
| --- | --- | --- |
| 443/tcp | control server | публично, существующий nginx aaPanel |
| 8081/tcp | control server | **только loopback**, за nginx |
| 5432/tcp | control server | только loopback |
| 51820/udp | VPN-нода | публично, WireGuard |
| 22/tcp | оба | как сейчас, не меняем |
| 31231/tcp | control server | aaPanel, как сейчас, не меняем |

Новый публичный порт ровно один: UDP 51820.

## 3. Как поднять Control Server

Всё выполняется на `ubuntu@138.2.186.223`. aaPanel, его nginx и SSH не
трогаем.

**3.1. Проверить, что уже есть**

```sh
node -v; npm -v
which psql; systemctl is-active postgresql 2>/dev/null
ss -lntp | grep -E ':(8081|5432)\b' || echo 'порты 8081/5432 свободны'
```

**3.2. Node.js 20 (если системный старше)**

Ubuntu 24.04 ставит Node 18, а проекту нужен >= 20.11:

```sh
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs
```

Если в aaPanel уже установлен Node >= 20, можно использовать его бинарь и
править `ExecStart` в systemd-юните — новый пакет тогда не нужен.

**3.3. PostgreSQL**

```sh
sudo apt-get install -y postgresql postgresql-contrib
sudo -u postgres psql -c "SELECT version();"
```

По умолчанию слушает только `127.0.0.1` — наружу ничего не открывается.

```sh
DB_PASS="$(openssl rand -base64 24)"
sudo -u postgres psql -c "CREATE ROLE vpncontrol LOGIN PASSWORD '$DB_PASS';"
sudo -u postgres psql -c "CREATE DATABASE vpncontrol OWNER vpncontrol;"
echo "DATABASE_URL=postgresql://vpncontrol:$DB_PASS@127.0.0.1:5432/vpncontrol"
```

Строку из последнего `echo` сохраните — она пойдёт в env-файл. Пароль в Git не
попадает.

**3.4. Код и сборка**

```sh
sudo install -d -o ubuntu -g ubuntu /opt/vpn-control
# скопировать control-server/ и node-agent/ + корневые package.json,
# tsconfig.base.json в /opt/vpn-control (scp/rsync с локальной машины)
cd /opt/vpn-control
npm install          # ставит workspaces и генерирует Prisma Client
npm run typecheck
npm test
npm run build
```

`npm install` обязательно выполнять в корне: workspaces тянут обе части, а
`postinstall` запускает `prisma generate` под ARM64.

**3.5. Секреты**

```sh
sudo useradd --system --no-create-home --shell /usr/sbin/nologin vpncontrol
sudo install -d -m 0750 -o root -g vpncontrol /etc/vpn-control
sudo tee /etc/vpn-control/control.env >/dev/null <<EOF
DATABASE_URL=postgresql://vpncontrol:ЗАМЕНИТЬ@127.0.0.1:5432/vpncontrol
JWT_SECRET=$(openssl rand -base64 48)
TOKEN_HASH_PEPPER=$(openssl rand -base64 48)
HOST=127.0.0.1
PORT=8081
PUBLIC_API_URL=https://api.gluk.tech
CORS_ALLOWED_ORIGINS=https://api.gluk.tech
TRUST_PROXY=127.0.0.1
EOF
sudo chown root:vpncontrol /etc/vpn-control/control.env
sudo chmod 0640 /etc/vpn-control/control.env
sudo chown -R vpncontrol:vpncontrol /opt/vpn-control
```

Остальные параметры (TTL токенов, лимиты, интервалы heartbeat) имеют
безопасные значения по умолчанию — см. `control-server/.env.example`.

**3.6. Миграции и seed**

```sh
cd /opt/vpn-control/control-server
sudo -u vpncontrol ENV_FILE=/etc/vpn-control/control.env npm run migrate:deploy
sudo -u vpncontrol ENV_FILE=/etc/vpn-control/control.env npm run seed
```

`seed` печатает **один раз**: пароль admin, пароль testuser и enrollment-токен
для ноды. Сохраните их сразу — повторно они не показываются, а повторный запуск
seed существующие пароли не сбрасывает.

**3.7. systemd**

```sh
sudo cp /opt/vpn-control/control-server/deploy/vpn-control.service \
  /etc/systemd/system/vpn-control.service
sudo systemctl daemon-reload
sudo systemctl enable --now vpn-control
systemctl status vpn-control --no-pager
curl -fsS http://127.0.0.1:8081/api/health
```

Ожидаемый ответ: `{"ok":true,...,"database":"up",...}`.

**3.8. Домен и HTTPS через aaPanel**

1. aaPanel → Website → Add site → `api.gluk.tech` (без FTP и без БД).
2. SSL → Let's Encrypt → выпустить сертификат, включить Force HTTPS.
3. Site → Config file → вставить `location`-блок из
   `control-server/deploy/nginx-api.gluk.tech.conf` внутрь существующего
   `server { ... }`, **ничего не удаляя**.
4. `sudo nginx -t && sudo systemctl reload nginx`

`nginx -t` перед reload обязателен: если конфиг сломан, reload положит все
сайты aaPanel.

```sh
curl -fsS https://api.gluk.tech/api/health
```

## 4. Как поднять VPN Node

Пока немецкой VM нет — те же шаги выполняются на основном сервере.

**4.1. WireGuard и ключи ноды**

```sh
sudo apt-get install -y wireguard wireguard-tools
sudo install -d -m 0700 /etc/wireguard
umask 077
wg genkey | sudo tee /etc/wireguard/node.key | wg pubkey | sudo tee /etc/wireguard/node.pub
sudo chmod 600 /etc/wireguard/node.key
```

Приватный ключ ноды остаётся только в `/etc/wireguard/node.key` (root, 0600).
В API и логи он не уходит — control plane знает только публичный ключ.

**4.2. Интерфейс `wg0`**

Возьмите шаблон `node-agent/deploy/wg0.conf.example` → `/etc/wireguard/wg0.conf`
(Address `10.8.0.1/24`, ListenPort `51820`). Peers в файл не пишем: их
добавляет агент через `wg set`, поэтому конфиг остаётся минимальным.

```sh
sudo systemctl enable --now wg-quick@wg0
sudo wg show
```

**4.3. Агент**

```sh
sudo useradd --system --no-create-home --shell /usr/sbin/nologin vpnagent
sudo install -d -o vpnagent -g vpnagent /opt/vpn-node-agent
# скопировать node-agent/ в /opt/vpn-node-agent, затем:
cd /opt/vpn-node-agent && npm install && npm run build

sudo install -d -m 0700 -o vpnagent -g vpnagent /etc/vpn-node-agent
sudo -u vpnagent tee /etc/vpn-node-agent/agent.env >/dev/null <<'EOF'
CONTROL_API_URL=https://api.gluk.tech
NODE_NAME=de-01
NODE_COUNTRY=Germany
NODE_COUNTRY_CODE=DE
NODE_PUBLIC_IP=<PUBLIC_IP_НОДЫ>
WG_INTERFACE=wg0
WG_LISTEN_PORT=51820
WG_ADDRESS=10.8.0.1/24
WG_SUBNET=10.8.0.0/24
WG_MTU=1420
WG_EGRESS_INTERFACE=<EGRESS_IF>
NODE_ENROLLMENT_TOKEN=<ТОКЕН_ИЗ_SEED>
EOF
sudo chmod 0600 /etc/vpn-node-agent/agent.env
```

`<EGRESS_IF>` — интерфейс с публичным IP (`ip -4 route get 1.1.1.1`), на Oracle
обычно `enp0s6`. Пока нода живёт на Oracle, честнее поставить
`NODE_NAME=oracle-01`, `NODE_COUNTRY` по факту — иначе приложение покажет
Германию там, где её нет.

Агент запускается под `vpnagent` и получает ровно две системные возможности:
`CAP_NET_ADMIN` для `wg set` и чтение `/proc` для метрик. Ни sudo, ни доступа к
PostgreSQL у него нет.

## 5. Как зарегистрировать Node

Нода регистрируется сама, одноразовым enrollment-токеном:

```sh
# на control server, если токен из seed потерян:
cd /opt/vpn-control/control-server
sudo -u vpncontrol ENV_FILE=/etc/vpn-control/control.env npm run cli -- nodes:token

# на ноде:
cd /opt/vpn-node-agent
sudo -u vpnagent ENV_FILE=/etc/vpn-node-agent/agent.env npm run enroll
```

`enroll` отправляет `POST /api/node/register`, получает `node_id` + `node_token`
и дописывает их в `agent.env`. Токен в control plane хранится только в виде
HMAC-SHA256 с pepper'ом — восстановить его из БД нельзя.

```sh
sudo cp /opt/vpn-node-agent/deploy/vpn-node-agent.service \
  /etc/systemd/system/vpn-node-agent.service
sudo systemctl daemon-reload
sudo systemctl enable --now vpn-node-agent
journalctl -u vpn-node-agent -n 30 --no-pager
```

Через 10 секунд нода должна стать `ONLINE` в `GET /api/nodes` и в админке.
Если heartbeat не приходит 30 секунд — статус `OFFLINE`, приложение показывает
ноду как недоступную.

## 6. Как настроить WireGuard

- Своя пара ключей у **каждого** устройства; общий конфиг не используется.
- Приватный ключ клиента генерируется на телефоне и **никогда** не покидает
  его: в API уходит только публичный ключ.
- `POST /api/vpn/connect` → control plane выдаёт ноде команду `ADD_PEER` →
  агент делает `wg set wg0 peer <pubkey> allowed-ips 10.8.0.X/32`.
- Телефон получает: публичный ключ ноды, endpoint, свой VPN IP, DNS, allowed
  IPs (`0.0.0.0/0`), keepalive 25.
- IP выдаются из пула `10.8.0.0/24`, `10.8.0.1` — сама нода.
- MTU 1420 (1500 − 80 на WireGuard-заголовки). При проблемах с большими
  пакетами снизьте до 1380 в `WG_MTU` и в поле `mtu` ноды.
- DNS по умолчанию `1.1.1.1, 1.0.0.1`.
- Учёт трафика — только счётчики байт из `wg show dump`, без DPI и без URL.

## 7. Как настроить firewall

> **ОПАСНО.** В Oracle Cloud в конце цепочки `INPUT` стоит
> `REJECT --reject-with icmp-host-prohibited`. Правило, добавленное через `-A`,
> окажется **после** REJECT и не будет работать. Вставлять нужно по номеру
> строки. Никогда не используйте здесь `ufw` — он перезапишет цепочки Oracle и
> может отрезать SSH и aaPanel.

**7.1. Снимок и вторая SSH-сессия**

```sh
sudo iptables-save | sudo tee /root/iptables-before-glukvpn.rules >/dev/null
sudo iptables -L INPUT -n --line-numbers
```

Откройте вторую SSH-сессию и не закрывайте её, пока не убедитесь, что доступ
живой. Запомните номер строки REJECT — ниже это `<N>`.

**7.2. Правила (заменить `<N>` и `<EGRESS_IF>`)**

```sh
# WireGuard снаружи
sudo iptables -I INPUT <N> -p udp --dport 51820 -j ACCEPT
# ICMP/трафик из туннеля к самой ноде: без этого не работает пинг 10.8.0.1
sudo iptables -I INPUT <N> -i wg0 -j ACCEPT
# маршрутизация туннель <-> интернет
sudo iptables -I FORWARD 1 -i wg0 -o <EGRESS_IF> -j ACCEPT
sudo iptables -I FORWARD 2 -i <EGRESS_IF> -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT
# NAT только для VPN-подсети
sudo iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o <EGRESS_IF> -j MASQUERADE
```

Что это меняет: сервер начинает работать маршрутизатором для `10.8.0.0/24` и
выпускать этот трафик в интернет под своим публичным IP. Правила FORWARD
ограничены парой `wg0 ↔ <EGRESS_IF>`, NAT — только подсетью `10.8.0.0/24`,
поэтому открытого релея не появляется.

**7.3. IP forwarding**

```sh
echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-glukvpn.conf
sudo sysctl --system
```

**7.4. Проверить SSH/aaPanel и сохранить**

```sh
sudo iptables -L INPUT -n --line-numbers | head -20
# в этот момент вторая SSH-сессия и https://linux1.crlx1q.com:31231 должны работать
sudo apt-get install -y iptables-persistent
sudo netfilter-persistent save
```

Без `netfilter-persistent save` правила исчезнут после перезагрузки.

**7.5. Oracle VCN**

В консоли Oracle: VCN → Security List / NSG → Ingress rule: Source `0.0.0.0/0`,
Protocol UDP, Destination port `51820`. Без этого пакеты не дойдут до сервера,
сколько бы правил iptables вы ни добавили.

Откат, если что-то сломалось:

```sh
sudo iptables-restore < /root/iptables-before-glukvpn.rules
```

## 8. Как создать test user

`seed` уже создал `admin` и `testuser` с активной подпиской на 365 дней и
случайными паролями (напечатаны один раз). Дополнительно:

```sh
cd /opt/vpn-control/control-server
R="sudo -u vpncontrol ENV_FILE=/etc/vpn-control/control.env npm run cli --"
$R users:list
$R users:create alice          # печатает сгенерированный пароль
$R users:passwd testuser       # сменить пароль
$R users:extend testuser 30    # продлить подписку
$R users:disable testuser      # блокировка: сессия закрывается, peer удаляется
$R users:enable testuser
```

В проекте нет ни email, ни телефона, ни самостоятельной регистрации — аккаунты
создаёт только владелец сервера.

## 9. Как собрать Flutter APK

Код клиента лежит в приватном репозитории
`crlx1q/glukvpn-flutter-client`; GitHub Actions собирает APK на каждый push в
`main` (workflow `build-apk`).

1. Repo → Settings → Secrets and variables → Actions → добавить:
   `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`,
   `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`.
2. Keystore создаётся один раз локально и в Git не попадает:

```sh
keytool -genkey -v -keystore release.jks -keyalg RSA -keysize 2048 \
  -validity 10000 -alias glukvpn
base64 -w0 release.jks   # значение для ANDROID_KEYSTORE_BASE64
```

3. APK появляется как артефакт `glukvpn-apk` и как pre-release `apk-<номер>`
   с файлом `glukvpn-release.apk`.

Без секретов сборка не падает: APK подписывается debug-ключом Flutter и в лог
пишется предупреждение. Установить такой APK можно, распространять — нет.

Локальная сборка и объяснение двух Android-патчей — в
`flutter-client/README.md`.

## 10. Как подключить телефон

1. Скачать `glukvpn-release.apk` из релиза на телефон.
2. Разрешить установку из неизвестных источников для браузера.
3. Установить, открыть, войти как `testuser`.
4. Нажать **CONNECT** → Android покажет системный диалог VPN-разрешения →
   Разрешить. Диалог появляется один раз на устройство.
5. В статус-баре появится иконка ключа — туннель поднят.

При первом входе приложение генерирует X25519-ключи и регистрирует устройство
(`POST /api/devices/register`), отправляя только публичный ключ.

## 11. Как проверить VPN

В приложении: статус `Connected`, страна, exit IP, VPN IP, длительность,
трафик и пинг до `10.8.0.1` в реальном времени.

На ноде:

```sh
sudo wg show                  # peer, latest handshake, transfer
sudo wg show wg0 transfer
```

На control plane:

```sh
curl -fsS https://api.gluk.tech/api/health
cd /opt/vpn-control/control-server
sudo -u vpncontrol ENV_FILE=/etc/vpn-control/control.env npm run cli -- sessions:list --live
```

С телефона: открыть `https://api.ipify.org` — должен показать IP ноды, а не IP
оператора. Проверить, что открываются сайты (DNS работает) и что после
отключения exit IP возвращается к прежнему.

Если пинг показывает `--`, но туннель работает: на ноде нет правила
`-i wg0 -j ACCEPT`, ICMP до `10.8.0.1` блокируется; приложение автоматически
переключается на замер HTTPS-запроса.

## 12. Как отключить VPN

Кнопка **DISCONNECT**: приложение закрывает туннель, затем
`POST /api/vpn/disconnect` → control plane ставит команду `REMOVE_PEER` → агент
удаляет peer. Проверка: `sudo wg show` — peer'а нет, сессия в БД получила
`disconnected_at`, `closeReason=user_request` и итоговые байты.

Аварийно на ноде (peer'ы вернутся при следующем connect):

```sh
sudo systemctl stop wg-quick@wg0
```

## 13. Как revoke device

Любым из трёх способов:

- приложение: Settings → Devices → Revoke;
- админка: `https://api.gluk.tech/admin` → Devices → Revoke;
- CLI:

```sh
cd /opt/vpn-control/control-server
R="sudo -u vpncontrol ENV_FILE=/etc/vpn-control/control.env npm run cli --"
$R devices:list
$R devices:revoke <device_id>
```

При revoke: refresh-токены устройства аннулируются, активная сессия
закрывается, peer удаляется с ноды. Access-токен перестаёт работать в пределах
его TTL (15 минут) — это осознанный компромисс прототипа, описанный в
`SECURITY.md`.

## 14. Как удалить Node

```sh
# 1. control plane: запретить новые подключения и закрыть текущие
cd /opt/vpn-control/control-server
R="sudo -u vpncontrol ENV_FILE=/etc/vpn-control/control.env npm run cli --"
$R nodes:list
$R nodes:disable <node_id>
$R nodes:revoke-tokens <node_id>

# 2. на ноде: остановить агент и туннель
sudo systemctl disable --now vpn-node-agent
sudo systemctl disable --now wg-quick@wg0

# 3. control plane: убрать запись
$R nodes:delete <node_id>
```

`nodes:delete` удаляет ноду, её токены, IP-аренды и команды; закрытые сессии
остаются в истории для статистики.

## 15. Как полностью удалить тестовый проект

> **ОПАСНО.** Всё ниже необратимо. aaPanel, его nginx, SSH и другие сайты
> остаются нетронутыми — в списке нет ни одной команды, которая их касается.

```sh
# сервисы
sudo systemctl disable --now vpn-control vpn-node-agent wg-quick@wg0
sudo rm -f /etc/systemd/system/vpn-control.service \
           /etc/systemd/system/vpn-node-agent.service
sudo systemctl daemon-reload

# код и секреты
sudo rm -rf /opt/vpn-control /opt/vpn-node-agent
sudo rm -rf /etc/vpn-control /etc/vpn-node-agent
sudo rm -f /etc/wireguard/wg0.conf /etc/wireguard/node.key /etc/wireguard/node.pub

# база
sudo -u postgres psql -c "DROP DATABASE IF EXISTS vpncontrol;"
sudo -u postgres psql -c "DROP ROLE IF EXISTS vpncontrol;"

# сеть: вернуть снимок правил, снять forwarding
sudo iptables-restore < /root/iptables-before-glukvpn.rules
sudo netfilter-persistent save
sudo rm -f /etc/sysctl.d/99-glukvpn.conf && sudo sysctl --system

# служебные пользователи
sudo userdel vpnagent; sudo userdel vpncontrol
```

Отдельно, вручную: удалить сайт `api.gluk.tech` в aaPanel, ingress-правило UDP
51820 в Oracle VCN, приложение с телефона и приватный репозиторий клиента.
PostgreSQL и WireGuard как пакеты можно оставить — они ничего не открывают
наружу.

## Структура репозитория

```
GlukVPN/
  control-server/     API, Prisma-схема, миграции, CLI, seed, админка, тесты
    deploy/           systemd-юнит и nginx-фрагмент для aaPanel
  node-agent/         агент ноды, enroll, systemd-юнит, шаблон wg0.conf
  flutter-client/     Android-клиент (+ приватный репо для CI-сборки APK)
  docs/               architecture.md, api.md, security.md, deployment.md
  README.md, SECURITY.md, .gitignore
```

В Git не попадает ничего секретного: `.gitignore` исключает `.env*`, `*.jks`,
`*.keystore`, `key.properties`, `node_modules`, `dist`, сгенерированный
`android/`. Все секреты живут в `/etc/vpn-control/control.env`,
`/etc/vpn-node-agent/agent.env`, `/etc/wireguard/node.key` и в GitHub Secrets.

## Что дальше

- отдельная VM в Германии: те же шаги 4–7, `NODE_NAME=de-01`, и клиент честно
  покажет 🇩🇪;
- mTLS или короткоживущие signed tokens вместо bearer-токена ноды;
- денилист access-токенов, чтобы revoke действовал мгновенно;
- `vpn.gluk.tech` для лендинга — DNS-запись пока не создана.
