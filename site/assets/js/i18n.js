/* GlukVPN — родная локализация (ru/en).
   Статические тексты живут в самом HTML (две сборки: / и /en/),
   а здесь только строки, которые рисует JS, плюс автовыбор языка. */
(function () {
  "use strict";

  var html = document.documentElement;
  var LANG = (html.getAttribute("data-lang") || html.lang || "ru").toLowerCase();
  if (LANG !== "en") LANG = "ru";
  var KEY = "gluk.lang";

  /* ---------------------------------------------------- словарь для JS-строк */
  var EN = {
    "Загрузка аккаунта": "Loading account",
    "Аккаунт": "Account",
    "Войти": "Sign in",
    "Выйти": "Sign out",
    "Регистрация": "Sign up",
    "Личный кабинет": "Dashboard",
    "Веб-приложение": "Web app",
    "Скачать приложение": "Get the app",
    "Подписка": "Subscription",
    "Устройства": "Devices",
    "Номер аккаунта": "Account number",
    "Активна": "Active",
    "Нет подписки": "No subscription",
    "Истекла": "Expired",
    "Приостановлена": "Paused",
    "бессрочно": "no expiry",
    "до": "until",
    "Показать пароль": "Show password",
    "Скрыть пароль": "Hide password",
    "Вход в аккаунт": "Sign in",
    "Создание аккаунта": "Create account",
    "Те же логин и пароль, что и в приложении GlukVPN.":
      "The same login and password as in the GlukVPN app.",
    "На время беты доступ выдаётся вручную — напишите нам, это быстро.":
      "During the beta access is granted manually — message us, it is quick.",
    "Неверный логин или пароль": "Wrong login or password",
    "Слишком много попыток, подождите минуту": "Too many attempts, wait a minute",
    "Сервис недоступен, попробуйте позже": "Service unavailable, try again later",
    "Не удалось связаться с сервером": "Could not reach the server",
    "Входим…": "Signing in\u2026",
    "Готово": "Done",
    "Сегодня": "Today",
    "Вчера": "Yesterday",
    "телефон": "phone",
    "планшет": "tablet",
    "компьютер": "desktop",
    "ноутбук": "laptop",
    "браузер": "browser",
    "устройство": "device",
    "Текущее": "Current",
    "Онлайн": "Online",
    "Офлайн": "Offline",
    "Отключить": "Disconnect",
    "Отключаем…": "Disconnecting\u2026",
    "Устройство отключено": "Device disconnected",
    "Не удалось отключить устройство": "Could not disconnect the device",
    "Нет активных устройств": "No active devices",
    "Список устройств недоступен": "Device list unavailable",
    "Обновляем…": "Refreshing\u2026",
    "Обновить": "Refresh",
    "дн.": "d",
    "из": "of",
    "Не указан": "Not set",
    "не указан": "not set",
    "Бесплатный": "Free",
    "Бета-канал": "Beta channel",
    "Продакшен": "Production",
    "Вы уже вошли": "You are signed in",
    "Открываем личный кабинет: устройства, карта подключений, подписка и оплата.":
      "Opening your dashboard: devices, connection map, subscription and billing.",
    "Действует до": "Valid until",
    "Открыть кабинет": "Open dashboard",
    "Нет": "None"
  };

  function T(s) {
    if (LANG === "ru") return s;
    return Object.prototype.hasOwnProperty.call(EN, s) ? EN[s] : s;
  }

  /* ------------------------------------------------------------ даты, числа */
  var LOCALE = LANG === "en" ? "en-GB" : "ru-RU";

  function dateLong(v) {
    if (!v) return "";
    var d = new Date(v);
    if (isNaN(d.getTime())) return "";
    return d.toLocaleDateString(LOCALE, { day: "numeric", month: "long", year: "numeric" });
  }

  function dateShort(v) {
    if (!v) return "";
    var d = new Date(v);
    if (isNaN(d.getTime())) return "";
    return d.toLocaleDateString(LOCALE, { day: "numeric", month: "short", year: "numeric" });
  }

  function dateTime(v) {
    if (!v) return "";
    var d = new Date(v);
    if (isNaN(d.getTime())) return "";
    var today = new Date();
    var sameDay =
      d.getDate() === today.getDate() &&
      d.getMonth() === today.getMonth() &&
      d.getFullYear() === today.getFullYear();
    var time = d.toLocaleTimeString(LOCALE, { hour: "2-digit", minute: "2-digit" });
    if (sameDay) return T("Сегодня") + ", " + time;
    return dateShort(v) + ", " + time;
  }

  /* дни: 5 дней / 5 days с русскими формами */
  function days(n) {
    n = Math.abs(Math.round(n));
    if (LANG === "en") return n + (n === 1 ? " day" : " days");
    var t10 = n % 10, t100 = n % 100;
    if (t10 === 1 && t100 !== 11) return n + " день";
    if (t10 >= 2 && t10 <= 4 && (t100 < 10 || t100 >= 20)) return n + " дня";
    return n + " дней";
  }

  /* ------------------------------------------------- автоопределение языка */
  var CIS = [
    "ru", "be", "uk", "kk", "ky", "uz", "tg", "tk", "hy", "az", "ka", "mo", "ro-md", "ab", "os"
  ];

  function guess() {
    var list = navigator.languages && navigator.languages.length
      ? navigator.languages
      : [navigator.language || "en"];
    for (var i = 0; i < list.length; i++) {
      var tag = String(list[i] || "").toLowerCase();
      var primary = tag.split("-")[0];
      var region = (tag.split("-")[1] || "").toLowerCase();
      if (CIS.indexOf(primary) > -1 || CIS.indexOf(tag) > -1) return "ru";
      if (
        ["ru", "by", "kz", "kg", "uz", "tj", "tm", "am", "az", "ge", "md", "ua"].indexOf(region) > -1
      ) {
        return "ru";
      }
      if (primary) return "en";
    }
    return "en";
  }

  function stored() {
    try { return localStorage.getItem(KEY); } catch (e) { return null; }
  }

  function remember(lang) {
    try { localStorage.setItem(KEY, lang); } catch (e) {}
  }

  function pathFor(lang, path) {
    var clean = path.replace(/^\/en(\/|$)/, "/");
    if (clean.charAt(0) !== "/") clean = "/" + clean;
    if (lang === "en") return "/en" + (clean === "/" ? "/" : clean);
    return clean;
  }

  /* ?lang=ru|en — жёсткий выбор, запоминается */
  var forced = (location.search.match(/[?&]lang=(ru|en)/i) || [])[1];
  if (forced) {
    forced = forced.toLowerCase();
    remember(forced);
    if (forced !== LANG) {
      location.replace(pathFor(forced, location.pathname) + location.hash);
      return;
    }
  } else {
    var choice = stored();
    if (!choice) {
      choice = guess();
      remember(choice);
      /* автоперевод только один раз и только если язык отличается */
      if (choice !== LANG) {
        location.replace(pathFor(choice, location.pathname) + location.search + location.hash);
        return;
      }
    }
  }

  /* клик по переключателю — запоминаем выбор */
  document.addEventListener("click", function (e) {
    var a = e.target.closest && e.target.closest("[data-lang-set]");
    if (a) remember(a.getAttribute("data-lang-set"));
  });

  /* подменяем href переключателя на текущий маршрут (для 404 и прочего) */
  document.addEventListener("DOMContentLoaded", function () {
    var opts = document.querySelectorAll("[data-lang-set]");
    for (var i = 0; i < opts.length; i++) {
      var lang = opts[i].getAttribute("data-lang-set");
      opts[i].setAttribute("href", pathFor(lang, location.pathname) + "?lang=" + lang);
    }
  });

  window.GlukI18n = {
    lang: LANG,
    locale: LOCALE,
    t: T,
    dateLong: dateLong,
    dateShort: dateShort,
    dateTime: dateTime,
    days: days,
    pathFor: pathFor
  };
  window.GlukT = T;
})();
