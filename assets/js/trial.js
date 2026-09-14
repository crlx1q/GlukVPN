/* ==========================================================================
   GlukVPN — акция «Пробный период Basic за 1 ₽».

   Один скрипт на три места, потому что правило видимости у них общее:

     [data-trial-banner]  баннер на главной
     [data-trial-strip]   полоса над тарифами + метка на карточке Basic
     [data-trial-page]    страница /trial с датами

   Решает всё сервер. GET /api/billing/trial отдаёт цену, длительность, даты
   и eligibility.reason — чего именно не хватает этому посетителю
   ("sign_in_required", "telegram_required", "already_used", ...). Поэтому
   здесь нет ни одной проверки «новый ли аккаунт»: страница показывает то,
   что ответил бэкенд, а активирует акцию POST /api/billing/trial/claim,
   который проверяет всё заново. Подделать состояние в консоли можно, выдать
   себе подписку — нет.

   Даты тоже считает сервер: часы в браузере бывают сбиты, а «доступ до
   16.09.2026» — обещание, которое должно совпадать с тем, что в базе.

   Списание одно и сразу (1 ₽), автопродления не существует, поэтому третий
   шаг таймлайна — окончание подписки, а не «с вас спишут».
   ========================================================================== */
(function () {
  "use strict";

  var banners = list("[data-trial-banner]");
  var strips = list("[data-trial-strip]");
  var pages = list("[data-trial-page]");
  if (!banners.length && !strips.length && !pages.length) return;

  var EN = (document.documentElement.getAttribute("data-lang") || "ru").toLowerCase() === "en";
  var root = document.documentElement.getAttribute("data-base") || "/";
  var T = window.GlukT || function (s) { return s; };

  /* Акция появилась позже словаря i18n.js — её подписи держим парами здесь. */
  function L(ru, en) {
    return EN ? en : ru;
  }

  /* Кому показываем сам баннер: тем, кто ещё может получить акцию. Гость —
     тоже «может»: ему и адресован призыв зарегистрироваться. */
  var PROMO_REASONS = { ok: 1, sign_in_required: 1, telegram_required: 1 };

  /* currency — валюта, в которой сервер выдал карточки тарифов (приходит
     с событием gluk:plans). Акция обязана быть в ней же: «$0.10» рядом
     с «790 ₸» — это и была рассинхронизация на странице тарифов. */
  var state = { offer: null, enabled: false, authStatus: "", busy: false, currency: "" };

  /* ------------------------------------------------------------- утилиты */
  function list(sel) {
    return Array.prototype.slice.call(document.querySelectorAll(sel));
  }

  function esc(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }

  /* Английские страницы живут в /en/, поэтому ссылки строим от data-base. */
  function href(u) {
    if (!u) return root;
    if (/^(https?:|mailto:|tel:|#)/.test(u)) return u;
    if (u.charAt(0) === "/") return (root === "/" ? "" : root.replace(/\/$/, "")) + u;
    return u;
  }

  function param(name) {
    var m = new RegExp("[?&]" + name + "=([^&]*)").exec(location.search || "");
    return m ? decodeURIComponent(m[1]) : "";
  }

  function daysLabel(n) {
    n = Number(n) || 0;
    if (window.GlukI18n && typeof window.GlukI18n.days === "function") {
      try {
        var out = window.GlukI18n.days(n);
        if (out) return out;
      } catch (e) {}
    }
    if (EN) return n + (n === 1 ? " day" : " days");
    var d10 = n % 10;
    var d100 = n % 100;
    var word = d10 === 1 && d100 !== 11
      ? "день"
      : d10 >= 2 && d10 <= 4 && (d100 < 10 || d100 >= 20) ? "дня" : "дней";
    return n + " " + word;
  }

  function fmtDate(iso) {
    var d = new Date(iso);
    if (isNaN(d.getTime())) return "";
    try {
      return d.toLocaleDateString(
        EN ? "en-GB" : "ru-RU",
        EN
          ? { day: "numeric", month: "short", year: "numeric" }
          : { day: "2-digit", month: "2-digit", year: "numeric" }
      );
    } catch (e) {
      return String(iso).slice(0, 10);
    }
  }

  /* Цену показываем в валюте рынка: сервер уже посчитал её по стране (СНГ —
     рубли, Казахстан — тенге, остальной мир — доллар). Приписку «(≈ 100 ₸ ·
     $0.10)» рядом с суммой не пишем: она ничего не добавляет тому, кто и так
     видит цену в своих деньгах. */
  /* Валюта страницы — та, в которой сервер отдал тарифы. Своей догадки
     до ответа не выдумываем и GlukPrice.currency не берём: она считается
     из языка страницы и на английской версии всегда даёт USD. */
  function pageCurrency() {
    return String(state.currency || "").toUpperCase();
  }

  /* Та же сумма в нужной валюте: сервер присылает все эквиваленты по
     матрице цен (100 ₸ / 10 ₽ / $0.10), поэтому пересчёты на клиенте
     не нужны — достаточно выбрать готовую строку. */
  function equivalent(offer, currency) {
    var list = (offer && offer.equivalents) || [];
    for (var i = 0; i < list.length; i++) {
      if (String(list[i].currency || "").toUpperCase() === currency) return list[i];
    }
    return null;
  }

  function priceLabel(offer) {
    var price = (offer && offer.price) || {};
    var wanted = pageCurrency();
    /* Валюта страницы важнее валюты оффера: запрос акции может уйти
       раньше, чем придут тарифы, и тогда сервер ответил по своему
       определению страны. На экране двух валют быть не должно. */
    if (wanted && price.currency && String(price.currency).toUpperCase() !== wanted) {
      var same = equivalent(offer, wanted);
      if (same && same.label) return same.label;
    }
    return price.label || (offer && offer.charge && offer.charge.label) || "";
  }

  /* Списание идёт рублями — это единственная валюта шлюза. Говорим об этом
     ровно один раз и только там, где цена показана в другой валюте: на /trial,
     где человек решает платить. */
  function chargeLabel(offer) {
    return (offer && offer.charge && offer.charge.label) || "";
  }

  function chargeNote(offer) {
    var price = (offer && offer.price) || {};
    var charge = (offer && offer.charge) || {};
    /* Сравниваем с валютой страницы: именно в ней человек видит цену. */
    var shown = pageCurrency() || String(price.currency || "").toUpperCase();
    if (!charge.label || !shown || shown === String(charge.currency || "").toUpperCase()) return "";
    return L(
      "Списание пройдёт в рублях: " + charge.label +
        " через СБП или картой по курсу вашего банка.",
      "The charge settles in roubles: " + charge.label +
        " by SBP or card, at your bank's rate."
    );
  }


  function planName(offer) {
    return (offer && offer.planName) || "Basic";
  }

  function signUpUrl() {
    /* Отдельная /register/ есть только в русской версии: на английских
       страницах вход и регистрация живут на одной. */
    var page = EN ? "/login/" : "/register/";
    return href(page) + "?next=" + encodeURIComponent(href("/trial/"));
  }

  /* ----------------------------------------------------- баннер и полоса */
  function bannerText(offer) {
    var days = daysLabel(offer.days);
    var price = priceLabel(offer);
    return L(
      "Новым аккаунтам с подтверждённым Telegram — " + days + " " + planName(offer) + " за " + price +
        ". Автосписаний нет: подписка просто закончится.",
      "New accounts with a confirmed Telegram get " + days + " of " + planName(offer) + " for " + price +
        ". No auto-renewal — the trial simply ends."
    );
  }

  function renderBanner(host, offer) {
    var days = daysLabel(offer.days);
    host.innerHTML =
      '<div class="trial-banner__copy">' +
        '<span class="trial-banner__badge">' + esc(L("Акция", "Offer")) + "</span>" +
        '<h2 class="trial-banner__title">' +
          esc(L("Пробный период " + planName(offer) + " — " + days + " за ", "Try " + planName(offer) + " for " + days + " — ")) +
          '<span class="trial-banner__price">' + esc(priceLabel(offer)) + "</span>" +
        "</h2>" +
        '<p class="trial-banner__text">' + esc(bannerText(offer)) + "</p>" +
      "</div>" +
      '<div class="trial-banner__actions">' +
        '<a class="btn btn--primary btn--lg" href="' + esc(href("/trial/")) + '">' + esc(L("Попробуйте", "Try it")) + "</a>" +
        '<a class="trial-banner__more" href="' + esc(href("/pricing/")) + '">' + esc(L("Смотреть тарифы", "See pricing")) + "</a>" +
      "</div>";
    host.hidden = false;
  }

  function renderStrip(host, offer) {
    var days = daysLabel(offer.days);
    host.innerHTML =
      '<span class="trial-strip__badge">' + esc(days + " \u00b7 " + priceLabel(offer)) + "</span>" +
      '<p class="trial-strip__text">' +
        esc(L("Пробный период для новых аккаунтов: ", "Trial for new accounts: ")) +
        "<b>" + esc(planName(offer)) + "</b>" +
        esc(L(" на " + days + " за " + priceLabel(offer) + ", дальше — обычная цена.",
              " for " + days + " at " + priceLabel(offer) + ", then the usual price.")) +
      "</p>" +
      '<a class="btn btn--primary" href="' + esc(href("/trial/")) + '">' + esc(L("Попробуйте", "Try it")) + "</a>";
    host.hidden = false;
  }

  /* Метка на самой карточке тарифа. Карточки рисует billing.js и
     перерисовывает при смене периода — поэтому вешаем метку заново на
     каждое событие gluk:plans, а не один раз при загрузке. */
  function decorateCards(offer, show) {
    var base = String((offer && offer.planCode) || "basic").toLowerCase();
    var days = offer ? daysLabel(offer.days) : "";
    list("[data-plans] [data-plan-code]").forEach(function (card) {
      var old = card.querySelector(".plan__trial");
      if (old && old.parentNode) old.parentNode.removeChild(old);
      if (!show || !offer) return;
      /* Только сам Basic: у квартального basic_3m своей акции нет. */
      if (String(card.getAttribute("data-plan-code") || "").toLowerCase() !== base) return;
      var link = document.createElement("a");
      link.className = "plan__trial";
      link.href = href("/trial/");
      link.textContent = L(
        "Новым аккаунтам: " + days + " за " + priceLabel(offer),
        "New accounts: " + days + " for " + priceLabel(offer)
      );
      var price = card.querySelector(".plan__price");
      if (price) card.insertBefore(link, price);
      else card.insertBefore(link, card.firstChild);
    });
  }

  /* ------------------------------------------------------- страница /trial */
  function fill(host, sel, text) {
    var el = host.querySelector(sel);
    if (el) el.textContent = text;
  }

  function step(cls, date, title, text) {
    return '<li class="trial-step' + (cls ? " " + cls : "") + '">' +
      (date ? '<span class="trial-step__date">' + esc(date) + "</span>" : "") +
      '<p class="trial-step__title">' + esc(title) + "</p>" +
      '<p class="trial-step__text">' + esc(text) + "</p>" +
      "</li>";
  }

  function renderTimeline(host, offer) {
    var box = host.querySelector("[data-trial-timeline]");
    if (!box) return;
    var tl = offer.timeline || {};
    var days = daysLabel(offer.days);
    var reminder = daysLabel(tl.reminderDays || 2);
    box.innerHTML =
      step(
        "",
        L("Сегодня, " + fmtDate(tl.startsAt), "Today, " + fmtDate(tl.startsAt)),
        L(planName(offer) + " на " + days + " за " + chargeLabel(offer), planName(offer) + " for " + days + " at " + chargeLabel(offer)),
        L("Один платёж " + priceLabel(offer) + " — и доступ открывается сразу после подтверждения оплаты.",
          "A single " + priceLabel(offer) + " payment, and access opens as soon as it is confirmed.")
      ) +
      step(
        "",
        fmtDate(tl.reminderAt),
        L("Напомним за " + reminder, "Reminder " + reminder + " before the end"),
        L("Сообщение в Telegram: пробный период заканчивается, можно продлить обычной подпиской.",
          "A Telegram message: the trial is ending and can be continued with a normal subscription.")
      ) +
      step(
        "trial-step--end",
        fmtDate(tl.endsAt),
        L("Пробный период заканчивается", "The trial ends"),
        L("Автосписаний нет — карта больше не понадобится. Аккаунт останется, тариф вернётся к Free.",
          "Nothing is charged again — the card is not stored. The account stays; the plan returns to Free.")
      );
  }

  function claimBox(offer) {
    var el = offer.eligibility || {};
    var reason = String(el.reason || (offer.enabled ? "ok" : "offer_disabled"));
    var price = chargeLabel(offer);
    var days = daysLabel(offer.days);
    var pricing = '<a class="btn btn--ghost btn--lg" href="' + esc(href("/pricing/")) + '">' + esc(L("Смотреть тарифы", "See pricing")) + "</a>";

    /* Биллинг выключен — активировать нечего, но цену показать честно можно. */
    if (!state.enabled) {
      return {
        cta: '<span class="btn btn--muted btn--lg" aria-disabled="true">' + esc(T("Скоро")) + "</span>",
        note: T("Оплата откроется вместе с запуском биллинга")
      };
    }

    if (reason === "ok") {
      var left = typeof el.daysLeft === "number" && el.daysLeft > 0
        ? L(" Активировать можно ещё " + daysLabel(el.daysLeft) + ".", " " + daysLabel(el.daysLeft) + " left to claim it.")
        : "";
      return {
        cta: '<button class="btn btn--primary btn--lg" type="button" data-trial-claim-btn>' +
          esc(L("Подключить за " + price, "Get it for " + price)) + "</button>",
        note: L(
          "Оплата на защищённой странице TabPay — СБП или карта. Данные карты не проходят через наш сервер." + left,
          "Payment happens on TabPay's own secure page — SBP or card. Card details never touch our server." + left
        )
      };
    }

    if (reason === "sign_in_required") {
      return {
        cta: '<a class="btn btn--primary btn--lg" href="' + esc(signUpUrl()) + '">' + esc(L("Создать аккаунт", "Create an account")) + "</a>",
        note: L(
          "Нужен новый аккаунт с подтверждённым Telegram — это одна минута. Акция доступна первые " +
            daysLabel(offer.eligibilityDays) + " после регистрации.",
          "You need a new account with a confirmed Telegram — that takes a minute. The offer is open for the first " +
            daysLabel(offer.eligibilityDays) + " after sign-up."
        )
      };
    }

    if (reason === "telegram_required") {
      return {
        cta: '<a class="btn btn--primary btn--lg" href="' + esc(href("/app/")) + '">' + esc(L("Подтвердить Telegram", "Confirm Telegram")) + "</a>",
        note: L(
          "Подтверждение занимает минуту и делается в кабинете: один номер — один аккаунт, иначе акцию можно было бы получать бесконечно.",
          "Confirmation takes a minute in the dashboard: one phone, one account — otherwise the offer could be claimed forever."
        )
      };
    }

    if (reason === "window_passed") {
      return {
        cta: pricing,
        note: L(
          "Акция для новых аккаунтов: активировать её можно первые " + daysLabel(offer.eligibilityDays) + " после регистрации.",
          "The offer is for new accounts: it can be claimed within " + daysLabel(offer.eligibilityDays) + " of signing up."
        )
      };
    }

    if (reason === "already_used") {
      return {
        cta: pricing,
        note: L("Этот аккаунт уже пользовался пробным периодом — он даётся один раз.",
                "This account has already used the trial — it is a one-time offer.")
      };
    }

    if (reason === "already_subscribed") {
      return {
        cta: '<a class="btn btn--ghost btn--lg" href="' + esc(href("/app/")) + '">' + esc(L("Открыть кабинет", "Open the dashboard")) + "</a>",
        note: L("У аккаунта уже есть активная подписка — пробный период ей ничего не добавит.",
                "This account already has an active subscription, so a preview of it would add nothing.")
      };
    }

    return {
      cta: pricing,
      note: L("Акция сейчас не идёт. Тарифы работают как обычно.", "The offer is not running right now. The usual plans are available.")
    };
  }

  function renderClaim(host, offer) {
    var box = host.querySelector("[data-trial-claim]");
    if (!box) return;
    var parts = claimBox(offer);
    box.innerHTML = parts.cta + '<p class="trial-claim__note">' + esc(parts.note) + "</p>";
  }

  function renderPage(host, offer) {
    var days = daysLabel(offer.days);
    fill(host, "[data-trial-plan]", planName(offer) + " \u00b7 " + days);
    fill(host, "[data-trial-amount]", priceLabel(offer));
    fill(host, "[data-trial-per]", L("за " + days, "for " + days));
    /* Не эквиваленты, а одна строка про валюту списания — и только тем,
       кому цена показана не в рублях. Пустую строку скрываем: пустой абзац
       оставляет дырку между ценой и таймлайном. */
    var note = host.querySelector("[data-trial-equiv]");
    if (note) {
      note.textContent = chargeNote(offer);
      note.hidden = !note.textContent;
    }
    renderTimeline(host, offer);
    renderClaim(host, offer);
  }

  function status(kind, html) {
    pages.forEach(function (host) {
      var box = host.querySelector("[data-trial-status]");
      if (!box) return;
      if (!html) {
        box.hidden = true;
        box.innerHTML = "";
        return;
      }
      box.className = "trial-status" + (kind ? " trial-status--" + kind : "");
      box.innerHTML = html;
      box.hidden = false;
    });
  }

  /* -------------------------------------------------------- активация */
  var CLAIM_ERRORS = {
    trial_offer_disabled: ["Акция сейчас не идёт.", "The offer is not running right now."],
    trial_sign_in_required: ["Войдите в аккаунт, чтобы активировать акцию.", "Sign in to claim the offer."],
    trial_telegram_required: ["Подтвердите Telegram в кабинете — и возвращайтесь.", "Confirm your Telegram in the dashboard, then come back."],
    trial_window_passed: ["Акция доступна только новым аккаунтам.", "The offer is only available to new accounts."],
    trial_already_used: ["Этот аккаунт уже пользовался пробным периодом.", "This account has already used the trial."],
    trial_already_subscribed: ["У аккаунта уже есть активная подписка.", "This account already has an active subscription."]
  };

  function errorText(e) {
    var code = e && e.code ? String(e.code) : "";
    if (CLAIM_ERRORS[code]) return L(CLAIM_ERRORS[code][0], CLAIM_ERRORS[code][1]);
    if (!e) return L("Не получилось. Попробуйте ещё раз.", "That did not work. Please try again.");
    if (e.status === 0) return T("Не удалось связаться с сервером. Проверьте соединение.");
    if (e.status === 401 || e.status === 403) return T("Сессия истекла — войдите заново.");
    if (e.status === 429) return T("Слишком много запросов. Попробуйте через минуту.");
    if (e.status >= 500) return T("Сервис временно недоступен. Попробуйте позже.");
    return e.message || L("Не получилось. Попробуйте ещё раз.", "That did not work. Please try again.");
  }

  function claim(btn) {
    var A = window.GlukAuth;
    if (!A) {
      window.location.href = signUpUrl();
      return;
    }
    /* Сессия ещё проверяется — дождёмся ответа один раз и повторим. */
    if (A.state && A.state.status === "loading") {
      btn.disabled = true;
      var once = function () {
        document.removeEventListener("gluk:auth", once);
        btn.disabled = false;
        claim(btn);
      };
      document.addEventListener("gluk:auth", once);
      return;
    }
    if (!A.isAuthed || !A.isAuthed()) {
      window.location.href = signUpUrl();
      return;
    }
    if (state.busy) return;

    var label = btn.textContent;
    state.busy = true;
    btn.disabled = true;
    btn.textContent = T("Создаём заказ…");
    status("", "");
    A.call("/api/billing/trial/claim", { method: "POST", body: {} }).then(
      function (res) {
        var order = (res && res.order) || {};
        if (res && res.paymentUrl) {
          btn.textContent = T("Переходим к оплате…");
          window.location.href = res.paymentUrl;
          return;
        }
        state.busy = false;
        btn.disabled = false;
        btn.textContent = label;
        /* Заказ уже оплачен: сервер сверился со шлюзом и сам включил подписку —
           платить второй раз не за что. */
        if (String(order.status || "") === "PAID") {
          status(
            "ok",
            "<b>" + esc(L("Оплата уже прошла", "That payment already went through")) + "</b>" +
              "<p>" + esc(L("Пробный период уже включён.", "The trial is already switched on.")) +
              ' <a href="' + esc(href("/app/")) + '">' + esc(L("Открыть кабинет", "Open the dashboard")) + "</a></p>"
          );
          if (A.refresh) A.refresh();
          load();
          return;
        }
        /* Ручной режим оплаты: заказ есть, дальше — инструкция из ответа. */
        status(
          "ok",
          "<b>" + esc(T("Заказ создан")) + (order.id ? " \u00b7 #" + esc(String(order.id).slice(0, 8)) : "") + "</b>" +
            "<p>" + esc(res && res.instructions ? res.instructions : L("Инструкции по оплате пришлём в поддержке.", "We will send the payment details in support.")) + "</p>"
        );
      },
      function (e) {
        state.busy = false;
        btn.disabled = false;
        btn.textContent = label;
        status("err", "<b>" + esc(L("Не удалось активировать акцию", "Could not claim the offer")) + "</b><p>" + esc(errorText(e)) + "</p>");
        /* Отказ мог измениться (акцию выключили, подписка появилась) —
           перечитываем состояние, чтобы кнопка стала честной. */
        load();
      }
    );
  }

  /* Возврат со страницы оплаты: TabPay присылает браузер на /trial/?paid=1
     или ?failed=1. Подписку выдаёт вебхук, но его доставка может опоздать или
     потеряться, поэтому здесь мы просим сервер сверить открытые платежи со
     шлюзом: заплативший не должен видеть «подписки нет», а отклонённая попытка
     не должна мешать следующей. */
  function syncOrders(done) {
    var A = window.GlukAuth;
    if (!A || !A.call) {
      done(null);
      return;
    }
    /* Сессия ещё проверяется — без токена сверка ничего не даст, ждём ответ. */
    if (A.state && A.state.status === "loading") {
      var once = function () {
        document.removeEventListener("gluk:auth", once);
        syncOrders(done);
      };
      document.addEventListener("gluk:auth", once);
      return;
    }
    if (!A.isAuthed || !A.isAuthed()) {
      done(null);
      return;
    }
    A.call("/api/billing/orders/sync", { method: "POST", body: {} }).then(
      function (res) { done(res || null); },
      function () { done(null); }
    );
  }

  function paidOrder(res) {
    var found = null;
    ((res && res.orders) || []).forEach(function (o) {
      if (!found && o && String(o.status || "") === "PAID") found = o;
    });
    return found;
  }

  function gatewayReturn() {
    if (param("paid")) {
      status("ok", "<b>" + esc(L("Проверяем платёж…", "Checking the payment…")) + "</b>");
      syncOrders(function (res) {
        var A = window.GlukAuth;
        if (paidOrder(res)) {
          status(
            "ok",
            "<b>" + esc(L("Подписка активна", "The subscription is live")) + "</b>" +
              "<p>" + esc(L("Пробный период уже включён.", "The trial is already switched on.")) +
              ' <a href="' + esc(href("/app/")) + '">' + esc(L("Открыть кабинет", "Open the dashboard")) + "</a></p>"
          );
          if (A && A.refresh) A.refresh();
        } else {
          status(
            "ok",
            "<b>" + esc(L("Оплата отправлена", "Payment sent")) + "</b>" +
              "<p>" + esc(L(
                "Подписка включится автоматически, как только банк подтвердит платёж — обычно это несколько секунд.",
                "The subscription switches on automatically as soon as the bank confirms the payment — usually a few seconds."
              )) + ' <a href="' + esc(href("/app/")) + '">' + esc(L("Открыть кабинет", "Open the dashboard")) + "</a></p>"
          );
        }
        load();
      });
      return;
    }
    if (param("failed")) {
      status(
        "err",
        "<b>" + esc(L("Оплата не прошла", "The payment did not go through")) + "</b>" +
          "<p>" + esc(L(
            "Деньги не списаны. Можно попробовать снова — кнопка ниже создаст новый платёж, можно взять другую карту или СБП.",
            "Nothing was charged. You can try again — the button below starts a new payment, with another card or SBP."
          )) + "</p>"
      );
      /* Закрываем отклонённую попытку сразу, чтобы следующее нажатие шло за новым
         платежом, а не на ту же страницу отказа. */
      syncOrders(function () { load(); });
    }
  }

  /* ---------------------------------------------------------------- вывод */
  /* Секция-обёртка, если она помечена: убирать надо её, иначе от «скрытого»
     блока останутся отступы секции. */
  function section(host) {
    return (host.closest && host.closest("[data-trial-section]")) || host;
  }

  /* Кому акция не положена, у того блока нет в разметке вовсе. Скрытый пустой
     блок всё равно находится поиском по странице и оставляет дырку в ритме
     секций, а попытки заплатить рубль у такого человека быть не должно вовсе.
     Место запоминаем: состояние меняется прямо на странице (вошёл, вышел,
     подтвердил Telegram), и блок должен уметь вернуться туда, где был. */
  function drop(host) {
    var box = section(host);
    if (!box.parentNode) return;
    if (!host.trialSlot) host.trialSlot = { parent: box.parentNode, next: box.nextSibling };
    host.innerHTML = "";
    box.parentNode.removeChild(box);
  }

  function restore(host) {
    var box = section(host);
    if (box.parentNode) return;
    var slot = host.trialSlot;
    if (!slot || !slot.parent) return;
    var ref = slot.next && slot.next.parentNode === slot.parent ? slot.next : null;
    slot.parent.insertBefore(box, ref);
  }

  function apply() {
    var offer = state.offer;
    var show = !!offer && state.enabled && !!offer.enabled &&
      !!PROMO_REASONS[String((offer.eligibility || {}).reason || "")];

    banners.forEach(function (host) {
      if (!show) {
        drop(host);
        return;
      }
      restore(host);
      renderBanner(host, offer);
    });
    strips.forEach(function (host) {
      if (!show) {
        drop(host);
        return;
      }
      restore(host);
      renderStrip(host, offer);
    });
    decorateCards(offer, show);
    /* Страница /trial показывает акцию всегда: даже отказ там полезен —
       человек пришёл по ссылке и должен понять, почему кнопки нет. */
    if (offer) pages.forEach(function (host) { renderPage(host, offer); });
  }

  /* Рынок сервер определяет сам, но api.gluk.tech открыт напрямую, без
     Cloudflare — значит cf-ipcountry там нет. Подсказываем таймзону, валюту,
     уже подтверждённую сервером для карточек, и язык — только если его
     выбрали руками. Без этого акция приходила в дефолтных долларах.
     Для денег это безопасно: сумма списания всё равно считается на сервере
     и всегда в рублях. */
  function marketQuery() {
    var parts = [];
    var tz = "";
    try {
      tz = (Intl.DateTimeFormat().resolvedOptions() || {}).timeZone || "";
    } catch (e) {
      tz = "";
    }
    if (tz) parts.push("tz=" + encodeURIComponent(tz));
    var cur = pageCurrency();
    if (cur) parts.push("currency=" + encodeURIComponent(cur));
    var chosen = window.GlukI18n && window.GlukI18n.chosen;
    if (chosen === "ru" || chosen === "en") parts.push("lang=" + chosen);
    return parts.length ? "?" + parts.join("&") : "";
  }

  function load() {
    var A = window.GlukAuth;
    if (!A || !A.public) return;
    state.authStatus = A.state ? A.state.status : "";
    /* Вошедшему нужен токен: без него сервер ответит "sign_in_required" и
       страница предложит регистрацию тому, кто уже зарегистрирован. */
    var url = "/api/billing/trial" + marketQuery();
    var req = A.isAuthed && A.isAuthed() ? A.call(url) : A.public(url);
    req.then(
      function (json) {
        state.enabled = !!(json && json.billingEnabled);
        state.offer = (json && json.trial) || null;
        apply();
      },
      function () {
        /* Акция — не критичный блок: молчащий сервер её просто не показывает. */
        state.enabled = false;
        state.offer = null;
        apply();
      }
    );
  }

  document.addEventListener("click", function (e) {
    var btn = e.target && e.target.closest ? e.target.closest("[data-trial-claim-btn]") : null;
    if (!btn) return;
    e.preventDefault();
    claim(btn);
  });

  /* Вход, выход и первая проверка сессии меняют ответ сервера. */
  document.addEventListener("gluk:auth", function (e) {
    var st = e && e.detail ? e.detail.status : "";
    if (!st || st === "loading" || st === state.authStatus) return;
    load();
  });

  /* billing.js перерисовал карточки тарифов — метку надо повесить заново.
     Он же — единственный надёжный источник валюты: её вернул сервер в
     ответе /api/billing/plans. Если валюта пришла впервые или сменилась,
     сразу перерисовываем акцию по эквивалентам и перезапрашиваем её уже
     с правильным ?currency=. Цикла нет: событие рассылает billing.js. */
  document.addEventListener("gluk:plans", function (e) {
    var next = String(((e && e.detail) || {}).currency || "").toUpperCase();
    if (next && next !== state.currency) {
      state.currency = next;
      apply();
      load();
      return;
    }
    var offer = state.offer;
    var show = !!offer && state.enabled && !!offer.enabled &&
      !!PROMO_REASONS[String(((offer || {}).eligibility || {}).reason || "")];
    decorateCards(offer, show);
  });

  function boot() {
    gatewayReturn();
    load();
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", boot);
  else boot();
})();
