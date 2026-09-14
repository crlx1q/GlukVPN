GlukVPN — шрифты

Сайт использует Poppins (500/600/700) — тот же шрифт, что и в мокапах приложения.
В этой сборке файлы шрифтов НЕ включены (не было доступа к сети), поэтому
assets/css/fonts.css объявляет @font-face с цепочкой:

  1) local("Poppins ...")  — если шрифт установлен в системе;
  2) url("../fonts/Poppins-*.woff2") — если положить файлы сюда;
  3) системный fallback (Inter / SF / Segoe / Roboto) — если ничего нет.

Чтобы включить self-hosted Poppins, положите в эту папку три файла:

  Poppins-Medium.woff2    (500)
  Poppins-SemiBold.woff2  (600)
  Poppins-Bold.woff2      (700)

Источник: https://fonts.google.com/specimen/Poppins (SIL Open Font License 1.1).
Больше ничего менять не нужно — fonts.css подхватит файлы автоматически.
