# GlukVPN — Правила разработки и деплоя для AI-агентов

## Обязательный регламент при получении отчёта о выполненных задачах («Готово, всё доделал» и аналогичные сценарии передачи):

1. **Изучение и верификация:**
   - Внимательно изучить, что изменилось (диффы, логика).
   - Запустить тесты:
     - 
pm test --prefix site
     - 
ode --test glukvpn-extension-1.5.0/extension/tests/
     - lutter test в lutter-client

2. **Если затронут клиентский код (Flutter / Desktop / Android):**
   - Закоммитить и запушить изменения в ветку desktop/beta (это запускает GitHub Actions workflows uild-apk и Build Desktop Client).
   - Дождаться успешного завершения сборки в GitHub Actions (gh run list).
   - Скачать собранные бинарники (glukvpn-release-X.Y.Z.apk и GlukVPN-Setup-X.Y.Z.exe) через gh run download.
   - Скопировать в локальную папку пользователя C:\Users\alish\Downloads\.
   - Скопировать в downloads/ ветки gh-pages, закоммитить и запушить (деплой на pp.gluk.tech).
   - Загрузить по SSH/SCP на сервер Oracle Node 2 (138.2.186.223, user ubuntu) в /var/www/vpn.gluk.tech/downloads/, выставить права www-data:www-data и выполнить скрипт синхронизации /var/www/vpn.gluk.tech/deploy/sync-downloads.sh (деплой на pn.gluk.tech).
   - Проверить HTTP-эндпоинты загрузки (302/200).

3. **Если затронут сайт (site/):**
   - Синхронизировать изменения в ветку gh-pages и запушить на GitHub Pages (pp.gluk.tech).
   - Задеплоить по SSH/SCP на сервер Oracle Node 2 в /var/www/vpn.gluk.tech/.

4. **Если затронут бэкенд или ноды (control-server, 
ode-agent):**
   - Задеплоить код на сервер по SSH и перезапустить соответствующие службы systemd (glukvpn-control, glukvpn-beta-control или glukvpn-node).
