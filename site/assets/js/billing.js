/* ==========================================================================
   GlukVPN — тарифы → биллинг (/pricing/ и /en/pricing/).

   ui.js рисует карточки тарифов из config.js — это офлайн-версия для
   поисковиков и для случая, когда API недоступен. Этот скрипт поверх неё:

     GET /api/billing/plans (публично)
       billingEnabled:true  → цены, названия, длительность и фичи из API
                              (config — запасной вариант для отсутствующих
                              полей), CTA Basic/Pro создают заказ:
                              POST /api/billing/orders { planCode } →
                              paymentUrl → переход к оплате;
                              manual:true → показываем instructions.
                              Без входа — на /login/?next=/pricing/.
       billingEnabled:false → карточки из config как раньше, CTA платных
                              тарифов — «Скоро», плюс короткая заметка.
       ошибка сети/404      → как billingEnabled:false.
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

  function cfgPlan(code) {
    var plans = PRICING.plans || [];
    for (var i = 0; i < plans.length; i++) {
      if (String(plans[i].id || "").toLowerCase() === code) return plans[i];
    }
    return null;
  }

  function money(minor, currency) {
    var amount = (Number(minor) || 0) / 100;
    var cur = String(currency || "KZT").toUpperCase();
    var sym = cur === "KZT" ? "\u20b8" : cur === "RUB" ? "\u20bd" : cur === "USD" ? "$" : cur === "EUR" ? "\u20ac" : cur;
    var num;
    try { num = amount.toLocaleString(LOCALE, { maximumFractionDigits: amount % 1 ? 2 : 0 }); } catch (e) { num = String(amount); }
    return sym.length === 1 && cur !== "KZT" ? sym + num : num + "\u00a0" + sym;
  }

  function period(days) {
    days = Number(days) || 0;
    if (!days || days === 30 || days === 31) return T("мес");
    if (days === 365 || days === 366) return T("год");
    if (days === 7) return T("нед");
    return window.GlukI18n ? window.GlukI18n.days(days) : days + " " + T("дн.");
  }

  /* --------------------------------------------------------------- рендер */
  function card(p, enabled) {
    var cfg = cfgPlan(p.code) || {};
    var paid = (typeof p.tier === "number" ? p.tier : (p.code === "free" ? 0 : 1)) > 0 || (p.priceMinor > 0);
    var features = "";
    if (Array.isArray(p.features) && p.features.length && typeof p.features[0] === "string") {
      features = p.features.map(function (f) {
        return "<li>" + ICONS.check + "<span>" + esc(f) + "</span></li>";
      }).join("");
    } else {
      features = (cfg.features || []).map(function (f) {
        return "<li" + (f.on ? "" : " data-off") + ">" + (f.on ? ICONS.check : ICONS.minus) + "<span>" + esc(f.text) + "</span></li>";
      }).join("");
    }
    var price = p.priceLabel != null && p.priceLabel !== ""
      ? p.priceLabel
      : (p.priceMinor != null ? (p.priceMinor ? money(p.priceMinor, p.currency) : "0") : (cfg.price ? (cfg.priceLabel + " " + (PRICING.currency || "")) : "0"));
    var name = p.name || cfg.name || p.code;
    var featured = typeof p.featured === "boolean" ? p.featured : !!cfg.featured;
    var cta;
    if (!paid) {
      var c = cfg.cta || {};
      cta = '<a class="btn btn--ghost btn--block plan__cta" href="' + esc(href(c.href || "/download/")) + '">' + esc(c.label || T("Начать бесплатно")) + "</a>";
    } else if (enabled) {
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
      '<div class="plan__price"><span class="plan__amount">' + esc(price) + '</span><span class="plan__period">/ ' + esc(period(p.days)) + "</span></div>" +
      '<p class="plan__note">' + esc(cfg.tagline || meta.join(" \u00b7 ") || "") + "</p>" +
      '<ul class="plan__features">' + features + "</ul>" + cta + "</article>";
  }

  function fromConfig() {
    return (PRICING.plans || []).map(function (c) {
      return {
        code: c.id, name: c.name, tier: c.id === "pro" ? 2 : c.id === "basic" ? 1 : 0, days: 30,
        priceMinor: (Number(c.price) || 0) * 100, currency: "KZT",
        priceLabel: c.price ? c.priceLabel + " " + (PRICING.currency || "") : "0",
        featured: !!c.featured, features: null
      };
    });
  }

  function render(plans, enabled) {
    var list = plans && plans.length ? plans.slice() : fromConfig();
    list.sort(function (a, b) { return (a.tier || 0) - (b.tier || 0) || (a.priceMinor || 0) - (b.priceMinor || 0); });
    hosts.forEach(function (host) {
      host.innerHTML = list.map(function (p) { return card(p, enabled); }).join("");
    });
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
    A.call("/api/billing/orders", { method: "POST", body: { planCode: code } })
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
        notice("<b>" + esc(T("Не удалось создать заказ")) + "</b><p class=\"billing-notice__text\">" + esc(human(e, T("Попробуйте ещё раз или напишите в поддержку."))) + "</p>", "err");
      });
  }

  document.addEventListener("click", function (e) {
    var btn = e.target && e.target.closest ? e.target.closest("[data-buy]") : null;
    if (!btn) return;
    e.preventDefault();
    buy(btn.getAttribute("data-buy"), btn);
  });

  /* ---------------------------------------------------------------- старт */
  function disabledMode(plans) {
    render(plans && plans.length ? plans : null, false);
    setPricingNote((PRICING.note || "") + (PRICING.note ? " " : "") + T("Кнопки оплаты включатся вместе с запуском биллинга."));
  }

  function boot() {
    var A = window.GlukAuth;
    if (!A || !A.public) { disabledMode(null); return; }
    A.public("/api/billing/plans").then(function (json) {
      var plans = (json && Array.isArray(json.plans)) ? json.plans.filter(function (p) { return p && p.code; }) : [];
      if (json && json.billingEnabled) {
        render(plans, true);
        var provider = json.provider ? String(json.provider) : "";
        setPricingNote(
          T("Оплата картой") + (provider ? " " + T("через") + " " + provider : "") + ". " +
          T("Подписка активируется автоматически после платежа; автосписаний нет.")
        );
      } else {
        disabledMode(plans);
      }
    }, function () { disabledMode(null); });
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", boot);
  else boot();
})();
