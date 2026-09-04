/* Космическая сфера GlukVPN на экране входа.

   Правая половина /login/ раньше была набором CSS-градиентов: красиво, но
   мертво. Здесь настоящая сцена на canvas - звёздное поле, медленно
   вращающийся глобус с сеткой параллелей и меридианов, точки реальных узлов
   сети и бегущие по великим окружностям нити между ними.

   Что важно и почему:
     - координаты узлов берутся из GLUK_CONFIG.network, то есть это те же
       точки, что рисует карта на главной. Ничего не выдумываем: нет
       координат - нет точки;
     - один requestAnimationFrame, никаких таймеров. Кадры не считаются,
       пока вкладка скрыта или сцена уехала за пределы экрана;
     - prefers-reduced-motion: рисуем один статичный кадр и выходим;
     - размеры пересчитываются от devicePixelRatio, поэтому на HiDPI сфера
       не мылится, а на мобильных сцена просто не монтируется - там её
       прячет CSS, и жечь батарею незачем.

   Монтирует сцену login.js: window.GlukCosmos.mount(canvas). */
(function () {
  "use strict";

  var DEG = Math.PI / 180;
  var TAU = Math.PI * 2;

  function net() {
    return (window.GLUK_CONFIG || {}).network || {};
  }

  /* Точки на сфере. Домашний узел помечен: он рисуется чуть крупнее. */
  function nodePoints() {
    var source = net();
    var list = source.nodes || [];
    var out = [];
    for (var i = 0; i < list.length; i++) {
      var n = list[i] || {};
      if (typeof n.lat !== "number" || typeof n.lon !== "number") continue;
      out.push({ lat: n.lat, lon: n.lon, home: false });
    }
    var home = source.home || null;
    if (home && typeof home.lat === "number" && typeof home.lon === "number") {
      out.push({ lat: home.lat, lon: home.lon, home: true });
    }
    return out;
  }

  function unit(lat, lon) {
    var la = lat * DEG;
    var lo = lon * DEG;
    return {
      x: Math.cos(la) * Math.sin(lo),
      y: Math.sin(la),
      z: Math.cos(la) * Math.cos(lo)
    };
  }

  function spin(p, yaw, pitch) {
    var cy = Math.cos(yaw);
    var sy = Math.sin(yaw);
    var x = p.x * cy + p.z * sy;
    var z = p.z * cy - p.x * sy;
    var cp = Math.cos(pitch);
    var sp = Math.sin(pitch);
    return { x: x, y: p.y * cp - z * sp, z: p.y * sp + z * cp };
  }

  /* Дуга по великой окружности: точка между a и b на сфере. */
  function slerp(a, b, t) {
    var dot = Math.max(-1, Math.min(1, a.x * b.x + a.y * b.y + a.z * b.z));
    var w = Math.acos(dot);
    if (w < 1e-4) return { x: a.x, y: a.y, z: a.z };
    var s = Math.sin(w);
    var k1 = Math.sin((1 - t) * w) / s;
    var k2 = Math.sin(t * w) / s;
    return {
      x: a.x * k1 + b.x * k2,
      y: a.y * k1 + b.y * k2,
      z: a.z * k1 + b.z * k2
    };
  }

  function mount(canvas) {
    if (!canvas || !canvas.getContext) return null;
    if (canvas.getAttribute("data-cosmos-on") === "1") return null;
    canvas.setAttribute("data-cosmos-on", "1");

    var ctx = canvas.getContext("2d");
    if (!ctx) return null;

    var still = false;
    try {
      still = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    } catch (e) {
      still = false;
    }

    var points = nodePoints();
    var vectors = points.map(function (p) {
      return { v: unit(p.lat, p.lon), home: p.home };
    });

    var W = 0;
    var H = 0;
    var R = 0;
    var stars = [];

    var yaw = -0.5;
    var pitch = -16 * DEG;
    var aimYaw = 0;
    var aimPitch = 0;
    var curYaw = 0;
    var curPitch = 0;
    var t0 = 0;
    var raf = 0;
    var live = true;
    var onScreen = true;

    function measure() {
      var box = canvas.getBoundingClientRect();
      var dpr = Math.min(window.devicePixelRatio || 1, 2);
      W = Math.max(1, Math.round(box.width));
      H = Math.max(1, Math.round(box.height));
      canvas.width = Math.round(W * dpr);
      canvas.height = Math.round(H * dpr);
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      R = Math.min(W, H) * 0.34;
      seedStars();
    }

    function seedStars() {
      var count = Math.round(Math.min(160, Math.max(40, (W * H) / 5200)));
      stars = [];
      for (var i = 0; i < count; i++) {
        stars.push({
          x: Math.random(),
          y: Math.random(),
          r: 0.4 + Math.random() * 1.3,
          a: 0.18 + Math.random() * 0.6,
          phase: Math.random() * TAU,
          speed: 0.4 + Math.random() * 1.1,
          drift: 0.2 + Math.random() * 0.9
        });
      }
    }

    function paintStars(time) {
      for (var i = 0; i < stars.length; i++) {
        var s = stars[i];
        var twinkle = still ? 1 : 0.65 + 0.35 * Math.sin(time * s.speed + s.phase);
        var px = s.x * W + curYaw * 26 * s.drift;
        var py = s.y * H + curPitch * 26 * s.drift;
        ctx.globalAlpha = s.a * twinkle;
        ctx.fillStyle = i % 9 === 0 ? "#d7c9ff" : "#ffffff";
        ctx.beginPath();
        ctx.arc(px, py, s.r, 0, TAU);
        ctx.fill();
      }
      ctx.globalAlpha = 1;
    }

    function paintBody(cx, cy) {
      /* Свечение за сферой. */
      var halo = ctx.createRadialGradient(cx, cy, R * 0.72, cx, cy, R * 1.85);
      halo.addColorStop(0, "rgba(139,92,246,0.30)");
      halo.addColorStop(0.45, "rgba(124,58,237,0.12)");
      halo.addColorStop(1, "rgba(124,58,237,0)");
      ctx.fillStyle = halo;
      ctx.beginPath();
      ctx.arc(cx, cy, R * 1.85, 0, TAU);
      ctx.fill();

      /* Тело: свет приходит слева сверху, поэтому центр градиента смещён. */
      var body = ctx.createRadialGradient(
        cx - R * 0.42,
        cy - R * 0.48,
        R * 0.12,
        cx,
        cy,
        R * 1.06
      );
      body.addColorStop(0, "#2a1f5e");
      body.addColorStop(0.48, "#170f36");
      body.addColorStop(1, "#08060f");
      ctx.fillStyle = body;
      ctx.beginPath();
      ctx.arc(cx, cy, R, 0, TAU);
      ctx.fill();

      /* Ободок - тонкая неоновая линия по краю диска. */
      ctx.lineWidth = 1.1;
      ctx.strokeStyle = "rgba(196,181,253,0.42)";
      ctx.beginPath();
      ctx.arc(cx, cy, R, 0, TAU);
      ctx.stroke();
    }

    /* Полилиния по сфере с отсечением задней стороны. */
    function strokePath(list, cx, cy, color, width) {
      ctx.lineWidth = width;
      for (var i = 1; i < list.length; i++) {
        var a = list[i - 1];
        var b = list[i];
        if (a.z <= 0.02 || b.z <= 0.02) continue;
        ctx.globalAlpha = Math.min(a.z, b.z) * 0.9;
        ctx.strokeStyle = color;
        ctx.beginPath();
        ctx.moveTo(cx + a.x * R, cy - a.y * R);
        ctx.lineTo(cx + b.x * R, cy - b.y * R);
        ctx.stroke();
      }
      ctx.globalAlpha = 1;
    }

    function paintGrid(cx, cy) {
      var lat;
      var lon;
      var step = 6;
      /* Параллели. */
      for (lat = -60; lat <= 60; lat += 30) {
        var ring = [];
        for (lon = -180; lon <= 180; lon += step) {
          ring.push(spin(unit(lat, lon), yaw, pitch));
        }
        strokePath(ring, cx, cy, "rgba(139,92,246,0.30)", lat === 0 ? 1.1 : 0.8);
      }
      /* Меридианы. */
      for (lon = -180; lon < 180; lon += 30) {
        var arc = [];
        for (lat = -90; lat <= 90; lat += step) {
          arc.push(spin(unit(lat, lon), yaw, pitch));
        }
        strokePath(arc, cx, cy, "rgba(139,92,246,0.22)", 0.8);
      }
    }

    /* Нити между соседними узлами: дуга плюс бегущая по ней искра. */
    function paintThreads(cx, cy, time) {
      if (vectors.length < 2) return;
      for (var i = 0; i < vectors.length; i++) {
        var a = vectors[i].v;
        var b = vectors[(i + 1) % vectors.length].v;
        var line = [];
        for (var s = 0; s <= 24; s++) {
          var p = slerp(a, b, s / 24);
          var lift = 1 + 0.06 * Math.sin((s / 24) * Math.PI);
          line.push(spin({ x: p.x * lift, y: p.y * lift, z: p.z * lift }, yaw, pitch));
        }
        strokePath(line, cx, cy, "rgba(94,231,163,0.34)", 1);

        var k = (time * 0.22 + i * 0.37) % 1;
        var spark = line[Math.floor(k * (line.length - 1))];
        if (!spark || spark.z <= 0.05) continue;
        ctx.globalAlpha = Math.min(1, spark.z) * 0.9;
        ctx.fillStyle = "#5ee7a3";
        ctx.beginPath();
        ctx.arc(cx + spark.x * R, cy - spark.y * R, 2.1, 0, TAU);
        ctx.fill();
        ctx.globalAlpha = 1;
      }
    }

    function paintNodes(cx, cy, time) {
      for (var i = 0; i < vectors.length; i++) {
        var p = spin(vectors[i].v, yaw, pitch);
        if (p.z <= 0.02) continue;
        var x = cx + p.x * R;
        var y = cy - p.y * R;
        var base = vectors[i].home ? 3.4 : 2.4;
        var pulse = still ? 0 : 0.5 + 0.5 * Math.sin(time * 1.6 + i);
        var depth = Math.min(1, p.z + 0.15);

        var glow = ctx.createRadialGradient(x, y, 0, x, y, base * 4.6);
        glow.addColorStop(0, vectors[i].home ? "rgba(94,231,163,0.55)" : "rgba(196,181,253,0.45)");
        glow.addColorStop(1, "rgba(124,58,237,0)");
        ctx.globalAlpha = depth;
        ctx.fillStyle = glow;
        ctx.beginPath();
        ctx.arc(x, y, base * 4.6 + pulse * 2.4, 0, TAU);
        ctx.fill();

        ctx.fillStyle = vectors[i].home ? "#5ee7a3" : "#ffffff";
        ctx.beginPath();
        ctx.arc(x, y, base, 0, TAU);
        ctx.fill();
        ctx.globalAlpha = 1;
      }
    }

    function frame(now) {
      raf = 0;
      if (!t0) t0 = now;
      var time = (now - t0) / 1000;

      /* Мышь тянет сцену, но не рывком: сглаживаем к цели. */
      curYaw += (aimYaw - curYaw) * 0.06;
      curPitch += (aimPitch - curPitch) * 0.06;
      if (!still) yaw += 0.0022;

      var drawYaw = yaw + curYaw * 0.55;
      var drawPitch = pitch + curPitch * 0.32;
      var keepYaw = yaw;
      var keepPitch = pitch;
      yaw = drawYaw;
      pitch = drawPitch;

      ctx.clearRect(0, 0, W, H);
      var cx = W * 0.5;
      var cy = H * 0.48;

      paintStars(time);
      paintBody(cx, cy);
      paintGrid(cx, cy);
      paintThreads(cx, cy, time);
      paintNodes(cx, cy, time);

      yaw = keepYaw;
      pitch = keepPitch;

      if (!still && live && onScreen) raf = window.requestAnimationFrame(frame);
    }

    function kick() {
      if (raf || still || !live || !onScreen) return;
      raf = window.requestAnimationFrame(frame);
    }

    function stop() {
      if (!raf) return;
      window.cancelAnimationFrame(raf);
      raf = 0;
    }

    function onPointer(e) {
      var box = canvas.getBoundingClientRect();
      if (!box.width || !box.height) return;
      aimYaw = ((e.clientX - box.left) / box.width) * 2 - 1;
      aimPitch = ((e.clientY - box.top) / box.height) * 2 - 1;
      kick();
    }

    function onLeave() {
      aimYaw = 0;
      aimPitch = 0;
    }

    measure();
    frame(0);

    var host = canvas.parentNode || canvas;
    host.addEventListener("pointermove", onPointer);
    host.addEventListener("pointerleave", onLeave);

    window.addEventListener("resize", function () {
      measure();
      if (still) frame(performance.now ? performance.now() : Date.now());
      else kick();
    });

    document.addEventListener("visibilitychange", function () {
      live = !document.hidden;
      if (live) kick();
      else stop();
    });

    if (window.IntersectionObserver) {
      var io = new window.IntersectionObserver(function (entries) {
        onScreen = entries[0] ? entries[0].isIntersecting : true;
        if (onScreen) kick();
        else stop();
      });
      io.observe(canvas);
    }

    return { stop: stop, start: kick };
  }

  window.GlukCosmos = { mount: mount };
})();
