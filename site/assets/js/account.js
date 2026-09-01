/* Личный кабинет /account/. Данные берём из window.GlukAuth (тот же аккаунт, что в приложении). */
(function () {
  "use strict";
  var views = [].slice.call(document.querySelectorAll("[data-acc-view]"));
  if (!views.length) return;

  var CFG = window.GLUK_CONFIG || {};
  var PLANS = (CFG.pricing && CFG.pricing.plans) || [];

  function view(name) {
    views.forEach(function (v) {
      v.hidden = v.getAttribute("data-acc-view") !== name;
    });
  }
  function set(key, value) {
    [].forEach.call(document.querySelectorAll('[data-acc="' + key + '"]'), function (el) {
      el.textContent = value;
    });
  }
  function planTitle(id) {
    if (!id) return null;
    var low = String(id).toLowerCase();
    for (var i = 0; i < PLANS.length; i++) {
      var p = PLANS[i];
      if (String(p.id || "").toLowerCase() === low) return p.name || p.title || id;
    }
    return String(id).charAt(0).toUpperCase() + String(id).slice(1);
  }
  function dateRu(value) {
    if (!value) return null;
    var d = new Date(value);
    if (isNaN(d.getTime())) return null;
    return d.toLocaleDateString("ru-RU", { day: "numeric", month: "long", year: "numeric" });
  }
  function daysLeft(value) {
    if (!value) return null;
    var d = new Date(value);
    if (isNaN(d.getTime())) return null;
    return Math.max(0, Math.ceil((d.getTime() - Date.now()) / 86400000));
  }
  function plural(n, one, few, many) {
    var a = Math.abs(n) % 100;
    var b = a % 10;
    if (a > 10 && a < 20) return many;
    if (b > 1 && b < 5) return few;
    if (b === 1) return one;
    return many;
  }
  function statusRu(s) {
    var map = {
      active: "Активна", trialing: "Пробный период", trial: "Пробный период",
      past_due: "Ожидает оплаты", canceled: "Отменена", cancelled: "Отменена",
      expired: "Истекла", inactive: "Не активна", suspended: "Приостановлена"
    };
    return map[String(s || "").toLowerCase()] || null;
  }

  function fill(state) {
    var u = state.user || {};
    var s = state.subscription || null;

    var name = u.username || u.email || "Аккаунт";
    set("name", name);
    set("initial", String(name).charAt(0).toUpperCase());
    set("email", u.email || "почта не указана");
    set("id", u.publicId ? "ID " + u.publicId : "");

    var acctStatus = statusRu(u.status) || (u.status === "active" ? "Активен" : "Активен");
    set("status", acctStatus);

    var plan = planTitle(s && (s.plan || s.planId || s.tier || s.name)) || "Free";
    set("plan", plan);
    set("stat-plan", plan);

    var sub = statusRu(s && s.status) || (s ? "Активна" : "Без подписки");
    set("sub-status", sub);

    var until = s && (s.expiresAt || s.currentPeriodEnd || s.validUntil || s.endsAt || s.expiryDate);
    var untilRu = dateRu(until);
    set("until", untilRu || "бессрочно");

    var left = daysLeft(until);
    set("left", left === null ? "—" : left + " " + plural(left, "день", "дня", "дней"));
    set("stat-days", left === null ? "∞" : String(left));
    set("stat-days-hint", left === null ? "без ограничения" : plural(left, "день", "дня", "дней"));
    set("plan-note", s
      ? "Тариф синхронизирован с приложением: изменения появляются на всех устройствах сразу."
      : "Сейчас активен бесплатный доступ. Тариф можно поднять в любой момент.");

    var startRaw = s && (s.startedAt || s.currentPeriodStart || s.createdAt);
    var start = startRaw ? new Date(startRaw).getTime() : null;
    var end = until ? new Date(until).getTime() : null;
    var wrap = document.querySelector('[data-acc="progress-wrap"]');
    var bar = document.querySelector('[data-acc="progress"]');
    if (wrap && bar && start && end && end > start) {
      var pct = Math.min(100, Math.max(0, ((Date.now() - start) / (end - start)) * 100));
      wrap.hidden = false;
      bar.style.width = (100 - pct).toFixed(1) + "%";
    } else if (wrap) {
      wrap.hidden = true;
    }

    var used = typeof state.devices === "number" ? state.devices : 0;
    var max = u.maxDevices || 3;
    set("dev-count", used + " / " + max);
    set("stat-devices", used + " / " + max);
    var db = document.querySelector('[data-acc="dev-bar"]');
    if (db) db.style.width = Math.min(100, (used / Math.max(1, max)) * 100).toFixed(0) + "%";

    var sess = u.maxConcurrentSessions || 1;
    set("sessions", "до " + sess);
    set("stat-sessions", String(sess));
    set("stat-sessions-hint", "одновременно");
    set("channel", (window.GlukAuth && window.GlukAuth.channel === "prod") ? "Основной" : "Бета");

    view("in");
  }

  function apply(state) {
    if (!state || state.status === "loading") { view("loading"); return; }
    if (state.status === "in") { fill(state); return; }
    view("guest");
  }

  document.addEventListener("gluk:auth", function (e) { apply(e.detail); });
  document.addEventListener("click", function (e) {
    var btn = e.target.closest && e.target.closest("[data-acc-logout]");
    if (!btn) return;
    e.preventDefault();
    if (window.GlukAuth) window.GlukAuth.logout();
    view("guest");
  });

  function boot() {
    if (!window.GlukAuth) { view("guest"); return; }
    apply(window.GlukAuth.state);
  }
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", boot);
  } else {
    boot();
  }
})();

/* ==========================================================================
   РАУНД 9 (2.2) — блок «Безопасность аккаунта» в личном кабинете /app/.

   Эндпоинты появились в раунде 8, но в кабинете на их месте стояла ссылка
   «Сменить пароль» → /support/. Человек нажимал её, попадал на форму
   обращения и писал в поддержку то, что сервер умел сделать сам.

   Три действия, три разные модели доверия — и это видно в коде:
     • пароль   — POST /api/auth/password   { currentPassword, password }
                  Токена доступа недостаточно: сервер требует старый пароль,
                  чтобы одолженный разблокированный ноутбук не означал потерю
                  аккаунта. Все прочие сессии после смены отзываются.
     • почта    — POST /api/auth/email      { email }        → код на новый адрес
                  POST /api/auth/email/confirm { code }      → адрес заменён
                  Новый адрес вступает в силу только после кода: иначе украденный
                  токен молча перевёл бы восстановление на чужой ящик. Адрес
                  хранится на записи кода, поэтому подменить его между шагами
                  нельзя — на втором шаге отправляется только код.
     • Telegram — POST /api/auth/telegram/link (без тела) → { url, code }
                  Дальше всё делает бот, ровно как при регистрации.

   Ошибки сервера приходят по-английски (это внутренний контракт API). Здесь
   они переводятся по смыслу: пользователю не должно доставаться «The current
   password is incorrect» в русском интерфейсе.
   ========================================================================== */
(function () {
  "use strict";

  var box = document.querySelector("[data-sec]");
  if (!box) return;

  var EN = String(document.documentElement.getAttribute("lang") || "ru")
    .toLowerCase().indexOf("en") === 0;
  function t(ru, en) { return EN ? en : ru; }

  var tabs = [].slice.call(box.querySelectorAll("[data-sec-open]"));
  var panes = [].slice.call(box.querySelectorAll("[data-sec-form]"));
  var pwForm = box.querySelector('[data-sec-form="password"]');
  var mailForm = box.querySelector('[data-sec-form="email"]');
  var codeField = mailForm && mailForm.querySelector("[data-sec-code]");
  var mailBtn = mailForm && mailForm.querySelector('button[type="submit"]');
  var tgBtn = box.querySelector("[data-sec-tg]");
  var tgOut = box.querySelector("[data-sec-tg-out]");
  var tgLink = box.querySelector("[data-sec-tg-link]");
  var tgCode = box.querySelector("[data-sec-tg-code]");

  /* Второй шаг смены почты. Пока false — кнопка просит код, после — подтверждает. */
  var awaitingCode = false;

  function msg(name, text, kind) {
    var el = box.querySelector('[data-sec-msg="' + name + '"]');
    if (!el) return;
    el.textContent = text || "";
    el.className = "auth-msg" + (text && kind ? " is-" + kind : "");
  }

  function open(name) {
    var target = null;
    panes.forEach(function (p) {
      var mine = p.getAttribute("data-sec-form") === name;
      if (mine && !p.hidden) { name = null; }        // повторное нажатие — закрыть
      if (mine) target = p;
    });
    panes.forEach(function (p) {
      p.hidden = p.getAttribute("data-sec-form") !== name;
    });
    tabs.forEach(function (b) {
      var on = b.getAttribute("data-sec-open") === name;
      b.classList.toggle("is-active", on);
      b.setAttribute("aria-expanded", on ? "true" : "false");
    });
    if (name && target) {
      var first = target.querySelector("input, button");
      if (first && first.focus) { try { first.focus({ preventScroll: true }); } catch (e) {} }
    }
  }

  function busy(form, on, label) {
    var btn = form.querySelector("button[type=submit]") || form.querySelector("button");
    if (!btn) return;
    btn.disabled = !!on;
    if (label != null) btn.textContent = label;
  }

  /* --------------------------------------------------------------- ошибки */
  /* Сначала по смыслу текста (сервер отвечает конкретно и это ценно),
     потом по коду состояния — как запасной вариант. */
  function byText(raw) {
    var s = String(raw || "");
    if (/current password is incorrect/i.test(s))
      return t("Текущий пароль неверный.", "The current password is incorrect.");
    if (/at least 8 characters/i.test(s))
      return t("Новый пароль — минимум 8 символов.", "The new password must be at least 8 characters.");
    if (/valid email address/i.test(s))
      return t("Введите корректный адрес почты.", "Enter a valid email address.");
    if (/already in use/i.test(s))
      return t("Эта почта уже привязана к другому аккаунту.", "This email already belongs to another account.");
    if (/confirmation code is required/i.test(s))
      return t("Введите код из письма.", "Enter the code from the email.");
    if (/code/i.test(s) && /(invalid|expired|incorrect|wrong)/i.test(s))
      return t("Код неверный или истёк. Запросите новый.", "The code is wrong or expired. Request a new one.");
    if (/email confirmation is not available/i.test(s))
      return t("Отправка писем сейчас недоступна. Напишите в поддержку.", "Email delivery is unavailable right now. Contact support.");
    if (/telegram is not available/i.test(s))
      return t("Telegram-бот на этом сервере не настроен.", "The Telegram bot is not configured on this server.");
    return null;
  }

  function human(e) {
    var status = (e && e.status) || 0;
    var known = byText(e && e.message);
    if (known) return known;
    if (status === 0)
      return t("Нет связи с сервером. Проверьте соединение.", "No connection to the server. Check your network.");
    if (status === 429) {
      var wait = e && e.retryAfter
        ? " " + t("Повторите через ", "Try again in ") + e.retryAfter + t(" с.", " s.")
        : "";
      return t("Слишком много попыток.", "Too many attempts.") + wait;
    }
    if (status === 401 || status === 403)
      return t("Сессия истекла — войдите заново.", "Your session has expired — sign in again.");
    if (status === 409)
      return t("Эта почта уже занята.", "This email is already taken.");
    if (status === 503)
      return t("Сервис временно недоступен. Попробуйте позже.", "The service is temporarily unavailable. Try again later.");
    if (status >= 500)
      return t("Ошибка на сервере. Мы уже смотрим.", "Server error. We are looking into it.");
    return (e && e.message)
      || t("Не получилось. Попробуйте ещё раз.", "That did not work. Please try again.");
  }

  function call(path, body) {
    if (!window.GlukAuth || !window.GlukAuth.call) {
      return Promise.reject({ status: 401, code: "no_session" });
    }
    return window.GlukAuth.call(path, { method: "POST", body: body || {} });
  }

  /* ----------------------------------------------------------- пароль */
  if (pwForm) {
    pwForm.addEventListener("submit", function (e) {
      e.preventDefault();
      var cur = pwForm.currentPassword.value;
      var pw = pwForm.password.value;
      var pw2 = pwForm.password2.value;
      if (pw.length < 8) {
        msg("password", t("Новый пароль — минимум 8 символов.", "The new password must be at least 8 characters."), "err");
        return;
      }
      if (pw !== pw2) {
        msg("password", t("Пароли не совпадают.", "The passwords do not match."), "err");
        return;
      }
      if (pw === cur) {
        msg("password", t("Новый пароль совпадает с текущим.", "The new password is the same as the current one."), "err");
        return;
      }
      var label = t("Сохранить пароль", "Save password");
      msg("password", "");
      busy(pwForm, true, t("Сохраняем…", "Saving…"));
      call("/api/auth/password", { currentPassword: cur, password: pw }).then(
        function (res) {
          busy(pwForm, false, label);
          pwForm.reset();
          var n = res && res.revokedTokens;
          msg("password", t("Пароль изменён.", "Password changed.") + (n
            ? " " + t("Остальные сессии завершены: ", "Other sessions signed out: ") + n + "."
            : ""), "ok");
        },
        function (err) {
          busy(pwForm, false, label);
          msg("password", human(err), "err");
        }
      );
    });
  }

  /* ------------------------------------------------------------- почта */
  if (mailForm) {
    mailForm.addEventListener("submit", function (e) {
      e.preventDefault();

      if (awaitingCode) {
        var code = String(mailForm.code.value || "").replace(/\D+/g, "");
        if (code.length !== 6) {
          msg("email", t("Код состоит из шести цифр.", "The code is six digits."), "err");
          return;
        }
        busy(mailForm, true, t("Проверяем…", "Checking…"));
        call("/api/auth/email/confirm", { code: code }).then(
          function () {
            awaitingCode = false;
            if (codeField) codeField.hidden = true;
            mailForm.reset();
            busy(mailForm, false, t("Прислать код", "Send code"));
            msg("email", t("Почта обновлена.", "Email updated."), "ok");
            /* Строки «Почта» и «Подтверждение почты» рисует app.js по данным
               /api/auth/me — перечитываем, иначе в карточке остался бы старый адрес. */
            if (window.GlukAuth && window.GlukAuth.refresh) window.GlukAuth.refresh();
          },
          function (err) {
            busy(mailForm, false, t("Подтвердить", "Confirm"));
            msg("email", human(err), "err");
          }
        );
        return;
      }

      var email = String(mailForm.email.value || "").trim();
      if (!/^[^@\s]+@[^@\s.]+\.[^@\s]+$/.test(email)) {
        msg("email", t("Введите корректный адрес почты.", "Enter a valid email address."), "err");
        return;
      }
      msg("email", "");
      busy(mailForm, true, t("Отправляем…", "Sending…"));
      call("/api/auth/email", { email: email }).then(
        function (res) {
          awaitingCode = true;
          if (codeField) codeField.hidden = false;
          busy(mailForm, false, t("Подтвердить", "Confirm"));
          var input = codeField && codeField.querySelector("input");
          if (input) { input.setAttribute("required", "required"); try { input.focus(); } catch (e2) {} }
          /* delivered:false — сервер честно говорит, что письмо не ушло.
             Молчать здесь нельзя: человек будет ждать код, которого нет. */
          if (res && res.delivered === false) {
            msg("email", t(
              "Код создан, но письмо отправить не удалось. Напишите в поддержку — подтвердим вручную.",
              "The code was created but the email could not be sent. Contact support and we will confirm it manually."
            ), "err");
          } else {
            msg("email", t("Код отправлен на ", "Code sent to ")
              + ((res && res.pendingEmail) || email) + ".", "ok");
          }
        },
        function (err) {
          busy(mailForm, false, t("Прислать код", "Send code"));
          msg("email", human(err), "err");
        }
      );
    });
  }

  /* ---------------------------------------------------------- Telegram */
  if (tgBtn) {
    tgBtn.addEventListener("click", function () {
      var label = t("Получить ссылку на бота", "Get the bot link");
      msg("telegram", "");
      tgBtn.disabled = true;
      tgBtn.textContent = t("Готовим ссылку…", "Preparing the link…");
      call("/api/auth/telegram/link", {}).then(
        function (res) {
          tgBtn.disabled = false;
          tgBtn.textContent = t("Получить новую ссылку", "Get a new link");
          if (tgLink && res && res.url) {
            tgLink.setAttribute("href", res.url);
            tgLink.textContent = t("бота", "the bot");
          }
          if (tgCode) tgCode.textContent = (res && res.code) || "";
          if (tgOut) tgOut.hidden = false;
          msg("telegram", t(
            "Ссылка готова. Откройте бота и нажмите «Поделиться контактом» — привязка обновится сама.",
            "The link is ready. Open the bot and press “Share contact” — the binding updates itself."
          ), "ok");
          if (res && res.url) { try { window.open(res.url, "_blank", "noopener"); } catch (e3) {} }
        },
        function (err) {
          tgBtn.disabled = false;
          tgBtn.textContent = label;
          msg("telegram", human(err), "err");
        }
      );
    });
  }

  tabs.forEach(function (b) {
    b.setAttribute("aria-expanded", "false");
    b.addEventListener("click", function () { open(b.getAttribute("data-sec-open")); });
  });
})();
