/* GlukVPN — личный кабинет /app/: аккаунт, подписка, устройства, карта. */
(function () {
  "use strict";

  var CFG = window.GLUK_CONFIG || {};
  var NET = CFG.network || {};
  var T = window.GlukT || function (s) { return s; };
  var I18N = window.GlukI18n || null;
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

  var IC = {
    phone: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><rect x="6" y="2.5" width="12" height="19" rx="3"/><path d="M10.5 18.6h3"/></svg>',
    tablet: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="2.5" width="16" height="19" rx="2.6"/><path d="M11 18.6h2"/></svg>',
    laptop: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="5" width="16" height="11" rx="2"/><path d="M2.5 19h19"/></svg>',
    desktop: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="18" height="12" rx="2"/><path d="M9 20h6"/><path d="M12 16v4"/></svg>',
    tv: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><rect x="2.5" y="6" width="19" height="12.5" rx="2.4"/><path d="M8.5 3.2 12 6l3.5-2.8"/></svg>',
    router: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="13" width="18" height="7" rx="2.2"/><path d="M7 16.5h.01M10.5 16.5h.01"/><path d="M12 10V4"/><path d="M8.5 6.5 12 3l3.5 3.5"/></svg>',
    browser: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="18" height="16" rx="2.4"/><path d="M3 9h18"/><path d="M7 6.5h.01M9.6 6.5h.01"/></svg>',
    node: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="18" height="7" rx="2"/><rect x="3" y="14" width="18" height="6" rx="2"/><path d="M7 7.5h.01M7 17h.01"/></svg>'
  };

  /* Приблизительная геометрия по часовому поясу браузера — геолокацию мы не запрашиваем. */
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
    if (TZ[tz]) return { lat: TZ[tz][0], lon: TZ[tz][1], name: TZ[tz][2] };
    var home = NET.home || {};
    return { lat: home.lat != null ? home.lat : 44.85, lon: home.lon != null ? home.lon : 65.51, name: home.name || T("Вы") };
  }

  function bestNode() {
    var live = (NET.nodes || []).filter(function (n) { return n.status !== "soon"; });
    live.sort(function (a, b) { return (a.ping || 999) - (b.ping || 999); });
    return live[0] || null;
  }

  /* ------------------------------------------------------------- устройства */
  function kind(d) {
    var s = (
      (d.type || "") + " " + (d.platform || "") + " " + (d.os || "") + " " + (d.name || "") + " " + (d.model || "")
    ).toLowerCase();
    if (/ipad|tablet|tab\b/.test(s)) return "tablet";
    if (/iphone|android|phone|pixel|galaxy|xiaomi|redmi|samsung|mobile/.test(s)) return "phone";
    if (/macbook|laptop|notebook|thinkpad|vivobook/.test(s)) return "laptop";
    if (/tv|shield|firestick|appletv/.test(s)) return "tv";
    if (/router|openwrt|keenetic|mikrotik/.test(s)) return "router";
    if (/chrome|firefox|safari|edge|browser|web/.test(s)) return "browser";
    if (/windows|linux|desktop|pc|mac/.test(s)) return "desktop";
    return "phone";
  }

  var KIND_LABEL = {
    phone: "Смартфон", tablet: "Планшет", laptop: "Ноутбук", desktop: "Компьютер",
    tv: "Телевизор", router: "Роутер", browser: "Браузер"
  };

  function localKind() {
    var ua = navigator.userAgent || "";
    if (/iPad|Tablet/i.test(ua)) return "tablet";
    if (/Android|iPhone|Mobile/i.test(ua)) return "phone";
    if (/Macintosh/i.test(ua)) return "laptop";
    return "desktop";
  }

  function localName() {
    var ua = navigator.userAgent || "";
    var os = /Windows/i.test(ua) ? "Windows" : /Android/i.test(ua) ? "Android"
      : /iPhone|iPad|iOS/i.test(ua) ? "iOS" : /Macintosh/i.test(ua) ? "macOS"
      : /Linux/i.test(ua) ? "Linux" : T("Браузер");
    var br = /Edg\//i.test(ua) ? "Edge" : /OPR\//i.test(ua) ? "Opera" : /Firefox/i.test(ua) ? "Firefox"
      : /Chrome/i.test(ua) ? "Chrome" : /Safari/i.test(ua) ? "Safari" : "";
    return os + (br ? " \u00b7 " + br : "");
  }

  function normalize(raw) {
    var list = [];
    if (!raw) return list;
    var arr = Array.isArray(raw) ? raw : (raw.devices || raw.items || raw.results || []);
    if (!Array.isArray(arr)) return list;
    arr.forEach(function (d) {
      if (!d || typeof d !== "object") return;
      list.push({
        id: d.id || d.deviceId || d.publicId || "",
        name: d.name || d.deviceName || d.label || d.model || T("Устройство"),
        platform: d.platform || d.os || d.type || "",
        kind: kind(d),
        last: d.lastSeenAt || d.lastSeen || d.updatedAt || d.connectedAt || d.createdAt || null,
        current: !!(d.isCurrent || d.current),
        online: String(d.status || d.state || "").toLowerCase() === "active" ||
                String(d.status || d.state || "").toLowerCase() === "online" ||
                !!d.isConnected || !!d.online,
        node: d.nodeName || d.node || d.nodeId || "",
        ip: d.ip || d.publicIp || d.address || ""
      });
    });
    return list;
  }

  function fallbackDevices(state) {
    var n = Math.max(1, state.devices || 1);
    var out = [{
      id: "local", name: localName(), platform: "", kind: localKind(),
      last: new Date().toISOString(), current: true, online: true, node: "", ip: "", local: true
    }];
    for (var i = 1; i < n; i++) {
      out.push({
        id: "", name: T("Устройство") + " " + (i + 1), platform: "", kind: i === 1 ? "phone" : "desktop",
        last: null, current: false, online: true, node: "", ip: "", local: true
      });
    }
    return out;
  }

  /* ------------------------------------------------------------------- карта */
  var map = null;
  var pinData = [];

  function initMap() {
    var canvas = $("[data-dash-map]");
    if (!canvas || !window.GlukNetworkMap || map) return;
    var h = here();
    var live = (NET.nodes || []).filter(function (n) { return n.status !== "soon"; });
    var nb = bestNode();
    map = new window.GlukNetworkMap(canvas, {
      home: { lat: h.lat, lon: h.lon, name: h.name },
      nodes: live,
      interactive: false,
      compact: false,
      dotSize: 1.15,
      fixedRoute: nb ? nb.id : null,
      view: { x: 0, y: 1.5, w: 119, h: 57 }
    });
    window.addEventListener("resize", function () { requestAnimationFrame(placePins); });
  }

  function pinsFor(devices) {
    var h = here();
    var nb = bestNode();
    var out = [];
    devices.slice(0, 5).forEach(function (d, i) {
      var ang = (i * 2.399) + 0.6;
      var r = i === 0 ? 0 : 3.2 + i * 1.15;
      out.push({
        lat: h.lat + Math.sin(ang) * r * 0.62,
        lon: h.lon + Math.cos(ang) * r,
        label: d.name,
        kind: d.kind,
        node: false
      });
    });
    if (nb) out.push({ lat: nb.lat, lon: nb.lon, label: (nb.city || nb.name) + " \u00b7 " + T("узел"), kind: "node", node: true });
    return out;
  }

  function placePins() {
    var box = $("[data-dash-pins]");
    if (!box || !map || !map.px) return;
    if (!map.scale) { try { map.resize(); } catch (e) {} }
    var html = pinData.map(function (p) {
      var x = ((p.lon + 180) / 360) * 119;
      var y = ((90 - p.lat) / 180) * 60;
      var pt = map.px(x, y);
      var l = Math.max(2, Math.min(98, (pt[0] / map.w) * 100));
      var t = Math.max(4, Math.min(96, (pt[1] / map.h) * 100));
      return '<span class="dash-pin' + (p.node ? " dash-pin--node" : "") + '" style="left:' + l.toFixed(2) + "%;top:" + t.toFixed(2) + '%">' +
        (p.node ? IC.node : (IC[p.kind] || IC.phone)) +
        (p.node ? "" : '<i class="dash-pin__dot"></i>') +
        esc(p.label) + "</span>";
    }).join("");
    box.innerHTML = html;
  }

  /* -------------------------------------------------------------- отрисовка */
  function view(name) {
    $$("[data-dash-view]").forEach(function (el) {
      el.hidden = el.getAttribute("data-dash-view") !== name;
    });
  }

  function msg(text, cls) {
    var el = $("[data-dash-msg]");
    if (!el) return;
    el.textContent = text || "";
    el.className = "dash-msg" + (cls ? " " + cls : "");
  }

  function fmtDate(v) {
    if (!v) return "\u2014";
    var d = new Date(v);
    if (isNaN(d)) return "\u2014";
    return I18N ? I18N.dateLong(d) : d.toLocaleDateString("ru-RU", { day: "numeric", month: "long", year: "numeric" });
  }

  function fmtWhen(v) {
    if (!v) return T("давно");
    var d = new Date(v);
    if (isNaN(d)) return T("давно");
    var diff = Date.now() - d.getTime();
    if (diff < 12e4) return T("только что");
    if (diff < 36e5) return Math.round(diff / 6e4) + " " + T("мин назад");
    if (diff < 864e5) return Math.round(diff / 36e5) + " " + T("ч назад");
    return I18N ? I18N.dateShort(d) : d.toLocaleDateString("ru-RU", { day: "numeric", month: "short", year: "numeric" });
  }

  function planName(sub) {
    if (!sub) return T("Free");
    return sub.planName || sub.plan || (sub.tier ? String(sub.tier) : T("Free"));
  }

  function renderDevices(devices, limited) {
    var ul = $("[data-dash-devices]");
    if (!ul) return;
    if (!devices.length) {
      ul.innerHTML = '<li class="dash-empty">' + T("Активных устройств пока нет. Запустите приложение и подключитесь — устройство появится здесь.") + "</li>";
      return;
    }
    ul.innerHTML = devices.map(function (d) {
      var meta = [KIND_LABEL[d.kind] ? T(KIND_LABEL[d.kind]) : d.kind];
      if (d.platform) meta.push(esc(d.platform));
      if (d.node) meta.push(esc(d.node));
      meta.push(T("активность") + ": " + fmtWhen(d.last));
      return '<li class="dev' + (d.current ? " dev--current" : "") + '">' +
        '<span class="dev__ic">' + (IC[d.kind] || IC.phone) + "</span>" +
        '<span class="dev__body"><span class="dev__name">' + esc(d.name) +
        (d.current ? '<span class="dev__tag">' + T("текущее") + "</span>" : "") + "</span>" +
        '<span class="dev__meta">' + meta.join(" \u00b7 ") + "</span></span>" +
        '<span class="dev__right"><span class="dev__state' + (d.online ? " is-on" : "") + '"><i></i>' +
        (d.online ? T("Онлайн") : T("Офлайн")) + "</span>" +
        '<button class="dev__btn" type="button" data-dash-kick="' + esc(d.id) + '"' +
        (d.id && !limited ? "" : " disabled") + ">" + T("Отключить") + "</button></span></li>";
    }).join("");
  }

  function renderAccount(st) {
    var u = st.user || {};
    var sub = st.subscription || null;
    var nb = bestNode();

    set("initial", esc((u.username || u.email || "?").trim().charAt(0).toUpperCase() || "?"));
    set("name", esc(u.username || u.email || T("Аккаунт")));
    set("email", esc(u.email || "\u2014"));
    set("plan", esc(planName(sub)));
    set("plan2", esc(planName(sub)));
    set("public-id", esc(u.publicId || u.id || "\u2014"));
    set("status", esc(u.status ? T(String(u.status).toUpperCase() === "ACTIVE" ? "Активен" : String(u.status)) : "\u2014"));
    set("sec-email", esc(u.email || "\u2014"));
    set("sec-verified", u.emailVerified ? T("Подтверждена") : T("Не подтверждена"));
    set("sec-max-dev", esc(String(u.maxDevices || 3)));
    set("sec-max-ses", esc(String(u.maxConcurrentSessions || 1)));
    set("sec-origin", esc(u.origin === "admin" ? T("выдан админом") : u.origin || "\u2014"));

    var badge = $('[data-d="status-badge"]');
    if (badge) {
      badge.classList.toggle("dash-badge--ok", String(u.status || "").toUpperCase() === "ACTIVE");
    }

    var active = sub && String(sub.status || "").toUpperCase() === "ACTIVE";
    var end = sub && sub.expiresAt ? new Date(sub.expiresAt) : null;
    var left = end && !isNaN(end) ? Math.max(0, Math.ceil((end - Date.now()) / 864e5)) : null;

    set("sub-state", active ? T("Активна") : T("Нет подписки"));
    set("sub-until", active && end ? T("до") + " " + fmtDate(end) : T("бесплатный тариф"));
    set("sub-status", active ? T("Активна") : T("Нет подписки"));
    set("sub-date", active && end ? fmtDate(end) : "\u2014");
    set("sub-left", left != null ? (I18N ? I18N.days(left) : left + " " + T("дн.")) : "\u2014");
    set("sub-hint", active ? T("дата указана с годом") : T("без карты и автосписаний"));

    var bar = $('[data-d="sub-bar"]');
    if (bar) {
      var pct = left == null ? 0 : Math.max(4, Math.min(100, (left / 30) * 100));
      bar.style.width = pct + "%";
      bar.classList.toggle("is-low", left != null && left <= 5);
    }

    set("dev-count", esc((st.devices || 0) + " / " + (u.maxDevices || 3)));
    set("dev-note", T("лимит тарифа"));
    set("sessions", esc(String(u.maxConcurrentSessions || 1)));
    set("channel", esc(String((CFG.api && CFG.api.channel) || "beta").toUpperCase()));
    set("node", nb ? esc((nb.city || "") + " \u00b7 " + nb.name) : "\u2014");
    set("node-ping", nb ? "~" + nb.ping + " " + T("мс") : "\u2014");
    set("node-load", nb && nb.load != null ? nb.load + " %" : "\u2014");
  }

  /* ------------------------------------------------------------------ загрузка */
  var loading = false;

  function loadDevices(state) {
    var A = window.GlukAuth;
    if (!A || !A.call) { renderDevices(fallbackDevices(state), true); return; }
    A.call("/api/devices")
      .then(function (json) {
        var list = normalize(json);
        if (!list.length) list = fallbackDevices(state);
        renderDevices(list, false);
        pinData = pinsFor(list);
        placePins();
      })
      .catch(function () {
        var list = fallbackDevices(state);
        renderDevices(list, true);
        pinData = pinsFor(list);
        placePins();
        msg(T("Список устройств ограничен на бета-канале: показано текущее устройство и количество активных сессий."), "");
      });
  }

  function kick(id, btn) {
    var A = window.GlukAuth;
    if (!A || !A.call || !id) return;
    btn.disabled = true;
    msg(T("Отключаем…"), "");
    A.call("/api/devices/" + encodeURIComponent(id) + "/disconnect", { method: "POST", body: {} })
      .catch(function () {
        return A.call("/api/devices/" + encodeURIComponent(id), { method: "DELETE" });
      })
      .then(function () {
        msg(T("Устройство отключено."), "is-ok");
        refresh();
      })
      .catch(function () {
        btn.disabled = false;
        msg(T("Не удалось отключить устройство. На бета-канале это можно сделать в приложении."), "is-err");
      });
  }

  function refresh() {
    var A = window.GlukAuth;
    if (!A) return;
    var btn = $("[data-dash-refresh]");
    if (btn) btn.classList.add("is-busy");
    if (A.refresh) A.refresh();
    window.setTimeout(function () {
      if (btn) btn.classList.remove("is-busy");
      apply();
    }, 900);
  }

  function apply() {
    var A = window.GlukAuth;
    var st = (A && A.state) || { status: "loading" };
    if (st.status === "loading") { view("loading"); return; }
    if (st.status !== "in") {
      view("guest");
      return;
    }
    view("in");
    renderAccount(st);
    initMap();
    pinData = pinsFor(fallbackDevices(st));
    placePins();
    if (!loading) {
      loading = true;
      loadDevices(st);
      window.setTimeout(function () { loading = false; }, 1500);
    }
  }

  function bind() {
    document.addEventListener("click", function (e) {
      var kickBtn = e.target.closest ? e.target.closest("[data-dash-kick]") : null;
      if (kickBtn) { kick(kickBtn.getAttribute("data-dash-kick"), kickBtn); return; }
      var out = e.target.closest ? e.target.closest("[data-dash-logout]") : null;
      if (out) {
        e.preventDefault();
        if (window.GlukAuth && window.GlukAuth.logout) window.GlukAuth.logout();
        window.setTimeout(function () { window.location.href = root; }, 350);
        return;
      }
      var rf = e.target.closest ? e.target.closest("[data-dash-refresh]") : null;
      if (rf) { refresh(); }
    });
    document.addEventListener("gluk:auth", apply);
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
