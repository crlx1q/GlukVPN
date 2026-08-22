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
