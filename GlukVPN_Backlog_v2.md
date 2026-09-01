# GlukVPN — Master Backlog / Roadmap / Ideas / Bugs / Decisions

> Единый живой документ GlukVPN. Здесь собраны текущие функции, найденные баги, UX-проблемы, security-задачи, архитектурные решения, будущие функции, идеи и продуктовые планы.
>
> **Статус:** рабочий MVP уже реально подключает Android к VPN-нode в Frankfurt и выводит интернет через `138.2.186.223`.

---

## 1. Текущее состояние MVP

Уже доказано end-to-end:

```text
Android
  ↓
GlukVPN Flutter
  ↓
Control API
  ↓
WireGuard peer provisioning
  ↓
138.2.186.223:51820
  ↓
wg0
  ↓
NAT
  ↓
Internet
```

Работают:

- login;
- node list;
- connect;
- disconnect;
- Android VPN permission;
- WireGuard;
- public IP;
- VPN IP;
- ping;
- traffic;
- heartbeat;
- node metrics;
- Control API;
- PostgreSQL;
- Node Agent;
- GitHub Actions;
- APK.

---

## 2. Тестовый сервер

Текущий сервер:

```text
Oracle Cloud
Ubuntu 24.04 ARM64
Frankfurt
138.2.186.223
```

Он временно одновременно:

- Control Server;
- VPN Node.

Позже эти роли должны быть разделены.

---

## 3. Control Plane

`api.gluk.tech` — главный Control Plane.

Отвечает за:

- authentication;
- users;
- devices;
- sessions;
- subscriptions;
- nodes;
- revoke;
- block;
- scheduling;
- monitoring;
- admin operations;
- future billing.

---

## 4. Data Plane

VPN traffic никогда не должен проходить через Control API.

Правильно:

```text
Phone → VPN Node → Internet
```

API используется только для управления.

---

## 5. Доменная архитектура

План:

```text
gluk.tech
    ↓
public website

api.gluk.tech
    ↓
Control API

admin.gluk.tech
    ↓
Admin Panel

de.gluk.tech
    ↓
Germany VPN endpoint

fr.gluk.tech
    ↓
France VPN endpoint

us.gluk.tech
    ↓
USA VPN endpoint
```

WireGuard должен подключаться непосредственно к VPN node.

---

## 6. Persistent Login

Пользователь не должен вводить пароль при каждом запуске.

Нужно:

```text
Login
→ access token
→ refresh token
→ Android Secure Storage
→ app restart
→ refresh
→ user remains logged in
```

---

## 7. Потеря интернета ≠ logout

Нужно чётко разделить:

```text
NETWORK LOST
SESSION REVOKED
LOGOUT
SUBSCRIPTION EXPIRED
```

Потеря сети не должна выбрасывать пользователя из аккаунта.

---

## 8. Wi-Fi ↔ Mobile switching

VPN должен переживать:

- Wi-Fi → LTE;
- LTE → Wi-Fi;
- смену Wi-Fi;
- кратковременный network loss.

Желаемое:

```text
Connected
↓
network changed
↓
Reconnecting...
↓
handshake restored
↓
Connected
```

Без повторного login.

---

## 9. Automatic reconnect

Добавить backoff:

```text
1s → 2s → 5s → 10s → ...
```

С ограничением, чтобы приложение не спамило сервер и WireGuard.

---

## 10. Background VPN lifecycle

Android `VpnService` должен быть отдельным от UI.

```text
GlukVPN UI
   ↓
Android VpnService
   ↓
WireGuard
```

Закрытие UI не должно автоматически убивать VPN.

---

## 11. Background active-app UX

Постоянное обычное пользовательское уведомление GlukVPN **не нужно**.

Желаемый UX — как системный active/background app status в One UI:

- VPN работает в фоне;
- пользователь видит активное приложение/службу в системном интерфейсе;
- при системном завершении службы VPN останавливается;
- VPN session закрывается/revokes as appropriate.

---

## 12. Только полезные уведомления

Разрешены только полезные уведомления:

- подписка скоро истечёт;
- подписка истекла;
- новый вход;
- новое устройство;
- node/service problem;
- новая версия приложения;
- критическое событие.

Не показывать постоянное:

> GlukVPN работает

---

## 13. Public IP

В клиенте должен отображаться фактический внешний IP node.

Пример:

```text
Public IP
138.2.186.223
```

После смены node должен отображаться новый IP.

---

## 14. VPN IP

Показывать внутренний адрес устройства:

```text
VPN IP
10.8.0.10
```

Это диагностическое поле, не главный user-facing показатель.

---

## 15. Ping

В UI уже есть:

```text
Ping via tunnel
```

Нужно чётко определить измерение:

- Phone → VPN gateway;
- и при желании отдельный Internet latency.

Не смешивать два показателя.

---

## 16. Traffic accounting

Сейчас есть:

- Downloaded;
- Uploaded.

Дальше нужны:

- current session;
- daily;
- monthly;
- account total;
- node total.

---

## 17. Traffic correctness

Проверить:

- RX/TX;
- reset при reconnect;
- session totals;
- cumulative totals;
- node counters;
- subscription counters.

---

## 18. Session state machine

Нормализовать:

```text
PENDING
PROVISIONED
CONNECTED
DEGRADED
RECONNECTING
CLOSING
CLOSED
REVOKED
EXPIRED
```

UI должен получать состояние с backend, а не полагаться только на local boolean.

---

## 19. Handshake health

Если WireGuard handshake давно не обновлялся, UI не должен бесконечно показывать `CONNECTED`.

Нужны состояния:

```text
Healthy
Degraded
Reconnecting
Offline
```

---

## 20. Kill Switch

Если VPN исчез:

```text
VPN lost
↓
Internet blocked
↓
VPN restored
↓
Internet restored
```

Это особенно важно для production.

---

## 21. DNS leak protection

Проверить:

- DNS через VPN;
- отсутствие DNS leak;
- корректный DNS fallback.

---

## 22. IPv6

Сейчас можно оставить IPv6 за рамками MVP.

Перед production выбрать:

```text
IPv6 through VPN
```

или

```text
IPv6 blocked safely
```

чтобы не было leak.

---

## 23. MTU / network compatibility

Проверить:

- Wi-Fi;
- LTE;
- разные ISP;
- разные Android devices.

Подобрать безопасный MTU и fallback.

---

## 24. Android VPN permission UX

Если permission отклонён:

```text
VPN permission required
[Allow]
```

Никаких непонятных generic errors.

---

## 25. Disconnect flow

Disconnect должен делать:

```text
Flutter
↓
Control API
↓
Node Agent
↓
remove WireGuard peer
↓
close session
↓
stop VpnService
↓
restore network
```

---

## 26. Force-stop behavior

При полном системном Force Stop:

- VPN останавливается;
- session закрывается либо помечается interrupted;
- peer после подтверждённого revoke/cleanup должен исчезнуть.

---

## 27. Device binding

Каждый device имеет:

- device ID;
- user ID;
- WireGuard public key;
- platform;
- status;
- created_at;
- last_seen.

---

## 28. Device limits

Ввести ограничения:

- max devices;
- max concurrent sessions.

Параметры зависят от тарифа.

---

## 29. Device management in app

В Settings → Devices:

```text
Samsung S24+
Android
Active now
```

Не показывать пользователю технические ID вроде:

```text
android-29od
```

---

## 30. Revoke device

Пользователь должен иметь возможность revoke собственное устройство.

Admin тоже должен иметь возможность revoke.

После revoke:

```text
peer removed
session revoked
future connect denied
```

---

## 31. Session lease

Control Plane должен контролировать живую VPN-сессию.

Добавить:

- session_id;
- started_at;
- expires_at;
- last_seen;
- heartbeat;
- status.

Например:

```text
session TTL: 15–30 minutes
heartbeat: 30–60 sec
```

---

## 32. Network loss должен сохранять session lease

Network loss:

```text
KEEP SESSION
```

а не:

```text
DELETE USER
LOGOUT
```

Приложение должно восстанавливать tunnel.

---

## 33. Admin live revoke

Admin:

```text
User
→ active session
→ Disconnect / Revoke
```

Backend:

```text
Control API
→ Node Agent
→ remove peer
→ internet stops
```

Это обязательный E2E security test.

---

## 34. BLOCK пользователя

Вместо простого `Disable` нужна явная кнопка:

```text
BLOCK
```

Block должен:

- отозвать active sessions;
- удалить WireGuard peers;
- запретить новые подключения;
- запретить login/session refresh по политике;
- сохранить audit event.

Нужен также `UNBLOCK`.

---

## 35. Account roles

Минимальные роли:

```text
Owner
Admin
Support
User
```

### Owner

Полный доступ.

### Admin

Users / nodes / sessions / subscriptions.

### Support

User/session support.

### User

Только собственный аккаунт и устройства.

---

## 36. Несколько администраторов

Сделать несколько админов.

Не использовать одного общего admin account.

Для каждого:

- отдельный аккаунт;
- отдельная сессия;
- отдельный audit trail.

---

## 37. Admin MFA

Для admin.gluk.tech позже:

- MFA;
- Passkey;
- Telegram alerts;
- login audit;
- device/session management.

Admin security должна быть сильнее обычного user.

---

## 38. Audit logs

Логировать административные и security события:

```text
LOGIN
VPN_CONNECT
VPN_DISCONNECT
DEVICE_REVOKE
USER_BLOCK
USER_UNBLOCK
NODE_OFFLINE
NODE_DISABLED
ADMIN_ACTION
```

Не логировать VPN payload/содержимое трафика.

---

## 39. Telegram Bot — регистрация

Будущая регистрация:

```text
Create account
↓
Telegram verification
↓
Bot
↓
Send Contact
↓
Phone verified
↓
Account activated
```

Это уменьшает abuse массовой регистрации.

---

## 40. Telegram ID / phone binding

Хранить:

- Telegram user ID;
- verified phone;
- verification status.

Один Telegram account не должен бесконтрольно создавать бесконечное количество accounts.

---

## 41. Telegram user notifications

Пользователь может получать:

- subscription expiration;
- new login;
- new device;
- critical account events;
- new version.

---

## 42. Telegram admin alerts

У всех нужных админов должны быть уведомления:

- API down;
- node down;
- database issue;
- app/backend error spike;
- unusual traffic;
- failed deployment;
- service-wide outage;
- new release.

---

## 43. Anti-abuse detection

Не использовать DPI.

Работать на основе метаданных:

- sessions;
- bytes;
- connection rate;
- device count;
- concurrent sessions;
- reconnect rate;
- account state.

---

## 44. Stolen key defense

Нельзя полагаться на «пользователь использует только наше приложение».

Если credential/device key украден:

- device binding;
- session lease;
- heartbeat;
- revoke;
- peer removal;
- expiry

должны позволять быстро прекратить доступ.

---

## 45. WireGuard security model

Каждое устройство получает свою key pair.

Client private key хранится только на устройстве.

Node public key отдаётся клиенту.

Не использовать общий private key для всех.

---

## 46. Manual WireGuard security test

После MVP проверить:

1. Подключить через GlukVPN.
2. Проверить собственный peer.
3. При необходимости протестировать direct WireGuard client на собственном устройстве.
4. Admin → revoke.
5. Проверить, что peer удалён.
6. Проверить, что старый credential больше не работает.

Это должен быть отдельный security test.

---

## 47. Admin panel — функционал

Админка должна иметь:

- Dashboard;
- Users;
- Devices;
- Sessions;
- Nodes;
- Subscriptions;
- Audit;
- Alerts.

---

## 48. Admin dashboard

Показывать:

```text
Users
Online users
Active sessions
Nodes
Traffic
Alerts
```

---

## 49. User management

Для пользователя:

- profile;
- status;
- devices;
- sessions;
- traffic;
- subscription;
- block/unblock;
- disconnect all;
- revoke device.

---

## 50. Sessions management

Показывать:

- user;
- device;
- node;
- VPN IP;
- connected time;
- duration;
- RX;
- TX;
- state.

---

## 51. Node management

Admin view:

- online/offline;
- region;
- city;
- CPU;
- RAM;
- disk;
- bandwidth;
- peers;
- heartbeat;
- uptime;
- agent version;
- WireGuard health.

---

## 52. User-facing server list

Пользователь НЕ должен видеть:

- CPU;
- RAM;
- agent version;
- heartbeat;
- internal capacity details.

Пользователь должен видеть:

```text
🇩🇪 Germany
Frankfurt
68 ms
Online
Recommended
```

---

## 53. Design separation: user vs admin

User UI:

- country;
- city;
- ping;
- public IP;
- VPN IP;
- duration;
- traffic;
- connection state.

Admin UI:

- infrastructure diagnostics;
- load;
- sessions;
- users;
- nodes;
- security.

---

## 54. Final mobile design direction

Текущий basic UI уже работает, но **не является финальным дизайном**.

Финальный дизайн будет разработан отдельно пользователем и затем передан AI-agent для реализации.

Цель:

- polished;
- consistent;
- premium;
- modern;
- clear;
- high quality;
- production-grade.

---

## 55. HTML design prototype

Текущий HTML-прототип `gluk_vpn_v5_connection.html` уже задаёт сильное visual direction:

- dark purple background;
- Poppins;
- glass cards;
- animated blobs;
- large central connection button;
- map background;
- animated route;
- bottom navigation;
- server selector;
- status badge;
- Public IP / VPN IP / Duration / Ping;
- Traffic.

В исходнике это реализовано как 390×844 mobile stage, с animated waves, morphing connection blob и glassmorphism cards. fileciteturn4file0L49-L112

Прототип также содержит отдельный Server screen с выбором стран и скоростью. fileciteturn4file1L154-L169 fileciteturn4file2L373-L408

Важно: HTML — дизайн/interaction prototype, а не production data source. В нём demo values hardcoded/random, например Public IP, ping и traffic. fileciteturn4file2L485-L503

---

## 56. Official logo

Нужно сделать официальный GlukVPN logo.

Применить:

- launcher icon;
- splash;
- app branding;
- website;
- favicon;
- admin;
- release assets;
- future clients.

---

## 57. Localization

Минимум:

- Russian;
- English.

Потом:

- другие популярные языки.

Все строки должны быть вынесены в localization system.

---

## 58. App version/update notifications

Control plane может сообщать:

```text
New GlukVPN version available
v1.1.0
```

Каналы:

- in-app;
- Telegram;
- system notification only when useful.

---

## 59. Public website gluk.tech

Сайт должен красиво объяснять:

- что такое GlukVPN;
- privacy;
- security;
- regions;
- features;
- pricing;
- promo codes;
- FAQ;
- download;
- support.

---

## 60. Auto Best Server

По кнопке `Connect` без ручного выбора клиент/Control Plane выбирает лучшую ноду.

Факторы:

- ping;
- availability;
- node load;
- capacity;
- region policy.

Ручной выбор сохраняется.

---

## 61. Manual server choice

Пользователь всегда может открыть Server list и выбрать регион вручную.

---

## 62. Server regions

План:

```text
Germany
France
USA
Japan
Korea
...
```

Добавлять по реальному спросу.

---

## 63. Region correctness

Frankfurt подтверждён как фактический регион текущего node.

Не показывать ложную страну.

Если node реально в другом регионе — UI должен это отражать.

---

## 64. Multiple nodes per region

В регионе может быть:

```text
Germany
DE-01
DE-02
DE-03
```

Пользователь видит регион, а scheduler выбирает конкретный node.

---

## 65. Node scheduling

Scheduler должен учитывать:

- availability;
- latency;
- CPU;
- RAM;
- bandwidth;
- active peers;
- capacity.

---

## 66. Node draining

При обновлении:

```text
DRAINING
```

Новые подключения не идут.

Существующие продолжают работать.

После `0 sessions` node можно перезапускать.

---

## 67. Failover policy

Два режима:

### Strict region

Germany → только Germany.

### Auto failover

Падение конкретной Germany node → другая Germany node.

---

## 68. Chrome-only VPN

Нужен режим, где VPN действует только для Chrome.

Варианты:

- browser proxy;
- native helper;
- отдельная desktop VPN integration.

Обычное Chrome Extension само по себе не заменяет системный VPN.

---

## 69. App-triggered VPN automation

Нишевая функция:

```text
Открыл Telegram
→ VPN ON

Закрыл Telegram
→ VPN OFF
```

Пользователь сможет создать сценарии:

- application;
- region;
- auto connect;
- auto disconnect;
- exceptions.

Нужно учесть Android restrictions и избежать connect/disconnect loops.

---

## 70. Desktop clients

План:

- Windows;
- macOS;
- Linux.

Control API и Node architecture должны оставаться общими.

---

## 71. iOS

Отдельный клиент позже.

Использовать системные VPN APIs Apple, соблюдая платформенные ограничения.

---

## 72. Subscription model

Архитектура:

```text
plans
subscriptions
entitlements
expires_at
status
```

Ограничения могут быть по:

- devices;
- sessions;
- traffic;
- speed;
- regions;
- duration.

---

## 73. Promo codes / free premium

Нужны промокоды:

- бесплатные дни Premium;
- trial;
- promo campaigns;
- limited offers.

---

## 74. Traffic limits

Не будет настоящего unlimited.

Максимальный ориентир:

**до ~10 TB / month**

Тарифы должны быть щедрыми, но конечными.

---

## 75. Payments

План в два этапа:

### Сначала

Онлайн payment system на сайте.

```text
gluk.tech
→ payment
→ backend
→ subscription
```

### Потом

Google Play subscriptions.

```text
Google Play
→ subscription
→ backend
```

---

## 76. Pricing

Позиционирование:

- дешевле крупных аналогов;
- низкая стартовая себестоимость;
- щедрые лимиты;
- без fake unlimited.

---

## 77. Production / scale / long-term

После качественного MVP:

- отдельный Control Server;
- отдельные VPN nodes;
- backups;
- monitoring;
- disaster recovery;
- node credential rotation;
- abuse response;
- public launch;
- legal pages;
- Terms;
- Privacy Policy;
- Acceptable Use;
- support;
- release signing;
- Google Play;
- multi-region;
- high availability;
- production security review.

---

# Priority order

## P0 — Stability + Control

1. Persistent login.
2. Wi-Fi/LTE switching.
3. Automatic reconnect.
4. Session lease.
5. Server-side revoke.
6. BLOCK/UNBLOCK.
7. Admin live session control.
8. Kill Switch.
9. DNS leak protection.
10. Better state/error handling.
11. Background active-app behavior.
12. Correct Force Stop / Disconnect semantics.

## P1 — Operations

13. Clean admin UI.
14. Device management.
15. Audit logs.
16. Multiple admins.
17. Telegram admin alerts.
18. Telegram verification.
19. Better user-facing server list.
20. Auto Best Server.
21. Node draining.
22. Node health.

## P2 — Scale

23. France.
24. USA.
25. Multi-region.
26. Multiple nodes per region.
27. Scheduler.
28. Failover.
29. Chrome-only mode.
30. App-triggered VPN.

## P3 — Product

31. gluk.tech.
32. Logo.
33. Localization.
34. Version update notifications.
35. Subscription system.
36. Promo codes.
37. Online payments.
38. Google Play subscriptions.
39. Traffic limits up to ~10 TB.
40. Desktop clients.
41. iOS.

## P4 — Production

42. Release signing.
43. Monitoring.
44. Backups.
45. Disaster recovery.
46. Abuse operations.
47. Legal pages.
48. Security audit.
49. Production HA.
50. Public launch.

---

# Core principles

1. Control Plane != Data Plane.
2. VPN traffic does not pass through API.
3. Each device has unique WireGuard keys.
4. Server-side revoke must work.
5. Network loss != logout.
6. UI close != necessarily VPN stop.
7. Explicit disconnect/revoke must stop VPN.
8. No DPI.
9. No shared client private keys.
10. No public admin without strong auth.
11. Best Server + manual selection.
12. One Control Plane, many nodes.
13. User UI hides infrastructure noise.
14. Admin UI exposes infrastructure detail.
15. Product design is separate from current prototype.
16. Security must not depend only on trusting the APK.
17. GlukVPN should be controllable centrally.
