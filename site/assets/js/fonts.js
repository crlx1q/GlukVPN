/* ==========================================================================
   Панель выбора шрифта (только на время беты).
   Все варианты — с полной кириллицей и латиницей.
   Выбор сохраняется в localStorage и применяется ко всем страницам.
   Когда шрифт выбран: ставим ui.fontPicker=false в config.js и вписываем
   его в fonts.css как основной.
   ========================================================================== */
(function () {
  "use strict";

  var FONTS = [
    { id: "inter", name: "Inter", css: "Inter", g: "Inter:wght@400;500;600;700", note: "Нейтральный интерфейсный" },
    { id: "manrope", name: "Manrope", css: "Manrope", g: "Manrope:wght@400;500;600;700", note: "Геометричный, мягкий" },
    { id: "onest", name: "Onest", css: "Onest", g: "Onest:wght@400;500;600;700", note: "Современный, плотный" },
    { id: "golos", name: "Golos Text", css: "Golos Text", g: "Golos+Text:wght@400;500;600;700", note: "Кириллица как родная" },
    { id: "geologica", name: "Geologica", css: "Geologica", g: "Geologica:wght@400;500;600;700", note: "Технологичный" },
    { id: "unbounded", name: "Unbounded", css: "Unbounded", g: "Unbounded:wght@400;500;600;700", note: "Дисплейный, характерный" },
    { id: "system", name: "Системный", css: "", g: "", note: "Без внешних загрузок" }
  ];
  var STACK = "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,'Helvetica Neue',Arial,sans-serif";
  var KEY = "gluk.font";
  var loaded = {};

  function byId(id) {
    for (var i = 0; i < FONTS.length; i++) if (FONTS[i].id === id) return FONTS[i];
    return null;
  }
  function load(f) {
    if (!f.g || loaded[f.id]) return;
    loaded[f.id] = true;
    var l = document.createElement("link");
    l.rel = "stylesheet";
    l.href = "https://fonts.googleapis.com/css2?family=" + f.g + "&display=swap";
    document.head.appendChild(l);
  }
  function apply(id, remember) {
    var f = byId(id) || FONTS[0];
    load(f);
    document.documentElement.style.setProperty("--font-sans", f.css ? "'" + f.css + "'," + STACK : STACK);
    document.documentElement.setAttribute("data-font", f.id);
    if (remember) { try { localStorage.setItem(KEY, f.id); } catch (e) {} }
    var panel = document.querySelector("[data-fontpanel]");
    if (panel) {
      Array.prototype.forEach.call(panel.querySelectorAll("[data-font-id]"), function (b) {
        b.classList.toggle("is-active", b.getAttribute("data-font-id") === f.id);
      });
    }
  }

  var saved = null;
  try { saved = localStorage.getItem(KEY); } catch (e) {}
  var q = (location.search.match(/[?&]font=([a-z]+)/) || [])[1];
  if (q && byId(q)) saved = q;
  if (saved && byId(saved)) apply(saved, false);

  var UI = (window.GLUK_CONFIG && window.GLUK_CONFIG.ui) || {};
  if (UI.fontPicker === false) return;

  var CSS =
    ".fontpick{position:fixed;right:18px;bottom:18px;z-index:80;font-size:13px}" +
    ".fontpick__btn{display:flex;align-items:center;gap:8px;padding:10px 14px;border-radius:999px;border:1px solid var(--stroke);background:var(--glass-3);backdrop-filter:blur(18px);-webkit-backdrop-filter:blur(18px);color:var(--text-0);font:inherit;font-weight:600;cursor:pointer;box-shadow:0 12px 40px rgba(0,0,0,.45);transition:transform .18s,border-color .18s}" +
    ".fontpick__btn:hover{transform:translateY(-2px);border-color:var(--stroke-violet)}" +
    ".fontpick__btn i{font-style:normal;font-size:15px;letter-spacing:-.02em}" +
    ".fontpick__panel{position:absolute;right:0;bottom:calc(100% + 10px);width:290px;padding:14px;border-radius:20px;border:1px solid var(--stroke);background:var(--glass-3);backdrop-filter:blur(24px);-webkit-backdrop-filter:blur(24px);box-shadow:0 26px 70px rgba(0,0,0,.6);opacity:0;visibility:hidden;transform:translateY(8px);transition:opacity .2s,transform .2s,visibility .2s}" +
    ".fontpick.is-open .fontpick__panel{opacity:1;visibility:visible;transform:none}" +
    ".fontpick__title{font-size:11px;letter-spacing:.09em;text-transform:uppercase;color:var(--text-2);margin:2px 2px 10px}" +
    ".fontpick__item{display:block;width:100%;text-align:left;padding:10px 12px;margin-bottom:4px;border-radius:14px;border:1px solid transparent;background:rgba(255,255,255,.03);color:var(--text-0);cursor:pointer;transition:background .18s,border-color .18s}" +
    ".fontpick__item:hover{background:rgba(255,255,255,.07)}" +
    ".fontpick__item.is-active{border-color:var(--stroke-violet);background:rgba(124,92,246,.14)}" +
    ".fontpick__name{display:flex;align-items:baseline;justify-content:space-between;gap:8px;font-size:14px;font-weight:600}" +
    ".fontpick__name em{font-style:normal;font-size:11px;color:var(--text-2);font-weight:400}" +
    ".fontpick__demo{margin-top:3px;font-size:13px;color:var(--text-1);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}" +
    ".fontpick__hint{margin:8px 2px 0;font-size:11.5px;color:var(--text-2);line-height:1.45}" +
    "@media (max-width:640px){.fontpick{right:12px;bottom:12px}.fontpick__panel{width:min(290px,calc(100vw - 32px))}}";

  function mount() {
    var style = document.createElement("style");
    style.textContent = CSS;
    document.head.appendChild(style);

    var wrap = document.createElement("div");
    wrap.className = "fontpick";
    wrap.setAttribute("data-fontpanel", "");
    var items = FONTS.map(function (f) {
      var stack = f.css ? "'" + f.css + "'," + STACK : STACK;
      return (
        '<button class="fontpick__item" type="button" data-font-id="' + f.id + '" style="font-family:' + stack + '">' +
        '<span class="fontpick__name">' + f.name + " <em>" + f.note + "</em></span>" +
        '<span class="fontpick__demo">Привет, GlukVPN — 24 мс · Aa Бб</span></button>"
      );
    }).join("");
    wrap.innerHTML =
      '<div class="fontpick__panel" role="dialog" aria-label="Выбор шрифта">' +
      '<div class="fontpick__title">Шрифт сайта · бета</div>' + items +
      '<p class="fontpick__hint">Выбор сохраняется в браузере и действует на всех страницах.</p></div>' +
      '<button class="fontpick__btn" type="button" data-font-toggle aria-expanded="false"><i>Aa</i> Шрифт</button>';
    document.body.appendChild(wrap);

    var btn = wrap.querySelector("[data-font-toggle]");
    btn.addEventListener("click", function (e) {
      e.stopPropagation();
      var open = wrap.classList.toggle("is-open");
      btn.setAttribute("aria-expanded", String(open));
      if (open) FONTS.forEach(load);
    });
    wrap.addEventListener("click", function (e) {
      var item = e.target.closest("[data-font-id]");
      if (!item) return;
      apply(item.getAttribute("data-font-id"), true);
    });
    document.addEventListener("click", function (e) {
      if (!wrap.contains(e.target)) {
        wrap.classList.remove("is-open");
        btn.setAttribute("aria-expanded", "false");
      }
    });
    document.addEventListener("keydown", function (e) {
      if (e.key === "Escape") {
        wrap.classList.remove("is-open");
        btn.setAttribute("aria-expanded", "false");
      }
    });
    apply(saved && byId(saved) ? saved : "inter", false);
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", mount);
  else mount();
})();
