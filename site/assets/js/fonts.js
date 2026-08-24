/* ==========================================================================
   Панель выбора шрифта (только на время беты).

   Все варианты — с кириллицей. Сгруппированы по характеру, а не по алфавиту:
   интерфейсные, строгие, геометричные, мягкие, серифные.
   Часть вариантов — пары: один шрифт на заголовки (--font-display),
   другой на текст (--font-sans).

   Когда вариант выбран: ui.fontPicker=false в config.js, а выбранные
   семейства вписываются в tokens.css (--font и --font-display).
   ========================================================================== */
(function () {
  "use strict";

  var STACK = "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,'Helvetica Neue',Arial,sans-serif";
  var SERIF = "Georgia,'Times New Roman',serif";
  var MONO = "ui-monospace,SFMono-Regular,Menlo,Consolas,monospace";
  var KEY = "gluk.font";

  /* g — параметр family для Google Fonts; fb — резервный стек.
     head — шрифт заголовков, если отличается от текстового. */
  var GROUPS = [
    {
      title: "Интерфейсные",
      fonts: [
        { id: "onest", name: "Onest", note: "текущий фаворит", body: { css: "Onest", g: "Onest:wght@400;500;600;700", fb: STACK } },
        { id: "inter", name: "Inter", note: "нейтральный", body: { css: "Inter", g: "Inter:wght@400;500;600;700", fb: STACK } },
        { id: "commissioner", name: "Commissioner", note: "тёплый гротеск", body: { css: "Commissioner", g: "Commissioner:wght@400;500;600;700", fb: STACK } },
        { id: "manrope", name: "Manrope", note: "мягкая геометрия", body: { css: "Manrope", g: "Manrope:wght@400;500;600;700", fb: STACK } }
      ]
    },
    {
      title: "Строгие и технические",
      fonts: [
        { id: "plex", name: "IBM Plex Sans", note: "инженерный, сухой", body: { css: "IBM Plex Sans", g: "IBM+Plex+Sans:wght@400;500;600;700", fb: STACK } },
        { id: "fira", name: "Fira Sans", note: "спокойный, читаемый", body: { css: "Fira Sans", g: "Fira+Sans:wght@400;500;600;700", fb: STACK } },
        { id: "ubuntu", name: "Ubuntu", note: "с характерными окончаниями", body: { css: "Ubuntu", g: "Ubuntu:wght@400;500;700", fb: STACK } },
        { id: "mono", name: "JetBrains Mono + Inter", note: "терминальные заголовки", head: { css: "JetBrains Mono", g: "JetBrains+Mono:wght@400;500;700", fb: MONO }, body: { css: "Inter", g: "Inter:wght@400;500;600;700", fb: STACK } }
      ]
    },
    {
      title: "Геометрия и характер",
      fonts: [
        { id: "jost", name: "Jost", note: "в духе Futura", body: { css: "Jost", g: "Jost:wght@400;500;600;700", fb: STACK } },
        { id: "montserrat", name: "Montserrat", note: "широкий, уверенный", body: { css: "Montserrat", g: "Montserrat:wght@400;500;600;700", fb: STACK } },
        { id: "oswald", name: "Oswald + Inter", note: "узкие плакатные заголовки", head: { css: "Oswald", g: "Oswald:wght@400;500;600", fb: STACK }, body: { css: "Inter", g: "Inter:wght@400;500;600;700", fb: STACK } },
        { id: "unbounded", name: "Unbounded + Onest", note: "дисплейный, громкий", head: { css: "Unbounded", g: "Unbounded:wght@400;500;600;700", fb: STACK }, body: { css: "Onest", g: "Onest:wght@400;500;600;700", fb: STACK } }
      ]
    },
    {
      title: "Мягкие и милые",
      fonts: [
        { id: "nunito", name: "Nunito", note: "скруглённый, дружелюбный", body: { css: "Nunito", g: "Nunito:wght@400;500;600;700", fb: STACK } },
        { id: "rubik", name: "Rubik", note: "мягкие углы", body: { css: "Rubik", g: "Rubik:wght@400;500;600;700", fb: STACK } },
        { id: "comfortaa", name: "Comfortaa + Nunito", note: "очень круглые заголовки", head: { css: "Comfortaa", g: "Comfortaa:wght@400;500;600;700", fb: STACK }, body: { css: "Nunito", g: "Nunito:wght@400;500;600;700", fb: STACK } },
        { id: "podkova", name: "Podkova + Rubik", note: "скруглённый слэб", head: { css: "Podkova", g: "Podkova:wght@400;500;600;700", fb: SERIF }, body: { css: "Rubik", g: "Rubik:wght@400;500;600;700", fb: STACK } }
      ]
    },
    {
      title: "Серифные и книжные",
      fonts: [
        { id: "playfair", name: "Playfair Display + Inter", note: "контрастный, премиальный", head: { css: "Playfair Display", g: "Playfair+Display:wght@400;500;600;700", fb: SERIF }, body: { css: "Inter", g: "Inter:wght@400;500;600;700", fb: STACK } },
        { id: "cormorant", name: "Cormorant Garamond + Manrope", note: "тонкий, изящный", head: { css: "Cormorant Garamond", g: "Cormorant+Garamond:wght@400;500;600;700", fb: SERIF }, body: { css: "Manrope", g: "Manrope:wght@400;500;600;700", fb: STACK } },
        { id: "ptserif", name: "PT Serif + PT Sans", note: "кириллица как родная", head: { css: "PT Serif", g: "PT+Serif:wght@400;700", fb: SERIF }, body: { css: "PT Sans", g: "PT+Sans:wght@400;700", fb: STACK } },
        { id: "piazzolla", name: "Piazzolla", note: "современный серив", body: { css: "Piazzolla:opsz@8..30", g: "Piazzolla:opsz,wght@8..30,400;8..30,500;8..30,600;8..30,700", fb: SERIF } },
        { id: "lora", name: "Lora", note: "спокойный книжный", body: { css: "Lora", g: "Lora:wght@400;500;600;700", fb: SERIF } }
      ]
    },
    {
      title: "Без загрузки",
      fonts: [
        { id: "system", name: "Системный", note: "шрифт устройства", body: { css: "", g: "", fb: STACK } }
      ]
    }
  ];

  var ALL = [];
  GROUPS.forEach(function (g) { g.fonts.forEach(function (f) { ALL.push(f); }); });

  function byId(id) {
    for (var i = 0; i < ALL.length; i++) if (ALL[i].id === id) return ALL[i];
    return null;
  }
  function stackOf(part) {
    if (!part) return null;
    var name = part.css ? part.css.split(":")[0] : "";
    return name ? "'" + name + "'," + part.fb : part.fb;
  }

  /* Загрузка семейств одним запросом к Google Fonts */
  var requested = {};
  function loadFamilies(list) {
    var fresh = [];
    list.forEach(function (g) {
      if (g && !requested[g]) { requested[g] = true; fresh.push(g); }
    });
    if (!fresh.length) return;
    var l = document.createElement("link");
    l.rel = "stylesheet";
    l.href = "https://fonts.googleapis.com/css2?family=" + fresh.join("&family=") + "&display=swap";
    document.head.appendChild(l);
  }
  function loadFont(f) {
    loadFamilies([f.body && f.body.g, f.head && f.head.g]);
  }

  function apply(id, remember) {
    var f = byId(id) || ALL[0];
    loadFont(f);
    var body = stackOf(f.body);
    var head = stackOf(f.head) || body;
    var root = document.documentElement;
    root.style.setProperty("--font-sans", body);
    root.style.setProperty("--font-display", head);
    root.setAttribute("data-font", f.id);
    if (remember) { try { localStorage.setItem(KEY, f.id); } catch (e) {} }
    var panel = document.querySelector("[data-fontpanel]");
    if (panel) {
      Array.prototype.forEach.call(panel.querySelectorAll("[data-font-id]"), function (b) {
        b.classList.toggle("is-active", b.getAttribute("data-font-id") === f.id);
      });
      var cur = panel.querySelector("[data-font-current]");
      if (cur) cur.textContent = f.name;
    }
  }

  var saved = null;
  try { saved = localStorage.getItem(KEY); } catch (e) {}
  var q = (location.search.match(/[?&]font=([a-z]+)/) || [])[1];
  if (q && byId(q)) saved = q;
  var UICFG = (window.GLUK_CONFIG && window.GLUK_CONFIG.ui) || {};
  if (UICFG.fontPicker === false && !q) saved = null;
  var initial = saved && byId(saved) ? saved : "nunito";
  apply(initial, false);

  var UI = (window.GLUK_CONFIG && window.GLUK_CONFIG.ui) || {};
  if (UI.fontPicker === false) return;

  var CSS =
    ".fontpick{position:fixed;right:18px;bottom:18px;z-index:80;font-size:13px}" +
    ".fontpick__btn{display:flex;align-items:center;gap:9px;padding:10px 15px;border-radius:999px;border:1px solid var(--stroke);background:var(--glass-3);backdrop-filter:blur(18px);-webkit-backdrop-filter:blur(18px);color:var(--text-0);font:inherit;font-weight:600;cursor:pointer;box-shadow:0 12px 40px rgba(0,0,0,.45);transition:transform .18s,border-color .18s}" +
    ".fontpick__btn:hover{transform:translateY(-2px);border-color:var(--stroke-violet)}" +
    ".fontpick__btn i{font-style:normal;font-size:15px;letter-spacing:-.02em}" +
    ".fontpick__btn small{color:var(--text-2);font-weight:500;max-width:120px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}" +
    ".fontpick__panel{position:absolute;right:0;bottom:calc(100% + 10px);width:330px;max-height:min(72vh,620px);overflow-y:auto;padding:14px;border-radius:20px;border:1px solid var(--stroke);background:var(--glass-3);backdrop-filter:blur(24px);-webkit-backdrop-filter:blur(24px);box-shadow:0 26px 70px rgba(0,0,0,.6);opacity:0;visibility:hidden;transform:translateY(8px);transition:opacity .2s,transform .2s,visibility .2s;overscroll-behavior:contain}" +
    ".fontpick.is-open .fontpick__panel{opacity:1;visibility:visible;transform:none}" +
    ".fontpick__title{font-size:11px;letter-spacing:.09em;text-transform:uppercase;color:var(--text-2);margin:2px 2px 10px}" +
    ".fontpick__group{font-size:10.5px;letter-spacing:.1em;text-transform:uppercase;color:var(--violet-light);opacity:.75;margin:12px 4px 6px}" +
    ".fontpick__item{display:block;width:100%;text-align:left;padding:9px 12px;margin-bottom:4px;border-radius:14px;border:1px solid transparent;background:rgba(255,255,255,.03);color:var(--text-0);cursor:pointer;transition:background .18s,border-color .18s}" +
    ".fontpick__item:hover{background:rgba(255,255,255,.07)}" +
    ".fontpick__item.is-active{border-color:var(--stroke-violet);background:rgba(124,92,246,.14)}" +
    ".fontpick__name{display:flex;align-items:baseline;justify-content:space-between;gap:8px;font-size:12px;font-weight:600;color:var(--text-1);font-family:inherit}" +
    ".fontpick__name em{font-style:normal;font-size:10.5px;color:var(--text-2);font-weight:400;white-space:nowrap}" +
    ".fontpick__demo{display:block;margin-top:2px;font-size:17px;line-height:1.25;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}" +
    ".fontpick__sub{display:block;margin-top:1px;font-size:12px;color:var(--text-1);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}" +
    ".fontpick__hint{margin:12px 2px 2px;font-size:11.5px;color:var(--text-2);line-height:1.45}" +
    "@media (max-width:640px){.fontpick{right:12px;bottom:12px}.fontpick__panel{width:min(330px,calc(100vw - 28px))}.fontpick__btn small{display:none}}";

  function mount() {
    var style = document.createElement("style");
    style.textContent = CSS;
    document.head.appendChild(style);

    var html = "";
    GROUPS.forEach(function (g) {
      html += '<div class="fontpick__group">' + g.title + "</div>";
      g.fonts.forEach(function (f) {
        var body = stackOf(f.body);
        var head = stackOf(f.head) || body;
        html +=
          '<button class="fontpick__item" type="button" data-font-id="' + f.id + '">' +
          '<span class="fontpick__name">' + f.name + " <em>" + f.note + "</em></span>" +
          '<span class="fontpick__demo" style="font-family:' + head + '">Быстрый VPN — 24 мс</span>' +
          '<span class="fontpick__sub" style="font-family:' + body + '">Одно нажатие и трафик в туннеле · Aa Бб 123</span>' +
          "</button>";
      });
    });

    var wrap = document.createElement("div");
    wrap.className = "fontpick";
    wrap.setAttribute("data-fontpanel", "");
    wrap.innerHTML =
      '<div class="fontpick__panel" role="dialog" aria-label="Выбор шрифта">' +
      '<div class="fontpick__title">Шрифт сайта · бета</div>' + html +
      '<p class="fontpick__hint">В парах первый шрифт идёт на заголовки, второй — на текст. Выбор сохраняется в браузере и действует на всех страницах.</p></div>' +
      '<button class="fontpick__btn" type="button" data-font-toggle aria-expanded="false">' +
      "<i>Aa</i> Шрифт <small data-font-current></small></button>";
    document.body.appendChild(wrap);

    var btn = wrap.querySelector("[data-font-toggle]");
    btn.addEventListener("click", function (e) {
      e.stopPropagation();
      var open = wrap.classList.toggle("is-open");
      btn.setAttribute("aria-expanded", String(open));
      if (open) ALL.forEach(loadFont);
    });
    wrap.addEventListener("click", function (e) {
      var item = e.target && e.target.closest ? e.target.closest("[data-font-id]") : null;
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

    apply(initial, false);
    if (/[?&]fontpanel=1/.test(location.search)) {
      wrap.classList.add("is-open");
      btn.setAttribute("aria-expanded", "true");
      ALL.forEach(loadFont);
    }
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", mount);
  else mount();
})();
