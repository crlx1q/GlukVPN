/* ==========================================================================
   GlukVPN - общий UI-слой: шапка, мобильное меню, reveal, рендер из config

   Никаких внешних зависимостей и никаких запросов к API:
   все страницы статичны и работают без бэкенда.
   ========================================================================== */

(function () {
  "use strict";

  var CFG = window.GLUK_CONFIG || {};
  var BASE = document.documentElement.getAttribute("data-base") || ".";

  var $ = function (sel, root) {
    return (root || document).querySelector(sel);
  };
  var $$ = function (sel, root) {
    return Array.prototype.slice.call((root || document).querySelectorAll(sel));
  };

  /* внутренние ссылки в config хранятся как "/pricing/" - приводим их к пути
     текущей страницы, чтобы сайт работал и из подпапки, и локально */
  function href(u) {
    if (!u) return BASE + "/";
    if (/^(https?:|mailto:|tel:|#)/.test(u)) return u;
    if (u.charAt(0) === "/") return BASE + u;
    return u;
  }

  var ICONS = {
    check:
      '<svg viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="M5 12.5l4.2 4.2L19 7" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    minus:
      '<svg viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="M6 12h12" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"/></svg>',
    bolt:
      '<svg viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="M13 2L4.5 13.5H11l-1 8.5 8.5-11.5H12l1-8.5Z" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round"/></svg>',
  };

  /* --------------------------------------------------------------- header */
  function header() {
    var el = $(".header");
    if (!el) return;
    var onScroll = function () {
      el.classList.toggle("is-stuck", window.scrollY > 8);
    };
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });

    var burger = $(".burger");
    var drawer = $(".drawer");
    if (!burger || !drawer) return;
    var toggle = function (open) {
      burger.setAttribute("aria-expanded", String(open));
      drawer.classList.toggle("is-open", open);
      drawer.setAttribute("aria-hidden", String(!open));
      document.documentElement.style.overflow = open ? "hidden" : "";
    };
    /* Подложка: тап в любом месте экрана закрывает меню — без жеста "назад". */
    var backdrop = $(".drawer-backdrop");
    if (!backdrop) {
      backdrop = document.createElement("div");
      backdrop.className = "drawer-backdrop";
      /* в .page, а не в body: у .page свой z-index, иначе подложка ложится поверх меню */
      (document.querySelector(".page") || document.body).appendChild(backdrop);
    }
    var pushed = false;
    var setOpen = function (open) {
      toggle(open);
      backdrop.classList.toggle("is-on", open);
      if (open) {
        /* Аппаратная/жестовая "назад" закроет меню, а не страницу. */
        if (!pushed && window.history && history.pushState) {
          try { history.pushState({ glukDrawer: 1 }, ""); pushed = true; } catch (e) {}
        }
      } else if (pushed) {
        pushed = false;
        try { history.back(); } catch (e) {}
      }
    };
    burger.addEventListener("click", function (e) {
      e.stopPropagation();
      setOpen(burger.getAttribute("aria-expanded") !== "true");
    });
    backdrop.addEventListener("click", function () {
      setOpen(false);
    });
    /* Клик где угодно вне панели и вне самой кнопки. */
    document.addEventListener("click", function (e) {
      if (!drawer.classList.contains("is-open")) return;
      if (drawer.contains(e.target) || burger.contains(e.target)) return;
      setOpen(false);
    });
    $$(".drawer a").forEach(function (a) {
      a.addEventListener("click", function () {
        setOpen(false);
      });
    });
    document.addEventListener("keydown", function (e) {
      if (e.key === "Escape") setOpen(false);
    });
    window.addEventListener("popstate", function () {
      if (drawer.classList.contains("is-open")) {
        pushed = false;
        setOpen(false);
      }
    });
    window.addEventListener("resize", function () {
      if (window.innerWidth > 900 && drawer.classList.contains("is-open")) setOpen(false);
    });
  }

  /* --------------------------------------------------------------- reveal */
  function reveal() {
    var items = $$(".reveal");
    if (!items.length) return;
    if (!("IntersectionObserver" in window)) {
      items.forEach(function (i) {
        i.classList.add("is-in");
      });
      return;
    }
    var io = new IntersectionObserver(
      function (entries) {
        entries.forEach(function (e) {
          if (e.isIntersecting) {
            e.target.classList.add("is-in");
            io.unobserve(e.target);
          }
        });
      },
      { rootMargin: "0px 0px -8% 0px", threshold: 0.08 }
    );
    items.forEach(function (i) {
      io.observe(i);
    });
  }

  /* ------------------------------------------------------- цены из config */
  function priceText(plan) {
    var p = CFG.pricing || {};
    var label = plan.priceLabel != null ? plan.priceLabel : String(plan.price);
    if (!plan.price) return "0";
    return p.currencyPosition === "before"
      ? (p.currency || "") + label
      : label + " " + (p.currency || "");
  }

  function planCard(plan) {
    var p = CFG.pricing || {};
    var features = (plan.features || [])
      .map(function (f) {
        return (
          "<li" +
          (f.on ? "" : " data-off") +
          ">" +
          (f.on ? ICONS.check : ICONS.minus) +
          "<span>" +
          f.text +
          "</span></li>"
        );
      })
      .join("");
    var cta = plan.cta || {};
    return (
      '<article class="plan glass' +
      (plan.featured ? " plan--featured" : "") +
      '">' +
      '<div class="plan__head"><h3 class="plan__name">' +
      plan.name +
      "</h3>" +
      (plan.badge ? '<span class="chip chip--violet">' + plan.badge + "</span>" : "") +
      "</div>" +
      '<div class="plan__price"><span class="plan__amount">' +
      priceText(plan) +
      '</span><span class="plan__period">/ ' +
      (p.period || "мес") +
      "</span></div>" +
      '<p class="plan__note">' +
      (plan.tagline || "") +
      "</p>" +
      '<ul class="plan__features">' +
      features +
      "</ul>" +
      '<a class="btn ' +
      (plan.featured ? "btn--primary" : "btn--ghost") +
      ' btn--block plan__cta" href="' +
      href(cta.href) +
      '">' +
      (cta.label || "Выбрать") +
      "</a>" +
      "</article>"
    );
  }

  function renderPlans() {
    var hosts = $$("[data-plans]");
    var plans = (CFG.pricing && CFG.pricing.plans) || [];
    if (!hosts.length || !plans.length) return;
    hosts.forEach(function (host) {
      host.innerHTML = plans.map(planCard).join("");
    });
    $$("[data-pricing-note]").forEach(function (n) {
      n.textContent = (CFG.pricing && CFG.pricing.note) || "";
    });
  }

  /* --------------------------------------------------- ссылки на загрузку */
  function downloads() {
    var d = CFG.downloads || {};
    var android = d.android || {};
    $$("[data-download-android]").forEach(function (a) {
      if (android.url) {
        a.setAttribute("href", android.url);
        a.setAttribute("download", "");
      }
      /* если ссылки на сборку пока нет - оставляем адрес из разметки (/download/) */
    });
    $$("[data-android-note]").forEach(function (n) {
      n.textContent = android.url
        ? android.note || ""
        : "Ссылка на сборку публикуется на странице загрузок.";
    });
    $$("[data-telegram]").forEach(function (a) {
      a.setAttribute("href", (CFG.site && CFG.site.telegram) || "#");
    });
    $$("[data-telegram-label]").forEach(function (el) {
      el.textContent = (CFG.site && CFG.site.telegramLabel) || "";
    });
    $$("[data-support-email]").forEach(function (a) {
      var mail = (CFG.site && CFG.site.supportEmail) || "";
      a.setAttribute("href", "mailto:" + mail);
      if (a.hasAttribute("data-fill-text")) a.textContent = mail;
    });
  }

  /* ------------------------------------------------------------- регионы */
  function regionRow(n) {
    var soon = n.status === "soon";
    var tag = soon ? "div" : "button";
    var meta = soon
      ? '<span class="region__meta"><span>' + (n.city || "") + "</span></span>"
      : '<span class="region__meta">' +
        ICONS.bolt +
        "<span>~" +
        n.ping +
        " мс</span>" +
        '<span class="load-bar" aria-hidden="true"><span style="width:' +
        n.load +
        '%"></span></span>' +
        "<span>загрузка " +
        n.load +
        "%</span></span>";
    return (
      "<" +
      tag +
      ' class="region' +
      (soon ? " region--soon" : "") +
      '" data-region="' +
      n.id +
      '"' +
      (soon ? "" : ' type="button"') +
      ">" +
      '<span class="region__flag" aria-hidden="true">' +
      n.flag +
      "</span>" +
      '<span class="region__info"><span class="region__name">' +
      n.name +
      "</span>" +
      meta +
      "</span>" +
      (soon
        ? '<span class="chip chip--soon">Скоро</span>'
        : '<span class="chip chip--live"><i class="chip__dot"></i>Онлайн</span>') +
      "</" +
      tag +
      ">"
    );
  }

  function renderRegions() {
    var hosts = $$("[data-regions]");
    var nodes = (CFG.network && CFG.network.nodes) || [];
    if (!hosts.length || !nodes.length) return;
    hosts.forEach(function (host) {
      var mode = host.getAttribute("data-regions");
      var list = nodes.filter(function (n) {
        if (mode === "live") return n.status !== "soon";
        if (mode === "soon") return n.status === "soon";
        return true;
      });
      host.innerHTML = list.map(regionRow).join("");
    });
  }

  /* ------------------------------------------------------------- мелочи */
  function misc() {
    $$("[data-year]").forEach(function (el) {
      el.textContent = new Date().getFullYear();
    });
    $$("[data-site-domain]").forEach(function (el) {
      el.textContent = (CFG.site && CFG.site.domain) || "";
    });
    $$("[data-live-count]").forEach(function (el) {
      el.textContent = String(
        ((CFG.network && CFG.network.nodes) || []).filter(function (x) {
          return x.status !== "soon";
        }).length
      );
    });
  }

  function init() {
    header();
    renderPlans();
    renderRegions();
    downloads();
    misc();
    reveal();
    if (window.GlukSections) window.GlukSections.init();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();

/* ===================== v3: плавное раскрытие FAQ ===================== */
(function () {
  var items = [].slice.call(document.querySelectorAll(".faq__item"));
  if (!items.length) return;
  var reduce =
    window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  items.forEach(function (item) {
    var head = item.querySelector(".faq__q");
    var body = item.querySelector(".faq__a");
    if (!head || !body) return;

    var inner = body.querySelector(".faq__inner");
    if (!inner) {
      inner = document.createElement("div");
      inner.className = "faq__inner";
      while (body.firstChild) inner.appendChild(body.firstChild);
      body.appendChild(inner);
    }

    var busy = false;
    head.addEventListener("click", function (e) {
      if (reduce || busy) return;
      e.preventDefault();
      busy = true;

      if (item.open) {
        body.style.height = inner.offsetHeight + "px";
        body.style.opacity = "1";
        requestAnimationFrame(function () {
          body.style.height = "0px";
          body.style.opacity = "0";
        });
        window.setTimeout(function () {
          item.open = false;
          body.style.height = "";
          body.style.opacity = "";
          busy = false;
        }, 340);
      } else {
        item.open = true;
        body.style.height = "0px";
        body.style.opacity = "0";
        requestAnimationFrame(function () {
          body.style.height = inner.offsetHeight + "px";
          body.style.opacity = "1";
        });
        window.setTimeout(function () {
          body.style.height = "";
          body.style.opacity = "";
          busy = false;
        }, 360);
      }
    });
  });
})();
