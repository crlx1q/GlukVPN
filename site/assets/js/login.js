/* Форма входа и мини-кабинет на /login/. Работает поверх window.GlukAuth. */
(function () {
  "use strict";
  var form = document.querySelector("[data-login-form]");
  var panel = document.querySelector("[data-acct-panel]");
  if (!form && !panel) return;

  var msg = document.querySelector("[data-login-msg]");
  var submit = form ? form.querySelector('button[type="submit"]') : null;

  function show(text, kind) {
    if (!msg) return;
    msg.textContent = text;
    msg.className = "auth-msg is-on " + (kind === "ok" ? "auth-msg--ok" : "auth-msg--err");
  }
  function clear() {
    if (msg) { msg.textContent = ""; msg.className = "auth-msg"; }
  }
  function busy(on) {
    if (!submit) return;
    submit.disabled = on;
    submit.setAttribute("data-busy", on ? "1" : "0");
    submit.textContent = on ? "Проверяем…" : "Войти";
  }
  function human(e) {
    if (!e) return "Не удалось войти. Попробуйте ещё раз.";
    if (e.status === 0) return "Сервер не отвечает. Проверьте соединение и попробуйте снова.";
    if (e.status === 400) return "Проверьте поля: логин от 3 символов, пароль от 8.";
    if (e.status === 401) return "Неверный логин или пароль.";
    if (e.status === 403) return e.message || "Доступ к аккаунту ограничен.";
    if (e.status === 429) {
      var s = e.retryAfter || 0;
      var m = Math.ceil(s / 60);
      return "Слишком много попыток. Повторите " + (m > 1 ? "через " + m + " мин." : "через минуту.");
    }
    if (e.status >= 500) return "Сервис временно недоступен. Попробуйте позже.";
    return e.message || "Не удалось войти.";
  }

  /* вкладки */
  var tabs = [].slice.call(document.querySelectorAll("[data-auth-tab]"));
  function tab(name) {
    tabs.forEach(function (t) {
      t.classList.toggle("is-active", t.getAttribute("data-auth-tab") === name);
    });
    [].forEach.call(document.querySelectorAll("[data-auth-pane]"), function (p) {
      p.hidden = p.getAttribute("data-auth-pane") !== name;
    });
  }
  tabs.forEach(function (t) {
    t.addEventListener("click", function () { tab(t.getAttribute("data-auth-tab")); });
  });
  if (/[?&]mode=register/.test(location.search)) tab("register");

  /* показать пароль */
  var pw = document.querySelector("[data-pw-toggle]");
  if (pw) {
    pw.addEventListener("click", function () {
      var input = form.querySelector('input[name="password"]');
      var vis = input.type === "text";
      input.type = vis ? "password" : "text";
      pw.setAttribute("aria-label", vis ? "Показать пароль" : "Скрыть пароль");
      pw.classList.toggle("is-on", !vis);
      input.focus();
    });
  }

  /* отправка */
  if (form) {
    form.addEventListener("submit", function (e) {
      e.preventDefault();
      if (!window.GlukAuth) return show("Авторизация не загрузилась. Обновите страницу.", "err");
      var id = String(form.identifier.value || "").trim();
      var pass = String(form.password.value || "");
      if (id.length < 3) return show("Логин или email — от 3 символов.", "err");
      if (pass.length < 8) return show("Пароль — минимум 8 символов.", "err");
      clear();
      busy(true);
      window.GlukAuth.login(id, pass).then(
        function () {
          busy(false);
          show("Готово. Вы вошли.", "ok");
          form.reset();
        },
        function (err) {
          busy(false);
          show(human(err), "err");
        }
      );
    });
  }

  /* мини-кабинет */
  function esc(v) {
    return String(v == null ? "" : v).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }
  function stat(label, value, ok) {
    return (
      '<div class="acct-stat"><span class="acct-stat__label">' + label + "</span>" +
      '<span class="acct-stat__value' + (ok ? " acct-stat__value--ok" : "") + '">' + value + "</span></div>"
    );
  }
  function paint(st) {
    if (!panel) return;
    var signedIn = st && st.status === "in" && st.user;
    panel.hidden = !signedIn;
    [].forEach.call(document.querySelectorAll("[data-auth-pane]"), function (p) {
      if (signedIn) p.hidden = true;
    });
    var tabsBox = document.querySelector(".auth-tabs");
    if (tabsBox) tabsBox.hidden = !!signedIn;
    if (!signedIn) return;

    var u = st.user;
    var sub = st.subscription;
    var active = sub && String(sub.status).toUpperCase() === "ACTIVE";
    var until = "—";
    if (active && sub.expiresAt) {
      var d = new Date(sub.expiresAt);
      if (!isNaN(d)) until = d.toLocaleDateString("ru-RU", { day: "2-digit", month: "long", year: "numeric" });
    }
    panel.innerHTML =
      '<h2 class="auth-card__title">Привет, ' + esc(u.username || "") + "</h2>" +
      '<p class="auth-card__sub">Вы вошли в аккаунт. Данные берутся из того же сервиса, что и в приложении.</p>' +
      '<div class="acct-panel__grid">' +
      stat("Подписка", active ? "Активна" : "Нет", active) +
      stat("Действует до", esc(until), false) +
      stat("Устройства", (st.devices || 0) + " / " + (u.maxDevices || 3), false) +
      stat("Номер аккаунта", esc(u.publicId || "—"), false) +
      stat("Email", esc(u.email || "не указан"), false) +
      stat("Статус", esc(u.status || "ACTIVE"), String(u.status || "ACTIVE").toUpperCase() === "ACTIVE") +
      "</div>" +
      '<div class="acct-panel__actions">' +
      '<button class="btn btn--ghost" type="button" data-acct-logout>Выйти</button>' +
      "</div>";
  }

  document.addEventListener("gluk:auth", function (e) { paint(e.detail); });
  if (window.GlukAuth) paint(window.GlukAuth.state);
})();
