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
    "Нет": "None",

    /* v6: личный кабинет и рантайм-строки */
    "Аккаунт": "Account",
    "Активен": "Active",
    "Активна": "Active",
    "Активных устройств пока нет. Запустите приложение и подключитесь — устройство появится здесь.": "No active devices yet. Open the app and connect — the device will show up here.",
    "Браузер": "Browser",
    "Вы": "You",
    "Компьютер": "Desktop",
    "Ноутбук": "Laptop",
    "Планшет": "Tablet",
    "Смартфон": "Phone",
    "Телевизор": "TV",
    "Роутер": "Router",
    "Устройство": "Device",
    "Не подтверждена": "Not verified",
    "Подтверждена": "Verified",
    "Не удалось отключить устройство. На бета-канале это можно сделать в приложении.": "Could not disconnect the device. On the beta channel you can do it in the app.",
    "Нет подписки": "No subscription",
    "Онлайн": "Online",
    "Офлайн": "Offline",
    "Отключаем…": "Disconnecting…",
    "Отключить": "Disconnect",
    "Устройство отключено.": "Device disconnected.",
    "Список устройств ограничен на бета-канале: показано текущее устройство и количество активных сессий.": "The device list is limited on the beta channel: it shows the current device and the number of active sessions.",
    "активность": "activity",
    "без карты и автосписаний": "no card, no auto-charges",
    "бесплатный тариф": "free plan",
    "выдан админом": "issued by admin",
    "давно": "a while ago",
    "дата указана с годом": "date includes the year",
    "дн.": "days",
    "до": "until",
    "лимит тарифа": "plan limit",
    "мин назад": "min ago",
    "ч назад": "h ago",
    "только что": "just now",
    "текущее": "current",
    "узел": "node",
    "мс": "ms",
    "Москва": "Moscow",
    "Санкт-Петербург": "Saint Petersburg",
    "Алматы": "Almaty",
    "Астана": "Astana",
    "Актау": "Aktau",
    "Актобе": "Aktobe",
    "Атырау": "Atyrau",
    "Кызылорда": "Kyzylorda",
    "Уральск": "Oral",
    "Ташкент": "Tashkent",
    "Бишкек": "Bishkek",
    "Душанбе": "Dushanbe",
    "Баку": "Baku",
    "Тбилиси": "Tbilisi",
    "Ереван": "Yerevan",
    "Минск": "Minsk",
    "Киев": "Kyiv",
    "Берлин": "Berlin",
    "Лондон": "London",
    "Лос-Анджелес": "Los Angeles",
    "Нью-Йорк": "New York",
    "Карта подключений": "Connection map",
    "Сеть онлайн": "Network online"
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

  /* регион по часовому поясу: СНГ -> ru, всё остальное -> en */
  var CIS_TZ = /^(Europe\/(Moscow|Minsk|Kyiv|Kiev|Kaliningrad|Samara|Volgograd|Saratov|Astrakhan|Ulyanovsk|Kirov|Chisinau|Simferopol|Uzhgorod|Zaporozhye|Tiraspol)|Asia\/(Almaty|Aqtau|Aqtobe|Atyrau|Oral|Qostanay|Qyzylorda|Tashkent|Samarkand|Bishkek|Dushanbe|Ashgabat|Baku|Yerevan|Tbilisi|Yekaterinburg|Omsk|Novosibirsk|Barnaul|Tomsk|Novokuznetsk|Krasnoyarsk|Irkutsk|Chita|Yakutsk|Khandyga|Ust-Nera|Vladivostok|Magadan|Sakhalin|Srednekolymsk|Kamchatka|Anadyr))$/;

  function tzIsCis() {
    try {
      var tz = Intl.DateTimeFormat().resolvedOptions().timeZone || "";
      return CIS_TZ.test(tz);
    } catch (e) {
      return false;
    }
  }

  function guess() {
    if (tzIsCis()) return "ru";
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

/* ===== v7.1 en-sweep ===== */
/* Часть строк рисует JS с зашитым русским текстом, поэтому на английских
   страницах просачивался русский. Сводим такие строки после рендера. */
(function () {
  "use strict";
  var html = document.documentElement;
  var lang = (html.getAttribute("data-lang") || html.lang || "ru").toLowerCase();
  if (lang !== "en") return;

  var DICT = {
    "Регистрация": "Sign up",
    "Войти": "Sign in",
    "Выйти": "Sign out",
    "Аккаунт": "Account",
    "Личный кабинет": "Dashboard",
    "Вход в аккаунт": "Sign in",
    "Создание аккаунта": "Create account",
    "Те же логин и пароль, что и в приложении GlukVPN.":
      "The same login and password as in the GlukVPN app.",
    "Карта подключений": "Connection map",
    "Сеть онлайн": "Network online",
    "региона онлайн": "regions online",
    "регионов онлайн": "regions online",
    "лучший latency": "best latency",
    "доступность": "availability",
    "Германия": "Germany",
    "Франция": "France",
    "США": "USA",
    "Нидерланды": "Netherlands",
    "Турция": "Turkey",
    "Сингапур": "Singapore",
    "Япония": "Japan",
    "Вы": "You",
    "Показать пароль": "Show password",
    "Скрыть пароль": "Hide password",
    "Скачать приложение": "Get the app",
    "Веб-приложение": "Web app",
    "Загрузка аккаунта": "Loading account",
    "Маршрут": "Route",
    "бессрочно": "no expiry",
    "Сегодня": "Today",
    "Вчера": "Yesterday"
  };
  var UNITS = [
    [/(\d)\s*мс\b/g, "$1 ms"],
    [/Мбит\/с/g, "Mbps"],
    [/Гбит\/с/g, "Gbps"],
    [/\bдн\./g, "d"]
  ];
  var CYR = /[А-Яа-яЁё]/;

  function fix(s) {
    var key = s.trim();
    if (DICT[key]) return s.replace(key, DICT[key]);
    var out = s;
    for (var i = 0; i < UNITS.length; i++) out = out.replace(UNITS[i][0], UNITS[i][1]);
    return out;
  }

  function sweep() {
    var body = document.body;
    if (!body) return;
    var walker = document.createTreeWalker(body, NodeFilter.SHOW_TEXT, null);
    var nodes = [];
    while (walker.nextNode()) nodes.push(walker.currentNode);
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i];
      var v = n.nodeValue;
      if (!v || !CYR.test(v)) continue;
      var p = n.parentNode;
      if (p && (p.tagName === "SCRIPT" || p.tagName === "STYLE")) continue;
      var next = fix(v);
      if (next !== v) n.nodeValue = next;
    }
    var els = body.querySelectorAll("[title],[aria-label],[placeholder]");
    var attrs = ["title", "aria-label", "placeholder"];
    for (var j = 0; j < els.length; j++) {
      for (var k = 0; k < attrs.length; k++) {
        var av = els[j].getAttribute(attrs[k]);
        if (av && CYR.test(av)) {
          var na = fix(av);
          if (na !== av) els[j].setAttribute(attrs[k], na);
        }
      }
    }
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", sweep);
  else sweep();

  if (window.MutationObserver) {
    var queued = false;
    new MutationObserver(function () {
      if (queued) return;
      queued = true;
      (window.requestAnimationFrame || setTimeout)(function () {
        queued = false;
        sweep();
      });
    }).observe(html, { childList: true, subtree: true, characterData: true });
  }
})();


/* ===== v7.2 langpop ===== */
/* пилюля языка в подвале */
(function () {
  "use strict";
  function closeAll(except) {
    var list = document.querySelectorAll(".langpop.is-open");
    for (var i = 0; i < list.length; i++) {
      if (list[i] === except) continue;
      list[i].classList.remove("is-open");
      var b = list[i].querySelector(".langpop__btn");
      if (b) b.setAttribute("aria-expanded", "false");
    }
  }
  document.addEventListener("click", function (e) {
    var t = e.target;
    if (!t || !t.closest) return;
    var btn = t.closest(".langpop__btn");
    if (btn) {
      var pop = btn.closest(".langpop");
      e.preventDefault();
      closeAll(pop);
      var on = pop.classList.toggle("is-open");
      btn.setAttribute("aria-expanded", on ? "true" : "false");
      return;
    }
    if (!t.closest(".langpop")) closeAll(null);
  });
  document.addEventListener("keydown", function (e) {
    if (e.key === "Escape" || e.keyCode === 27) closeAll(null);
  });
})();

