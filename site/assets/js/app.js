/* ==========================================================================
   GlukVPN — личный кабинет /app/ (и /en/app/).

   Данные: window.GlukAuth (сессия и /api/auth/me), затем параллельно
     GET /api/devices        — устройства аккаунта (имя, платформа, онлайн, узел)
     GET /api/vpn/sessions   — последние 20 VPN-сессий (узел, трафик, длительность)
     GET /api/billing/plans  — включён ли биллинг, длительность тарифов (публично)
     GET /api/billing/orders — платежи пользователя (только при включённом биллинге)

   Всё написано «мягко»: поле может отсутствовать на старом сервере — тогда
   считаем на клиенте (daysLeft из expiresAt) или прячем строку, но страница
   не падает. Строки интерфейса — через GlukT (словарь в i18n.js).
   ========================================================================== */
(function () {
  "use strict";

  var CFG = window.GLUK_CONFIG || {};
  var NET = CFG.network || {};
  var PRICING = CFG.pricing || {};
  var T = window.GlukT || function (s) { return s; };
  var I18N = window.GlukI18n || null;
  var LANG = I18N ? I18N.lang : ((document.documentElement.getAttribute("data-lang") || "ru").toLowerCase());
  var EN = LANG === "en";
  var LOCALE = EN ? "en-GB" : "ru-RU";
  var root = document.documentElement.getAttribute("data-base") || "/";

  var $ = function (s, r) { return (r || document).querySelector(s); };
  var $$ = function (s, r) { return Array.prototype.slice.call((r || document).querySelectorAll(s)); };
  var esc = function (s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  };
  var set = function (key, html) {
    $$('[data-d="' + key + '"]').forEach(function (el) { el.innerHTML = html; });
  };
  var setText = function (key, text) {
    $$('[data-d="' + key + '"]').forEach(function (el) { el.textContent = text; });
  };
  var setClass = function (key, cls, on) {
    $$('[data-d="' + key + '"]').forEach(function (el) { el.classList.toggle(cls, !!on); });
  };
  var show = function (sel, on) {
    $$(sel).forEach(function (el) { el.hidden = !on; });
  };

  /* ------------------------------------------------------------------ иконки */
  var IC = {
    android: '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M17.523 15.3414c-.5511 0-.9993-.4486-.9993-.9997s.4482-.9993.9993-.9993c.5511 0 .9993.4482.9993.9993.0001.5511-.4482.9997-.9993.9997m-11.046 0c-.5511 0-.9993-.4486-.9993-.9997s.4482-.9993.9993-.9993c.5511 0 .9993.4482.9993.9993 0 .5511-.4482.9997-.9993.9997m11.4045-6.02l1.9973-3.4592a.416.416 0 00-.1521-.5676.416.416 0 00-.5676.1521l-2.0223 3.503C15.5902 8.2439 13.8533 7.8508 12 7.8508s-3.5902.3931-5.1367 1.0989L4.841 5.4467a.4161.4161 0 00-.5677-.1521.4157.4157 0 00-.1521.5676l1.9973 3.4592C2.6889 11.1867.3432 14.6589 0 18.761h24c-.3435-4.1021-2.6892-7.5743-6.1185-9.4396"/></svg>',
    windows: '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M0 3.449L9.75 2.1v9.451H0m10.949-9.602L24 0v11.4H10.949M0 12.6h9.75v9.451L0 20.699M10.949 12.6H24V24l-13.051-1.801"/></svg>',
    extension: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M9 4.5a1.5 1.5 0 0 1 3 0V6h3a1 1 0 0 1 1 1v3h1.5a1.5 1.5 0 0 1 0 3H16v3a1 1 0 0 1-1 1h-3v1.5a1.5 1.5 0 0 1-3 0V17H6a1 1 0 0 1-1-1v-3H3.5a1.5 1.5 0 0 1 0-3H5V7a1 1 0 0 1 1-1h3V4.5Z"/></svg>',
    ios: '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M12.152 6.896c-.948 0-2.415-1.078-3.96-1.04-2.04.027-3.91 1.183-4.961 3.014-2.117 3.675-.546 9.103 1.519 12.09 1.013 1.454 2.208 3.09 3.792 3.035 1.52-.065 2.09-.987 3.935-.987 1.831 0 2.35.987 3.96.948 1.637-.026 2.676-1.48 3.676-2.948 1.156-1.688 1.636-3.325 1.662-3.415-.039-.013-3.182-1.221-3.22-4.857-.026-3.04 2.48-4.494 2.597-4.559-1.429-2.09-3.623-2.324-4.39-2.376-2-.156-3.675 1.088-4.61 1.088zM15.53 3.83c.843-1.012 1.4-2.427 1.245-3.83-1.207.052-2.662.805-3.532 1.818-.78.896-1.454 2.338-1.273 3.714 1.338.104 2.715-.688 3.559-1.701"/></svg>',
    macos: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="4" y="5" width="16" height="11" rx="2"/><path d="M2.5 19h19"/></svg>',
    linux: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="4" width="18" height="12" rx="2"/><path d="M9 20h6"/><path d="M12 16v4"/></svg>',
    other: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="6" y="2.5" width="12" height="19" rx="3"/><path d="M10.5 18.6h3"/></svg>',
    node: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="4" width="18" height="7" rx="2"/><rect x="3" y="14" width="18" height="6" rx="2"/><path d="M7 7.5h.01M7 17h.01"/></svg>',
    globe: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" aria-hidden="true"><circle cx="12" cy="12" r="9"/><path d="M3.5 9.5h17M3.5 14.5h17"/><path d="M12 3c2.5 2.6 3.8 5.6 3.8 9s-1.3 6.4-3.8 9c-2.5-2.6-3.8-5.6-3.8-9S9.5 5.6 12 3Z"/></svg>',
    down: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 5v14"/><path d="m6 13 6 6 6-6"/></svg>',
    up: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 19V5"/><path d="m6 11 6-6 6 6"/></svg>'
  };

  var KIND_LABEL = {
    android: "Android", windows: "Windows", extension: "Расширение", ios: "iOS",
    macos: "macOS", linux: "Linux", other: "Устройство"
  };

  /* ------------------------------------------------------------ форматирование */
  function fmtDate(v) {
    if (!v) return "\u2014";
    var d = new Date(v);
    if (isNaN(d)) return "\u2014";
    return I18N ? I18N.dateLong(d) : d.toLocaleDateString(LOCALE, { day: "numeric", month: "long", year: "numeric" });
  }

  function fmtDateTime(v) {
    if (!v) return "\u2014";
    var d = new Date(v);
    if (isNaN(d)) return "\u2014";
    if (I18N && I18N.dateTime) return I18N.dateTime(d);
    return d.toLocaleString(LOCALE, { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });
  }

  function fmtWhen(v) {
    if (!v) return T("давно");
    var d = new Date(v);
    if (isNaN(d)) return T("давно");
    var diff = Date.now() - d.getTime();
    if (diff < 9e4) return T("только что");
    if (diff < 36e5) return Math.round(diff / 6e4) + " " + T("мин назад");
    if (diff < 864e5) return Math.round(diff / 36e5) + " " + T("ч назад");
    if (diff < 7 * 864e5) return Math.round(diff / 864e5) + " " + T("дн назад");
    return I18N ? I18N.dateShort(d) : d.toLocaleDateString(LOCALE, { day: "numeric", month: "short", year: "numeric" });
  }

  function fmtDays(n) {
    if (n == null || isNaN(n)) return "\u2014";
    return I18N ? I18N.days(n) : n + " " + T("дн.");
  }

  function fmtBytes(n) {
    n = Number(n) || 0;
    var units = [T("Б"), T("КБ"), T("МБ"), T("ГБ"), T("ТБ")];
    var i = 0;
    while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
    var v = i === 0 ? String(Math.round(n)) : (n >= 100 ? Math.round(n).toString() : n.toFixed(1));
    return v.replace(".", EN ? "." : ",") + "\u00a0" + units[i];
  }

  function fmtDur(sec) {
    sec = Math.max(0, Math.round(Number(sec) || 0));
    var h = Math.floor(sec / 3600);
    var m = Math.floor((sec % 3600) / 60);
    if (h >= 24) {
      var d = Math.floor(h / 24);
      return d + " " + T("д") + " " + (h % 24) + " " + T("ч");
    }
    if (h > 0) return h + " " + T("ч") + " " + m + " " + T("мин");
    if (m > 0) return m + " " + T("мин");
    return "< 1 " + T("мин");
  }

  function fmtMoney(minor, currency) {
    var amount = (Number(minor) || 0) / 100;
    var cur = String(currency || (PRICING.currencyCode || "KZT")).toUpperCase();
    var sym = cur === "KZT" ? "\u20b8" : cur === "RUB" ? "\u20bd" : cur === "USD" ? "$" : cur === "EUR" ? "\u20ac" : cur;
    var num;
    try {
      num = amount.toLocaleString(LOCALE, { minimumFractionDigits: amount % 1 ? 2 : 0, maximumFractionDigits: 2 });
    } catch (e) { num = String(amount); }
    return sym.length === 1 && cur !== "KZT" ? sym + num : num + "\u00a0" + sym;
  }

  function flagEmoji(cc) {
    cc = String(cc || "").toUpperCase();
    if (!/^[A-Z]{2}$/.test(cc)) return "";
    try {
      return String.fromCodePoint(0x1f1e6 + cc.charCodeAt(0) - 65, 0x1f1e6 + cc.charCodeAt(1) - 65);
    } catch (e) { return ""; }
  }

  /* Узел из config.js по коду страны/идентификатору/имени — там лежат SVG-флаги
     (эмодзи-флаги на Windows не рисуются), координаты и русские названия. */
  function cfgNode(ref) {
    if (!ref) return null;
    var nodes = NET.nodes || [];
    var cc = String(ref.countryCode || ref.country || ref.id || ref).toLowerCase();
    var name = String(ref.name || ref.city || ref).toLowerCase();
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i];
      var nid = String(n.id || "").toLowerCase();
      if (nid && (nid === cc || name.indexOf(nid) === 0)) return n;
      if (n.name && name && (String(n.name).toLowerCase() === name || String(n.city || "").toLowerCase() === name)) return n;
    }
    return null;
  }

  function flagHtml(ref) {
    var n = cfgNode(ref);
    if (n && n.flag) return n.flag;
    var em = flagEmoji(ref && (ref.countryCode || ref.country));
    return em ? '<span aria-hidden="true">' + em + "</span>" : IC.globe;
  }

  /* --------------------------------------------------------------- тариф */
  function planByCode(code) {
    code = String(code || "").toLowerCase();
    var plans = PRICING.plans || [];
    for (var i = 0; i < plans.length; i++) {
      if (String(plans[i].id || "").toLowerCase() === code) return plans[i];
    }
    return null;
  }

  var TIER_NAMES = { 0: "Free", 1: "Basic", 2: "Pro" };

  function planName(sub) {
    if (!sub) return EN ? 'No subscription' : 'Нет подписки';
    var code = String(sub.plan || sub.planCode || "").toLowerCase();
    if (code === "test") return T("Тестовый");
    var p = planByCode(code);
    if (p && p.name) return p.name;
    if (billing.plansByCode[code] && billing.plansByCode[code].name) return billing.plansByCode[code].name;
    if (sub.planName) return sub.planName;
    if (code) return code.charAt(0).toUpperCase() + code.slice(1);
    if (sub.tier != null && TIER_NAMES[sub.tier]) return TIER_NAMES[sub.tier];
    return "Free";
  }

  function planTier(sub) {
    if (!sub) return 0;
    if (typeof sub.tier === "number") return sub.tier;
    var code = String(sub.plan || "").toLowerCase();
    return code === "pro" ? 2 : code === "basic" || code === "test" ? 1 : 0;
  }

  function planDays(sub) {
    var code = String((sub && sub.plan) || "").toLowerCase();
    var p = billing.plansByCode[code];
    if (p && p.days) return p.days;
    return null;
  }

  var SUB_STATUS = {
    ACTIVE: "Активна", EXPIRED: "Истекла", INACTIVE: "Нет подписки", NONE: "Нет подписки",
    SUSPENDED: "Приостановлена", PENDING: "Ожидает оплаты", TRIAL: "Пробный период", CANCELED: "Отменена", CANCELLED: "Отменена"
  };

  function subStatusLabel(sub) {
    var s = String((sub && sub.status) || "").toUpperCase();
    if (!s) return T("Нет подписки");
    return SUB_STATUS[s] ? T(SUB_STATUS[s]) : s;
  }

  function daysLeftOf(sub) {
    if (!sub) return null;
    if (typeof sub.daysLeft === "number" && !isNaN(sub.daysLeft)) return Math.max(0, sub.daysLeft);
    if (!sub.expiresAt) return null;
    var end = new Date(sub.expiresAt);
    if (isNaN(end)) return null;
    return Math.max(0, Math.ceil((end - Date.now()) / 864e5));
  }

  /* ------------------------------------------------------------- геометрия */
  var TZ = {
    "Asia/Qyzylorda": [44.85, 65.51, "Кызылорда"],
    "Asia/Almaty": [43.24, 76.89, "Алматы"],
    "Asia/Aqtobe": [50.28, 57.17, "Актобе"],
    "Asia/Aqtau": [43.65, 51.16, "Актау"],
    "Asia/Atyrau": [47.09, 51.92, "Атырау"],
    "Asia/Oral": [51.23, 51.37, "Уральск"],
    "Asia/Tashkent": [41.31, 69.28, "Ташкент"],
    "Asia/Bishkek": [42.87, 74.59, "Бишкек"],
    "Asia/Dushanbe": [38.56, 68.79, "Душанбе"],
    "Asia/Baku": [40.41, 49.87, "Баку"],
    "Asia/Tbilisi": [41.72, 44.79, "Тбилиси"],
    "Asia/Yerevan": [40.18, 44.51, "Ереван"],
    "Europe/Moscow": [55.75, 37.62, "Москва"],
    "Europe/Kyiv": [50.45, 30.52, "Киев"],
    "Europe/Minsk": [53.9, 27.57, "Минск"],
    "Europe/Berlin": [52.52, 13.4, "Берлин"],
    "Europe/London": [51.5, -0.13, "Лондон"],
    "America/New_York": [40.71, -74.01, "Нью-Йорк"],
    "America/Los_Angeles": [34.05, -118.24, "Лос-Анджелес"]
  };

  function here() {
    var tz = "";
    try { tz = Intl.DateTimeFormat().resolvedOptions().timeZone || ""; } catch (e) {}
    if (TZ[tz]) return { lat: TZ[tz][0], lon: TZ[tz][1], name: T(TZ[tz][2]) };
    var home = NET.home || {};
    return { lat: home.lat != null ? home.lat : 44.85, lon: home.lon != null ? home.lon : 65.51, name: home.name ? T(home.name) : T("Вы") };
  }

  function liveNodes() {
    return (NET.nodes || []).filter(function (n) { return n.status !== "soon"; });
  }

  function bestNode() {
    var live = liveNodes().slice();
    live.sort(function (a, b) { return (a.ping || 999) - (b.ping || 999); });
    return live[0] || null;
  }

  /* ------------------------------------------------------------- устройства */
  function platformKind(p) {
    var s = String(p || "").toLowerCase();
    if (/android/.test(s)) return "android";
    if (/win/.test(s)) return "windows";
    if (/ext|chrome|browser|web/.test(s)) return "extension";
    if (/ios|iphone|ipad/.test(s)) return "ios";
    if (/mac|darwin/.test(s)) return "macos";
    if (/linux/.test(s)) return "linux";
    return "other";
  }

  function nodeLabel(n) {
    if (!n) return "";
    if (typeof n === "string") {
      var c = cfgNode(n);
      return c ? T(c.name) + (c.city ? " \u00b7 " + T(c.city) : "") : n;
    }
    var cfg = cfgNode(n);
    var country = n.country || (cfg ? T(cfg.name) : "");
    var name = n.name || n.id || "";
    if (country && name && String(country).toLowerCase() !== String(name).toLowerCase()) return country + " \u00b7 " + name;
    return country || name;
  }

  function normalizeDevices(raw) {
    var arr = raw && Array.isArray(raw.devices) ? raw.devices : Array.isArray(raw) ? raw : [];
    return arr.filter(Boolean).map(function (d) {
      var status = String(d.status || "").toUpperCase();
      return {
        id: d.id || d.deviceId || "",
        name: d.deviceName || d.name || T("Устройство"),
        platform: d.platform || "",
        kind: platformKind(d.platform),
        status: status,
        created: d.createdAt || null,
        last: d.lastSeen || d.lastSeenAt || d.createdAt || null,
        current: !!(d.isCurrent || d.current || (state.currentDeviceId && d.id === state.currentDeviceId)),
        online: d.connected === true,
        node: d.connectedNode || null
      };
    });
  }

  var state = { devices: [], sessions: [], orders: [], maxDevices: null, currentDeviceId: null, sessionsOk: null };
  var epoch = 0, accountKey = ''; var D = window.GlukDashboard;
  function resetAccount() {
    epoch++; inflight = false; if(D)D.history=[]; state.devices = []; state.sessions = []; state.orders = []; state.maxDevices = null; state.sessionsOk = null;
    $$('[data-d]').forEach(function(el){if(!el.querySelector('[data-d]')&&el.getAttribute('data-d')!=='sub-bar'&&!el.getAttribute('data-d').endsWith('-badge'))el.textContent='—';});
    ['[data-dash-devices]','[data-dash-sessions]','[data-dash-orders-list]'].forEach(function(sel){var el=$(sel);if(el)el.innerHTML='';});
    var conn=$('[data-dash-conn]'); if(conn)conn.hidden=true;
  }
  var billing = { enabled: null, currency: "KZT", plansByCode: {}, loaded: false };

  function renderDevices(list) {
    var ul = $("[data-dash-devices]");
    if (!ul) return;
    if (!list.length) {
      ul.innerHTML = '<li class="dash-empty">' + esc(T("Активных устройств пока нет. Запустите приложение и подключитесь — устройство появится здесь.")) + "</li>";
      return;
    }
    ul.innerHTML = list.map(function (d) {
      var meta = [T(KIND_LABEL[d.kind] || KIND_LABEL.other)];
      if (d.online && d.node) meta.push(esc(nodeLabel(d.node)));
      if (d.status && d.status !== "ACTIVE") meta.push(esc(d.status.toLowerCase()));
      meta.push(d.online ? T("сейчас в сети") : T("был в сети") + ": " + fmtWhen(d.last));
      return '<li class="dev' + (d.current ? " dev--current" : "") + '" data-dev-id="' + esc(d.id) + '">' +
        '<span class="dev__ic">' + (IC[d.kind] || IC.other) + "</span>" +
        '<span class="dev__body"><span class="dev__name"><span>' + esc(d.name) + "</span>" +
        (d.current ? '<span class="dev__tag">' + esc(T("текущее")) + "</span>" : "") + "</span>" +
        '<span class="dev__meta">' + meta.join(" \u00b7 ") + "</span></span>" +
        '<span class="dev__right"><span class="dev__state' + (d.online ? " is-on" : "") + '"><i></i>' +
        esc(d.online ? T("Подключено") : T("Не подключено")) + "</span>" +
        '<button class="dev__btn" type="button" data-dash-kick="' + esc(d.id) + '"' + (d.id ? "" : " disabled") + ">" +
        esc(T("Отключить")) + "</button></span></li>";
    }).join("");
  }

  /* ------------------------------------------------------------------ карта */
  var map = null;
  var pinData = [];

  function initMap() {
    if (D) return; // The live-map renderer is the sole owner.
    var canvas = $("[data-dash-map]");
    if (!canvas || !window.GlukNetworkMap || map) return;
    var h = here();
    var nb = bestNode();
    map = new window.GlukNetworkMap(canvas, {
      home: null,
      nodes: [],
      interactive: false,
      compact: false,
      dotSize: 1.15,
      fixedRoute: null,
      view: { x: 0, y: 1.5, w: 119, h: 57 }
    });
    canvas._glukMap = map;
    window.addEventListener("resize", function () { requestAnimationFrame(placePins); });
  }

  function pinsFor(devices) {
    if (D) return []; // Never invent locations from the browser timezone.
    var h = here();
    var out = [];
    var usedNodes = {};
    devices.slice(0, 5).forEach(function (d, i) {
      var ang = (i * 2.399) + 0.6;
      var r = i === 0 ? 0 : 3.2 + i * 1.15;
      out.push({
        lat: h.lat + Math.sin(ang) * r * 0.62,
        lon: h.lon + Math.cos(ang) * r,
        label: d.name,
        kind: d.kind,
        online: d.online,
        node: false
      });
      var cn = d.online ? cfgNode(d.node) : null;
      if (cn && !usedNodes[cn.id]) usedNodes[cn.id] = cn;
    });
    var nodeList = Object.keys(usedNodes).map(function (k) { return usedNodes[k]; });
    if (!nodeList.length) {
      var nb = bestNode();
      if (nb) nodeList.push(nb);
    }
    nodeList.forEach(function (nb) {
      out.push({ lat: nb.lat, lon: nb.lon, label: T(nb.city || nb.name) + " \u00b7 " + T("узел"), kind: "node", node: true });
    });
    return out;
  }

  function placePins() {
    if (D) return;
    var box = $("[data-dash-pins]");
    if (!box || !map || !map.px) return;
    if (!map.scale) { try { map.resize(); } catch (e) {} }
    box.innerHTML = pinData.map(function (p) {
      var x = ((p.lon + 180) / 360) * 119;
      var y = ((90 - p.lat) / 180) * 60;
      var pt = map.px(x, y);
      var l = Math.max(2, Math.min(98, (pt[0] / map.w) * 100));
      var t = Math.max(4, Math.min(96, (pt[1] / map.h) * 100));
      return '<span class="dash-pin' + (p.node ? " dash-pin--node" : "") + '" style="left:' + l.toFixed(2) + "%;top:" + t.toFixed(2) + '%">' +
        (p.node ? IC.node : (IC[p.kind] || IC.other)) +
        (p.node || !p.online ? "" : '<i class="dash-pin__dot"></i>') +
        esc(p.label) + "</span>";
    }).join("");
  }

  /* ----------------------------------------------------------------- сессии */
  function normalizeSessions(raw) {
    var arr = raw && Array.isArray(raw.sessions) ? raw.sessions : Array.isArray(raw) ? raw : [];
    return arr.filter(Boolean).map(function (s) {
      var status = String(s.status || "").toUpperCase();
      var start = s.connectedAt ? new Date(s.connectedAt) : null;
      var stop = s.disconnectedAt ? new Date(s.disconnectedAt) : null;
      var dur = typeof s.durationSec === "number" ? s.durationSec
        : (start && !isNaN(start) ? ((stop && !isNaN(stop) ? stop : new Date()) - start) / 1000 : 0);
      var live = !stop && (status === 'ACTIVE' || status === 'CONNECTED');
      return {
        id: s.id || "",
        live: live,
        status: status,
        ip: s.assignedVpnIp || "",
        start: s.connectedAt || null,
        stop: s.disconnectedAt || null,
        hs: s.lastHandshakeAt || null,
        rx: Number(s.bytesRx) || 0,
        tx: Number(s.bytesTx) || 0,
        dur: dur,
        node: s.node || null,
        deviceId: s.deviceId || ""
      };
    });
  }

  function deviceName(id) {
    for (var i = 0; i < state.devices.length; i++) {
      if (state.devices[i].id === id) return state.devices[i].name;
    }
    return "";
  }

  var SES_VISIBLE = 6;

  function renderSessions(list, failed) {
    var ul = $("[data-dash-sessions]");
    if (!ul) return;
    var more = $("[data-dash-sessions-more]");
    if (failed) {
      ul.innerHTML = '<li class="dash-empty">' + esc(T("История сессий пока недоступна.")) + "</li>";
      if (more) more.hidden = true;
      return;
    }
    if (!list.length) {
      ul.innerHTML = '<li class="dash-empty">' + esc(T("Сессий ещё не было. Подключитесь в приложении — здесь появится история.")) + "</li>";
      if (more) more.hidden = true;
      return;
    }
    ul.innerHTML = list.map(function (s, i) {
      var title = nodeLabel(s.node) || T("Узел");
      var dev = deviceName(s.deviceId);
      var meta = [];
      if (dev) meta.push(esc(dev));
      meta.push(s.live ? T("с") + " " + fmtDateTime(s.start) : fmtDateTime(s.stop || s.start));
      if (s.ip) meta.push(esc(s.ip));
      var total = s.rx + s.tx;
      return '<li class="ses' + (s.live ? " ses--live" : "") + '"' + (i >= SES_VISIBLE ? " hidden data-ses-extra" : "") + ">" +
        '<span class="ses__flag">' + flagHtml(s.node) + "</span>" +
        '<span class="ses__body"><span class="ses__title"><span>' + esc(title) + "</span>" +
        (s.live ? '<span class="ses__live"><i></i>' + esc(T("сейчас")) + "</span>" : "") + "</span>" +
        '<span class="ses__meta">' + meta.join(" \u00b7 ") + "</span></span>" +
        '<span class="ses__right"><span class="ses__traffic" title="' + esc(T("Получено")) + " " + esc(fmtBytes(s.rx)) + " \u00b7 " + esc(T("Отправлено")) + " " + esc(fmtBytes(s.tx)) + '">' +
        IC.down + esc(fmtBytes(s.rx)) + " " + IC.up + esc(fmtBytes(s.tx)) + (total ? "" : "") + "</span>" +
        '<span class="ses__dur">' + esc(fmtDur(s.dur)) + "</span></span></li>";
    }).join("");
    if (more) {
      more.hidden = list.length <= SES_VISIBLE;
      more.textContent = T("Показать все") + " (" + list.length + ")";
      more.removeAttribute("data-open");
    }
    var liveCount = list.filter(function (s) { return s.live; }).length;
    var u = (window.GlukAuth && window.GlukAuth.state.user) || {};
    set("sessions", esc(liveCount + " / " + (u.maxConcurrentSessions || 1)));
    setText("sessions-note", T("активных сейчас из лимита"));
    renderConnection(list);
  }

  /* Блок «Соединение»: раньше показывал «рекомендованный узел» и пинг из
     config.js — то есть выдуманные цифры. Теперь — живая сессия: узел,
     VPN-адрес, начало, последний handshake. Нет активной сессии — честно
     говорим, что не подключено. */
  function renderConnection(list) {
    if(D){D.history=list;if(D.liveData)D.live(D.liveData);return;} // Match details only to server-confirmed sessions.
    var card = $("[data-dash-conn]");
    if (!card) return;
    card.hidden = false;
    var live = list.filter(function (s) { return s.live; });
    var s = live[0] || null;
    var stateEl = $('[data-d="conn-state"]');
    if (stateEl) {
      stateEl.textContent = s
        ? (live.length > 1 ? T("Подключено") + " \u00b7 " + live.length : T("Подключено"))
        : T("Не подключено");
      stateEl.classList.toggle("is-ok", !!s);
    }
    show('[data-conn-row]', !!s);
    if (s) {
      setText("conn-node", nodeLabel(s.node) || "\u2014");
      setText("conn-ip", s.ip || "\u2014");
      setText("conn-since", fmtDateTime(s.start));
      setText("conn-hs", s.hs ? fmtWhen(s.hs) : "\u2014");
      setText("conn-dev", deviceName(s.deviceId) || "\u2014");
    }
    setText("conn-hint", s ? T("данные последней активной сессии") : T("подключитесь в приложении — сессия появится здесь"));
  }

  /* ---------------------------------------------------------------- платежи */
  var ORDER_STATUS = {
    PAID: ["Оплачен", "is-paid"], COMPLETED: ["Оплачен", "is-paid"], SUCCEEDED: ["Оплачен", "is-paid"],
    PENDING: ["Ожидает оплаты", "is-pending"], CREATED: ["Ожидает оплаты", "is-pending"], PROCESSING: ["Обрабатывается", "is-pending"],
    FAILED: ["Не прошёл", "is-failed"], CANCELED: ["Отменён", "is-failed"], CANCELLED: ["Отменён", "is-failed"],
    EXPIRED: ["Истёк", "is-failed"], REFUNDED: ["Возвращён", ""]
  };

  function renderOrders(list) {
    var card = $("[data-dash-orders]");
    var ul = $("[data-dash-orders-list]");
    if (!card || !ul) return;
    if (!billing.enabled || !list.length) { card.hidden = true; return; }
    card.hidden = false;
    ul.innerHTML = list.slice(0, 10).map(function (o) {
      var code = String(o.planCode || "").toLowerCase();
      var p = billing.plansByCode[code] || planByCode(code);
      var name = (p && p.name) || (code ? code.charAt(0).toUpperCase() + code.slice(1) : T("Тариф"));
      var st = ORDER_STATUS[String(o.status || "").toUpperCase()] || [o.status || "\u2014", ""];
      var meta = [fmtDateTime(o.createdAt)];
      if (o.id) meta.push("#" + String(o.id).slice(0, 8));
      return '<li class="ord">' +
        '<span class="ord__body"><span class="ord__title">' + esc(name) + (p && p.days ? " \u00b7 " + esc(fmtDays(p.days)) : "") + "</span>" +
        '<span class="ord__meta">' + esc(meta.join(" \u00b7 ")) + "</span></span>" +
        '<span class="ord__right"><span class="ord__amount">' + esc(fmtMoney(o.amountMinor, o.currency || billing.currency)) + "</span>" +
        '<span class="ord__status ' + st[1] + '">' + esc(T(st[0])) + "</span></span></li>";
    }).join("");
  }

  /* -------------------------------------------------------------- аккаунт */
  function renderAccount(st) {
    var u = st.user || {};
    var sub = st.subscription || null;
    var A = window.GlukAuth;

    state.currentDeviceId = u.currentDeviceId || st.currentDeviceId || null;

    var display = u.username || u.email || T("Аккаунт");
    set("initial", esc(String(display).trim().charAt(0).toUpperCase() || "?"));
    set("name", esc(display));
    set("email", esc(u.email || "\u2014"));
    set("public-id", esc(u.publicId || u.id || "\u2014"));

    var name = D.planLabel(sub);
    var tier = planTier(sub);
    var badge = D.planBadge(sub);
    /* Нет подписки — это и есть Free, а не «—». */
    var planText = name && name !== "\u2014" ? name : D.badgeLabel(badge);
    set("plan", esc(planText));
    set("plan2", esc(planText));
    $$('[data-d="plan-badge"]').forEach(function (el) {
      el.setAttribute("data-tier", String(tier));
      el.setAttribute("data-badge", badge);
      var glyph = D.planBadgeGlyph(badge);
      var svg = el.querySelector("svg");
      if (svg && glyph) svg.innerHTML = glyph;
    });

    var ustatus = String(u.status || "").toUpperCase();
    var ULABEL = { ACTIVE: "Активен", BLOCKED: "Заблокирован", SUSPENDED: "Приостановлен", PENDING: "Ожидает подтверждения" };
    set("status", esc(ustatus ? (ULABEL[ustatus] ? T(ULABEL[ustatus]) : ustatus) : "\u2014"));
    setClass("status-badge", "dash-badge--ok", ustatus === "ACTIVE");
    setClass("status-badge", "dash-badge--warn", !!ustatus && ustatus !== "ACTIVE");
    show('[data-d="status-badge"]', !!ustatus && ustatus!=='ACTIVE');

    set("sec-email", esc(u.email || "\u2014"));
    set("sec-verified", esc(u.emailVerified ? T("Подтверждена") : T("Не подтверждена")));
    setClass("sec-verified", "is-ok", !!u.emailVerified);
    var maxDev = state.maxDevices ?? u.maxDevices ?? '—';
    set("sec-max-dev", esc(String(maxDev)));
    set("sec-max-ses", esc(String(u.maxConcurrentSessions ?? '—')));
    var ORIGIN = { admin: "выдан админом", self: "самостоятельно", register: "самостоятельно", google: "Google", telegram: "Telegram", invite: "по приглашению" };
    var origin = u.origin;
    set('sec-origin', esc(origin && typeof origin === 'object' ? [origin.country, origin.region].filter(Boolean).join(' · ') || '—' : '—'));

    /* подписка */
    var model = D.subscription(sub, billing.plansByCode);
    var status = model.status;
    var active = model.active;
    var end = model.end !== null ? new Date(model.end) : null;
    if (end && isNaN(end)) end = null;
    var left = model.left;
    var paid = tier > 0 && (active || status === "EXPIRED" || status === "PENDING");

    set('sub-state',esc(active ? name : subStatusLabel({status:status})));
    setClass("sub-state", "is-ok", active && tier > 0);
    setClass("sub-state", "is-warn", !active || (left != null && left <= 5 && tier > 0));
    set('sub-until',esc(end ? T('до')+' '+fmtDate(end) : subStatusLabel({status:status})));
    set('sub-status', esc(subStatusLabel({status:status})));
    setClass("sub-status", "is-ok", active);
    set('sub-date', esc(end ? fmtDate(end) : '—'));
    set("sub-left", esc(left != null && end ? fmtDays(left) : "\u2014"));
    setClass("sub-left", "is-warn", left != null && end && left <= 5);
    var days = model.days;
    set('sub-hint', esc(days ? name + ' · ' + fmtDays(days) : name));

    var bar = $('[data-d="sub-bar"]');
    if (bar) {
      var pct;
      if (!end || left == null) pct = 100;
      else pct = Math.max(left > 0 ? 3 : 0, Math.min(100, (left / Math.max(1, days)) * 100));
      bar.parentElement.hidden = model.percent === null;
      bar.style.width = (model.percent ?? 0) + '%';
      bar.classList.toggle("is-low", !!end && left != null && left <= 5);
      bar.classList.toggle("is-off", !end || !active);
    }

    var cta = $("[data-dash-upgrade]");
    if (cta) {
      cta.textContent = paid && active ? T("Продлить") : tier > 0 ? T("Оплатить снова") : T("Перейти на платный тариф");
      cta.setAttribute("href", root + "pricing/");
    }
    setText('sub-note',billing.enabled===null ? (EN?'Payment options are unavailable. Refresh to retry.':'Способы оплаты не загрузились. Повторите обновление.') : billing.enabled ? T('Оплата и продление — на странице тарифов. Платёж зачисляется автоматически.') : T('Оплата и продление на время беты оформляются вручную.'));

    set("dev-count", esc((typeof st.devices === "number" ? st.devices : state.devices.length) + " / " + maxDev));
    set("dev-note", esc(T("лимит тарифа")));
    if (state.sessionsOk === null) {
      set("sessions", esc("\u2014 / " + (u.maxConcurrentSessions || 1)));
      setText("sessions-note", T("активных сейчас из лимита"));
    }
    var ch = (A && A.channel) || (CFG.api && CFG.api.channel) || "beta";
    set("channel", esc(ch === "prod" ? T("Основной") : T("Бета")));
    var host = "";
    try { host = new URL((A && A.base) || "").host; } catch (e) { host = ""; }
    setText("channel-note", host || T("активная среда"));
  }

  /* ------------------------------------------------------------------ загрузка */
  var inflight = false;

  function loadBillingMeta() {
    var A = window.GlukAuth;
    if (billing.loaded || !A || !A.public) return Promise.resolve();
    var version=epoch;
    return D.request(A,'/api/billing/plans',null,true).then(function (json) {
      if(version!==epoch)return;
      billing.loaded = true;
      billing.enabled = !!(json && json.billingEnabled);
      billing.currency = (json && json.currency) || billing.currency;
      (json && json.plans || []).forEach(function (p) {
        if (p && p.code) billing.plansByCode[String(p.code).toLowerCase()] = p;
      });
    }).catch(function () {
      if(version!==epoch)return;
      billing.loaded = false;
      billing.enabled = null;
    });
  }

  function loadDevices() {
    var A = window.GlukAuth;
    var version=epoch;
    return D.request(A,'/api/devices').then(function (json) {
      if(version!==epoch || !A.isAuthed())return;
      msg('', '');
      state.devices = normalizeDevices(json);
      if (json && typeof json.maxDevices === "number") state.maxDevices = json.maxDevices;
      renderDevices(state.devices);
      set("dev-count", esc(state.devices.length + " / " + (state.maxDevices ?? (A.state.user && A.state.user.maxDevices) ?? '—')));
      if (state.maxDevices) set("sec-max-dev", esc(String(state.maxDevices)));
      var online = state.devices.filter(function (d) { return d.online; }).length;
      setText("dev-hint", online
        ? online + " " + T("в сети сейчас")
        : T("где и к какому узлу подключены"));
      pinData = pinsFor(state.devices);
      placePins();
    }).catch(function (e) {
      if(version!==epoch || !A.isAuthed())return;
      state.devices = [];
      var ul=$('[data-dash-devices]');if(ul)ul.innerHTML='<li class="dash-empty">'+esc(EN?'Devices could not be loaded. Refresh to retry.':'Не удалось загрузить устройства. Нажмите «Обновить».')+'</li>';
      setText('dev-count','—');
      pinData = pinsFor([]);
      placePins();
      msg(human(e, T("Не удалось загрузить устройства.")), "is-err");
    });
  }

  function loadSessions() {
    var A = window.GlukAuth;
    var version=epoch;
    return D.request(A,'/api/vpn/sessions').then(function (json) {
      if(version!==epoch || !A.isAuthed())return;
      state.sessions = normalizeSessions(json);
      state.sessionsOk = true;
      renderSessions(state.sessions, false);
    }).catch(function () {
      if(version!==epoch || !A.isAuthed())return;
      state.sessions = [];
      state.sessionsOk = false;
      renderSessions([], true);
      if(D)return;
      var card = $("[data-dash-conn]");
      if (card) card.hidden = false;
      show('[data-conn-row]',false);
      setText('conn-state',EN?'Unavailable':'Нет данных'); setClass('conn-state','is-ok',false);
      setText('conn-hint',EN?'Could not load sessions. Refresh to retry.':'Сессии не загрузились. Повторите обновление.');
    });
  }

  function loadOrders() {
    var A = window.GlukAuth;
    if (!billing.enabled) { renderOrders([]); return Promise.resolve(); }
    var version=epoch;
    return D.request(A,'/api/billing/orders').then(function (json) {
      if(version!==epoch || !A.isAuthed())return;
      state.orders = (json && Array.isArray(json.orders)) ? json.orders : [];
      renderOrders(state.orders);
    }).catch(function () {
      if(version!==epoch || !A.isAuthed())return;
      renderOrders([]);
    });
  }

  function loadAll() {
    var A = window.GlukAuth;
    if (!A || !A.call || !A.isAuthed() || inflight) return;
    inflight = true;
    var btn = $("[data-dash-refresh]");
    if (btn) btn.classList.add("is-busy");
    var version = epoch;
    Promise.all([loadDevices(), loadSessions(), loadBillingMeta().then(function(){
      if(version!==epoch || !A.isAuthed())return;
      renderAccount(A.state); return loadOrders();
    })])
      .then(function () {
        /* имена устройств в сессиях зависят от списка устройств */
        if (version===epoch && state.sessionsOk) renderSessions(state.sessions, false);
      })
      .then(done, done);
    function done() {
      if (version!==epoch) return;
      inflight = false;
      if (btn) btn.classList.remove("is-busy");
    }
  }

  function human(e, fallback) {
    if (!e) return fallback;
    if (e.status === 0) return T("Нет связи с сервером. Проверьте соединение.");
    if (e.status === 401 || e.status === 403) return T("Сессия истекла — войдите заново.");
    if (e.status === 404) return fallback;
    if (e.status === 429) return T("Слишком много запросов. Попробуйте через минуту.");
    if (e.status >= 500) return T("Сервис временно недоступен. Попробуйте позже.");
    return fallback;
  }

  function msg(text, cls) {
    var el = $("[data-dash-msg]");
    if (!el) return;
    el.textContent = text || "";
    el.className = "dash-msg" + (cls ? " " + cls : "");
  }

  function kick(id, btn) {
    var A = window.GlukAuth;
    if (!A || !A.call || !id) return;
    var manage = $("[data-s2-manage]");
    if (manage) { manage.click(); return; }
    btn.disabled = true;
    msg(T("Отключаем…"), "");
    A.call("/api/devices/" + encodeURIComponent(id), { method: "DELETE" })
      .then(function () {
        msg(T("Устройство отключено."), "is-ok");
        if (A.refresh) A.refresh();
        loadAll();
      })
      .catch(function (e) {
        btn.disabled = false;
        msg(human(e, T("Не удалось отключить устройство.")), "is-err");
      });
  }

  function refresh() {
    var A = window.GlukAuth;
    if (!A) return;
    msg("", "");
    if (A.refresh) A.refresh();
    loadAll();
  }

  /* -------------------------------------------------------------- отрисовка */
  function view(name) {
    $$("[data-dash-view]").forEach(function (el) {
      el.hidden = el.getAttribute("data-dash-view") !== name;
    });
  }

  var wasIn = false;

  function apply() {
    var A = window.GlukAuth;
    var st = (A && A.state) || { status: "loading" };
    if (st.status === "loading") { view("loading"); return; }
    if (st.status !== "in") {
      view('guest');
      if(wasIn || accountKey)resetAccount();
      accountKey=''; wasIn = false;
      return;
    }
    var key = String(A.base||'') + ':' + String(st.user && st.user.id || '');
    if(key!==accountKey){resetAccount();accountKey=key;wasIn=false;billing.loaded=false;billing.plansByCode={};}
    view('in');
    renderAccount(st);
    initMap();
    if (!wasIn) {
      wasIn = true;
      pinData = pinsFor([]);
      placePins();
      loadAll();
    }
  }

  function bind() {
    document.addEventListener("click", function (e) {
      var t = e.target;
      if (!t || !t.closest) return;
      var kickBtn = t.closest("[data-dash-kick]");
      if (kickBtn) { kick(kickBtn.getAttribute("data-dash-kick"), kickBtn); return; }
      var out = t.closest("[data-dash-logout]");
      if (out) {
        e.preventDefault();
        if (window.GlukAuth && window.GlukAuth.logout) window.GlukAuth.logout();
        window.setTimeout(function () { window.location.href = root; }, 350);
        return;
      }
      var rf = t.closest("[data-dash-refresh]");
      if (rf) { refresh(); return; }
      var more = t.closest("[data-dash-sessions-more]");
      if (more) {
        var open = more.hasAttribute("data-open");
        $$("[data-ses-extra]").forEach(function (li) { li.hidden = open; });
        if (open) { more.removeAttribute("data-open"); more.textContent = T("Показать все") + " (" + state.sessions.length + ")"; }
        else { more.setAttribute("data-open", "1"); more.textContent = T("Свернуть"); }
      }
    });
    document.addEventListener('gluk:auth', apply);
    document.addEventListener('gluk:devices-changed', refresh);

    /* Мягкое автообновление: раз в 45 с, только на видимой вкладке и только
       когда человек вошёл. Ничего не мигает — списки перерисовываются на месте. */
    window.setInterval(function () {
      if (document.visibilityState !== "visible") return;
      var A = window.GlukAuth;
      if (!A || !A.isAuthed || !A.isAuthed()) return;
      loadAll();
    }, 45000);
  }

  function init() {
    if (!$("[data-dash-view]")) return;
    bind();
    apply();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
