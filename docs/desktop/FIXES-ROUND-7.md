# Круг 7 — что исправлено

Ветка `desktop/beta`. PROD не тронут.

---

## 1. Кнопки «Войти» и «Выйти» — вернул прежнюю форму

В круге 6 я неверно понял задачу и сделал кнопку узкой (178 px), а «Выйти» —
вообще другой кнопкой (`_DangerButton`). Просили не это: форма прежняя,
меньше только текст и сам блок.

| Файл | Изменение |
| --- | --- |
| `lib/widgets/glass.dart` | У `PrimaryPillButton` появился флаг `compact`. Он уменьшает: паддинги `26/6` → `18/4`, шрифт `titleMedium` → `titleSmall`, кружок стрелки `46` → `34`, спиннер `18` → `14`, иконку `20` → `16`. На мобильном значения по умолчанию не изменились. |
| `desktop_login_screen.dart` | Снова обычная кнопка на всю ширину, только `compact: true`. |
| `desktop_account_screen.dart` | «Выйти» — снова такая же кнопка на всю ширину с `compact: true`. Класс `_DangerButton` удалён. |

---

## 2. «This sign-in link is unknown or has expired»

Причина ровно та, что в задаче: ПК-клиент создаёт ссылку на PROD API
(`api.gluk.tech`, :8081), запись `startLink` лежит в памяти этого процесса, а
сайт с `channel: "beta"` шёл проверять код на `beta-api.gluk.tech` (:8082) —
другой процесс, другая память, 404.

Сделал оба пункта, а не один: переключение канала лечит сегодня, динамический
хост лечит навсегда.

| Файл | Изменение |
| --- | --- |
| `site/assets/js/config.js` | `api.channel`: `"beta"` → `"prod"`. |
| `control-server/src/routes/link.ts` | `verifyUrl` теперь содержит канал, который выдал ссылку: `…/link?code=ABCD-EFGH&api=prod`. В ответе `POST /api/auth/link/start` добавлено поле `apiChannel`. |
| `site/assets/js/auth.js` | `pickChannel()` читает `?api=` из адреса, запоминает в `sessionStorage["gluk.api"]` и проверяет по списку известных хостов. Подделать хост нельзя. |
| `site/assets/js/link.js` | `apiFromUrl()` + `withApi()`: канал переживает переход на `/login/` и обратно. |

Теперь ссылка сама рассказывает сайту, на каком API её подтверждать. Даже если
в конфиге сайта снова окажется `beta`, вход по ссылке с PROD не сломается.

---

## 3. Код `ABCD-EFGH` больше не показывается

`desktop_login_screen.dart`: вместо текста кода — строка «Ожидание
подтверждения входа в браузере…», круговой спиннер и кнопка «Отмена».
Пользователю код не нужен: он просто нажимает «Войти» на сайте.

---

## 4. Туннель: `ok=0, ran 1s` — настоящая причина и настоящее лечение

Это главное изменение круга.

### Что было не так

В круге 6 я заменил WireGuard-NT на Wintun, но оставил `tunnel.dll` из
`wireguard-windows/embeddable-dll-service`. Это не помогло, и вот почему:

> **`tunnel.dll` — это не реализация WireGuard.** Это запускалка *ядерного*
> драйвера WireGuard-NT, которая при первом старте ставит `wireguard.sys`.

У `wireguard.sys` нет WHQL-подписи Microsoft. На машине с включённой
«Изоляцией ядра» (Memory Integrity / WDAC) ядро отказывается его грузить, и
процесс умирает через секунду. Отсюда ровно то, что было в диагностике:

```
[connect] tunnel up accepted, waiting for verification
Tunnel worker exited, ok=0, ran 1s
ConnectionPhase.connecting -> ConnectionPhase.connectionFailed (tunnel_error)
```

Положить рядом `wintun.dll` было бесполезно: `tunnel.dll` про Wintun никогда и
не спрашивал.

### Что теперь

Драйвера ядра в схеме больше нет вообще. Data plane — собственная Go-программа
**`glukvpn-wg.exe`**: wireguard-go, который считает криптографию и гоняет
пакеты в userspace, а от системы ему нужен только виртуальный адаптер — это и
есть Wintun, и он **подписан WHQL**. Ровно так устроены Proton, Mullvad и
Tailscale на Windows.

**Новые файлы**

| Файл | Что делает |
| --- | --- |
| `native/glukvpn-tunnel-service/go/glukvpn-wg/main.go` | 583 строки. Парсит wg-quick конфиг, поднимает Wintun-адаптер (`tun.CreateTUN`), настраивает адреса, маршруты, DNS и MTU через `winipcfg`, отдаёт UAPI-канал для статистики, ждёт событие остановки. |
| `native/glukvpn-tunnel-service/go/glukvpn-wg/go.mod` | Модуль с зафиксированной версией `golang.zx2c4.com/wireguard/windows v0.5.3`. |

**Изменённые файлы**

| Файл | Изменение |
| --- | --- |
| `src/tunnel.h` / `src/tunnel.cpp` | Загрузка `tunnel.dll` (`LoadTunnelDll`, `HMODULE`, `FreeLibrary`) удалена. Вместо неё `CreateProcessW` на `glukvpn-wg.exe` с надзором: `stdout`/`stderr` пишутся в `tunnel-worker.log`, при остановке даётся 8 секунд, потом `TerminateProcess`. `DriverReady()` проверяет наличие обоих файлов, `DriverDescription()` → `wintun (userspace)`. |
| `src/tunnel.cpp` | Новый `ReadTail()`: последняя строка лога воркера попадает в текст ошибки, поэтому вместо «туннель остановился» пользователь видит настоящую причину. |
| `CMakeLists.txt` | Копирует `glukvpn-wg.exe` + `wintun.dll` вместо `tunnel.dll` + `wintun.dll`. |
| `desktop/packaging/build-all.ps1` | Больше не тянет `embeddable-dll-service`. Качает только `wintun-0.14.1.zip` и собирает наш воркер: `go mod tidy` + `go build` с `CGO_ENABLED=0`. |
| `.github/workflows/build-desktop.yml` | То же самое в CI. |
| `desktop/packaging/installer.iss`, `vendor/amd64/README.md`, `BUILD-WINDOWS.md`, `DESKTOP-README.md`, `ARCHITECTURE.md`, `FILES.md`, `native/.../README.md` | Документация приведена в соответствие. |

**Что важно для сборки:** `CGO_ENABLED=0` — сборка чисто на Go, никакого
mingw-w64/gcc ставить не надо. Прошлый вариант (`-buildmode=c-shared`) требовал
C-тулчейн; теперь нет.

**Контракт с сервисом не изменился:**

- остановка — то же событие `Global\WireGuard-Stop-GlukVPN`;
- статистика — тот же UAPI-канал
  `\\.\pipe\ProtectedPrefix\Administrators\WireGuard\GlukVPN`, транзакция
  `get=1`;
- дополнительно воркер получает `--parent <pid>` и сам умирает, если сервис
  упал не позвав `Down()`. Это страховка от «адаптер жив, интернета нет».

### Критерий приёмки

Чистая Windows, «Изоляция ядра» включена: установил → нажал Connect → в
«Сетевых подключениях» появился адаптер GlukVPN, трафик идёт. Ничего
доустанавливать не надо, окон UAC про драйвер нет.

---

## 5. Прочее, что оставалось с круга 6

| Что | Где |
| --- | --- |
| Из «Настроек» убран дублирующий раздел «Аккаунт» (профиль, тариф, список устройств, «Выйти») — он живёт на отдельном экране, как в расширении | `desktop_settings_screen.dart` |
| Список серверов теперь получает язык интерфейса, поэтому подпись «Франкфурт, Германия» не превращается в английскую при переключении языка | `desktop_servers_screen.dart` |

---

## Что осталось на следующий круг

Честно, чтобы не терялось:

1. **Экран «Аккаунт» на мобильном** — на ПК он отдельный, на телефоне ещё внутри настроек.
2. **Расширение**: вход по ссылке (сейчас там `linkWithSite` + опрос 90 секунд) и фильтр списка устройств `#seg-devices`.
3. **Экран статистики** — вы сами отметили его отдельной задачей.
4. **Тарифы Free / Basic / Pro** — следующая задача по вашему списку.
5. Хранение link-записей в Redis, если API поедет на несколько инстансов.
