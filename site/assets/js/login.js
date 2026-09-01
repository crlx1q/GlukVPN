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

  /* Куда вернуться после входа.
     Вход часто является чужим шагом: /login/?next=/link/?code=... открывается
     из десктопа и расширения. Раньше форма писала «Готово» и оставляла
     человека на месте — подтверждение входа с ПК упиралось в тупик.
     Разрешаем только собственные относительные пути: абсолютный URL из
     параметра — это open redirect, классическая дыра фишинга. */
  function nextTarget() {
    var m = /[?&]next=([^&]*)/.exec(window.location.search || "");
    if (!m) return "";
    var raw = "";
    try { raw = decodeURIComponent(m[1]); } catch (e) { return ""; }
    if (!raw || raw.charAt(0) !== "/") return "";
    if (raw.charAt(1) === "/" || raw.charAt(1) === "\\") return "";
    return raw;
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
  /* ROUND 9 (2.1): три режима на одной странице. Восстановление больше не
     отдельный лендинг: /login/?mode=recover открывает третью вкладку. */
  var initialMode = /[?&]mode=(register|recover)/.exec(location.search || "");
  if (initialMode) tab(initialMode[1]);

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
          form.reset();
          var next = nextTarget();
          if (next) {
            show("Готово. Возвращаемся…", "ok");
            window.location.href = next;
            return;
          }
          show("Готово. Вы вошли.", "ok");
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
  var hop = null;
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
      var loc = document.documentElement.getAttribute("data-lang") === "en" ? "en-GB" : "ru-RU";
      if (!isNaN(d)) until = d.toLocaleDateString(loc, { day: "2-digit", month: "long", year: "numeric" });
    }
    var T = window.GlukT || function (s) { return s; };
    var root = document.documentElement.getAttribute("data-base") || "/";
    panel.innerHTML =
      '<h2 class="auth-card__title">' + T("Вы уже вошли") + ", " + esc(u.username || "") + "</h2>" +
      '<p class="auth-card__sub">' + T("Открываем личный кабинет: устройства, карта подключений, подписка и оплата.") + "</p>" +
      '<div class="acct-panel__grid">' +
      stat(T("Подписка"), active ? T("Активна") : T("Нет"), active) +
      stat(T("Действует до"), esc(until), false) +
      stat(T("Устройства"), (st.devices || 0) + " / " + (u.maxDevices || 3), false) +
      stat(T("Номер аккаунта"), esc(u.publicId || "—"), false) +
      "</div>" +
      '<div class="acct-panel__actions">' +
      '<a class="btn btn--primary" href="' + root + 'app/">' + T("Открыть кабинет") + "</a>" +
      '<button class="btn btn--ghost" type="button" data-acct-logout>' + T("Выйти") + "</button>" +
      "</div>";
    /* Уже вошли, а нас звали ради ?next= — не показываем кабинет вообще,
       иначе подтверждение входа с ПК теряется за редиректом в /app/. */
    var next = nextTarget();
    if (next) {
      if (hop) clearTimeout(hop);
      hop = setTimeout(function () { location.replace(next); }, 250);
      return;
    }
    if (!/[?&]stay=1/.test(location.search)) {
      if (hop) clearTimeout(hop);
      hop = setTimeout(function () { location.replace(root + "app/"); }, 1100);
    }
  }

  document.addEventListener("gluk:auth", function (e) { paint(e.detail); });
  if (window.GlukAuth) paint(window.GlukAuth.state);
})();

/* =============== v3: плавное переключение Вход / Регистрация =============== */
(function () {
  var tabs = [].slice.call(document.querySelectorAll("[data-auth-tab]"));
  if (!tabs.length) return;
  var ind = document.querySelector("[data-auth-ind]");
  var title = document.querySelector("[data-auth-title]");
  var sub = document.querySelector("[data-auth-sub]");
  var panes = [].slice.call(document.querySelectorAll("[data-auth-pane]"));
  var COPY = {
    login: {
      t: "Вход в аккаунт",
      s: "Те же логин и пароль, что и в приложении GlukVPN.",
    },
    register: {
      t: "Создание аккаунта",
      s: "Почта и пароль, код из письма, подтверждение в Telegram — три шага.",
    },
    recover: {
      t: "Восстановление доступа",
      s: "Пришлём код на почту или в Telegram — куда удобнее.",
    },
  };
  var timer = null;

  function place(name) {
    if (!COPY[name]) name = "login";
    if (title && COPY[name]) title.textContent = COPY[name].t;
    if (sub && COPY[name]) sub.textContent = COPY[name].s;

    var active = null;
    tabs.forEach(function (t) {
      var on = t.getAttribute("data-auth-tab") === name;
      t.classList.toggle("is-active", on);
      t.setAttribute("aria-selected", on ? "true" : "false");
      if (on) active = t;
    });

    /* ROUND 9: раньше индикатор ездил на translateX(i * 100%). Это верно
       только для двух вкладок одинаковой ширины; с третьей
       («Восстановление») он уезжал за край. Теперь позиция и ширина
       берутся из измерений, поэтому вкладок может быть сколько угодно
       и любой длины после перевода.                                    */
    if (ind && active && active.offsetWidth) {
      ind.style.width = active.offsetWidth + "px";
      ind.style.transform = "translateX(" + active.offsetLeft + "px)";
    }

    if (timer) window.clearTimeout(timer);
    panes.forEach(function (p) {
      var on = p.getAttribute("data-auth-pane") === name;
      if (on) {
        p.hidden = false;
        requestAnimationFrame(function () {
          p.classList.add("is-in");
        });
      } else {
        p.hidden = false;
        p.classList.remove("is-in");
      }
    });
    timer = window.setTimeout(function () {
      panes.forEach(function (p) {
        if (p.getAttribute("data-auth-pane") !== name) p.hidden = true;
      });
    }, 320);
  }

  tabs.forEach(function (t) {
    t.addEventListener("click", function () {
      place(t.getAttribute("data-auth-tab"));
    });
  });

  var startMode = /[?&]mode=(register|recover)/.exec(window.location.search || "");
  place(startMode ? startMode[1] : "login");

  /* Внутрикарточные переходы («Забыли пароль?», «Регистрация»)
     переключают режим, а не уводят на другую страницу. href остаётся
     рабочим — ссылка должна открываться и в новой вкладке, и без JS. */
  Array.prototype.forEach.call(document.querySelectorAll("[data-auth-goto]"), function (link) {
    link.addEventListener("click", function (e) {
      if (e.metaKey || e.ctrlKey || e.shiftKey || e.button === 1) return;
      e.preventDefault();
      var mode = link.getAttribute("data-auth-goto");
      place(mode);
      try {
        history.replaceState(null, "", location.pathname + (mode === "login" ? "" : "?mode=" + mode));
      } catch (err) {}
    });
  });

  /* Ширина вкладки зависит от шрифта, а шрифт грузится позже скрипта. */
  window.addEventListener("resize", function () {
    var on = document.querySelector("[data-auth-tab].is-active");
    if (on) place(on.getAttribute("data-auth-tab"));
  });
  if (document.fonts && document.fonts.ready) {
    document.fonts.ready.then(function () {
      var on = document.querySelector("[data-auth-tab].is-active");
      if (on) place(on.getAttribute("data-auth-tab"));
    });
  }

  /* глаз: меняем иконку и подпись */
  var pw = document.querySelector("[data-pw-toggle]");
  if (pw) {
    pw.addEventListener("click", function () {
      var input = pw.parentNode ? pw.parentNode.querySelector("input") : null;
      var shown = !!input && input.type === "text";
      pw.classList.toggle("is-on", shown);
      pw.setAttribute("aria-label", shown ? "Скрыть пароль" : "Показать пароль");
    });
  }
})();
