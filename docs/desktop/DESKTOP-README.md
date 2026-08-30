# GlukVPN Desktop — начни отсюда

Ветка `desktop/beta`. Код полностью лежит в репозитории. Компилировать нужно
у себя — это Flutter Windows плюс нативный C++ сервис, а Windows-тулчейна
в среде, где писался код, не было.

## Что нужно один раз

| Инструмент | Зачем |
| --- | --- |
| Flutter SDK 3.19+ | Само приложение |
| Visual Studio 2022 + «Desktop development with C++» | Flutter Windows и сервис |
| Inno Setup 6 | Установщик (опционально) |
| 7-Zip | Один exe-файл (опционально) |

Плюс две DLL от WireGuard — их нельзя класть в git, поэтому скачай сам в
`native\glukvpn-tunnel-service\vendor\amd64\`:

- `tunnel.dll` — <https://download.wireguard.com/windows-client/> → `embeddable-dll-service/amd64/`
- `wireguard.dll` — <https://download.wireguard.com/wireguard-nt/> → `bin/amd64/`

Без них сборка пройдёт, но Connect будет отвечать `driver_unavailable`.

## Сборка одной командой

```powershell
cd C:\Users\alish\Downloads\GlukVPN
git checkout desktop/beta
flutter config --enable-windows-desktop

powershell -ExecutionPolicy Bypass -File desktop\packaging\build-all.ps1 `
    -Channel prod -Installer -MakeIcons
```

На выходе — `dist\GlukVPN-Setup-1.0.0.exe`.

Хочешь портативный вариант:

```powershell
.\build-all.ps1 -Channel prod -Portable -SingleFile
```

→ `dist\GlukVPN-portable-1.0.0.zip` и `dist\GlukVPN-1.0.0-portable.exe`.

Внутренняя BETA-сборка против `beta-api.gluk.tech`:

```powershell
.\build-all.ps1 -Channel beta -Internal -Installer
```

## Если хочешь руками

```powershell
# 1. Нативный сервис
cmake -S native\glukvpn-tunnel-service -B native\glukvpn-tunnel-service\build `
      -G "Visual Studio 17 2022" -A x64
cmake --build native\glukvpn-tunnel-service\build --config Release

# 2. Иконки
powershell -ExecutionPolicy Bypass -File desktop\packaging\make-icons.ps1

# 3. Flutter (подмена pubspec обязательна)
cd flutter-client
copy pubspec.yaml pubspec.android.bak
copy pubspec.desktop.yaml pubspec.yaml
flutter pub get
flutter build windows --release --target lib\main_windows.dart `
    --dart-define=GLUK_CHANNEL=prod --dart-define=GLUK_INTERNAL=false
copy pubspec.android.bak pubspec.yaml
del pubspec.android.bak
cd ..

# 4. Установщик
iscc /DAppVersion=1.0.0 /DStageDir=..\..\dist\stage desktop\packaging\installer.iss
```

Верни `pubspec.yaml` обратно — иначе следующая сборка Android потянет
`window_manager`. `build-all.ps1` делает это сам через `try/finally`.

## Перед тем как радоваться

```powershell
cd flutter-client
flutter test              # 6 desktop-тестов + все старые
flutter build apk --debug # Android не сломан
```

Оба должны пройти. Если второй падает — скорее всего остался подменённый
pubspec: `git checkout flutter-client/pubspec.yaml`.

## Что увидит пользователь

1. Запускает `GlukVPN-Setup-1.0.0.exe`, один раз подтверждает UAC.
2. Короткая анимация логотипа (~620 мс).
3. Вход по своему обычному аккаунту — username или email.
4. Список серверов, Connect, настоящий системный VPN-адаптер `GlukVPN`.
5. Крестик прячет окно в трей, VPN продолжает работать.
6. Exit из трея — отключает и выходит.

Никаких скриптов, PowerShell, node или отдельного proxy пользователь не
запускает.

## Честно о трёх вещах

**Настоящего одного exe у Flutter не бывает.** Всегда есть `glukvpn.exe`,
`flutter_windows.dll` и папка `data\`. `-SingleFile` делает SFX-архив: один
файл, двойной клик, распаковка в `%LOCALAPPDATA%\GlukVPN\app` и запуск.
Данные — в `%APPDATA%\GlukVPN`, как ты и просил.

**Один UAC при установке неизбежен.** Создание сетевого адаптера требует
прав. Дальше — ни одного. У официального WireGuard точно так же.

**В Параметрах Windows → VPN нашего подключения не будет.** Та страница
показывает только RAS/IKEv2. WireGuard туда не попадает никогда — это
ограничение Windows. Статус виден в «Сетевых подключениях» (адаптер
`GlukVPN`), в `ipconfig /all` и в нашем трее.

## Куда смотреть дальше

| Документ | О чём |
| --- | --- |
| `ARCHITECTURE.md` | Как всё устроено и почему именно так |
| `BUILD-WINDOWS.md` | Подробная сборка и таблица проблем |
| `TESTING.md` | Что проверено автотестами, а что тебе надо проверить руками |
| `RELEASE-CHECKLIST.md` | Что мешает публичному релизу |
| `FILES.md` | Полный список файлов |
| `../../native/glukvpn-tunnel-service/README.md` | Протокол сервиса и коды ошибок |

## Главное правило

Работаем только в `desktop/beta`. Сначала мерж в `beta`, и только после
реальной проверки на железе — думать о продакшене. PROD не трогаем.
