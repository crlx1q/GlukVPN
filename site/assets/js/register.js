/* ==========================================================================
   GlukVPN — регистрация и восстановление пароля.

   Регистрация идёт тремя шагами:
     1. почта + пароль дважды (+ капча)
     2. 6-значный код из письма
     3. Telegram-бот: человек делится контактом, и аккаунт создаётся

   Порядок не случаен. Код на почту доказывает только то, что адрес
   существует, а адреса бесплатны и бесконечны. Телефон, полученный
   через штатную кнопку Telegram «поделиться контактом», — нет.

   Собственный transport, а не GlukAuth.call: все эти ручки публичные,
   а GlukAuth.call по своей природе требует живую сессию и крутит refresh.
   ========================================================================== */
(function () {
  "use strict";

  var G = window.GLUK_CONFIG || {};
  var API = G.api || {};
  var AC = G.auth || {};
  var TS = AC.turnstile || {};
  var rootPath = document.documentElement.getAttribute("data-base") || "/";
  var ru = (document.documentElement.getAttribute("data-lang") || "ru") !== "en";

  var form = document.querySelector("[data-reg-form]");
  var recForm = document.querySelector("[data-rec-form]");
  if (!form && !recForm) return;

  function t(rus, eng) { return ru ? rus : eng; }
  function $(id) { return document.getElementById(id); }

  /* --------------------------------------------------------------- transport */

  /* Тот же выбор канала, что и в auth.js: ?api=prod|beta проверяется по
     своему же списку API.base, так что параметром в URL нельзя увести
     страницу на чужой сервер. Регистрация обязана попасть в тот же
     инстанс, где потом будет вход: базы prod и beta раздельные.      */
  function pickChannel() {
    var fallback = API.channel === "prod" ? "prod" : "beta";
    var bases = API.base || {};
    var m = /[?&]api=([^&]*)/.exec(location.search || "");
    var wanted = m ? decodeURIComponent(m[1]).toLowerCase() : "";
    if (!wanted) {
      try { wanted = sessionStorage.getItem("gluk.api") || ""; } catch (e) { wanted = ""; }
    }
    return wanted && bases[wanted] ? wanted : fallback;
  }

  function trimBase(url) { return String(url || "").replace(/\/+$/, ""); }

  var BASE = trimBase((API.base || {})[pickChannel()]);

  /* ROUND 10 (2.1): регистрация всегда идёт на боевой контур.

     Бета — закрытая среда со своей базой, саморегистрация там выключена,
     и раньше страница честно рисовала заглушку «регистрация закрыта».
     Но /login/?api=beta открывают не для того, чтобы читать заглушку:
     единственный аккаунт, который вообще имеет смысл создавать, живёт на
     prod. Поэтому канал страницы больше не решает, куда уйдёт регистрация
     — только куда уйдёт вход.

     Захардкоженный адрес — это запасной вариант на случай усечённого
     конфига, а не источник истины: обычно берём его из API.base.prod. */
  var PROD_BASE = trimBase((API.base || {}).prod) || "https://api.gluk.tech";

  /* Ручки, которые обязаны попадать на prod независимо от ?api=beta и
     sessionStorage: сама регистрация, опрос её статуса и /auth/config,
     по которому решается, открыта ли регистрация вообще.
     Восстановление пароля сюда НЕ входит осознанно — пароль меняют тому
     аккаунту, в который потом будут входить, то есть на своём канале.  */
  function baseFor(path) {
    return (/^\/api\/auth\/(register|config)\b/.test(path) || path === "/api/service/status") ? PROD_BASE : BASE;
  }

  var TIMEOUT = API.timeoutMs || 12000;

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
    return fetch(baseFor(path) + path, init).then(
      function (res) {
        clearTimeout(timer);
        return res.text().then(function (text) {
          var json = {};
          if (text) { try { json = JSON.parse(text); } catch (e) { json = {}; } }
          if (res.ok) return json;
          var err = (json && json.error) || {};
          var e = new Error(err.message || t("Запрос не выполнен.", "Request failed."));
          e.status = res.status;
          e.code = err.code || "http_" + res.status;
          e.details = err.details || null;
          e.retryAfter = parseInt(res.headers.get("retry-after") || "", 10) || null;
          throw e;
        });
      },
      function () {
        clearTimeout(timer);
        var e = new Error(t(
          "Не удалось связаться с сервером. Проверьте соединение.",
          "Could not reach the server. Check your connection."
        ));
        e.status = 0;
        e.code = "network_error";
        throw e;
      }
    );
  }

  function human(e) {
    if (!e) return t("Не получилось. Попробуйте ещё раз.", "Something went wrong. Try again.");
    if (e.code === "registration_disabled") {
      closeRegistration(t("Регистрация временно закрыта сервисом.", "Registration is temporarily disabled by the service."));
      return t("Регистрация временно закрыта сервисом.", "Registration is temporarily disabled by the service.");
    }
    /* Капча живёт недолго: пока человек заполняет форму, токен успевает
       протухнуть, и сервер отказывает на anti-bot проверке. Раньше это
       выглядело как «непонятная ошибка» — теперь причина названа, а код
       рядом уже перезагружен (captchaRecover ниже).                     */
    if (captchaFailure(e)) {
      return t(
        "Проверка «я не робот» устарела. Мы обновили её — подтвердите ещё раз и отправьте форму.",
        "The anti-bot check expired. We refreshed it - confirm again and resubmit."
      );
    }
    if (e.status === 429) {
      var s = e.retryAfter || 0;
      var min = Math.ceil(s / 60);
      return t(
        "Слишком много попыток. Повторите " + (min > 1 ? "через " + min + " мин." : "через минуту."),
        "Too many attempts. Try again in " + (min > 1 ? min + " min." : "a minute.")
      );
    }
    if (e.status >= 500) {
      return t("Сервис временно недоступен. Попробуйте позже.", "Service is temporarily unavailable.");
    }
    return t("Не получилось. Проверьте данные и повторите.", "Something went wrong. Check your details and retry.");
  }

  /* ----------------------------------------------------------------- captcha */

  /* Turnstile грузится только если ключ задан. Сервер без секретного
     ключа проверку вовсе не делает, поэтому локальная разработка не
     упирается в виджет, который негде отрисовать.                       */
  var CAPTCHA_HOST = "challenges.cloudflare.com";
  var widgets = {};
  var captchaLoading = null;

  function captchaWanted() {
    return Boolean(TS.siteKey) && document.querySelector("[data-turnstile]") !== null;
  }

  function loadCaptcha() {
    if (!captchaWanted()) return Promise.resolve(false);
    if (captchaLoading) return captchaLoading;
    captchaLoading = new Promise(function (resolve) {
      var s = document.createElement("script");
      s.src = "https://" + CAPTCHA_HOST + "/turnstile/v0/api.js?render=explicit";
      s.async = true;
      s.defer = true;
      s.onload = function () { resolve(true); };
      /* Капча не загрузилась — не причина закрывать регистрацию: сервер
         при недоступности Cloudflare тоже пропускает проверку.        */
      s.onerror = function () { resolve(false); };
      document.head.appendChild(s);
    });
    return captchaLoading;
  }

  /* ROUND 9: капчу было не видно. Причина не одна, поэтому закрываем все:
     size:"flexible" — сравнительно новый режим, и если он не поддержан,
     виджет не рисуется вовсе; без appearance:"always" ключ типа
     invisible тоже не даёт ничего видимого; а ошибка рендера нигде не
     показывалась. Теперь слот подписан, виджет явно видимый, а любой
     сбой пишется текстом рядом.                                        */
  function captchaNote(key, text) {
    var host = document.querySelector('[data-turnstile="' + key + '"]');
    if (!host || !host.parentNode) return;
    var note = host.parentNode.querySelector('[data-captcha-note="' + key + '"]');
    if (!note) {
      note = document.createElement("p");
      note.className = "captcha__note";
      note.setAttribute("data-captcha-note", key);
      host.parentNode.insertBefore(note, host.nextSibling);
    }
    note.textContent = text || "";
    note.hidden = !text;
  }

  /* Подпись над слотом. Ставится из JS, а не в разметке, чтобы при
     выключенной капче не оставалось подписанного пустого места.  */
  function labelCaptchaSlots() {
    Array.prototype.forEach.call(document.querySelectorAll("[data-turnstile]"), function (host) {
      var prev = host.previousElementSibling;
      if (prev && prev.className === "captcha__head") return;
      var key = host.getAttribute("data-turnstile") || "register";

      /* Подпись и кнопка обновления — одной строкой над слотом: ⟳ должна быть
         там, куда человек смотрит на капчу, а не под кнопкой отправки. */
      var head = document.createElement("div");
      head.className = "captcha__head";

      var cap = document.createElement("span");
      cap.className = "captcha__cap";
      cap.textContent = t("Проверка, что вы человек", "Quick check that you are human");
      head.appendChild(cap);

      var refresh = document.createElement("button");
      refresh.type = "button";
      refresh.className = "captcha__refresh";
      refresh.setAttribute("data-captcha-refresh", key);
      refresh.title = t("Обновить проверку", "Refresh the check");
      refresh.setAttribute("aria-label", t("Обновить проверку", "Refresh the check"));
      refresh.innerHTML =
        '<svg viewBox="0 0 24 24" fill="none" aria-hidden="true">' +
        '<path d="M19.5 11a7.5 7.5 0 1 0-2.2 5.3" stroke="currentColor" stroke-width="1.9" stroke-linecap="round"/>' +
        '<path d="M19.5 5.8V11H14.3" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"/></svg>';
      refresh.addEventListener("click", function () {
        refresh.classList.add("is-spin");
        window.setTimeout(function () { refresh.classList.remove("is-spin"); }, 640);
        refreshCaptcha(key, false);
      });
      head.appendChild(refresh);

      if (host.parentNode) host.parentNode.insertBefore(head, host);
    });
  }

  function hideCaptchaSlots() {
    Array.prototype.forEach.call(document.querySelectorAll("[data-turnstile]"), function (host) {
      host.hidden = true;
    });
  }

  function mountCaptcha(key) {
    var host = document.querySelector('[data-turnstile="' + key + '"]');
    if (!host || !window.turnstile || widgets[key] !== undefined) return;
    try {
      widgets[key] = window.turnstile.render(host, {
        sitekey: TS.siteKey,
        theme: "dark",
        size: "normal",
        appearance: "always",
        callback: function () { captchaNote(key, ""); },
        "expired-callback": function () {
          /* CAPTCHA_EXPIRED. Не заставляем искать кнопку: сами перезагружаем
             код и говорим, что произошло. Через таймаут — Turnstile не любит
             reset() прямо из своего же колбэка.                            */
          captchaNote(key, t(
            "Проверка устарела — обновляем код…",
            "The check expired - refreshing it…"
          ));
          window.setTimeout(function () { refreshCaptcha(key, true); }, 60);
        },
        "timeout-callback": function () {
          window.setTimeout(function () { refreshCaptcha(key, true); }, 60);
        },
        "error-callback": function () {
          /* Сервер при недоступности Cloudflare пропускает проверку,
             так что это предупреждение, а не тупик.                     */
          captchaNote(key, t(
            "Проверка не отвечает. Можно продолжать — сервер проверит запрос сам.",
            "The check is not responding. You can continue - the server verifies the request as well."
          ));
        }
      });
    } catch (e) {
      captchaNote(key, t(
        "Не удалось показать проверку. Попробуйте обновить страницу.",
        "The check could not be displayed. Try reloading the page."
      ));
    }
  }

  function captchaToken(key) {
    if (widgets[key] === undefined || !window.turnstile) return "";
    try { return window.turnstile.getResponse(widgets[key]) || ""; } catch (e) { return ""; }
  }

  function captchaReset(key) {
    if (widgets[key] === undefined || !window.turnstile) return;
    try { window.turnstile.reset(widgets[key]); } catch (e) {}
  }

  /* «Сервер отверг именно капчу». Контрол-сервер отвечает на это обычным 400:
     verifyCaptcha не выдаёт отдельного кода, поэтому смотрим и на код, и на
     текст. CAPTCHA_EXPIRED от Turnstile и «anti-bot check» от нашего API
     ведут к одному и тому же действию — перезагрузить код.              */
  function captchaFailure(e) {
    if (!e) return false;
    var code = String(e.code || "").toLowerCase();
    var text = String(e.message || "").toLowerCase();
    if (code.indexOf("captcha") >= 0) return true;
    return e.status === 400 && (text.indexOf("anti-bot") >= 0 || text.indexOf("captcha") >= 0);
  }

  /* Мгновенное обновление кода: кнопка ⟳ и любой протухший токен приходят
     сюда. Turnstile не умеет «перерисовать» виджет, но reset() выдаёт новый
     вызов — для человека это и есть обновление.                          */
  function refreshCaptcha(key, quiet) {
    if (widgets[key] === undefined) {
      /* Виджет ещё не смонтирован: капча грузилась медленнее формы. */
      loadCaptcha().then(function (ok) { if (ok) mountCaptcha(key); });
      return;
    }
    captchaReset(key);
    captchaNote(key, quiet ? "" : t("Готово — новая проверка загружена.", "Done - a fresh check has loaded."));
  }

  /* После отказа сервера токен заведомо израсходован, поэтому обновляем его
     сразу, а не после второй неудачной попытки.                          */
  function captchaRecover(e, key) {
    if (!captchaFailure(e)) {
      captchaReset(key);
      return;
    }
    refreshCaptcha(key, true);
    captchaNote(key, t("Проверка устарела — загрузили новую.", "The check expired - a fresh one has loaded."));
  }

  /* -------------------------------------------------------------------- шаги */

  /* Шаги живут в двух разных контекстах: на отдельных страницах это вся
     карточка, а на объединённой /login/ — внутри своей вкладки. Поэтому
     переключаем только соседей в пределах одной панели: иначе step("code")
     в регистрации гасит первый шаг восстановления, и вкладка
     «Восстановление» открывается пустой.                                */
  function scopeOf(node) {
    if (!node || !node.closest) return document;
    return node.closest("[data-auth-pane]") || document;
  }

  function step(name) {
    var target = document.querySelector('[data-reg-step="' + name + '"]');
    if (!target) return;
    var scope = scopeOf(target);
    Array.prototype.forEach.call(scope.querySelectorAll("[data-reg-step]"), function (node) {
      node.hidden = node.getAttribute("data-reg-step") !== name;
    });
    var bar = scope.querySelector("[data-reg-progress]");
    if (bar) bar.setAttribute("data-at", name);
  }

  function msg(box, text, kind) {
    if (!box) return;
    box.textContent = text || "";
    box.className = "auth-msg" + (text ? " is-on " + (kind === "ok" ? "auth-msg--ok" : "auth-msg--err") : "");
  }

  function busy(button, on, labelBusy, labelIdle) {
    if (!button) return;
    button.disabled = on;
    button.textContent = on ? labelBusy : labelIdle;
  }

  /* ------------------------------------------------------------- регистрация */

  var reg = { email: "", telegramUrl: "", poll: null, tries: 0 };

  function stopPolling() {
    if (reg.poll) { clearTimeout(reg.poll); reg.poll = null; }
  }

  /* Страница не узнает от бота ничего напрямую, поэтому спрашиваем
     сервер. Поллинг ограничен по времени: забытая открытой вкладка
     не должна стучать в API бесконечно.                              */
  function pollStatus() {
    stopPolling();
    if (reg.tries > 200) {
      msg($("reg-tg-msg"), t(
        "Проверка остановлена. Обновите страницу, если уже подтвердили в Telegram.",
        "Stopped checking. Reload the page if you already confirmed in Telegram."
      ), "err");
      return;
    }
    reg.tries += 1;
    request("/api/auth/register/status?email=" + encodeURIComponent(reg.email))
      .then(function (json) {
        if (json && json.state === "done") {
          var login = $("reg-done-login");
          if (login) login.textContent = json.username || "";
          step("done");
          return;
        }
        reg.poll = setTimeout(pollStatus, 3000);
      })
      .catch(function () {
        /* Один неудавшийся опрос ничего не значит — человек в этот
           момент в Telegram, а не здесь. Пробуем снова, реже.      */
        reg.poll = setTimeout(pollStatus, 6000);
      });
  }

  if (form) {
    var regBtn = form.querySelector('button[type="submit"]');
    form.addEventListener("submit", function (e) {
      e.preventDefault();
      var email = String(form.email.value || "").trim();
      var pass = String(form.password.value || "");
      var pass2 = String(form.password2.value || "");
      var box = $("reg-msg");

      if (email.indexOf("@") < 1) {
        return msg(box, t("Введите корректный email.", "Enter a valid email."), "err");
      }
      if (pass.length < 8) {
        return msg(box, t("Пароль — минимум 8 символов.", "Password must be at least 8 characters."), "err");
      }
      if (pass !== pass2) {
        return msg(box, t("Пароли не совпадают.", "The passwords do not match."), "err");
      }

      msg(box, "");
      busy(regBtn, true, t("Отправляем…", "Sending…"), t("Продолжить", "Continue"));
      request("/api/auth/register/start", {
        method: "POST",
        body: {
          email: email,
          password: pass,
          passwordConfirm: pass2,
          captchaToken: captchaToken("register")
        }
      }).then(
        function (json) {
          busy(regBtn, false, "", t("Продолжить", "Continue"));
          reg.email = json.email || email;
          var to = $("reg-code-to");
          if (to) to.textContent = reg.email;
          var warn = $("reg-code-warn");
          if (warn) {
            /* Если письмо не ушло, говорим об этом прямо. Молчаливо
               ждать код, который никогда не придёт, — худшее из поведений. */
            warn.hidden = json.delivered !== false;
          }
          step("code");
        },
        function (err) {
          busy(regBtn, false, "", t("Продолжить", "Continue"));
          captchaRecover(err, "register");
          msg(box, human(err), "err");
        }
      );
    });
  }

  var codeForm = document.querySelector("[data-reg-code-form]");
  if (codeForm) {
    var codeBtn = codeForm.querySelector('button[type="submit"]');
    codeForm.addEventListener("submit", function (e) {
      e.preventDefault();
      var code = String(codeForm.code.value || "").replace(/\D/g, "");
      var box = $("reg-code-msg");
      if (code.length !== 6) {
        return msg(box, t("Код — 6 цифр.", "The code is 6 digits."), "err");
      }
      msg(box, "");
      busy(codeBtn, true, t("Проверяем…", "Checking…"), t("Подтвердить", "Confirm"));
      request("/api/auth/register/verify-email", {
        method: "POST",
        body: { email: reg.email, code: code }
      }).then(
        function (json) {
          busy(codeBtn, false, "", t("Подтвердить", "Confirm"));
          reg.telegramUrl = json.telegramUrl || "";
          var open = $("reg-tg-open");
          if (open && reg.telegramUrl) open.href = reg.telegramUrl;
          var manual = $("reg-tg-code");
          if (manual) manual.textContent = json.telegramCode || "";
          step("telegram");
          reg.tries = 0;
          pollStatus();
        },
        function (err) {
          busy(codeBtn, false, "", t("Подтвердить", "Confirm"));
          msg(box, human(err), "err");
        }
      );
    });
  }

  /* 0.8.0: вход через Google может вернуть outcome:"registration" — аккаунт
     создан, но контакт в Telegram ещё не подтверждён. sso.js переводит карточку
     в этот же телеграм-шаг и запускает тот же опрос статуса, что и обычная
     регистрация: одна ручка, один экран, одно поведение. */
  window.GlukRegister = {
    showTelegramStep: function (email, telegramUrl, telegramCode, note) {
      stopPolling();
      reg.email = String(email || "");
      reg.telegramUrl = String(telegramUrl || "");
      var open = $("reg-tg-open");
      if (open) {
        if (reg.telegramUrl) open.href = reg.telegramUrl;
        else open.removeAttribute("href");
      }
      var manual = $("reg-tg-code");
      if (manual) manual.textContent = telegramCode || "";
      msg($("reg-tg-msg"), note || "", "ok");
      step("telegram");
      reg.tries = 0;
      if (reg.email) pollStatus();
    }
  };

  var resend = $("reg-code-resend");
  if (resend) {
    resend.addEventListener("click", function () {
      resend.disabled = true;
      request("/api/auth/register/resend", { method: "POST", body: { email: reg.email } }).then(
        function () {
          msg($("reg-code-msg"), t("Новый код отправлен.", "A new code has been sent."), "ok");
          setTimeout(function () { resend.disabled = false; }, 30000);
        },
        function (err) {
          msg($("reg-code-msg"), human(err), "err");
          resend.disabled = false;
        }
      );
    });
  }

  /* ------------------------------------------------- восстановление пароля */

  var rec = { identifier: "" };

  if (recForm) {
    var recBtn = recForm.querySelector('button[type="submit"]');
    recForm.addEventListener("submit", function (e) {
      e.preventDefault();
      var id = String(recForm.identifier.value || "").trim();
      var box = $("rec-msg");
      if (id.length < 3) {
        return msg(box, t("Введите логин или email.", "Enter your username or email."), "err");
      }
      var picked = recForm.querySelector('input[name="channel"]:checked');
      msg(box, "");
      busy(recBtn, true, t("Отправляем…", "Sending…"), t("Прислать код", "Send the code"));
      request("/api/auth/password/forgot", {
        method: "POST",
        body: {
          identifier: id,
          channel: picked ? picked.value : undefined,
          captchaToken: captchaToken("recover")
        }
      }).then(
        function (json) {
          busy(recBtn, false, "", t("Прислать код", "Send the code"));
          rec.identifier = id;
          var where = $("rec-where");
          if (where) {
            where.textContent = json && json.channel === "telegram"
              ? t("Код отправлен в Telegram.", "The code was sent to Telegram.")
              : t("Код отправлен на почту.", "The code was sent by email.");
          }
          step("reset");
        },
        function (err) {
          busy(recBtn, false, "", t("Прислать код", "Send the code"));
          captchaRecover(err, "recover");
          msg(box, human(err), "err");
        }
      );
    });
  }

  var resetForm = document.querySelector("[data-rec-reset-form]");
  if (resetForm) {
    var resetBtn = resetForm.querySelector('button[type="submit"]');
    resetForm.addEventListener("submit", function (e) {
      e.preventDefault();
      var code = String(resetForm.code.value || "").replace(/\D/g, "");
      var pass = String(resetForm.password.value || "");
      var pass2 = String(resetForm.password2.value || "");
      var box = $("rec-reset-msg");
      if (code.length !== 6) {
        return msg(box, t("Код — 6 цифр.", "The code is 6 digits."), "err");
      }
      if (pass.length < 8) {
        return msg(box, t("Пароль — минимум 8 символов.", "Password must be at least 8 characters."), "err");
      }
      if (pass !== pass2) {
        return msg(box, t("Пароли не совпадают.", "The passwords do not match."), "err");
      }
      msg(box, "");
      busy(resetBtn, true, t("Сохраняем…", "Saving…"), t("Сохранить пароль", "Save the password"));
      request("/api/auth/password/reset", {
        method: "POST",
        body: { identifier: rec.identifier, code: code, password: pass }
      }).then(
        function () {
          busy(resetBtn, false, "", t("Сохранить пароль", "Save the password"));
          step("reset-done");
        },
        function (err) {
          busy(resetBtn, false, "", t("Сохранить пароль", "Save the password"));
          msg(box, human(err), "err");
        }
      );
    });
  }

  /* ------------------------------------------------------------------- старт */

  /* Показать всё, что пароль показывает — такая же механика, как на /login/. */
  Array.prototype.forEach.call(document.querySelectorAll("[data-pw-toggle]"), function (btn) {
    /* ROUND 9: на объединённой /login/ у формы входа есть свой обработчик
       в login.js. Два обработчика на одной кнопке меняют type дважды, то
       есть визуально не меняют вовсе.                                  */
    if (btn.closest && btn.closest("[data-login-form]")) return;
    btn.addEventListener("click", function () {
      var input = btn.parentNode ? btn.parentNode.querySelector("input") : null;
      if (!input) return;
      var shown = input.type === "text";
      input.type = shown ? "password" : "text";
      btn.classList.toggle("is-on", !shown);
      btn.setAttribute("aria-label", shown
        ? t("Показать пароль", "Show password")
        : t("Скрыть пароль", "Hide password"));
      input.focus();
    });
  });

  /* ROUND 10 (2.1): здесь стояла проверка канала, закрывавшая форму на
     бете. Она больше не нужна и вредна: запросы регистрации уходят на
     prod сами (см. baseFor), так что на /login/?mode=register заглушки
     не будет ни при каком ?api. Закрыть регистрацию теперь может только
     сервер — выключенная саморегистрация или неработающий бот.        */

  function closeRegistration(why) {
    if (!form) return;
    var notice = $("reg-closed");
    if (!notice) return;
    var text = $("reg-closed-msg");
    if (text && why) text.textContent = why;

    /* РАУНД 17: сначала гасим все шаги, и только потом показываем
       заглушку. Порядок был обратный, и на экране одновременно висели
       форма регистрации и «Регистрация сейчас закрыта» под ней — именно
       это было видно на сайте. Шаги прячем сами, не полагаясь на step():
       если тот по какой-то причине не сработает, две панели сразу
       показать всё равно будет нельзя. */
    var pane = notice.parentNode;
    if (pane) {
      var steps = pane.querySelectorAll("[data-reg-step]");
      for (var i = 0; i < steps.length; i += 1) {
        if (steps[i] !== notice) steps[i].hidden = true;
      }
    }

    notice.hidden = false;
    step("closed");
  }

  /* Общий статус сервиса закрывает все варианты регистрации до отправки формы. */
  request("/api/service/status").then(function (status) {
    if (status && status.registrationEnabled === false) {
      closeRegistration(t("Регистрация временно закрыта сервисом.", "Registration is temporarily disabled by the service."));
    }
  }, function () { /* Ошибка статуса не подменяет предметную ошибку регистрации. */ });

  /* Сервер — истина в последней инстанции: если регистрация закрыта
     или бот не настроен, честнее сказать это сразу, а не на шаге 3. */
  request("/api/auth/config").then(
    function (json) {
      var closed = json && json.selfRegistration === false;
      var noBot = json && json.telegram && json.telegram.enabled === false;
      if (noBot && !closed) {
        closeRegistration(t(
          "Подтверждение в Telegram сейчас недоступно, поэтому регистрация закрыта. Напишите нам — откроем доступ вручную.",
          "Telegram confirmation is unavailable right now, so sign-up is closed. Message us and we will open access by hand."
        ));
      } else if (closed) {
        closeRegistration("");
      }
      var ttl = json && json.codeTtlMinutes;
      if (ttl) {
        Array.prototype.forEach.call(document.querySelectorAll("[data-code-ttl]"), function (n) {
          n.textContent = String(ttl);
        });
      }
    },
    function () { /* Нет связи — пусть человек попробует; ошибка придёт по делу. */ }
  );

  if (captchaWanted()) {
    labelCaptchaSlots();
    loadCaptcha().then(function (ok) {
      if (!ok) {
        captchaNote("register", t(
          "Проверка не загрузилась — возможно, её блокирует расширение. Пробуйте продолжить или отключите блокировщик.",
          "The check did not load - an extension may be blocking it. Try continuing anyway, or disable the blocker."
        ));
        captchaNote("recover", t(
          "Проверка не загрузилась — возможно, её блокирует расширение. Пробуйте продолжить или отключите блокировщик.",
          "The check did not load - an extension may be blocking it. Try continuing anyway, or disable the blocker."
        ));
        return;
      }
      mountCaptcha("register");
      mountCaptcha("recover");
    });
  } else {
    /* Капча выключена (нет ключа) — подписанная рамка без виджета
       выглядит как поломка, поэтому убираем слот целиком.        */
    hideCaptchaSlots();
  }

  window.addEventListener("beforeunload", stopPolling);
})();
