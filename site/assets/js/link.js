/* ==========================================================================
   GlukVPN — подтверждение входа по ссылке (device authorization).

   Зачем это нужно: у программы на ПК и у расширения не должно быть
   своего поля пароля. Они создают короткий запрос и открывают эту
   страницу; здесы уже есть живая сессия, и именно она превращает код в
   токены. Код в URL сам по себе ничего не даёт — без входа в аккаунт его
   невозможно подтвердить, а pollSecret никогда не покидает клиента.
   ========================================================================== */
(function () {
  "use strict";

  var rootPath = document.documentElement.getAttribute("data-base") || "/";
  var ru = (document.documentElement.getAttribute("data-lang") || "ru") !== "en";

  function t(rus, eng) { return ru ? rus : eng; }
  function $(id) { return document.getElementById(id); }
  function esc(v) {
    return String(v == null ? "" : v).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }

  /* Код приходит из ?code=XXXX-XXXX, но его можно ввести и руками:
     браузер мог не открыться сам, и тупик здесь недопустим. */
  function codeFromUrl() {
    var m = /[?&]code=([^&]*)/.exec(location.search || "");
    return m ? decodeURIComponent(m[1]) : "";
  }

  function normalize(raw) {
    var clean = String(raw || "").toUpperCase().replace(/[^A-Z0-9]/g, "");
    if (clean.length <= 4) return clean;
    return clean.slice(0, 4) + "-" + clean.slice(4, 8);
  }

  var CLIENTS = {
    windows: { ru: "Программа для Windows", en: "Windows app" },
    android: { ru: "Приложение для Android", en: "Android app" },
    extension: { ru: "Расширение для браузера", en: "Browser extension" },
    web: { ru: "Веб-клиент", en: "Web client" }
  };

  function clientLabel(key) {
    var c = CLIENTS[key];
    if (!c) return t("Неизвестное приложение", "Unknown app");
    return ru ? c.ru : c.en;
  }

  var state = { code: "", busy: false, request: null };

  function show(view) {
    ["gate", "ask", "confirm", "done", "fail"].forEach(function (id) {
      var node = $("link-" + id);
      if (node) node.hidden = id !== view;
    });
  }

  function fail(message, retry) {
    var box = $("link-fail");
    if (box) {
      box.innerHTML =
        '<h2 class="linkcard__title">' + esc(t("Не получилось", "Something went wrong")) + "</h2>" +
        '<p class="linkcard__text">' + esc(message) + "</p>" +
        (retry
          ? '<button class="btn btn--primary" type="button" id="link-retry">' +
            esc(t("Повторить", "Try again")) + "</button>"
          : "");
      var again = $("link-retry");
      if (again) again.addEventListener("click", function () { load(state.code); });
    }
    show("fail");
  }

  function renderConfirm(req) {
    state.request = req;
    var device = req.deviceName || t("без имени", "unnamed");
    $("link-client").textContent = clientLabel(req.client);
    $("link-device").textContent = device;
    $("link-code-shown").textContent = state.code;
    show("confirm");
  }

  function load(code) {
    state.code = normalize(code);
    if (!state.code || state.code.length < 9) { show("ask"); return; }
    if (!window.GlukAuth || !window.GlukAuth.isAuthed()) { renderGate(); return; }

    show("gate");
    $("link-gate-text").textContent = t("Проверяем запрос…", "Checking the request…");
    window.GlukAuth.call("/api/auth/link/" + encodeURIComponent(state.code))
      .then(function (json) { renderConfirm(json.request || {}); })
      .catch(function (e) {
        fail(
          (e && e.message) ||
            t("Ссылка не найдена или устарела.", "This link is unknown or has expired."),
          true
        );
      });
  }

  function renderGate() {
    show("gate");
    var next = rootPath + "link/?code=" + encodeURIComponent(state.code);
    $("link-gate-text").innerHTML =
      esc(t(
        "Сначала войдите в аккаунт — именно он разрешает вход на устройстве.",
        "Sign in first — your account is what authorises the device."
      )) +
      '<br><a class="btn btn--primary" href="' + esc(rootPath) + "login/?next=" +
      encodeURIComponent(next) + '">' + esc(t("Войти", "Sign in")) + "</a>";
  }

  function answer(approve) {
    if (state.busy) return;
    state.busy = true;
    var buttons = document.querySelectorAll("#link-confirm button");
    Array.prototype.forEach.call(buttons, function (b) { b.disabled = true; });

    var path =
      "/api/auth/link/" + encodeURIComponent(state.code) + (approve ? "/approve" : "/deny");
    window.GlukAuth.call(path, { method: "POST", body: {} })
      .then(function () {
        state.busy = false;
        $("link-done-title").textContent = approve
          ? t("Готово", "Done")
          : t("Вход отклонён", "Request declined");
        $("link-done-text").textContent = approve
          ? t(
              "Можно вернуться в приложение — оно уже вошло в аккаунт.",
              "You can go back to the app — it is already signed in."
            )
          : t(
              "Запрос отклонён. Если это были не вы — ничего делать не нужно.",
              "The request was declined. If it was not you, nothing else is needed."
            );
        show("done");
      })
      .catch(function (e) {
        state.busy = false;
        fail((e && e.message) || t("Не удалось отправить ответ.", "Could not send the answer."), true);
      });
  }

  function wire() {
    var approve = $("link-approve");
    var deny = $("link-deny");
    if (approve) approve.addEventListener("click", function () { answer(true); });
    if (deny) deny.addEventListener("click", function () { answer(false); });

    var form = $("link-ask-form");
    if (form) {
      form.addEventListener("submit", function (e) {
        e.preventDefault();
        load($("link-ask-input").value);
      });
    }

    /* auth.js грузит сессию асинхронно, так что ждём его события, а не
       угадываем момент готовности. */
    var started = false;
    document.addEventListener("gluk:auth", function (e) {
      var st = (e && e.detail) || {};
      if (st.status === "loading") return;
      if (started) return;
      started = true;
      load(codeFromUrl());
    });

    // Если auth.js успел завершиться до нашего подписчика.
    setTimeout(function () {
      if (started) return;
      if (window.GlukAuth && window.GlukAuth.state.status !== "loading") {
        started = true;
        load(codeFromUrl());
      }
    }, 600);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", wire);
  } else {
    wire();
  }
})();
