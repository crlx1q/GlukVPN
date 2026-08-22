/* ==========================================================================
   GlukVPN — авторизация на сайте.

   Тот же control plane, что и у приложения (см. flutter-client/lib/services/
   api_client.dart): POST /api/auth/login → refresh-токен хранится, access
   живёт только в памяти, перед запросами делается rotate.
   Токены разделены по каналам: prod и beta — разные базы и разные ключи
   подписи, сессия одного канала бессмысленна в другом.
   ========================================================================== */
(function () {
  "use strict";

  var G = window.GLUK_CONFIG || {};
  var API = G.api || {};
  var AC = G.auth || {};
  var CHANNEL = API.channel === "prod" ? "prod" : "beta";
  var BASE = String((API.base || {})[CHANNEL] || "").replace(/\/+$/, "");
  var TIMEOUT = API.timeoutMs || 12000;
  var KEY = "gluk." + CHANNEL + ".refresh";
  var root = document.documentElement.getAttribute("data-base") || "";

  var IC = {
    caret: '<svg class="acct__caret" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M6 9l6 6 6-6"/></svg>',
    user: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2"/><circle cx="12" cy="7" r="4"/></svg>',
    grid: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="3" width="7" height="7" rx="2"/><rect x="14" y="3" width="7" height="7" rx="2"/><rect x="3" y="14" width="7" height="7" rx="2"/><rect x="14" y="14" width="7" height="7" rx="2"/></svg>',
    down: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 3v12"/><path d="m7 11 5 5 5-5"/><path d="M5 21h14"/></svg>',
    out: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/><path d="m16 17 5-5-5-5"/><path d="M21 12H9"/></svg>',
    warn: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 9v4"/><path d="M12 17h.01"/><circle cx="12" cy="12" r="9"/></svg>',
    ok: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m20 6-11 11-5-5"/></svg>'
  };

  function esc(v) {
    return String(v == null ? "" : v).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }
  function read() { try { return localStorage.getItem(KEY); } catch (e) { return null; } }
  function write(v) {
    try { v ? localStorage.setItem(KEY, v) : localStorage.removeItem(KEY); } catch (e) {}
  }

  /* ------------------------------------------------------------ transport */
  var access = null;

  function request(path, opts) {
    opts = opts || {};
    var ctrl = window.AbortController ? new AbortController() : null;
    var timer = setTimeout(function () { ctrl && ctrl.abort(); }, TIMEOUT);
    var init = {
      method: opts.method || "GET",
      headers: { accept: "application/json" },
      mode: "cors",
      credentials: "omit"
    };
    if (ctrl) init.signal = ctrl.signal;
    if (opts.body) {
      init.headers["content-type"] = "application/json";
      init.body = JSON.stringify(opts.body);
    }
    if (opts.auth && access) init.headers.authorization = "Bearer " + access;

    return fetch(BASE + path, init).then(
      function (res) {
        clearTimeout(timer);
        return res.text().then(function (text) {
          var json = {};
          if (text) { try { json = JSON.parse(text); } catch (e) { json = {}; } }
          if (res.ok) return json;
          var err = (json && json.error) || {};
          var e = new Error(err.message || "Запрос не выполнен (" + res.status + ").");
          e.status = res.status;
          e.code = err.code || "http_" + res.status;
          e.retryAfter = parseInt(res.headers.get("retry-after") || "", 10) || null;
          throw e;
        });
      },
      function () {
        clearTimeout(timer);
        var e = new Error("Не удалось связаться с сервером. Проверьте соединение.");
        e.status = 0;
        e.code = "network_error";
        throw e;
      }
    );
  }

  function setSession(json) {
    access = json.accessToken || null;
    if (json.refreshToken) write(json.refreshToken);
    return json;
  }

  function rotate() {
    var rt = read();
    if (!rt) return Promise.reject({ status: 401, code: "no_session" });
    return request("/api/auth/refresh", { method: "POST", body: { refreshToken: rt } }).then(setSession);
  }

  /* --------------------------------------------------------------- состояние */
  var state = { status: "loading", user: null, subscription: null, devices: 0, offline: false };

  function emit() {
    document.dispatchEvent(new CustomEvent("gluk:auth", { detail: state }));
    render();
  }

  function applyMe(json) {
    state.status = "in";
    state.user = json.user || null;
    state.subscription = json.subscription || null;
    state.devices = typeof json.activeDevices === "number" ? json.activeDevices : 0;
    state.offline = false;
    emit();
    return state;
  }

  function guest(offline) {
    state.status = "out";
    state.user = null;
    state.subscription = null;
    state.devices = 0;
    state.offline = !!offline;
    emit();
  }

  function boot() {
    if (AC.enabled === false) { guest(false); return; }
    if (!read()) { guest(false); return; }
    rotate()
      .then(function () { return request("/api/auth/me", { auth: true }); })
      .then(applyMe)
      .catch(function (e) {
        // Сервер явно отказал — сессия больше не действительна.
        // Оффлайн/таймаут — токен сохраняем и пробуем в следующий раз.
        if (e && (e.status === 401 || e.status === 403)) write(null);
        guest(!e || e.status === 0);
      });
  }

  /* ------------------------------------------------------------ шапка */
  function initials(u) {
    var s = (u && (u.username || u.email || "")) + "";
    var parts = s.replace(/[^\p{L}\p{N}]+/gu, " ").trim().split(/\s+/);
    var a = (parts[0] || "?").charAt(0);
    var b = parts.length > 1 ? parts[1].charAt(0) : (parts[0] || "").charAt(1) || "";
    return (a + b).toUpperCase();
  }

  function subLabel() {
    var s = state.subscription;
    if (!s || !s.status) return { text: "Нет подписки", ok: false };
    if (String(s.status).toUpperCase() === "ACTIVE") {
      var d = s.expiresAt ? new Date(s.expiresAt) : null;
      var until = d && !isNaN(d) ? " до " + d.toLocaleDateString("ru-RU", { day: "2-digit", month: "short" }) : "";
      return { text: "Активна" + until, ok: true };
    }
    return { text: "Неактивна", ok: false };
  }

  function render() {
    var slots = document.querySelectorAll("[data-acct]");
    if (!slots.length) return;
    var html;
    if (state.status === "loading") {
      html = '<div class="acct__skel" aria-hidden="true"></div><span class="sr-only">Загрузка аккаунта</span>';
    } else if (state.status === "out") {
      html =
        '<div class="acct__guest">' +
        '<a class="btn btn--ghost btn--sm" href="' + root + 'login/">Войти</a>' +
        '<a class="btn btn--primary btn--sm" href="' + root + 'login/?mode=register">Регистрация</a>' +
        "</div>";
    } else {
      var u = state.user || {};
      var sub = subLabel();
      html =
        '<button class="acct__chip" type="button" aria-haspopup="true" aria-expanded="false" data-acct-toggle>' +
        '<span class="avatar avatar--online">' + esc(initials(u)) + "</span>" +
        '<span class="acct__name">' + esc(u.username || "Аккаунт") + "</span>" + IC.caret +
        "</button>" +
        '<div class="acct__menu" data-acct-menu role="menu">' +
        '<div class="acct__head"><span class="avatar avatar--lg">' + esc(initials(u)) + "</span>" +
        '<span class="acct__id"><b>' + esc(u.username || "") + "</b><span>" +
        esc(u.email || (u.publicId ? "№ " + u.publicId : "")) + "</span></span></div>" +
        '<div class="acct__rows">' +
        '<div class="acct__row"><span>Подписка</span><b class="' + (sub.ok ? "ok" : "") + '">' + esc(sub.text) + "</b></div>" +
        '<div class="acct__row"><span>Устройства</span><b>' + state.devices + " / " + (u.maxDevices || 3) + "</b></div>" +
        (u.publicId ? '<div class="acct__row"><span>Номер аккаунта</span><b>' + esc(u.publicId) + "</b></div>" : "") +
        "</div>" +
        '<div class="acct__links">' +
        '<a class="acct__link" href="' + esc(AC.accountUrl || "/account/") + '">' + IC.user + "Личный кабинет</a>" +
        (AC.webAppUrl ? '<a class="acct__link" href="' + esc(AC.webAppUrl) + '">' + IC.grid + "Веб-приложение</a>" : "") +
        '<a class="acct__link" href="' + root + 'download/">' + IC.down + "Скачать приложение</a>" +
        '<button class="acct__link acct__link--danger" type="button" data-acct-logout>' + IC.out + "Выйти</button>" +
        "</div></div>";
    }
    Array.prototype.forEach.call(slots, function (slot) {
      slot.innerHTML = html;
    });
  }

  function closeMenus() {
    Array.prototype.forEach.call(document.querySelectorAll("[data-acct-menu]"), function (m) {
      m.classList.remove("is-open");
    });
    Array.prototype.forEach.call(document.querySelectorAll("[data-acct-toggle]"), function (b) {
      b.setAttribute("aria-expanded", "false");
    });
  }

  document.addEventListener("click", function (e) {
    var toggle = e.target.closest && e.target.closest("[data-acct-toggle]");
    if (toggle) {
      var box = toggle.parentNode;
      var menu = box.querySelector("[data-acct-menu]");
      var open = menu.classList.contains("is-open");
      closeMenus();
      if (!open) {
        menu.classList.add("is-open");
        toggle.setAttribute("aria-expanded", "true");
      }
      return;
    }
    if (e.target.closest && e.target.closest("[data-acct-logout]")) {
      api.logout();
      return;
    }
    if (!(e.target.closest && e.target.closest("[data-acct-menu]"))) closeMenus();
  });
  document.addEventListener("keydown", function (e) {
    if (e.key === "Escape") closeMenus();
  });

  /* ------------------------------------------------------------- публичное API */
  var api = {
    channel: CHANNEL,
    get state() { return state; },
    login: function (identifier, password) {
      return request("/api/auth/login", {
        method: "POST",
        body: { identifier: identifier, username: identifier, password: password }
      })
        .then(setSession)
        .then(function () { return request("/api/auth/me", { auth: true }); })
        .then(applyMe);
    },
    logout: function () {
      var rt = read();
      write(null);
      var done = function () { access = null; guest(false); };
      request("/api/auth/logout", { method: "POST", auth: true, body: rt ? { refreshToken: rt } : {} })
        .then(done, done);
    },
    refresh: boot
  };
  window.GlukAuth = api;

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", function () { render(); boot(); });
  } else {
    render();
    boot();
  }
})();
