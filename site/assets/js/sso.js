/* ==========================================================================
   GlukVPN — вход через Telegram и Google на /login/ (и /en/login/).

   Оба способа заканчиваются одинаково: тот же набор токенов, что выдаёт
   /api/auth/login, передаётся в GlukAuth.adoptTokens(). Дальше работает
   обычный сценарий страницы входа: login.js слышит событие gluk:auth и
   уводит человека по ?next= или в кабинет.

   Telegram — это существующий device-link flow:
     POST /api/auth/link/start { client:"web", deviceName } → { requestId,
       userCode, pollSecret, verifyUrl, telegramUrl, expiresAt, intervalSec }
     открыть telegramUrl → POST /api/auth/link/poll { requestId, pollSecret }
       каждые intervalSec до status: approved | denied | expired | unknown.
   Канал — тот же, что у GlukAuth (prod/beta): подтверждать вход нужно на том
   инстансе, где потом живёт сессия.

   Google — Google Identity Services. Скрипт GIS грузится только когда
   /api/auth/config говорит google.enabled; client_id берём оттуда же, в
   config.js его нет и не должно быть. Ответ /api/auth/google:
     outcome:"signed_in"    → токены → adoptTokens
     outcome:"registration" → новый аккаунт без Telegram → телеграм-шаг
                              регистрации (GlukRegister.showTelegramStep).
   ========================================================================== */
(function () {
  "use strict";

  var row = document.querySelector("[data-sso]");
  var googleHosts = Array.prototype.slice.call(document.querySelectorAll("[data-google-btn]"));
  if (!row && !googleHosts.length) return;

  var T = window.GlukT || function (s) { return s; };
  var LANG = (document.documentElement.getAttribute("data-lang") || "ru").toLowerCase() === "en" ? "en" : "ru";
  var root = document.documentElement.getAttribute("data-base") || "/";

  var tgBtn = document.querySelector("[data-sso-telegram]");
  var note = document.querySelector("[data-sso-note]");
  var wait = document.querySelector("[data-sso-wait]");
  var waitTitle = document.querySelector("[data-sso-wait-title]");
  var waitCode = document.querySelector("[data-sso-code]");
  var waitLink = document.querySelector("[data-sso-link]");
  var waitTimer = document.querySelector("[data-sso-timer]");
  var waitMsg = document.querySelector("[data-sso-msg]");
  var cancelBtn = document.querySelector("[data-sso-cancel]");
  var loginForm = document.querySelector("[data-login-form]");
  var loginMsg = document.querySelector("[data-login-msg]");
  var regRows = Array.prototype.slice.call(document.querySelectorAll("[data-sso-register]"));

  function A() { return window.GlukAuth || null; }

  function say(el, text, kind) {
    if (!el) return;
    el.textContent = text || "";
    el.className = "auth-msg" + (text ? " is-on " + (kind === "ok" ? "auth-msg--ok" : "auth-msg--err") : "");
  }

  function human(e, fallback) {
    if (!e) return fallback;
    if (e.code === "registration_disabled") return T("Регистрация временно закрыта сервисом.");
    if (e.status === 0) return T("Не удалось связаться с сервером. Проверьте соединение.");
    if (e.status === 429) return T("Слишком много попыток. Повторите через минуту.");
    if (e.status >= 500) return T("Сервис временно недоступен. Попробуйте позже.");
    return fallback;
  }

  /* «navigator.platform-ish»: ОС и браузер, чтобы устройство в списке
     называлось «Windows · Chrome», а не «web». */
  function webDeviceName() {
    var ua = navigator.userAgent || "";
    var os = /Windows/i.test(ua) ? "Windows" : /Android/i.test(ua) ? "Android"
      : /iPhone|iPad|iOS/i.test(ua) ? "iOS" : /Macintosh/i.test(ua) ? "macOS"
      : /Linux/i.test(ua) ? "Linux" : (navigator.platform || "Web");
    var br = /Edg\//i.test(ua) ? "Edge" : /OPR\//i.test(ua) ? "Opera" : /Firefox/i.test(ua) ? "Firefox"
      : /Chrome/i.test(ua) ? "Chrome" : /Safari/i.test(ua) ? "Safari" : "";
    return (os + (br ? " \u00b7 " + br : "")).slice(0, 60);
  }

  /* ------------------------------------------------------------ Telegram */
  var tg = { timer: null, tick: null, active: false, expiresAt: 0 };

  function tgStop() {
    if (tg.timer) { clearTimeout(tg.timer); tg.timer = null; }
    if (tg.tick) { clearInterval(tg.tick); tg.tick = null; }
    tg.active = false;
  }

  function tgShowWait(on) {
    if (wait) wait.hidden = !on;
    if (loginForm) loginForm.hidden = on;
    if (row) row.hidden = on || row.getAttribute("data-sso-empty") === "1";
  }

  function tgCountdown() {
    if (!waitTimer) return;
    var left = Math.max(0, Math.round((tg.expiresAt - Date.now()) / 1000));
    var m = Math.floor(left / 60), s = left % 60;
    waitTimer.textContent = T("Код действует ещё") + " " + m + ":" + (s < 10 ? "0" : "") + s;
    waitTimer.classList.toggle("is-low", left <= 30);
    if (left <= 0) {
      tgStop();
      say(waitMsg, T("Время подтверждения истекло. Нажмите «Войти через Telegram» ещё раз."), "err");
      if (waitTitle) waitTitle.textContent = T("Время вышло");
    }
  }

  function tgFinish(payload) {
    tgStop();
    if (waitTitle) waitTitle.textContent = T("Подтверждено");
    say(waitMsg, T("Готово. Входим…"), "ok");
    A().adoptTokens(payload).then(
      function () {
        /* login.js увидит gluk:auth и уведёт по ?next= или в кабинет. */
        tgShowWait(false);
        say(loginMsg, T("Готово. Вы вошли."), "ok");
      },
      function (e) {
        tgShowWait(false);
        say(loginMsg, human(e, T("Не удалось завершить вход. Попробуйте ещё раз.")), "err");
      }
    );
  }

  function tgPoll(req, everyMs, fails) {
    if (!tg.active) return;
    A().public("/api/auth/link/poll", { method: "POST", body: { requestId: req.requestId, pollSecret: req.pollSecret } })
      .then(function (res) {
        if (!tg.active) return;
        var st = String((res && res.status) || "").toLowerCase();
        if (st === "approved") { tgFinish(res); return; }
        if (st === "denied") {
          tgStop();
          say(waitMsg, T("Вход отклонён в Telegram."), "err");
          if (waitTitle) waitTitle.textContent = T("Вход отклонён");
          return;
        }
        if (st === "expired") {
          tgStop();
          say(waitMsg, T("Время подтверждения истекло. Нажмите «Войти через Telegram» ещё раз."), "err");
          if (waitTitle) waitTitle.textContent = T("Время вышло");
          return;
        }
        if (st === "unknown") {
          tgStop();
          say(waitMsg, T("Запрос на вход не найден. Попробуйте ещё раз."), "err");
          return;
        }
        tg.timer = setTimeout(function () { tgPoll(req, everyMs, 0); }, everyMs);
      })
      .catch(function (e) {
        if (!tg.active) return;
        if (e && (e.status === 404 || e.status === 410)) {
          tgStop();
          say(waitMsg, T("Запрос на вход не найден. Попробуйте ещё раз."), "err");
          return;
        }
        /* Один неудавшийся опрос — не повод сдаваться: человек сейчас в
           Telegram. Пробуем реже, пока не истечёт срок кода. */
        var n = (fails || 0) + 1;
        tg.timer = setTimeout(function () { tgPoll(req, everyMs, n); }, Math.min(everyMs * (n + 1), 10000));
      });
  }

  function tgStart() {
    var auth = A();
    if (!auth || !auth.public || !auth.adoptTokens) {
      say(loginMsg, T("Авторизация не загрузилась. Обновите страницу."), "err");
      return;
    }
    tgStop();
    say(loginMsg, "");
    say(waitMsg, "");
    tgBtn.disabled = true;
    auth.public("/api/auth/link/start", { method: "POST", body: { client: "web", deviceName: webDeviceName() } })
      .then(function (res) {
        tgBtn.disabled = false;
        if (!res || !res.requestId || !res.pollSecret) throw { status: 500 };
        if (!res.telegramUrl) {
          tgBtn.hidden = true;
          say(loginMsg, T("Вход через Telegram сейчас недоступен. Войдите по паролю."), "err");
          return;
        }
        tg.active = true;
        tg.expiresAt = res.expiresAt ? new Date(res.expiresAt).getTime() : Date.now() + 5 * 60000;
        if (isNaN(tg.expiresAt)) tg.expiresAt = Date.now() + 5 * 60000;
        if (waitTitle) waitTitle.textContent = T("Ждём подтверждения в Telegram…");
        if (waitCode) waitCode.textContent = res.userCode || "\u2014";
        if (waitLink) {
          waitLink.href = res.telegramUrl;
          waitLink.setAttribute("data-verify-url", res.verifyUrl || "");
        }
        var verify = document.querySelector("[data-sso-verify]");
        if (verify) {
          if (res.verifyUrl) { verify.href = res.verifyUrl; verify.textContent = res.verifyUrl.replace(/^https?:\/\//, ""); verify.hidden = false; }
          else verify.hidden = true;
        }
        tgShowWait(true);
        tgCountdown();
        tg.tick = setInterval(tgCountdown, 1000);
        var every = Math.max(1, Number(res.intervalSec) || 2) * 1000;
        tg.timer = setTimeout(function () { tgPoll(res, every, 0); }, every);
        /* Новая вкладка открывается уже после ответа сервера. Браузеры дают на
           это несколько секунд после клика; если окно всё же заблокировано —
           в карточке ожидания есть та же ссылка и код для ручного ввода. */
        try { window.open(res.telegramUrl, "_blank", "noopener"); } catch (e) {}
      })
      .catch(function (e) {
        tgBtn.disabled = false;
        say(loginMsg, human(e, T("Не удалось начать вход через Telegram.")), "err");
      });
  }

  if (tgBtn) tgBtn.addEventListener("click", tgStart);
  if (cancelBtn) cancelBtn.addEventListener("click", function () {
    tgStop();
    tgShowWait(false);
    say(waitMsg, "");
  });
  window.addEventListener("beforeunload", tgStop);

  /* -------------------------------------------------------------- Google */
  var GIS_SRC = "https://accounts.google.com/gsi/client";
  var gsiLoading = null;

  function loadGis() {
    if (window.google && window.google.accounts && window.google.accounts.id) return Promise.resolve(true);
    if (gsiLoading) return gsiLoading;
    gsiLoading = new Promise(function (resolve) {
      var s = document.createElement("script");
      s.src = GIS_SRC;
      s.async = true;
      s.defer = true;
      s.onload = function () { resolve(!!(window.google && window.google.accounts && window.google.accounts.id)); };
      s.onerror = function () { resolve(false); };
      document.head.appendChild(s);
    });
    return gsiLoading;
  }

  function activeMode() {
    var on = document.querySelector("[data-auth-tab].is-active");
    return on && on.getAttribute("data-auth-tab") === "register" ? "register" : "login";
  }

  function switchTab(name) {
    var tab = document.querySelector('[data-auth-tab="' + name + '"]');
    if (tab) tab.click();
  }

  function onGoogleCredential(resp) {
    var auth = A();
    var cred = resp && resp.credential;
    var mode = activeMode();
    var target = mode === "register" ? document.getElementById("reg-msg") : loginMsg;
    if (!cred) { say(target, T("Google не вернул подтверждение. Попробуйте ещё раз."), "err"); return; }
    if (!auth || !auth.public) { say(target, T("Авторизация не загрузилась. Обновите страницу."), "err"); return; }
    say(target, T("Проверяем аккаунт Google…"), "ok");
    auth.public("/api/auth/google", { method: "POST", body: { credential: cred, mode: mode } })
      .then(function (res) {
        var outcome = String((res && res.outcome) || "").toLowerCase();
        if (outcome === "signed_in" || (!outcome && res && res.accessToken)) {
          return auth.adoptTokens(res).then(function () {
            say(loginMsg, T("Готово. Вы вошли."), "ok");
          });
        }
        if (outcome === "registration") {
          /* Аккаунт создан, остался Telegram. Показываем тот же шаг, что и в
             обычной регистрации, с тем же опросом статуса. */
          say(target, "");
          switchTab("register");
          if (window.GlukRegister && window.GlukRegister.showTelegramStep) {
            window.GlukRegister.showTelegramStep(
              res.email || "",
              res.telegramUrl || "",
              res.telegramCode || "",
              T("Аккаунт почти готов — подтвердите номер в Telegram.")
            );
            if (res.telegramUrl) { try { window.open(res.telegramUrl, "_blank", "noopener"); } catch (e) {} }
          } else {
            say(document.getElementById("reg-msg"), T("Аккаунт почти готов — подтвердите номер в Telegram."), "ok");
          }
          return;
        }
        throw { status: 500, message: T("Неожиданный ответ сервера.") };
      })
      .catch(function (e) {
        var text;
        if (e && e.code === "registration_disabled") text = T("Регистрация через Google временно закрыта сервисом.");
        else if (e && e.status === 403) text = T("Регистрация через Google сейчас закрыта. Войдите по паролю или напишите нам.");
        else if (e && e.status === 400) text = T("Google не подтвердил вход. Попробуйте ещё раз.");
        else text = human(e, T("Не удалось войти через Google."));
        say(mode === "register" ? document.getElementById("reg-msg") : loginMsg, text, "err");
      });
  }

  function mountGoogle(clientId) {
    return loadGis().then(function (ok) {
      if (!ok) {
        if (note) { note.textContent = T("Кнопка Google не загрузилась — возможно, её блокирует расширение."); note.hidden = false; }
        return false;
      }
      try {
        window.google.accounts.id.initialize({
          client_id: clientId,
          callback: onGoogleCredential,
          ux_mode: "popup",
          auto_select: false,
          cancel_on_tap_outside: true,
          itp_support: true
        });
      } catch (e) {
        if (note) { note.textContent = T("Кнопка Google не загрузилась — возможно, её блокирует расширение."); note.hidden = false; }
        return false;
      }
      googleHosts.forEach(function (host) {
        host.hidden = false;
        host.innerHTML = "";
        var width = Math.min(400, Math.max(120, Math.floor(host.clientWidth || (host.closest('[data-google-mode="login"]') ? 190 : 320))));
        try {
          window.google.accounts.id.renderButton(host, {
            type: "standard",
            theme: "filled_black",
            size: "large",
            shape: "pill",
            width: width,
            text: "signin",
            logo_alignment: "left",
            locale: LANG
          });
        } catch (e) { host.hidden = true; }
      });
      return true;
    });
  }

  /* ------------------------------------------------------------- старт */
  function hideAll() {
    if (row) { row.hidden = true; row.setAttribute("data-sso-empty", "1"); }
    regRows.forEach(function (r) { r.hidden = true; });
    googleHosts.forEach(function (h) { h.hidden = true; });
    if (tgBtn) tgBtn.hidden = true;
  }

  function applyConfig(cfg) {
    var tgOn = !!(cfg && cfg.telegram && cfg.telegram.enabled);
    var g = (cfg && cfg.google) || {};
    var gOn = !!(g.enabled && g.clientId);

    if (tgBtn) tgBtn.hidden = !tgOn;

    if (!gOn) {
      googleHosts.forEach(function (h) {
        h.hidden = h.getAttribute('data-google-mode') !== 'login';
        if (!h.hidden) h.innerHTML = '<button class="auth-alt__btn" type="button" disabled aria-label="Google — '+(LANG==='en'?'unavailable':'пока недоступен')+'"><svg viewBox="0 0 48 48" aria-hidden="true"><path fill="#EA4335" d="M24 9.5c3.54 0 6.71 1.22 9.21 3.6l6.85-6.85C35.9 2.38 30.47 0 24 0 14.62 0 6.51 5.38 2.56 13.22l7.98 6.19C12.43 13.72 17.74 9.5 24 9.5z"/><path fill="#4285F4" d="M46.98 24.55c0-1.57-.15-3.09-.38-4.55H24v9.02h12.94c-.58 2.96-2.26 5.48-4.78 7.18l7.73 6C44.4 38.03 46.98 31.85 46.98 24.55z"/><path fill="#FBBC05" d="M10.53 28.59A14.5 14.5 0 0 1 9.75 24c0-1.59.27-3.13.76-4.59l-7.98-6.19A23.9 23.9 0 0 0 0 24c0 3.87.93 7.52 2.56 10.78l7.97-6.19z"/><path fill="#34A853" d="M24 48c6.48 0 11.93-2.13 15.91-5.8l-7.73-6c-2.15 1.45-4.92 2.3-8.18 2.3-6.26 0-11.57-4.22-13.47-9.91l-7.98 6.19C6.51 42.62 14.62 48 24 48z"/></svg>Google</button>';
      });
      regRows.forEach(function (r) { r.hidden = true; });
      if (note) {
        note.textContent = T("Вход через Google пока не настроен — используйте пароль или Telegram.");
        note.hidden = !tgOn;
      }
    } else {
      if (note) note.hidden = true;
      regRows.forEach(function (r) { r.hidden = false; });
      mountGoogle(g.clientId);
    }

    if (row) {
      var any = tgOn || gOn || googleHosts.length > 0;
      row.hidden = !any;
      row.setAttribute("data-sso-empty", any ? "0" : "1");
    }
  }

  function boot() {
    var auth = A();
    if (!auth || !auth.public) { hideAll(); return; }
    auth.public("/api/auth/config").then(applyConfig, function () { hideAll(); });
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", boot);
  else boot();
})();
