/* One controller owns login/register/recover visibility. API contracts stay in GlukAuth/register.js/sso.js. */
(function () {
  "use strict";
  var $ = function (s) { return document.querySelector(s); };
  var all = function (s) { return Array.prototype.slice.call(document.querySelectorAll(s)); };
  var form = $("[data-login-form]"), panel = $("[data-acct-panel]");
  if (!form && !panel) return;
  var EN = document.documentElement.getAttribute("data-lang") === "en";
  var t = function (ru, en) { return EN ? en : ru; };
  var root = document.documentElement.getAttribute("data-base") || "/";
  var tabs = all("[data-auth-tab]"), panes = all("[data-auth-pane]");
  var title = $("[data-auth-title]"), sub = $("[data-auth-sub]");
  var msg = $("[data-login-msg]"), submit = form && form.querySelector('[type="submit"]');
  var mode = new URLSearchParams(location.search).get("mode") || "login";
  var signedIn = false, hop = null, busy = false;
  var copy = {
    login: [t("С возвращением", "Welcome back"), t("Один аккаунт для всех ваших устройств.", "One account for all your devices.")],
    register: [t("Создать аккаунт", "Create your account"), t("Начните с почты и пароля. Затем подтвердите почту и Telegram.", "Start with email and password. Then verify your email and Telegram.")],
    recover: [t("Восстановить доступ", "Recover access"), t("Пришлём код на почту или в Telegram.", "We will send a code by email or Telegram.")]
  };
  function nextTarget() {
    var raw = new URLSearchParams(location.search).get("next") || "";
    if (!raw.startsWith("/") || raw.startsWith("//") || /[\\\u0000-\u0020]/.test(raw)) return "";
    try {
      var u = new URL(raw, location.origin);
      if (u.origin !== location.origin || /\/(?:login|register|recover)\/?$/.test(u.pathname)) return "";
      return u.pathname + u.search + u.hash;
    } catch (_) { return ""; }
  }
  function message(text, ok) {
    if (!msg) return;
    msg.textContent = text || "";
    msg.className = "auth-msg" + (text ? " is-on " + (ok ? "auth-msg--ok" : "auth-msg--err") : "");
  }
  function renderMode(focus) {
    if (!copy[mode]) mode = "login";
    if (title) title.textContent = copy[mode][0];
    if (sub) sub.textContent = copy[mode][1];
    tabs.forEach(function (tab) {
      var active = tab.getAttribute("data-auth-tab") === mode;
      tab.classList.toggle("is-active", active);
      tab.setAttribute("aria-selected", String(active));
      tab.tabIndex = active || mode === "recover" && tab.getAttribute("data-auth-tab") === "login" ? 0 : -1;
    });
    panes.forEach(function (pane) {
      var active = !signedIn && pane.getAttribute("data-auth-pane") === mode;
      pane.hidden = !active;
      pane.inert = !active;
      pane.classList.toggle("is-in", active);
      if (active && focus) {
        var input = pane.querySelector("input:not([type=hidden])");
        if (input && input.getClientRects().length) input.focus({ preventScroll: true });
      }
    });
    var box = $(".auth-tabs");
    if (box) box.hidden = signedIn;
    if (panel) panel.hidden = !signedIn;
  }
  function select(name, updateUrl, focus) {
    if (signedIn) return;
    mode = copy[name] ? name : "login";
    if (updateUrl) {
      var u = new URL(location.href);
      if (mode === "login") u.searchParams.delete("mode");
      else u.searchParams.set("mode", mode);
      history.replaceState(null, "", u.pathname + u.search + u.hash);
    }
    renderMode(focus);
    document.dispatchEvent(new CustomEvent("gluk:auth-mode", { detail: { mode: mode } }));
  }
  tabs.forEach(function (tab) {
    var name = tab.getAttribute("data-auth-tab"), pane = $('[data-auth-pane="' + name + '"]');
    tab.id = "auth-tab-" + name;
    if (pane) {
      pane.id = "auth-pane-" + name;
      pane.setAttribute("role", "tabpanel");
      pane.setAttribute("aria-labelledby", tab.id);
      tab.setAttribute("aria-controls", pane.id);
    }
    tab.addEventListener("click", function () { select(name, true, false); });
    tab.addEventListener("keydown", function (e) {
      if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(e.key)) return;
      e.preventDefault();
      var visible = tabs.filter(function (x) { return !x.hidden; });
      var at = visible.indexOf(tab);
      var next = e.key === "Home" ? 0 : e.key === "End" ? visible.length - 1 : (at + (e.key === "ArrowRight" ? 1 : -1) + visible.length) % visible.length;
      visible[next].click(); visible[next].focus();
    });
  });
  all("[data-auth-goto]").forEach(function (link) {
    link.addEventListener("click", function (e) {
      if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey || e.button !== 0) return;
      e.preventDefault(); select(link.getAttribute("data-auth-goto"), true, true);
    });
  });
  window.addEventListener("popstate", function () {
    mode = new URLSearchParams(location.search).get("mode") || "login"; renderMode(false);
  });
  if (form) {
    var pw = form.querySelector("[data-pw-toggle]");
    if (pw) pw.addEventListener("click", function () {
      var input = form.elements.namedItem("password"), show = input.type === "password";
      input.type = show ? "text" : "password";
      pw.classList.toggle("is-on", show);
      pw.setAttribute("aria-pressed", String(show));
      pw.setAttribute("aria-label", show ? t("Скрыть пароль", "Hide password") : t("Показать пароль", "Show password"));
    });
    form.addEventListener("submit", function (e) {
      e.preventDefault(); if (busy) return;
      var A = window.GlukAuth;
      if (!A || !A.login) return message(t("Авторизация не загрузилась. Обновите страницу.", "Sign-in did not load. Reload the page."));
      var id = form.elements.namedItem("identifier"), pass = form.elements.namedItem("password");
      id.setAttribute("aria-invalid", String(id.value.trim().length < 3));
      pass.setAttribute("aria-invalid", String(pass.value.length < 8));
      if (id.value.trim().length < 3) { id.focus(); return message(t("Логин или email — от 3 символов.", "Login or email must be at least 3 characters.")); }
      if (pass.value.length < 8) { pass.focus(); return message(t("Пароль — минимум 8 символов.", "Password must be at least 8 characters.")); }
      busy = true; submit.disabled = true; form.setAttribute("aria-busy", "true");
      submit.textContent = t("Проверяем…", "Checking…"); message("");
      Promise.resolve().then(function () { return A.login(id.value.trim(), pass.value); }).then(function () {
        form.reset(); message(t("Готово. Открываем кабинет…", "Done. Opening your dashboard…"), true);
        paint(A.state);
      }, function (err) {
        var text = t("Не удалось войти. Попробуйте снова.", "Could not sign in. Try again.");
        if (err && err.status === 401) text = t("Неверный логин или пароль.", "Wrong login or password.");
        else if (err && err.status === 403) text = t("Доступ к аккаунту ограничен.", "Access to this account is restricted.");
        else if (err && err.status === 429) text = t("Слишком много попыток. Повторите позже.", "Too many attempts. Please try again later.");
        else if (err && (err.status === 0 || err.status >= 500)) text = t("Сервис не отвечает. Проверьте соединение и повторите.", "The service is unavailable. Check your connection and retry.");
        message(text);
      }).finally(function () {
        busy = false; submit.disabled = false; form.setAttribute("aria-busy", "false");
        submit.textContent = t("Войти", "Sign in");
      });
    });
  }
  function paint(st) {
    signedIn = !!(st && st.status === "in" && st.user);
    clearTimeout(hop);
    renderMode(false);
    if (!signedIn) { if (panel) panel.replaceChildren(); return; }
    if (panel) {
      var heading = document.createElement("h2"), link = document.createElement("a");
      heading.textContent = t("Вы вошли в аккаунт", "You are signed in");
      link.className = "btn btn--primary btn--block";
      link.href = nextTarget() || root + "app/";
      link.textContent = t("Продолжить", "Continue");
      panel.replaceChildren(heading, link);
    }
    if (nextTarget() || new URLSearchParams(location.search).get("stay") !== "1") {
      hop = setTimeout(function () { location.replace(nextTarget() || root + "app/"); }, 250);
    }
  }
  var beta = new URLSearchParams(location.search).get("api");
  try { beta = beta || sessionStorage.getItem("gluk.api"); } catch (_) {}
  if (beta === "beta") {
    var reg = $('[data-auth-pane="register"]');
    if (reg && !reg.querySelector("[data-reg-prod-note]")) {
      var note = document.createElement("p"); note.className = "auth-hint";
      note.setAttribute("data-reg-prod-note", "");
      note.textContent = t("Регистрация создаёт аккаунт на основном сервере, не на бете.", "Registration creates your account on the main server, not beta.");
      reg.prepend(note);
    }
  }
  document.addEventListener("gluk:auth", function (e) { paint(e.detail); });
  paint(window.GlukAuth && window.GlukAuth.state);
})();
