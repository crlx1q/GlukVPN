# Deployment — runbook

Целевой сервер: `ubuntu@138.2.186.223`, Ubuntu 24.04 ARM64, aaPanel, nginx, SSH.
Домен API: `api.gluk.tech` → 127.0.0.1:8081.

Порядок важен. Каждая фаза заканчивается проверкой. Если проверка не прошла —
дальше не идём.

## Правила работы с этим сервером

1. Не трогать aaPanel, его nginx-конфиги вне сайта `api.gluk.tech`, SSH,
   существующие сайты и базы.
2. `ufw` не использовать вообще (перезапишет цепочки Oracle).
3. Перед любой правкой iptables — снимок и вторая живая SSH-сессия.
4. Ничего не удалять без явного подтверждения.
5. Секреты не передавать в чат и не класть в Git.

## Фаза 0 — рекогносцировка (только чтение)

Сначала понять, что уже есть. Ни одна команда ничего не меняет:

```sh
# система
uname -m; lsb_release -ds; uptime
# что уже установлено
node -v 2>/dev/null; npm -v 2>/dev/null; which psql wg 2>/dev/null
ls /www/server/nodejs 2>/dev/null
# порты и сервисы
ss -lntup | grep -E ':(80|443|8081|5432|31231|51820)\b'
systemctl list-units --type=service --state=running --no-pager | head -30
# сеть
ip -4 addr show; ip -4 route get 1.1.1.1
cat /proc/sys/net/ipv4/ip_forward
# firewall: важен номер строки REJECT
sudo iptables -L INPUT -n --line-numbers
sudo iptables -t nat -L POSTROUTING -n --line-numbers
# aaPanel
ls /www/server/panel/vhost/nginx/ 2>/dev/null
nginx -v; sudo nginx -t
# место
df -h /; free -m
```

Из этого вывода нужны четыре вещи: версия Node, есть ли PostgreSQL, имя
внешнего интерфейса (`<EGRESS_IF>`) и номер строки `REJECT` в `INPUT`
(`<REJECT_LINE>`). Без них нельзя корректно вставить правила firewall.

## Фаза 1 — рантайм и база

Детали и команды — `README.md`, раздел 3.2–3.3.

Изменения: устанавливается пакет `nodejs` (если системный старше 20) и
`postgresql`. PostgreSQL слушает только loopback — публичных портов не
появляется. aaPanel не затрагивается: свой Node он держит в
`/www/server/nodejs` и на системный не опирается.

Проверка: `node -v` ≥ 20.11, `sudo -u postgres psql -c 'select 1'` работает,
`sudo nginx -t` всё ещё ok.

## Фаза 2 — control-api

1. Код в `/opt/vpn-control` (scp/rsync), `npm install` → `npm run typecheck` →
   `npm test` → `npm run build` в корне.
2. Пользователь `vpncontrol`, env `/etc/vpn-control/control.env` (0640).
3. `npm run migrate:deploy`, затем `npm run seed` — сохранить вывод.
4. Юнит `vpn-control.service`, `systemctl enable --now`.

Проверка:

```sh
curl -fsS http://127.0.0.1:8081/api/health
systemctl is-enabled vpn-control; systemctl is-active vpn-control
journalctl -u vpn-control -n 20 --no-pager
```

Откат: `sudo systemctl disable --now vpn-control` и удалить юнит. База и код
останутся на месте и никому не мешают.

## Фаза 3 — домен и HTTPS

Сайт `api.gluk.tech` создаётся штатными средствами aaPanel, сертификат —
Let's Encrypt из панели. Затем в `server{}` добавляется только `location`-блок
из `control-server/deploy/nginx-api.gluk.tech.conf`.

НЕ трогать в этом файле: `listen`, `ssl_certificate`, `ssl_certificate_key`,
`include /www/server/panel/vhost/rewrite/...`, `location ~ \.well-known`,
строки логов. Этот блок принадлежит панели.

```sh
sudo nginx -t && sudo systemctl reload nginx
curl -fsS https://api.gluk.tech/api/health
curl -sI https://api.gluk.tech/api/health | grep -i strict-transport
```

Откат: убрать добавленный `location` и `nginx -t && reload`. Другие сайты
не затронуты, так как правка локальна в одном файле vhost.

## Фаза 4 — WireGuard и сеть (самая опасная)

Порядок строго такой:

1. `iptables-save` в файл, открыта вторая SSH-сессия.
2. Ключи ноды, `wg0.conf`, `wg-quick@wg0`.
3. `net.ipv4.ip_forward=1` через `/etc/sysctl.d/99-glukvpn.conf`.
4. Правила iptables **вставкой по номеру** до `REJECT`.
5. Проверить SSH и aaPanel во второй сессии.
6. `netfilter-persistent save`.
7. Ingress-правило UDP 51820 в Oracle VCN.

Команды и объяснения — `README.md`, раздел 7.

Что именно меняется в системе:

| Изменение | Следствие | Откат |
| --- | --- | --- |
| `ip_forward=1` | хост становится маршрутизатором | удалить файл + `sysctl --system` |
| `INPUT ... udp 51820 ACCEPT` | WireGuard доступен снаружи | `iptables -D INPUT ...` |
| `INPUT -i wg0 ACCEPT` | работает пинг шлюза 10.8.0.1 | `-D` |
| `FORWARD wg0 ↔ <EGRESS_IF>` | трафик из туннеля выходит в интернет | `-D` |
| `nat POSTROUTING MASQUERADE` | подмена адреса на публичный IP ноды | `-t nat -D` |
| `wg-quick@wg0 enabled` | интерфейс поднимается при загрузке | `disable --now` |

Проверка:

```sh
sudo wg show                        # интерфейс есть, peers пока пусто
ip -4 addr show wg0                 # 10.8.0.1/24
cat /proc/sys/net/ipv4/ip_forward   # 1
sudo iptables -L INPUT -n --line-numbers | head -12   # наши правила ВЫШЕ REJECT
```

## Фаза 5 — node-agent

1. Пользователь `vpnagent`, код в `/opt/vpn-node-agent`, `npm install && npm run build`.
2. `/etc/vpn-node-agent/agent.env` (0600) с enrollment-токеном.
3. `npm run enroll` — получает `NODE_ID`/`NODE_TOKEN` и дописывает в env.
4. `vpn-node-agent.service`, `enable --now`.

Проверка:

```sh
journalctl -u vpn-node-agent -n 30 --no-pager      # heartbeat ok каждые 10с
cd /opt/vpn-control/control-server
sudo -u vpncontrol ENV_FILE=/etc/vpn-control/control.env npm run cli -- nodes:list
```

Нода должна быть `ONLINE` с живыми CPU/RAM/uptime.

## Фаза 6 — тестовая матрица

Считаем готовым только после всех пунктов.

**Control API:** health; login верный/неверный; refresh; me; список нод;
регистрация устройства; список устройств; connect; status; disconnect; revoke.

**Нода:** регистрация; heartbeat; добавление peer (`wg show` показывает ключ);
удаление peer; самовосстановление после `wg-quick down/up`.

**Flutter:** логин; список серверов; системный диалог VPN; connect; disconnect;
пинг в реальном времени; счётчики трафика и таймер.

**Туннель:** handshake есть; exit IP равен IP ноды; DNS работает; сайты
открываются; после disconnect интернет возвращается к обычному состоянию.

**Безопасность:** таблица в `docs/security.md`, раздел 6.

## Фаза 7 — APK

GitHub Actions в `crlx1q/glukvpn-flutter-client` собирает APK автоматически.
Секреты подписи — `README.md`, раздел 9. Сборка блокируется, если `flutter test`
не прошёл — так сломанный клиент не попадёт на телефон.

Если `API_BASE_URL` другой — запустить workflow вручную (`workflow_dispatch`)
с нужным значением.

## Опасные действия — сводный список

| Действие | Риск | Митигация |
| --- | --- | --- |
| правка iptables | потеря SSH и aaPanel | снимок, вторая сессия, вставка по номеру |
| `ufw enable` | обрыв всего | не используется вовсе |
| `nginx reload` с битым конфигом | легут все сайты | всегда `nginx -t` до reload |
| `ip_forward=1` + NAT | сервер — роутер | NAT только для 10.8.0.0/24 |
| `apt install postgresql` | новый сервис на сервере | только loopback, отдельная роль и БД |
| NodeSource Node 20 | может сменить системный node | aaPanel держит свой в /www/server/nodejs |
| `DROP DATABASE` | потеря данных | только в фазе полного удаления |
| удаление `/etc/wireguard/node.key` | клиенты перестанут подключаться | перерегистрация ноды |

Ни одно из этих действий не выполняется автоматически скриптом: все команды
выполняются вручную и по одной.

## Диагностика

| Симптом | Причина | Что делать |
| --- | --- | --- |
| `/api/health` локально ок, через домен 502 | nginx не видит 8081 | проверить `proxy_pass` и `ss -lntp` |
| `database: down` | неверный `DATABASE_URL` | проверить пароль роли |
| нода `PENDING` навсегда | heartbeat не доходит | `journalctl -u vpn-node-agent`, проверить `CONTROL_API_URL` |
| `connect` 201, но туннель не встаёт | UDP 51820 закрыт | Oracle VCN + правило INPUT |
| `wg show` показывает peer, handshake нет | несовпадение ключей | в приложении Settings → перерегистрация устройства |
| handshake есть, сайты не открываются | нет NAT или forwarding | проверить `ip_forward` и POSTROUTING |
| часть сайтов виснет | MTU | снизить MTU до 1380 |
| пинг показывает `--` | нет `INPUT -i wg0 ACCEPT` | добавить правило |
| 401 сразу после логина | расхождение часов | `timedatectl` на сервере и телефоне |

## Следующий шаг: переезд на немецкую VM

Когда появится отдельная VM: выполнить только фазы 4 и 5 на новом сервере,
затем `nodes:disable` и `nodes:delete` для старой ноды. Control plane не
меняется вообще, приложение пересобирать не нужно — список нод приходит из
API.

На новой VM потребуется: public IP, SSH-доступ, OS, имя пользователя и открытый
UDP 51820 в её firewall. Приватные ключи пересылать никуда не надо.

## Лимиты скорости (VLESS/Desktop): один порт 443 и SNI

Скорость тарифа режется на ноде, а снаружи остаётся ровно **один** открытый
порт — 443. Отдельные внешние порты под тарифы (2053, 2083, …) не используются:
в Oracle VCN закрыто всё, кроме 443, поэтому клиент с лимитом получал
`connect_timeout` вместо медленного туннеля, а нестандартные порты вырезают
провайдеры и отельный Wi-Fi.

nginx `stream` + `ssl_preread` читает имя сервера из TLS ClientHello, не
расшифровывая поток, и раскладывает соединения:

| SNI на :443 | Куда идёт | Что это значит |
| --- | --- | --- |
| `de-01.gluk.tech` | `127.0.0.1:8445` (sing-box) | без лимита |
| `speed30.de-01.gluk.tech` | `127.0.0.1:8460` → sing-box | 30 Мбит/с |
| `speed50/100/250/500.de-01.gluk.tech` | `8461`…`8464` → sing-box | тариф |
| всё остальное | vhost сайта/API | обычный HTTPS |

Шейперы (`GatewayShaper` в node-agent) слушают только loopback: новых правил в
облачном firewall не нужно, и клиент не может дозвониться до более быстрого
тира напрямую. Поддомен выбирает control-server по тарифу из БД (`gatewayFor` →
`speedGatewaySni`), клиент лишь подставляет присланный `sni`. Порт у всех тиров
остаётся 443, и TLS остаётся сквозным между клиентом и sing-box.

Порт для тира считают обе стороны по одному правилу (`base-port + индекс` по
возрастанию скорости), поэтому хранить карту негде и рассинхронизировать её
нельзя. Авторитетный ответ — лог агента: `shapedGateways=30=8460,50=8461,…`.

### Установка на ноде

```bash
cd /opt/glukvpn/node-agent/deploy
./install-speed-router.sh --domain de-01.gluk.tech                 # только печать
./install-speed-router.sh --domain de-01.gluk.tech --write --reload
./install-speed-router.sh --domain de-01.gluk.tech --certbot       # команда для SAN
```

Без `--write` скрипт ничего не меняет: печатает карту «скорость → порт»,
готовый конфиг и строки для env-файлов. С `--write` пишет
`/etc/nginx/glukvpn/stream-speed-router.conf`, делает бэкап, прогоняет
`nginx -t` и откатывается при ошибке. Блок `stream` подключается на **верхнем
уровне** `nginx.conf` (вне `http{}`): скрипт печатает нужную строку `include`,
но глобальный конфиг не правит. Если 443 по SNI уже раскладывает чужой файл,
скрипт останавливается — второй `listen 443` в `stream` не забиндится.

### Порядок включения

1. DNS: `speed30`…`speed500` (или `*.de-01`) — A/AAAA на IP ноды.
2. Сертификат: имена тиров должны попасть в SAN, иначе клиент получит
   TLS-ошибку вместо лимита:
   `certbot --expand -d de-01.gluk.tech -d speed30.de-01.gluk.tech …`.
3. `/etc/vpn-node-agent/agent.env`: `SHAPING_GATEWAY_SPEEDS=30,50,100,250,500`,
   `SHAPING_GATEWAY_BASE_PORT=8460`, `SHAPING_GATEWAY_TARGET_PORT=8445`
   (порт sing-box, **не** 443 — иначе релей зацикливается через nginx).
   Старый `SHAPING_GATEWAY_TIERS` (пары «скорость=внешний порт») оставлен для
   совместимости и имеет приоритет, поэтому на новой схеме он должен быть пуст.
4. `/etc/glukvpn/control.env`: `VLESS_SPEED_TIERS=30,50,100,250,500` — ставится
   последним, именно он начинает выдавать поддомены. Пустое значение = все
   клиенты идут на безлимитное имя (fail open), что и есть безопасный дефолт,
   пока пункты 1–3 не сделаны.

### Проверка

```bash
journalctl -u vpn-node-agent -n 50 | grep shapedGateways   # 30=8460,50=8461,...
ss -lntp | grep -E ':(846[0-9])'                           # релеи на loopback
ss -lntp | grep ':8445'                                    # sing-box
nginx -T | grep -A3 ssl_preread                            # карта SNI
openssl s_client -connect de-01.gluk.tech:443 -servername speed30.de-01.gluk.tech </dev/null 2>&1 | head -5
```

| Симптом | Причина | Что делать |
| --- | --- | --- |
| лимит не работает, скорость полная | `VLESS_SPEED_TIERS` пуст или имя без точки/bare IP в `gatewayHost` | выдача SNI отключена по fail open — проверить обе переменные |
| клиент с тарифом не подключается, безлимитный работает | нет DNS или SAN для `speedNN` | пункты 1–2, затем `--certbot` |
| один тир даёт connection refused | релей не слушает свой порт | сверить `shapedGateways` в логе с `nginx -T` |
| ноды заканчиваются сокеты, скорость 0 | `SHAPING_GATEWAY_TARGET_PORT=443` | поставить порт sing-box (8445) |

## Релизы: «залил два файла» и sync-downloads

Версия больше не живёт в сайте. Страницы и `config.js` знают только два
постоянных эндпоинта — `/download/windows` и `/download/android`, — а из `ui.js`
убран хардкод `download="GlukVPN-Setup-1.5.0.exe"`, из-за которого установщик
1.6.0 сохранялся под именем 1.5.0. Имя файла теперь задаёт сервер: редирект
ведёт на версионный файл, при `--attachment` добавляется `Content-Disposition`.

Единственный источник правды — имена двух файлов в каталоге загрузок:

```
/var/www/vpn.gluk.tech/downloads/GlukVPN-Setup-X.Y.Z.exe
/var/www/vpn.gluk.tech/downloads/glukvpn-release-X.Y.Z.apk
```

Релиз = два шага:

```bash
# 1. залить сборки (ровно два файла в каталоге)
scp GlukVPN-Setup-1.7.0.exe glukvpn-release-1.7.0.apk \
    root@138.2.186.223:/var/www/vpn.gluk.tech/downloads/
# 2. запустить скрипт из копии репозитория на сервере
sudo bash site/deploy/sync-downloads.sh --changelog 'GlukVPN 1.7.0: ...'
```

Что делает `site/deploy/sync-downloads.sh`:

- сканирует `downloads/`, берёт один `.exe` и один `.apk`, парсит из имени `X.Y.Z`;
- пишет `api/version.json`: `version`, `build` (+1 при новой версии, тот же при
  повторном запуске), `releaseDate` из mtime, `downloads.*` (версионные пути) и
  `endpoints.*` (постоянные). `changelog` и `minSupportedVersion` сохраняются,
  если не переданы флагами; неизвестные ключи файла не теряются;
- генерирует сниппет nginx с `return 302` на актуальные файлы, проверяет
  `nginx -t` и откатывается из бэкапа при ошибке;
- ставит владельца `www-data:www-data` и права `644`.

302, а не 301: цель меняется каждый релиз, а браузер с закэшированным постоянным
редиректом ещё долго тянул бы удалённый установщик.

Сниппет подключается вручную один раз, внутри server-блока `vpn.gluk.tech`:

```nginx
include /etc/glukvpn/nginx/downloads.conf;
```

Скрипт печатает эту строку и не перезагружает nginx, пока не увидит её в
`nginx -T` — чтобы не рапортовать об успехе, когда редиректов на самом деле нет.

Полезные флаги: `--dry-run` (ничего не пишет), `--json` (для CI), `--prune`
(удалить лишние сборки; по умолчанию только предупреждение), `--min-supported`
(форсировать обновление, баннер становится блокирующим), `--root` для беты.
Повторный запуск без новых файлов ничего не меняет.

### Проверка

```bash
curl -sI https://vpn.gluk.tech/download/windows | head -3        # 302 на .exe
curl -sI https://vpn.gluk.tech/download/android | head -3        # 302 на .apk
curl -s https://vpn.gluk.tech/api/version.json | jq '.version,.build,.downloads,.endpoints'
```

| Симптом | Причина | Что делать |
| --- | --- | --- |
| `/download/windows` даёт 404 | сниппет не подключён в server-блоке | добавить `include`, затем `nginx -s reload` |
| скрипт ругается на имя файла | артефакт без версии (`glukvpn-release.apk` из `build-apk.yml`) | переименовать в `glukvpn-release-X.Y.Z.apk` до заливки |
| клиенты не видят обновление | `version.json` не перегенерирован или отдаётся из кэша | запустить скрипт, проверить `curl` выше |
| скачивается старый установщик | в `downloads/` осталось две версии | `--prune` или удалить лишние вручную |
