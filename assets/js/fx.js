/* Микро-анимации: счётчики, блик под курсором, наклон, магнитные кнопки,
   бегущая строка, смена фактов, прогресс чтения. Всё выключается при prefers-reduced-motion. */
(function () {
  "use strict";
  var reduced = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var $$ = function (s, r) { return [].slice.call((r || document).querySelectorAll(s)); };

  /* ---------- счётчики ---------- */
  function countUp(el) {
    var to = parseFloat(el.getAttribute("data-count-to") || "0");
    var dec = parseInt(el.getAttribute("data-dec") || "0", 10);
    var dur = parseInt(el.getAttribute("data-dur") || "1400", 10);
    var suffix = el.getAttribute("data-suffix") || "";
    if (reduced) { el.textContent = to.toFixed(dec) + suffix; return; }
    var t0 = 0;
    function frame(t) {
      if (!t0) t0 = t;
      var k = Math.min(1, (t - t0) / dur);
      var e = 1 - Math.pow(1 - k, 3);
      el.textContent = (to * e).toFixed(dec) + suffix;
      if (k < 1) requestAnimationFrame(frame);
    }
    requestAnimationFrame(frame);
  }

  var seen = new WeakSet();
  var io = "IntersectionObserver" in window
    ? new IntersectionObserver(function (entries) {
        entries.forEach(function (en) {
          if (en.isIntersecting && !seen.has(en.target)) { seen.add(en.target); countUp(en.target); }
        });
      }, { threshold: 0.4 })
    : null;
  $$("[data-count-to]").forEach(function (el) {
    if (io) io.observe(el); else countUp(el);
  });

  /* ---------- блик под курсором ---------- */
  var SPOT = ".card, .plan, .platform, .support-card, .auth-card, .map-card, [data-spotlight]";
  if (!reduced && window.matchMedia("(hover: hover)").matches) {
    $$(SPOT).forEach(function (el) {
      el.classList.add("fx-spot");
      el.addEventListener("pointermove", function (e) {
        var r = el.getBoundingClientRect();
        el.style.setProperty("--mx", ((e.clientX - r.left) / r.width * 100).toFixed(2) + "%");
        el.style.setProperty("--my", ((e.clientY - r.top) / r.height * 100).toFixed(2) + "%");
      });
      el.addEventListener("pointerleave", function () {
        el.style.setProperty("--mx", "50%");
        el.style.setProperty("--my", "-20%");
      });
    });
  }

  /* ---------- наклон ---------- */
  if (!reduced && window.matchMedia("(hover: hover)").matches) {
    $$("[data-tilt]").forEach(function (el) {
      var max = parseFloat(el.getAttribute("data-tilt")) || 6;
      el.addEventListener("pointermove", function (e) {
        var r = el.getBoundingClientRect();
        var px = (e.clientX - r.left) / r.width - 0.5;
        var py = (e.clientY - r.top) / r.height - 0.5;
        el.style.transform = "perspective(900px) rotateX(" + (-py * max).toFixed(2) + "deg) rotateY(" + (px * max).toFixed(2) + "deg)";
      });
      el.addEventListener("pointerleave", function () { el.style.transform = ""; });
    });

    /* ---------- магнитные кнопки ---------- */
    $$("[data-magnetic]").forEach(function (el) {
      el.addEventListener("pointermove", function (e) {
        var r = el.getBoundingClientRect();
        var dx = (e.clientX - r.left - r.width / 2) / r.width;
        var dy = (e.clientY - r.top - r.height / 2) / r.height;
        el.style.transform = "translate(" + (dx * 6).toFixed(1) + "px," + (dy * 5).toFixed(1) + "px)";
      });
      el.addEventListener("pointerleave", function () { el.style.transform = ""; });
    });
  }

  /* ---------- бегущая строка ---------- */
  $$("[data-marquee]").forEach(function (el) {
    var track = el.querySelector(".marquee__track");
    if (!track) return;
    track.innerHTML += track.innerHTML;
    if (reduced) track.style.animation = "none";
  });

  /* ---------- смена фактов ---------- */
  $$("[data-ticker]").forEach(function (el) {
    var items = $$(".ticker__item", el);
    if (items.length < 2) return;
    var i = 0;
    items.forEach(function (it, n) { it.classList.toggle("is-on", n === 0); });
    if (reduced) return;
    setInterval(function () {
      items[i].classList.remove("is-on");
      i = (i + 1) % items.length;
      items[i].classList.add("is-on");
    }, 2600);
  });

  /* ---------- прогресс чтения на длинных страницах ---------- */
  if (document.querySelector(".doc")) {
    var bar = document.createElement("div");
    bar.className = "read-progress";
    document.body.appendChild(bar);
    var tick = function () {
      var h = document.documentElement;
      var max = h.scrollHeight - h.clientHeight;
      bar.style.transform = "scaleX(" + (max > 0 ? h.scrollTop / max : 0).toFixed(4) + ")";
    };
    document.addEventListener("scroll", tick, { passive: true });
    tick();
  }

  /* ---------- живой счётчик сессий (декор, без претензий на точность) ---------- */
  $$("[data-drift]").forEach(function (el) {
    if (reduced) return;
    var base = parseFloat(el.getAttribute("data-drift")) || 0;
    setInterval(function () {
      var v = base + Math.round((Math.random() - 0.5) * 4);
      el.textContent = String(Math.max(0, v));
    }, 3200);
  });
})();

/* ============ v3: «нитки» безопасности рисуются пошагово ============ */
(function () {
  var flows = [].slice.call(document.querySelectorAll(".flow"));
  if (!flows.length) return;

  flows.forEach(function (flow) {
    [].slice.call(flow.children).forEach(function (el, i) {
      el.style.setProperty("--i", String(i));
    });
  });

  if (!("IntersectionObserver" in window)) {
    flows.forEach(function (f) {
      f.classList.add("is-live");
    });
    return;
  }

  var io = new IntersectionObserver(
    function (entries) {
      entries.forEach(function (en) {
        if (!en.isIntersecting) return;
        en.target.classList.add("is-live");
        io.unobserve(en.target);
      });
    },
    { threshold: 0.2, rootMargin: "0px 0px -8% 0px" }
  );
  flows.forEach(function (f) {
    io.observe(f);
  });
})();

/* ================== v4: счётчики, шкала скорости, лестница качества ================== */
(function () {
  "use strict";

  var mq = window.matchMedia ? window.matchMedia("(prefers-reduced-motion: reduce)") : null;
  var reduce = !!(mq && mq.matches);
  var nf = function (n) {
    try {
      var loc = (window.GlukI18n && window.GlukI18n.locale) || "ru-RU";
      return n.toLocaleString(loc);
    } catch (e) { return String(n); }
  };

  function countUp(el) {
    if (el.getAttribute("data-count-done") === "1") return;
    el.setAttribute("data-count-done", "1");
    var target = parseFloat(el.getAttribute("data-count"));
    if (isNaN(target)) return;
    var suffix = el.getAttribute("data-count-suffix") || "";
    if (reduce) { el.textContent = nf(target) + suffix; return; }
    var dur = 900 + Math.min(700, Math.abs(target) * 4);
    var t0 = 0;
    function step(ts) {
      if (!t0) t0 = ts;
      var p = Math.min(1, (ts - t0) / dur);
      var eased = 1 - Math.pow(1 - p, 3);
      var val = target * eased;
      el.textContent = nf(target % 1 === 0 ? Math.round(val) : Math.round(val * 10) / 10) + suffix;
      if (p < 1) requestAnimationFrame(step);
    }
    requestAnimationFrame(step);
  }

  function gauge(el) {
    var frac = parseFloat(el.getAttribute("data-gauge"));
    if (isNaN(frac)) return;
    var len = 290;
    try { len = el.getTotalLength ? el.getTotalLength() : 290; } catch (e) {}
    el.style.strokeDasharray = len;
    el.style.strokeDashoffset = len * (1 - Math.max(0, Math.min(1, frac)));
  }

  function activate(node) {
    if (node.hasAttribute("data-count")) countUp(node);
    if (node.hasAttribute("data-gauge")) gauge(node);
    if (node.classList.contains("acs-ladder")) node.classList.add("is-in");
    var kids = node.querySelectorAll("[data-count],[data-gauge]");
    for (var i = 0; i < kids.length; i++) {
      if (kids[i].hasAttribute("data-count")) countUp(kids[i]);
      if (kids[i].hasAttribute("data-gauge")) gauge(kids[i]);
    }
    var ladders = node.querySelectorAll(".acs-ladder");
    for (var j = 0; j < ladders.length; j++) ladders[j].classList.add("is-in");
  }

  function init() {
    var targets = document.querySelectorAll("[data-count],[data-gauge],.acs-ladder");
    if (!targets.length) return;
    if (!("IntersectionObserver" in window)) {
      for (var k = 0; k < targets.length; k++) activate(targets[k]);
      return;
    }
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (!e.isIntersecting) return;
        activate(e.target);
        io.unobserve(e.target);
      });
    }, { rootMargin: "0px 0px -12% 0px", threshold: 0.2 });
    for (var i = 0; i < targets.length; i++) io.observe(targets[i]);
  }

  if (mq && mq.addEventListener) {
    mq.addEventListener("change", function (e) { reduce = e.matches; });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
