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

   Способ оплаты тоже приходит с сервера: набор рельсов зависит от включённого
   шлюза, а порог рельса сверяется с суммой списания — карту Cashera «от 100 ₽»
   на акции за рубль выбрать нельзя, и она выключена прямо в разметке.
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
  /* methods/method — способы оплаты активного шлюза и выбранный рельс.
     Список составляет шлюз, а не витрина: у TabPay он один, у Cashera другой,
     у MulenPay выбора нет вовсе. */
  /* ready/show — «ответ сервера получен для устоявшегося статуса» и сам ответ
     на вопрос «показывать ли этому посетителю акцию». До ответа не показываем
     ничего: гостевой баннер, мелькнувший перед вошедшим, — это и был баг. */
  var state = {
    offer: null,
    enabled: false,
    authStatus: "",
    busy: false,
    currency: "",
    provider: "",
    methods: [],
    method: "",
    ready: false,
    show: null
  };

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

  /* Признак начатой сессии — refresh-токен auth.js. Канал спрашиваем у него
     же: у беты ключ другой, а чужой канал ничего не говорит о этой странице.
     Если auth.js ещё не объявился, смотрим оба ключа. localStorage бывает
     запрещён (приватный режим, блокировка сторонних данных), поэтому всё в
     try/catch: недоступное хранилище — это «токена нет». */
  function sessionKeys() {
    var A = window.GlukAuth;
    var ch = A && A.channel ? String(A.channel) : "";
    return ch ? ["gluk." + ch + ".refresh"] : ["gluk.prod.refresh", "gluk.beta.refresh"];
  }

  function hasSession() {
    var keys = sessionKeys();
    for (var i = 0; i < keys.length; i++) {
      try {
        if (localStorage.getItem(keys[i])) return true;
      } catch (e) {
        return false;
      }
    }
    return false;
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

  /* ------------------------------------------------- способы оплаты */
  /* Значки рисуем свои: логотипы СБП, «Мира» и Visa — товарные знаки со
     своими правилами показа, а понятный значок их не требует. Набор тот же,
     что на /pricing/ (billing.js): один и тот же выбор не должен выглядеть
     на двух страницах по-разному. */
  var PAY_ICONS = {
    all: '<svg viewBox="0 0 24 24" fill="none" aria-hidden="true"><rect x="2.6" y="6.4" width="14.8" height="10.4" rx="2.4" stroke="currentColor" stroke-width="1.7"/><path d="M2.6 10.2h14.8" stroke="currentColor" stroke-width="1.7"/><path d="M6.8 20.2h11a2.6 2.6 0 0 0 2.6-2.6V9.4" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"/></svg>',
    sbp: '<svg viewBox="0 0 24 24" fill="none" aria-hidden="true"><rect x="6.6" y="2.8" width="10.8" height="18.4" rx="2.6" stroke="currentColor" stroke-width="1.7"/><path d="M12 7.4v6.4" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"/><path d="M9.7 11.4L12 13.8L14.3 11.4" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"/><path d="M10.4 17.4h3.2" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"/></svg>',
    card: '<svg viewBox="0 0 24 24" fill="none" aria-hidden="true"><rect x="2.6" y="5.2" width="18.8" height="13.6" rx="3" stroke="currentColor" stroke-width="1.7"/><path d="M2.6 10.2h18.8" stroke="currentColor" stroke-width="1.7"/><path d="M6.4 14.8h4" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"/></svg>',
    crypto: '<svg viewBox="0 0 24 24" fill="none" aria-hidden="true"><circle cx="12" cy="12" r="8.8" stroke="currentColor" stroke-width="1.7"/><path d="M9.6 7.6v8.8M12.2 7.6v8.8" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/><path d="M8.6 9.4h4.2a1.8 1.8 0 0 1 0 3.6H8.6h4.6a1.8 1.8 0 0 1 0 3.6H8.6" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg>'
  };

  /* Подписи знакомых рельсов держим здесь: сервер отдаёт их по-русски.
     Незнакомый id показываем как пришёл — новый способ появится сам. */
  var PAY_LABELS = {
    all: ["Все способы", "All methods"],
    sbp: ["СБП", "SBP"],
    card: ["Банковская карта", "Bank card"],
    crypto: ["Криптовалюта", "Crypto"]
  };

  var PROVIDER_LABELS = { tabpay: "TabPay", cashera: "Cashera", mulenpay: "MulenPay" };

  /* Шлюз называем правильно: он переключается в админке, и обещать «страницу
     TabPay» там, где платит Cashera, нельзя. */
  function providerLabel() {
    var id = String(state.provider || "").trim();
    return PROVIDER_LABELS[id.toLowerCase()] || id;
  }

  function money(minor, currency) {
    var P = window.GlukPrice;
    if (P && P.money) {
      try {
        return P.money(minor, currency);
      } catch (e) {}
    }
    /* Запас, если ui.js не загрузился. */
    var amount = (Number(minor) || 0) / 100;
    var code = String(currency || "").toUpperCase();
    var sym = code === "RUB" ? "\u20bd" : code === "KZT" ? "\u20b8" : code === "USD" ? "$" : code;
    var num = amount % 1 ? amount.toFixed(2) : String(Math.round(amount));
    return sym === "$" ? sym + num : num + "\u00a0" + sym;
  }

  function methodId(m) {
    return String((m && m.id) || "").toLowerCase();
  }

  function methodById(id) {
    var want = String(id || "").toLowerCase();
    var all = state.methods || [];
    for (var i = 0; i < all.length; i++) {
      if (methodId(all[i]) === want) return all[i];
    }
    return null;
  }

  /* Порог рельса сравниваем с суммой списания, а не с ценой на экране:
     цена бывает в тенге, а платёж всегда уходит в рублях. */
  function chargeMinor(offer) {
    var charge = (offer && offer.charge) || null;
    return charge ? Number(charge.minor) || 0 : 0;
  }

  function chargeCurrency(offer) {
    var charge = (offer && offer.charge) || null;
    return String((charge && charge.currency) || "").toUpperCase();
  }

  function methodFits(m, offer) {
    var min = Number(m && m.minimumMinor) || 0;
    var minor = chargeMinor(offer);
    return !min || !minor || minor >= min;
  }

  /* Порог — часть подписи, а не сюрприз на странице шлюза: «Карта (от 100 ₽)»
     сразу объясняет, почему её нельзя нажать на акции за рубль. */
  function methodLabel(m, offer) {
    var pair = PAY_LABELS[methodId(m)];
    var text = pair ? L(pair[0], pair[1]) : String((m && m.label) || methodId(m));
    if (m && Number(m.minimumMinor) > 0) {
      text += " (" + L("от ", "from ") + money(m.minimumMinor, chargeCurrency(offer)) + ")";
    }
    return text;
  }

  /* Выбор по умолчанию. Обычно это первый способ («Все способы»), но если
     сумме подходят не все рельсы, «все способы» превращаются в ловушку: на
     витрине шлюза человек выберет карту и получит отказ. Тогда ведём на СБП. */
  function pickMethod(offer) {
    var all = state.methods || [];
    if (!all.length) return "";
    var current = methodById(state.method);
    if (current && methodFits(current, offer)) return methodId(current);
    var blocked = false;
    for (var i = 0; i < all.length; i++) {
      if (!methodFits(all[i], offer)) blocked = true;
    }
    if (blocked) {
      var sbp = methodById("sbp");
      if (sbp && methodFits(sbp, offer)) return methodId(sbp);
    }
    for (var k = 0; k < all.length; k++) {
      if (methodFits(all[k], offer)) return methodId(all[k]);
    }
    return "";
  }

  /* Один рельс — это не выбор, а лишний вопрос перед оплатой. */
  function methodsMarkup(offer) {
    var all = state.methods || [];
    if (!state.enabled || all.length < 2) return "";
    return '<div class="pay-method" role="group" aria-label="' + esc(L("Способ оплаты", "Payment method")) + '" data-trial-methods>' +
      '<span class="pay-method__title">' + esc(L("Способ оплаты", "Payment method")) + "</span>" +
      '<div class="pay-method__row">' +
        all
          .map(function (m) {
            var id = methodId(m);
            var fits = methodFits(m, offer);
            var on = fits && id === String(state.method || "").toLowerCase();
            /* Причину блокировки говорим сразу: неактивная кнопка без
               объяснения читается как поломка страницы. */
            var why = fits ? "" : L(
              "Недоступно для суммы " + chargeLabel(offer) + ": шлюз принимает картой от " +
                money(m.minimumMinor, chargeCurrency(offer)) + ".",
              "Not available for " + chargeLabel(offer) + ": the gateway takes cards from " +
                money(m.minimumMinor, chargeCurrency(offer)) + "."
            );
            return '<button class="pay-method__btn' + (on ? " is-on" : "") + '" type="button" data-trial-method="' + esc(id) + '"' +
              (fits ? "" : ' disabled aria-disabled="true" title="' + esc(why) + '"') +
              ' aria-pressed="' + (on ? "true" : "false") + '">' +
              '<span class="pay-method__icon" aria-hidden="true">' + (PAY_ICONS[id] || PAY_ICONS.card) + "</span>" +
              '<span class="pay-method__label">' + esc(methodLabel(m, offer)) + "</span>" +
              "</button>";
          })
          .join("") +
      "</div>" +
      "</div>";
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
    unhide(host);
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
    unhide(host);
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
      /* Шлюз называем тот, который включён сейчас, а не тот, с которым акцию
         запускали: провайдер переключается в админке. */
      var gate = providerLabel();
      return {
        methods: methodsMarkup(offer),
        cta: '<button class="btn btn--primary btn--lg" type="button" data-trial-claim-btn>' +
          esc(L("Подключить за " + price, "Get it for " + price)) + "</button>",
        note: L(
          "Оплата проходит на защищённой странице " + (gate || "платёжного сервиса") +
            ": соединение по HTTPS, карты проходят проверку 3-D Secure. Данные карты не проходят через наш сервер." + left,
          "Payment happens on " + (gate || "the payment provider") +
            "'s own secure page: HTTPS, with 3-D Secure for cards. Card details never touch our server." + left
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
    /* Селектор способов показываем только там, где кнопка оплаты живая:
       в остальных состояниях выбирать нечего. */
    box.innerHTML = (parts.methods || "") + parts.cta + '<p class="trial-claim__note">' + esc(parts.note) + "</p>";
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

    /* Выбранный рельс мог перестать подходить (сумму акции меняют
       настройкой) — переключаем сами и просим нажать ещё раз, а не
       отправляем заказ, который шлюз всё равно отклонит. */
    var picked = methodById(state.method);
    if (picked && !methodFits(picked, state.offer)) {
      state.method = pickMethod(state.offer);
      if (state.offer) pages.forEach(function (host) { renderClaim(host, state.offer); });
      status(
        "err",
        "<b>" + esc(L("Этот способ не подходит к сумме", "That method does not fit this amount")) + "</b><p>" +
          esc(L("Выбрали другой способ — нажмите оплату ещё раз.",
                "We picked another method — press pay again.")) + "</p>"
      );
      return;
    }

    var label = btn.textContent;
    state.busy = true;
    btn.disabled = true;
    btn.textContent = T("Создаём заказ…");
    status("", "");
    /* «Все способы» — это отсутствие выбора: пусть шлюз покажет свою витрину. */
    var body = {};
    if (state.method && state.method !== "all") body.method = state.method;
    A.call("/api/billing/trial/claim", { method: "POST", body: body }).then(
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

  /* hidden стоит в разметке и на секции, и на самом блоке: так до ответа
     сервера на странице нет ни баннера, ни отступов его секции. Показ снимает
     атрибут с обоих. */
  function unhide(host) {
    var box = section(host);
    if (box !== host) box.hidden = false;
    host.hidden = false;
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
    /* Возвращать блок в документ можно только скрытым: вернуть его видимым
       значит показать пустую рамку до того, как придёт ответ. */
    host.hidden = true;
    if (box !== host) box.hidden = true;
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

  /* Право на баннер решает сервер — полем show в /api/billing/trial. Старый
     control-server его не отдаёт: тогда повторяем то же правило по reason,
     чтобы сайт не остался без акции до обновления бэкенда. */
  function promoted(offer) {
    return !!offer && state.enabled && !!offer.enabled &&
      !!PROMO_REASONS[String((offer.eligibility || {}).reason || "")];
  }

  /* Пока ответа для устоявшегося статуса нет — не показываем ничего. */
  function visible() {
    if (!state.ready) return false;
    return state.show === null ? promoted(state.offer) : state.show === true;
  }

  function apply() {
    var offer = state.offer;
    var show = visible();

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
    var status = A.state ? A.state.status : "";
    var authed = !!(A.isAuthed && A.isAuthed());
    /* Гостевой запрос — только для настоящих гостей. Пока сессия не устоялась
       (status "loading") или в хранилище лежит refresh-токен, человек, скорее
       всего, входит: сервер ответил бы ему "sign_in_required", и перед
       вошедшим мелькнул бы баннер «создайте аккаунт». Ждём gluk:auth и
       спросим уже с токеном — обработчик события ниже позовёт load() сам. */
    if (!authed && (status === "loading" || hasSession())) {
      state.authStatus = status;
      state.ready = false;
      apply();
      return;
    }
    state.authStatus = status;
    /* Вошедшему нужен токен: без него сервер ответит "sign_in_required" и
       страница предложит регистрацию тому, кто уже зарегистрирован. */
    var url = "/api/billing/trial" + marketQuery();
    var req = authed ? A.call(url) : A.public(url);
    req.then(
      function (json) {
        state.ready = true;
        /* show — ответ сервера; null значит «сервер не сказал», решаем сами. */
        state.show = json && typeof json.show === "boolean" ? json.show : null;
        state.enabled = !!(json && json.billingEnabled);
        state.offer = (json && json.trial) || null;
        state.provider = (json && json.provider) ? String(json.provider) : "";
        /* Способы отдаёт активный шлюз; без id строка бесполезна. */
        state.methods = ((json && json.methods) || []).filter(function (m) {
          return m && m.id;
        });
        state.method = pickMethod(state.offer);
        apply();
      },
      function () {
        /* Акция — не критичный блок: молчащий сервер её просто не показывает. */
        state.ready = true;
        state.show = false;
        state.enabled = false;
        state.offer = null;
        state.provider = "";
        state.methods = [];
        state.method = "";
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

  /* Ключи разметки у акции свои (data-trial-method): на /pricing/ рядом
     работает billing.js со своим селектором, и два обработчика на одних
     и тех же кнопках меняли бы выбор друг другу. */
  document.addEventListener("click", function (e) {
    var btn = e.target && e.target.closest ? e.target.closest("[data-trial-method]") : null;
    if (!btn || btn.disabled) return;
    e.preventDefault();
    var id = String(btn.getAttribute("data-trial-method") || "").toLowerCase();
    if (!id || id === state.method) return;
    state.method = id;
    if (state.offer) pages.forEach(function (host) { renderClaim(host, state.offer); });
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
    decorateCards(state.offer, visible());
  });

  function boot() {
    gatewayReturn();
    load();
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", boot);
  else boot();
})();
