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
