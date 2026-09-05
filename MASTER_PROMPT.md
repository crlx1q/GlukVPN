# 🚀 GlukVPN: Мастер-промпт и полное техническое руководство проекта

> **Назначение документа**: Этот файл содержит полное исчерпывающее описание архитектуры, структуры файлов, окружения, правил разработки и команд GlukVPN. Используйте его в качестве системного контекста (Master Prompt) для любых AI-ассистентов, новых разработчиков или для собственной работы.

---

## 1. О проекте GlukVPN

**GlukVPN** — это кроссплатформенная экосистема персонального VPN-сервиса нового поколения с защитой от блокировок (DPI-resistant), единым аккаунтом на всех платформах, строгим контролем сессий и бережным расходованием ресурсов бесплатной инфраструктуры Oracle Cloud Always Free.

### Ключевые компоненты:
1. **Control Server** (Node.js / TypeScript / Fastify / Prisma / PostgreSQL) — центральный API управления пользователями, устройствами, подписками, нодами, биллингом и техработами.
2. **Android Client** (Flutter / Kotlin / GoBackend WireGuard) — нативное мобильное приложение с поддержкой фоновой службы, шторки уведомлений и генерацией ключей на устройстве.
3. **Windows Desktop Client** (Flutter / Win32 / Sing-box TUN / Wintun) — десктопный клиент с треем, защитой от DPI и туннелем на базе Wintun.
4. **Browser Extension & Browser Proxy** (Chrome MV3 + Node.js TLS CONNECT Proxy) — расширение для браузера с PAC-скриптом и прокси-сервер с валидацией токенов в реальном времени.
5. **Node Agent** (Node.js / TypeScript) — легковесный демон, работающий на каждой ноде (pull-модель по HTTPS).
6. **Web Dashboard & Site** (HTML5 / Vanilla JS / CSS) — сайт `vpn.gluk.tech` с личным кабинетом, авторизацией, покупкой тарифов и загрузкой релизов.

---

## 2. Структура репозитория: что и где лежит

```text
GlukVPN/
├── control-server/                    # [Backend] Центр управления (Control Plane)
│   ├── prisma/
│   │   ├── schema.prisma              # Схема базы данных PostgreSQL
│   │   └── migrations/                # Версионированные SQL-миграции
│   ├── src/
│   │   ├── app.ts                     # Инициализация Fastify, плагинов и роутов
│   │   ├── server.ts                  # Точка входа, запуск слушателя порта
│   │   ├── config.ts                  # Переменные окружения и константы
│   │   ├── middleware/                # Аутентификация JWT (requireUser, requireAdmin)
│   │   ├── routes/                    # API-эндпоинты:
│   │   │   ├── auth.ts                # Вход, выход, рефреш токенов
│   │   │   ├── devices.ts             # Регистрация, листинг, отвязка устройств
│   │   │   ├── vpn.ts                 # Создание сессий, получение конфигов туннеля
│   │   │   ├── nodes.ts               # Heartbeat нод, отчёты, опрос политик
│   │   │   ├── insights.ts            # Аналитика трафика, карта активных сессий, техработы
│   │   │   ├── admin.ts               # Административные ручки
│   │   │   └── register.ts            # Регистрация новых пользователей
│   │   └── services/                  # Бизнес-логика:
│   │       ├── tokens.ts              # Выпуск и валидация JWT
│   │       ├── sessions.ts            # Учёт активных WireGuard/VLESS сессий
│   │       ├── deviceAccess.ts        # Контроль версии токена устройства (token_version)
│   │       ├── accountInsights.ts     # Почасовая агрегация трафика (traffic_usage_buckets)
│   │       ├── serviceControl.ts      # Режим техработ (maintenance) и тумблер регистраций
│   │       └── telegramBot.ts         # Бот для уведомлений и подтверждения входа
│   └── public/                        # Веб-интерфейс админки (admin.js, admin.css)
│
├── flutter-client/                    # [Mobile & Desktop] Клиент на Flutter
│   ├── lib/
│   │   ├── main.dart                  # Точка входа для Android
│   │   ├── main_windows.dart          # Точка входа для Windows Desktop
│   │   ├── screens/                   # Экраны (главный, сервера, настройки, диагностика)
│   │   ├── widgets/                   # Виджеты (карты, кнопка connect, модалка 5/5 устройств)
│   │   ├── desktop/                   # Десктопная специфика (трей, pipe-клиент, окно)
│   │   ├── models/                    # Модели данных (AccountInsights, DeviceLimitDetails)
│   │   ├── services/                  # Сетевой клиент, VPN-сервис, хранилище SecureStorage
│   │   └── state/                     # Контроллеры состояния (VpnController, InsightsController)
│   ├── android_overrides/             # Нативный Kotlin код для Android:
│   │   ├── MainActivity.kt            # Мост системного VPN диалога
│   │   └── TunnelNotificationService  # Сервис фонового уведомления с кнопкой «Отключить»
│   ├── pubspec.yaml                   # Зависимости для Android (НЕ трогать десктопными пакетами!)
│   └── pubspec.desktop.yaml           # Зависимости для Windows (с window_manager, tray_manager)
│
├── node-agent/                        # [Server Agent] Демон VPN-ноды
│   ├── src/
│   │   ├── agent.ts                   # Главный цикл опроса control-server
│   │   ├── singboxManager.ts          # Управление процессом sing-box и правилами
│   │   └── lib/                       # Работа с интерфейсами, метриками и WireGuard
│   └── deploy/
│       ├── glukvpn-egress-guard.sh    # Скрипт защиты: блокировка SMTP 25 и BitTorrent
│       └── glukvpn-egress-guard.service # Systemd юнит защиты портов
│
├── glukvpn-extension-1.5.0/           # [Browser] Расширение Chrome и Browser Proxy
│   ├── extension/                     # Chrome Extension (Manifest V3)
│   │   ├── background.js              # Service Worker (Proxy PAC, auth 407, polling)
│   │   ├── lib/                       # Движок прокси (proxy.js), API, переводы (i18n.js)
│   │   └── ui/                        # Попап (popup.html, popup.js, theme.css)
│   └── server/glukvpn-browser-proxy/  # Node.js HTTPS TLS CONNECT Proxy
│       └── src/server.js              # Прокси-сервер (порты 8443/8444) с проверкой токенов
│
├── site/                              # [Web] Публичный сайт и веб-кабинет (vpn.gluk.tech)
│   ├── app/index.html                 # Веб-приложение личного кабинета
│   └── assets/                        # Стили и скрипты (app.js, auth.js, sprint2.js)
│
├── desktop/                           # [Desktop Build] Скрипты сборки Windows
│   └── packaging/
│       ├── build-all.ps1              # Мастер-сборщик EXE/инсталлятора (Inno Setup)
│       └── make-icons.ps1             # Генератор .ico иконок
│
└── .github/workflows/                 # [CI/CD] Автоматические сборки GitHub Actions
    ├── build-apk.yml                  # Сборка и подпись Android APK постоянным JKS
    └── build-desktop.yml              # Сборка Windows Installer (GlukVPN-Setup-1.3.0.exe)
```

---

## 3. Серверная инфраструктура (Production & Beta)

* **Хост**: `138.2.186.223` (Oracle Cloud Always Free, ARM64 Ubuntu 24.04, Франкфурт).
* **SSH-доступ**: `ssh -i "<путь_к_ключу>" ubuntu@138.2.186.223`.
* **Веб-окружение**: aaPanel (Nginx) управляет сайтами и SSL-сертификатами Let's Encrypt.
* **Базы данных**: Локальный PostgreSQL 16 (слушает только `127.0.0.1:5432`).

### Два параллельных контура (Channels):

| Параметр | Production (PROD) | Staging (BETA) |
| :--- | :--- | :--- |
| **API Domain** | `api.gluk.tech` | `beta-api.gluk.tech` |
| **Control Port** | `8081` (внутренний) | `8082` (внутренний) |
| **Systemd Service** | `glukvpn-control.service` | `glukvpn-beta-control.service` |
| **Директория** | `/opt/glukvpn/control-server` | `/opt/glukvpn/beta-control-server` |
| **Env файл** | `/etc/glukvpn/control.env` | `/etc/glukvpn/beta-control.env` |
| **Имя БД** | `glukvpn` | `glukvpn_beta` |
| **Browser Proxy**| `127.0.0.1:8443` | `127.0.0.1:8444` |
| **Proxy Service** | `glukvpn-browser-proxy.service`| `glukvpn-beta-browser-proxy.service` |

---

## 4. Ключевые бизнес-механизмы и логика

### А. Лимит устройств (5/5 Device Limit) и Instant Revocation
* При авторизации каждого нового устройства создаётся запись в таблице `devices`.
* Если лимит исчерпан (например, 5 девайсов на тарифе Pro), API возвращает `409 Conflict` с кодом `device_limit_reached` и списком занятых слотов.
* Клиенты (Desktop, Mobile, Extension, Web) показывают **модалку со списком девайсов**. Пользователь в один клик отвязывает старое устройство.
* **Мгновенный отзыв (Instant Revocation)**: в таблице `devices` инкрементируется `token_version`. Все выданные ранее RefreshToken и сессии этого девайса мгновенно становятся недействительными. Browser Proxy при следующем запросе `CONNECT` моментально рвёт соединение с кодом `407`.

### Б. Почасовой учёт трафика (Traffic Usage Buckets)
* В PostgreSQL действует триггер `capture_session_usage` на таблице `sessions`.
* При каждом отчёте от ноды (увеличение счетчиков `bytes_rx` / `bytes_tx`) триггер высчитывает дельту и записывает её в почасовую корзину `traffic_usage_buckets(user_id, device_id, bucket_start)`.
* **Инвариант**: Удаление устройства из аккаунта **не удаляет** историю трафика, накопленную этим устройством.

### В. Режим обслуживания (Maintenance Mode)
* Таблица `service_settings` содержит глобальный флаг `maintenance` и `registration_enabled`.
* Эндпоинт `GET /api/service/status` отдаёт клиентам текущее состояние.
* При включении техработ активные сессии закрываются, клиенты показывают вежливый баннер техработ с таймером автоповтора, а не ошибки сети.

### Г. Безопасность серверов: Egress Guard
* Сервис `glukvpn-egress-guard.service` запускает `glukvpn-egress-guard.sh`.
* В цепочках `OUTPUT` и `FORWARD` (для `wg0` `10.8.0.0/24`) блокируются:
  1. **TCP порт 25 (SMTP)** — предотвращение спам-рассылок и защита репутации IP от попадания в чёрные списки (Spamhaus).
  2. **Порты BitTorrent (6881–6999, 51413)** — блокировка торрент-трафика во избежание превышения Always Free лимитов (10 ТБ) и жалоб правообладателей (DMCA).

---

## 5. Железные правила разработки («Чего делать НЕЛЬЗЯ»)

1. **НИКОГДА не устанавливать и не включать `ufw`** на сервере `138.2.186.223`. Это сбросит цепочки iptables Oracle Cloud и заблокирует доступ по SSH.
2. **НИКОГДА не модифицировать конфиги Nginx в aaPanel глобально**. Менять можно только секцию `location` в пределах сайта `api.gluk.tech` или статики `vpn.gluk.tech`.
3. **НЕ объединять `pubspec.yaml` и `pubspec.desktop.yaml`**. Десктопные плагины (`window_manager`, `tray_manager`) ломают сборку Android APK. Подмена выполняется автоматически только внутри `desktop/packaging/build-all.ps1`.
4. **НЕ удалять постоянный ключ подписи Android** (`glukvpn-release.jks` в GitHub Secrets). Все сборки APK обязаны подписываться им, иначе пользователи не смогут обновить приложение поверх существующего.
5. **НЕ оставлять мусор на сервере**. Любые временные файлы распаковки (`/tmp/deploy_*`, скрипты деплоя) должны очищаться сразу после выполнения команд.

---

## 6. Частые команды и сценарии

### Сборка и деплой бэкенда (`control-server`):
```bash
cd control-server
npm run build              # Компиляция TypeScript и генерация Prisma Client
npm test                   # Запуск тестов Vitest (50+ тестов)
```

### Применение миграций БД на сервере:
```bash
# Для PROD:
cd /opt/glukvpn/control-server && sudo -u glukvpn npx prisma migrate deploy
# Для BETA:
cd /opt/glukvpn/beta-control-server && sudo -u glukvpn npx prisma migrate deploy
```

### Проверка здоровья сервисов:
```bash
curl -fsS https://api.gluk.tech/api/health
curl -fsS https://beta-api.gluk.tech/api/health
curl -fsS https://api.gluk.tech/api/service/status
```

### Проверка статусов и перезапуск служб на сервере:
```bash
sudo systemctl restart glukvpn-control glukvpn-beta-control
sudo systemctl restart glukvpn-browser-proxy glukvpn-beta-browser-proxy
sudo systemctl status glukvpn-egress-guard
```

### Сборка клиентов через GitHub Actions:
* **Android APK**: триггерится пушем в `master` или вручную в workflow `build-apk.yml`.
* **Windows Setup**: триггерится пушем в `desktop/beta` или вручную в workflow `build-desktop.yml`.
* Релизные файлы автоматически публикуются в GitHub Releases и дублируются на `https://vpn.gluk.tech/downloads/`.
