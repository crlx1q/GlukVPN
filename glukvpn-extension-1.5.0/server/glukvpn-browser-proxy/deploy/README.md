# Установка шлюза на немецкий узел

Шлюз нужен только для того, чтобы трафик браузера реально уходил через сервер.
Без него расширение установится, залогинится и создаст устройство в базе, но
трафик пойдёт напрямую.

Шлюз ничего не меняет в control-server и не трогает WireGuard. Он проверяет
токен устройства через `GET /api/vpn/status` и, если ответ положительный,
пропускает CONNECT.

## 1. Файлы и пользователь

```bash
sudo useradd --system --home /opt/glukvpn-browser-proxy --shell /usr/sbin/nologin glukproxy
sudo mkdir -p /opt/glukvpn-browser-proxy
sudo rsync -a ./ /opt/glukvpn-browser-proxy/        # из папки glukvpn-browser-proxy
sudo chown -R glukproxy:glukproxy /opt/glukvpn-browser-proxy
```

Зависимостей нет, `npm install` не нужен. Требуется Node 20+ (`node -v`).

## 2. Сертификат

Браузер обращается к шлюзу по имени из сертификата, поэтому нужен DNS-хост,
а не IP. Заведите, например, `de-01.gluk.tech` → `138.2.186.223`.

```bash
sudo certbot certonly --standalone -d de-01.gluk.tech
sudo usermod -aG ssl-cert glukproxy
sudo chmod 750 /etc/letsencrypt/{live,archive}
```

## 3. Конфиг

```bash
sudo cp /opt/glukvpn-browser-proxy/.env.example /opt/glukvpn-browser-proxy/.env
sudo nano /opt/glukvpn-browser-proxy/.env
```

Минимум: `TLS_CERT`, `TLS_KEY`, `CONTROL_API`, `REQUIRE_SESSION`.

`REQUIRE_SESSION=false` стоит поставить, пока `max_concurrent_sessions = 1`:
иначе телефон и браузер будут забирать сессию друг у друга.

## 4. Служба

```bash
sudo cp /opt/glukvpn-browser-proxy/deploy/glukvpn-browser-proxy.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now glukvpn-browser-proxy
sudo systemctl status glukvpn-browser-proxy
journalctl -u glukvpn-browser-proxy -f
```

## 5. Порт

```bash
sudo ufw allow 8443/tcp
sudo iptables -I INPUT -p tcp --dport 8443 -j ACCEPT
sudo netfilter-persistent save
```

Oracle Cloud: тот же порт нужно открыть в Security List / NSG подсети, иначе
соединение не дойдёт до машины.

## 6. Проверка

```bash
# живой ли шлюз
curl -sv https://de-01.gluk.tech:8443/__gluk/ping 2>&1 | grep '204\|SSL'

# полный путь: токен устройства -> CONNECT -> внешний IP
curl -x https://DEVICE_ID:ACCESS_TOKEN@de-01.gluk.tech:8443 https://api.ipify.org
```

Вторая команда должна вернуть IP немецкого узла. Если `407` — токен не принят
control-plane, если `403 no-active-session` — включён `REQUIRE_SESSION=true`,
а сессии у браузера нет.

`curl` умеет `-x https://` начиная с 7.52 и требует поддержки HTTPS-прокси в
сборке; иначе проверяйте прямо из расширения.

## Что смотреть при проблемах

| Симптом | Причина |
| --- | --- |
| В браузере `ERR_PROXY_CONNECTION_FAILED` | порт закрыт в NSG/ufw или служба не поднялась |
| Постоянное окно ввода логина прокси | расширение не отдало Basic — проверьте, что устройство зарегистрировано |
| `403 blocked-address` | цель разрешилась в приватный диапазон, это защита от SSRF |
| `429 Too Many Connections` | лимит `MAX_CONNECTIONS_PER_DEVICE` |
| Сайты на нестандартных портах не грузятся | добавьте порт в `ALLOWED_PORTS` |
