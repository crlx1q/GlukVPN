/* ==========================================================================
   GlukVPN — тарифы → биллинг (/pricing/ и /en/pricing/).

   ui.js рисует карточки тарифов из config.js — это офлайн-версия для
   поисковиков и для случая, когда API недоступен. Этот скрипт поверх неё:

     GET /api/billing/plans (публично)
       billingEnabled:true  → цены, названия, длительность и фичи из API
                              (config — запасной вариант для отсутствующих
                              полей), CTA Basic/Pro создают заказ:
                              POST /api/billing/orders { planCode, currency } →
                              paymentUrl → переход к оплате;
                              manual:true → показываем instructions.
                              Без входа — на /login/?next=/pricing/.
       billingEnabled:false → карточки из config как раньше, CTA платных
                              тарифов — «Скоро», плюс короткая заметка.
       ошибка сети/404      → как billingEnabled:false.

   Переключатель «1 месяц / 3 месяца» появляется только тогда, когда
   квартальные тарифы реально есть (в ответе API или в запасной матрице):
   пустой тумблер хуже отсутствующего. Выгода считается из самих сумм
   (3 × месяц против квартала), а не пишется руками. Валюту назначает
   бэкенд по стране, поэтому суммы берём как есть и курс не считаем.
   ========================================================================== */
(function () {
  "use strict";

  var hosts = Array.prototype.slice.call(document.querySelectorAll("[data-plans]"));
  if (!hosts.length) return;

  var CFG = window.GLUK_CONFIG || {};
  var PRICING = CFG.pricing || {};
  var T = window.GlukT || function (s) { return s; };
  var EN = (document.documentElement.getAttribute("data-lang") || "ru").toLowerCase() === "en";
  var LOCALE = EN ? "en-GB" : "ru-RU";
  var root = document.documentElement.getAttribute("data-base") || "/";
  /* ui.js уже знает правила формата сумм — не дублируем их. */
  var PRICE = window.GlukPrice || null;

  /* Словарь i18n.js переводит только знакомые ему фразы, поэтому новые
     подписи держим парами здесь. */
  function L(ru, en) {
    return EN ? en : ru;
  }

  var PERIODS = PRICING.periods && PRICING.periods.length
    ? PRICING.periods
    : [
        { id: "monthly", days: 30, label: "1 месяц", labelEn: "1 month", suffix: "мес", suffixEn: "mo" },
        { id: "quarterly", days: 90, label: "3 месяца", labelEn: "3 months", suffix: "3 мес", suffixEn: "3 mo" }
      ];

  var state = {
    periodId: PRICING.defaultPeriod || "monthly",
    currency: (PRICE && PRICE.currency) || (EN ? "USD" : PRICING.defaultCurrency || "KZT"),
    plans: [],
    enabled: false
  };

  function esc(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }
  function href(u) {
    if (!u) return root;
    if (/^(https?:|mailto:|tel:|#)/.test(u)) return u;
    if (u.charAt(0) === "/") return (root === "/" ? "" : root.replace(/\/$/, "")) + u;
    return u;
  }

  var ICONS = {
    check: '<svg viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="M5 12.5l4.2 4.2L19 7" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    minus: '<svg viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="M6 12h12" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"/></svg>'
  };

  /* ------------------------------------------------------------- форматы */
  function money(minor, currency) {
    if (PRICE && PRICE.money) return PRICE.money(minor, currency);
    /* Запас, если ui.js не загрузился: те же правила, но локально. */
    var code = String(currency || state.currency).toUpperCase();
    var conf = (PRICING.currencies || {})[code] || {};
    var amount = (Number(minor) || 0) / 100;
    var digits = conf.decimals != null ? conf.decimals : amount % 1 ? 2 : 0;
    var num;
    try {
      num = amount.toLocaleString(conf.locale || LOCALE, {
        minimumFractionDigits: digits,
        maximumFractionDigits: digits
      });
    } catch (e) {
      num = amount.toFixed(digits);
    }
    var sym = conf.symbol || (code === "RUB" ? "\u20bd" : code === "USD" ? "$" : code === "EUR" ? "\u20ac" : code === "KZT" ? "\u20b8" : code);
    return conf.position === "before" || sym === "$" ? sym + num : num + "\u00a0" + sym;
  }

  function periodConf(id) {
    for (var i = 0; i < PERIODS.length; i++) {
      if (PERIODS[i].id === id) return PERIODS[i];
    }
    return PERIODS[0];
  }

  function periodLabel(id) {
    var c = periodConf(id);
    return EN ? c.labelEn || c.label : c.label;
  }

  function periodSuffix(id) {
    if (PRICE && PRICE.periodSuffix) return PRICE.periodSuffix(id);
    var c = periodConf(id);
    return EN ? c.suffixEn || c.suffix : c.suffix;
  }

  /* API отдаёт тарифы плоским списком, период — в днях. */
  function periodOf(days) {
    days = Number(days) || 30;
    if (days <= 31) return "monthly";
    if (days >= 85 && days <= 100) return "quarterly";
    return null;
  }

  /* Для необычных сроков подпись берётся из самих дней, чтобы цена
     не подписывалась «/ мес» для годового тарифа. */
  function suffixForDays(days) {
    var id = periodOf(days);
    if (id) return periodSuffix(id);
    days = Number(days) || 0;
    if (days === 365 || days === 366) return L("год", "yr");
    if (days === 7) return L("нед", "wk");
    return window.GlukI18n ? window.GlukI18n.days(days) : days + " " + L("дн.", "d");
  }

  function paidPlan(p) {
    var tier = typeof p.tier === "number" ? p.tier : p.code === "free" ? 0 : 1;
    return tier > 0 || Number(p.priceMinor) > 0;
  }

  /* Сопоставление кода тарифа с записью в config: ищем и по id, и по
     codes, иначе basic_3m остался бы без бейджа и описания. */
  function cfgPlan(code) {
    var want = String(code || "").toLowerCase();
    var plans = PRICING.plans || [];
    for (var i = 0; i < plans.length; i++) {
      var c = plans[i];
      if (String(c.id || "").toLowerCase() === want) return c;
      var codes = c.codes || {};
      for (var key in codes) {
        if (Object.prototype.hasOwnProperty.call(codes, key) && String(codes[key]).toLowerCase() === want) return c;
      }
    }
    return null;
  }

  function familyOf(p) {
    var cfg = cfgPlan(p.code);
    if (cfg && cfg.id) return String(cfg.id);
    return "tier" + (typeof p.tier === "number" ? p.tier : 1);
  }

  /* Скидка — результат арифметики, а не маркетинговое обещание. */
  function savingPercent(monthlyMinor, quarterlyMinor) {
    var full = (Number(monthlyMinor) || 0) * 3;
    var q = Number(quarterlyMinor) || 0;
    if (!full || !q || q >= full) return 0;
    return Math.round((1 - q / full) * 100);
  }

  function buckets(plans) {
    var out = { monthly: [], quarterly: [] };
    plans.forEach(function (p) {
      var id = periodOf(p.days) || "monthly";
      if (!out[id]) out[id] = [];
      out[id].push(p);
      /* Free один на все периоды: иначе при «3 месяца» бесплатный тариф
         просто исчезает из сетки. */
      if (id === "monthly" && !paidPlan(p)) out.quarterly.push(p);
    });
    return out;
  }

  function pairIndex(plans) {
    var map = {};
    plans.forEach(function (p) {
      if (!paidPlan(p)) return;
      var id = periodOf(p.days) || "monthly";
      var key = familyOf(p);
      if (!map[key]) map[key] = {};
      if (!map[key][id]) map[key][id] = p;
    });
    return map;
  }

  function bestSaving(pairs) {
    var best = 0;
    for (var key in pairs) {
      if (!Object.prototype.hasOwnProperty.call(pairs, key)) continue;
      var m = pairs[key].monthly;
      var q = pairs[key].quarterly;
      if (!m || !q) continue;
      best = Math.max(best, savingPercent(m.priceMinor, q.priceMinor));
    }
    return best;
  }

  /* --------------------------------------------------------------- рендер */
  function card(p, pairs) {
    var cfg = cfgPlan(p.code) || {};
    var paid = paidPlan(p);
    var features = "";
    if (Array.isArray(p.features) && p.features.length && typeof p.features[0] === "string") {
      features = p.features
        .map(function (f) {
          return "<li>" + ICONS.check + "<span>" + esc(f) + "</span></li>";
        })
        .join("");
    } else {
      features = (cfg.features || [])
        .map(function (f) {
          return "<li" + (f.on ? "" : " data-off") + ">" + (f.on ? ICONS.check : ICONS.minus) + "<span>" + esc(f.text) + "</span></li>";
        })
        .join("");
    }
    var price = p.priceMinor ? money(p.priceMinor, p.currency) : "0";
    /* Название из config важнее: в базе квартальный тариф называется
       «Basic · 3 месяца» — это дублирует тумблер и протекает русским
       текстом на английские страницы. */
    var name = cfg.name || p.name || p.code;
    var featured = typeof p.featured === "boolean" ? p.featured : !!cfg.featured;
    var save = 0;
    if (periodOf(p.days) === "quarterly") {
      var fam = pairs[familyOf(p)] || {};
      if (fam.monthly) save = savingPercent(fam.monthly.priceMinor, p.priceMinor);
    }
    var cta;
    if (!paid) {
      var c = cfg.cta || {};
      cta = '<a class="btn btn--ghost btn--block plan__cta" href="' + esc(href(c.href || "/download/")) + '">' + esc(c.label || T("Начать бесплатно")) + "</a>";
    } else if (state.enabled) {
      cta = '<button class="btn ' + (featured ? "btn--primary" : "btn--ghost") + ' btn--block plan__cta" type="button" data-buy="' + esc(p.code) + '">' +
        esc(T("Выбрать") + " " + name) + "</button>";
    } else {
      cta = '<span class="btn btn--muted btn--block plan__cta" aria-disabled="true" title="' + esc(T("Оплата откроется вместе с запуском биллинга")) + '">' + esc(T("Скоро")) + "</span>";
    }
    var meta = [];
    if (p.maxDevices) meta.push(p.maxDevices + " " + T("устр."));
    if (p.maxSessions) meta.push(p.maxSessions + " " + T("сес."));
    return '<article class="plan glass' + (featured ? " plan--featured" : "") + '" data-plan-code="' + esc(p.code) + '">' +
      '<div class="plan__head"><h3 class="plan__name">' + esc(name) + "</h3>" +
      (cfg.badge ? '<span class="chip chip--violet">' + esc(cfg.badge) + "</span>" : "") + "</div>" +
      '<div class="plan__price"><span class="plan__amount">' + esc(price) + '</span><span class="plan__period">/ ' + esc(suffixForDays(p.days)) + "</span></div>" +
      (save ? '<p class="plan__save">' + esc(L("Выгоднее на " + save + "%", "Save " + save + "%")) + "</p>" : "") +
      '<p class="plan__note">' + esc(cfg.tagline || meta.join(" \u00b7 ") || "") + "</p>" +
      '<ul class="plan__features">' + features + "</ul>" + cta + "</article>";
  }

  /* Запасная сетка из config: тот же вид, что у ответа API, чтобы
     переключатель периода работал и без сети. */
  function fromConfig(currency) {
    var cur = String(currency || state.currency).toUpperCase();
    var out = [];
    (PRICING.plans || []).forEach(function (c) {
      var codes = c.codes || {};
      PERIODS.forEach(function (per) {
        var code = codes[per.id] || c.id;
        var minor = ((c.prices || {})[per.id] || {})[cur];
        if (minor == null) return;
        /* У Free нет отдельного квартального кода — не делаем двойника. */
        if (per.id !== "monthly" && code === (codes.monthly || c.id) && !(Number(minor) > 0)) return;
        out.push({
          code: code,
          name: c.name,
          tier: c.tier != null ? c.tier : 0,
          days: per.days,
          priceMinor: Number(minor) || 0,
          currency: cur,
          featured: !!c.featured,
          features: null
        });
      });
    });
    return out;
  }

  function toggleHost() {
    var el = document.querySelector("[data-plan-period]");
    if (el) return el;
    el = document.createElement("div");
    el.className = "plan-period";
    el.setAttribute("data-plan-period", "");
    hosts[0].parentNode.insertBefore(el, hosts[0]);
    return el;
  }

  function renderToggle(group, pairs) {
    var quarterlyPaid = (group.quarterly || []).filter(paidPlan).length;
    var existing = document.querySelector("[data-plan-period]");
    /* Нет квартальных тарифов — нет и тумблера. */
    if (!quarterlyPaid) {
      if (existing) {
        existing.innerHTML = "";
        existing.hidden = true;
      }
      return;
    }
    var host = existing || toggleHost();
    host.hidden = false;
    host.setAttribute("role", "group");
    host.setAttribute("aria-label", L("Период оплаты", "Billing period"));
    var best = bestSaving(pairs);
    host.innerHTML = PERIODS.map(function (per) {
      var on = per.id === state.periodId;
      return '<button class="plan-period__btn' + (on ? " is-on" : "") + '" type="button" data-period="' + esc(per.id) + '" aria-pressed="' + (on ? "true" : "false") + '">' +
        esc(periodLabel(per.id)) +
        (per.id === "quarterly" && best ? '<span class="plan-period__save">\u2212' + best + "%</span>" : "") +
        "</button>";
    }).join("");
  }

  function render() {
    var all = state.plans && state.plans.length ? state.plans : fromConfig(state.currency);
    var group = buckets(all);
    var pairs = pairIndex(all);
    var list = (group[state.periodId] || []).slice();
    if (!list.length) {
      state.periodId = "monthly";
      list = (group.monthly || []).slice();
    }
    list.sort(function (a, b) {
      return (a.tier || 0) - (b.tier || 0) || (a.priceMinor || 0) - (b.priceMinor || 0);
    });
    hosts.forEach(function (host) {
      host.innerHTML = list
        .map(function (p) {
          return card(p, pairs);
        })
        .join("");
    });
    renderToggle(group, pairs);
  }

  function noteBox() {
    var el = document.querySelector("[data-billing-notice]");
    if (el) return el;
    el = document.createElement("div");
    el.className = "billing-notice";
    el.setAttribute("data-billing-notice", "");
    el.setAttribute("role", "status");
    el.setAttribute("aria-live", "polite");
    el.hidden = true;
    var first = hosts[0];
    first.parentNode.insertBefore(el, first);
    return el;
  }

  function notice(html, kind) {
    var el = noteBox();
    if (!html) { el.hidden = true; el.innerHTML = ""; return; }
    el.hidden = false;
    el.className = "billing-notice" + (kind ? " billing-notice--" + kind : "");
    el.innerHTML = html;
    try { el.scrollIntoView({ block: "center", behavior: "smooth" }); } catch (e) {}
  }

  function setPricingNote(text) {
    Array.prototype.forEach.call(document.querySelectorAll("[data-pricing-note]"), function (n) {
      n.textContent = text;
    });
  }

  /* ---------------------------------------------------------------- заказ */
  function human(e, fallback) {
    if (!e) return fallback;
    if (e.status === 0) return T("Не удалось связаться с сервером. Проверьте соединение.");
    if (e.status === 401 || e.status === 403) return T("Сессия истекла — войдите заново.");
    if (e.status === 409) return e.message || T("У вас уже есть неоплаченный заказ. Откройте кабинет, чтобы посмотреть его.");
    if (e.status === 429) return T("Слишком много запросов. Попробуйте через минуту.");
    if (e.status >= 500) return T("Сервис временно недоступен. Попробуйте позже.");
    return e.message || fallback;
  }

  function goLogin() {
    var next = root + "pricing/";
    window.location.href = root + "login/?next=" + encodeURIComponent(next);
  }

  function buy(code, btn) {
    var A = window.GlukAuth;
    if (!A) { goLogin(); return; }
    if (A.state.status === "loading") {
      /* Сессия ещё проверяется — дождёмся ответа один раз и повторим. */
      btn.disabled = true;
      var once = function () {
        document.removeEventListener("gluk:auth", once);
        btn.disabled = false;
        buy(code, btn);
      };
      document.addEventListener("gluk:auth", once);
      return;
    }
    if (!A.isAuthed()) { goLogin(); return; }

    var label = btn.textContent;
    btn.disabled = true;
    btn.textContent = T("Создаём заказ…");
    notice("");
    A.call("/api/billing/orders", { method: "POST", body: { planCode: code, currency: state.currency } })
      .then(function (res) {
        var order = (res && res.order) || {};
        if (res && res.paymentUrl) {
          btn.textContent = T("Переходим к оплате…");
          window.location.href = res.paymentUrl;
          return;
        }
        btn.disabled = false;
        btn.textContent = label;
        if (res && res.manual) {
          notice(
            "<b>" + esc(T("Заказ создан")) + (order.id ? " \u00b7 #" + esc(String(order.id).slice(0, 8)) : "") + "</b>" +
            '<p class="billing-notice__text">' + esc(res.instructions || T("Инструкции по оплате пришлём в ответ на обращение в поддержку.")).replace(/\n/g, "<br>") + "</p>" +
            (order.amountMinor != null ? '<p class="billing-notice__meta">' + esc(T("Сумма")) + ": <b>" + esc(money(order.amountMinor, order.currency)) + "</b></p>" : "") +
            '<p class="billing-notice__meta"><a href="' + esc(root + "app/") + '">' + esc(T("Статус заказа — в кабинете")) + "</a></p>",
            "ok"
          );
          return;
        }
        notice(
          "<b>" + esc(T("Заказ создан")) + (order.id ? " \u00b7 #" + esc(String(order.id).slice(0, 8)) : "") + "</b>" +
          '<p class="billing-notice__text">' + esc(T("Статус")) + ": " + esc(order.status || "PENDING") + ". " +
          esc(T("Следите за заказом в личном кабинете.")) + ' <a href="' + esc(root + "app/") + '">' + esc(T("Открыть кабинет")) + "</a></p>",
          "ok"
        );
      })
      .catch(function (e) {
        btn.disabled = false;
        btn.textContent = label;
        if (e && (e.status === 401 || e.status === 403) && !(e.message && /closed|disabled|not available/i.test(e.message))) {
          goLogin();
          return;
        }
        notice("<b>" + esc(T("Не удалось создать заказ")) + '</b><p class="billing-notice__text">' + esc(human(e, T("Попробуйте ещё раз или напишите в поддержку."))) + "</p>", "err");
      });
  }

  document.addEventListener("click", function (e) {
    var btn = e.target && e.target.closest ? e.target.closest("[data-buy]") : null;
    if (!btn) return;
    e.preventDefault();
    buy(btn.getAttribute("data-buy"), btn);
  });

  document.addEventListener("click", function (e) {
    var btn = e.target && e.target.closest ? e.target.closest("[data-period]") : null;
    if (!btn) return;
    e.preventDefault();
    var id = btn.getAttribute("data-period");
    if (!id || id === state.periodId) return;
    state.periodId = id;
    render();
  });

  /* ---------------------------------------------------------------- старт */
  function disabledMode(plans, currency) {
    state.plans = plans && plans.length ? plans : [];
    if (currency) state.currency = String(currency).toUpperCase();
    state.enabled = false;
    render();
    setPricingNote((PRICING.note || "") + (PRICING.note ? " " : "") + T("Кнопки оплаты включатся вместе с запуском биллинга."));
  }

  function boot() {
    var A = window.GlukAuth;
    if (!A || !A.public) { disabledMode(null, null); return; }
    A.public("/api/billing/plans").then(function (json) {
      var plans = json && Array.isArray(json.plans)
        ? json.plans.filter(function (p) { return p && p.code; })
        : [];
      var currency = (json && (json.currency || (json.market && json.market.currency))) || null;
      if (json && json.billingEnabled) {
        state.plans = plans;
        if (currency) state.currency = String(currency).toUpperCase();
        state.enabled = true;
        render();
        var provider = json.provider ? String(json.provider) : "";
        setPricingNote(
          T("Оплата картой") + (provider ? " " + T("через") + " " + provider : "") + ". " +
          T("Подписка активируется автоматически после платежа; автосписаний нет.")
        );
      } else {
        disabledMode(plans, currency);
      }
    }, function () { disabledMode(null, null); });
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", boot);
  else boot();
})();
