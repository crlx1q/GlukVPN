/* ==========================================================================
   GlukVPN - сборка сцены: глобус в hero, карта сети, экраны приложения.
   Все данные берутся из config.js. Сетевых запросов нет.
   ========================================================================== */

(function () {
  "use strict";

  var CFG = window.GLUK_CONFIG || {};
  var reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var $ = function (s, r) {
    return (r || document).querySelector(s);
  };
  var $$ = function (s, r) {
    return Array.prototype.slice.call((r || document).querySelectorAll(s));
  };

  function liveNodes() {
    return ((CFG.network && CFG.network.nodes) || []).filter(function (n) {
      return n.status !== "soon";
    });
  }

  /* ------------------------------------------------------------ hero globe */
  function initGlobe() {
    var canvas = $("[data-globe]");
    if (!canvas || !window.GlukGlobe) return;
    var net = CFG.network || {};

    var caption = {
      region: $("[data-caption-region]"),
      ping: $("[data-caption-ping]"),
    };
    var setCaption = function (node) {
      if (!node) return;
      if (caption.region) caption.region.textContent = node.name;
      if (caption.ping) caption.ping.textContent = "~" + node.ping + " мс";
    };

    setCaption(liveNodes()[0]);

    new window.GlukGlobe(canvas, {
      home: net.home,
      nodes: net.nodes || [],
      tilt: 15,
      dotSize: 1.6,
      radius: 0.8,
      cycle: 6400,
      onRoute: setCaption,
    });
  }

  /* ------------------------------------------------------------ карта сети */
  function initNetwork() {
    var canvas = $("[data-network-map]");
    if (!canvas || !window.GlukNetworkMap) return;
    var net = CFG.network || {};
    var tip = $("[data-map-tip]");
    var tipName = tip ? $("[data-tip-name]", tip) : null;
    var tipFlag = tip ? $("[data-tip-flag]", tip) : null;
    var tipRows = tip ? $("[data-tip-rows]", tip) : null;

    var map = new window.GlukNetworkMap(canvas, {
      home: net.home,
      nodes: net.nodes || [],
      interactive: true,
      cycle: 5200,
      onHover: function (node, hit) {
        if (!tip) return;
        if (!node) {
          tip.classList.remove("is-on");
          return;
        }
        if (tipFlag) tipFlag.innerHTML = node.flag || "";
        if (tipName) tipName.textContent = node.name + " · " + (node.city || "");
        if (tipRows) {
          tipRows.innerHTML =
            node.status === "soon"
              ? '<div class="tip__row"><span>Статус</span><b>Скоро</b></div>'
              : '<div class="tip__row"><span>Отклик</span><b>~' +
                node.ping +
                ' мс</b></div><div class="tip__row"><span>Загрузка</span><b>' +
                node.load +
                '%</b></div><div class="tip__row"><span>Статус</span><b style="color:var(--green)">Онлайн</b></div>';
        }
        tip.style.left = hit.x + "px";
        tip.style.top = hit.y + "px";
        tip.classList.add("is-on");
      },
      onSelect: function (node) {
        if (node.status === "soon") return;
        setActiveRegion(node.id);
        map.focus(node.id);
      },
    });

    function setActiveRegion(id) {
      $$("[data-region]").forEach(function (el) {
        el.classList.toggle("is-active", el.getAttribute("data-region") === id);
      });
    }

    $$("[data-region]").forEach(function (el) {
      if (el.classList.contains("region--soon")) return;
      var id = el.getAttribute("data-region");
      var focus = function () {
        setActiveRegion(id);
        map.focus(id);
      };
      el.addEventListener("mouseenter", focus);
      el.addEventListener("focus", focus);
      el.addEventListener("click", focus);
    });

    var first = liveNodes()[0];
    if (first) setActiveRegion(first.id);
  }

  /* ------------------------------------------------- экраны приложения */
  function initPhones() {
    var net = CFG.network || {};

    /* карта на главном экране приложения */
    $$("[data-phone-map]").forEach(function (canvas) {
      if (!window.GlukNetworkMap) return;
      new window.GlukNetworkMap(canvas, {
        home: net.home,
        nodes: (net.nodes || []).filter(function (n) {
          return n.status !== "soon";
        }),
        compact: true,
        dotSize: 1.05,
        fixedRoute: canvas.getAttribute("data-phone-map") || "de",
        view: { x: 34, y: 2, w: 62, h: 30 },
      });
    });

    /* планета на экране онбординга */
    $$("[data-onb-globe]").forEach(function (canvas) {
      if (!window.GlukGlobe) return;
      new window.GlukGlobe(canvas, {
        home: net.home,
        nodes: net.nodes || [],
        tilt: 14,
        dotSize: 1.15,
        radius: 0.94,
        spin: 0.02,
        cycle: 5200,
      });
    });

    /* живые счётчики в карточках (демо-значения, не телеметрия) */
    var timer = $("[data-demo-timer]");
    var down = $("[data-demo-down]");
    var up = $("[data-demo-up]");
    var ping = $("[data-demo-ping]");
    if (!timer && !down) return;
    if (reduced) return;

    var t = 5 * 60 + 42;
    var dv = 1.24;
    var uv = 0.36;
    var pv = 24;

    var pad = function (n) {
      return n < 10 ? "0" + n : String(n);
    };

    var tick = function () {
      if (document.hidden) return;
      t += 1;
      dv += Math.random() * 0.05;
      uv += Math.random() * 0.02;
      pv = Math.max(18, Math.min(34, pv + (Math.random() * 4 - 2)));
      if (timer)
        timer.textContent =
          pad(Math.floor(t / 3600)) +
          ":" +
          pad(Math.floor((t % 3600) / 60)) +
          ":" +
          pad(t % 60);
      if (down) down.textContent = dv.toFixed(2) + " GB";
      if (up) up.textContent = uv.toFixed(2) + " GB";
      if (ping) ping.textContent = Math.round(pv);
    };
    tick();
    setInterval(tick, 1000);
  }

  /* --------------------------------------------- масштаб телефонов */
  function scalePhones() {
    var apply = function () {
      $$(".phone-scale").forEach(function (el) {
        var max = parseFloat(el.getAttribute("data-scale-max") || "0.78");
        var host = el.parentElement;
        if (!host) return;
        var avail = host.clientWidth;
        var count = el.getAttribute("data-scale-share") === "2" ? 1.55 : 1;
        var scale = Math.min(max, (avail / count - 24) / 390);
        el.style.setProperty("--scale", Math.max(0.34, scale).toFixed(3));
      });
    };
    apply();
    window.addEventListener("resize", apply, { passive: true });
  }

  window.GlukSections = {
    init: function () {
      scalePhones();
      initGlobe();
      initNetwork();
      initPhones();
    },
  };
})();
