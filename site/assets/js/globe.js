/* ==========================================================================
   GlukVPN - живой глобус (canvas, без внешних библиотек)

   Точки берутся из того же dotted-map ассета, что используется в приложении
   (assets/js/world-dots.js), поэтому планета на сайте и планета в приложении
   нарисованы одними и теми же данными.

   Движение повторяет идеи приложения: медленный idleSpin, halo, пульсы нод,
   dashFlow-маршрут и «зелёное» состояние подключения.
   ========================================================================== */

(function () {
  "use strict";

  var TAU = Math.PI * 2;
  var DEG = Math.PI / 180;
  var reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* ------------------------------------------------------------ dot data */
  var cache = null;

  function worldPoints() {
    if (cache) return cache;
    var data = window.GLUK_WORLD_DOTS;
    if (!data) return (cache = []);
    var bin = atob(data.packed);
    var n = bin.length / 2;
    var pts = new Float32Array(n * 3);
    for (var i = 0; i < n; i++) {
      var x2 = bin.charCodeAt(i * 2);
      var row = bin.charCodeAt(i * 2 + 1);
      var lon = ((x2 / 2 / data.vbW) * 360 - 180) * DEG;
      var lat = (90 - ((row * data.yStep) / data.vbH) * 180) * DEG;
      var cl = Math.cos(lat);
      pts[i * 3] = cl * Math.cos(lon); // x
      pts[i * 3 + 1] = Math.sin(lat); // y
      pts[i * 3 + 2] = cl * Math.sin(lon); // z
    }
    cache = pts;
    return pts;
  }

  function unit(lat, lon) {
    var la = lat * DEG;
    var lo = lon * DEG;
    var cl = Math.cos(la);
    return [cl * Math.cos(lo), Math.sin(la), cl * Math.sin(lo)];
  }

  function slerp(a, b, t) {
    var dot = Math.max(-1, Math.min(1, a[0] * b[0] + a[1] * b[1] + a[2] * b[2]));
    var omega = Math.acos(dot);
    if (omega < 1e-4) return a.slice();
    var s = Math.sin(omega);
    var k0 = Math.sin((1 - t) * omega) / s;
    var k1 = Math.sin(t * omega) / s;
    return [a[0] * k0 + b[0] * k1, a[1] * k0 + b[1] * k1, a[2] * k0 + b[2] * k1];
  }

  /* --------------------------------------------------------------- globe */

  function Globe(canvas, opts) {
    this.canvas = canvas;
    this.ctx = canvas.getContext("2d");
    this.o = Object.assign(
      {
        tilt: 16,
        spin: 0.014, // rad/s - очень медленно, как idleSpin в приложении
        dotSize: 1.5,
        radius: 0.78,
        home: null,
        nodes: [],
        cycle: 6200,
        onRoute: null,
      },
      opts || {}
    );
    this.spinAngle = -1.1;
    this.t0 = performance.now();
    this.routeIndex = 0;
    this.routeStart = this.t0;
    this.live = (this.o.nodes || []).filter(function (n) {
      return n.status !== "soon";
    });
    this.resize();
    this.bind();
  }

  Globe.prototype.bind = function () {
    var self = this;
    this.onResize = function () {
      self.resize();
      if (reduced) self.draw(0);
    };
    window.addEventListener("resize", this.onResize, { passive: true });

    if ("IntersectionObserver" in window) {
      this.io = new IntersectionObserver(
        function (entries) {
          entries.forEach(function (e) {
            e.isIntersecting ? self.start() : self.stop();
          });
        },
        { rootMargin: "120px" }
      );
      this.io.observe(this.canvas);
    } else {
      this.start();
    }

    document.addEventListener("visibilitychange", function () {
      document.hidden ? self.stop() : self.start();
    });
  };

  Globe.prototype.resize = function () {
    var dpr = Math.min(window.devicePixelRatio || 1, 2);
    var r = this.canvas.getBoundingClientRect();
    var w = Math.max(1, Math.round(r.width));
    var h = Math.max(1, Math.round(r.height));
    this.canvas.width = Math.round(w * dpr);
    this.canvas.height = Math.round(h * dpr);
    this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    this.w = w;
    this.h = h;
    this.cx = w / 2;
    this.cy = h / 2;
    this.R = Math.min(w, h) * this.o.radius * 0.5;
  };

  Globe.prototype.start = function () {
    if (this.raf) return;
    if (reduced) {
      this.draw(0);
      return;
    }
    var self = this;
    var last = performance.now();
    var loop = function (now) {
      var dt = Math.min(64, now - last);
      last = now;
      self.spinAngle += self.o.spin * (dt / 1000);
      self.draw(now);
      self.raf = requestAnimationFrame(loop);
    };
    this.raf = requestAnimationFrame(loop);
  };

  Globe.prototype.stop = function () {
    if (this.raf) cancelAnimationFrame(this.raf);
    this.raf = null;
  };

  Globe.prototype.project = function (p) {
    var ca = Math.cos(this.spinAngle);
    var sa = Math.sin(this.spinAngle);
    var x = p[0] * ca + p[2] * sa;
    var z = -p[0] * sa + p[2] * ca;
    var y = p[1];
    var ct = Math.cos(this.o.tilt * DEG);
    var st = Math.sin(this.o.tilt * DEG);
    var y2 = y * ct - z * st;
    var z2 = y * st + z * ct;
    return [x, y2, z2];
  };

  Globe.prototype.draw = function (now) {
    var ctx = this.ctx;
    var R = this.R;
    var cx = this.cx;
    var cy = this.cy;
    ctx.clearRect(0, 0, this.w, this.h);

    /* атмосфера / rim light */
    var atm = ctx.createRadialGradient(cx, cy, R * 0.86, cx, cy, R * 1.14);
    atm.addColorStop(0, "rgba(124,92,246,0.16)");
    atm.addColorStop(0.55, "rgba(79,124,255,0.07)");
    atm.addColorStop(1, "rgba(124,92,246,0)");
    ctx.fillStyle = atm;
    ctx.beginPath();
    ctx.arc(cx, cy, R * 1.14, 0, TAU);
    ctx.fill();

    /* тело планеты */
    var body = ctx.createRadialGradient(
      cx - R * 0.32,
      cy - R * 0.36,
      R * 0.12,
      cx,
      cy,
      R
    );
    body.addColorStop(0, "rgba(38,28,64,0.92)");
    body.addColorStop(0.62, "rgba(15,10,28,0.94)");
    body.addColorStop(1, "rgba(6,4,12,0.98)");
    ctx.fillStyle = body;
    ctx.beginPath();
    ctx.arc(cx, cy, R, 0, TAU);
    ctx.fill();

    /* суша: точки того же ассета, что и в приложении */
    var pts = worldPoints();
    var size = this.o.dotSize;
    var buckets = [[], [], [], []];
    for (var i = 0; i < pts.length; i += 3) {
      var pr = this.project([pts[i], pts[i + 1], pts[i + 2]]);
      if (pr[2] <= 0.02) continue;
      var sx = cx + pr[0] * R;
      var sy = cy - pr[1] * R;
      var b = pr[2] > 0.78 ? 0 : pr[2] > 0.5 ? 1 : pr[2] > 0.24 ? 2 : 3;
      buckets[b].push(sx, sy);
    }
    var alphas = [0.92, 0.7, 0.46, 0.24];
    var colors = ["#c9bcff", "#a996f7", "#8b7cf6", "#6f5fd0"];
    for (var b2 = 0; b2 < 4; b2++) {
      var arr = buckets[b2];
      if (!arr.length) continue;
      ctx.globalAlpha = alphas[b2];
      ctx.fillStyle = colors[b2];
      var s = size * (b2 === 0 ? 1.08 : b2 === 3 ? 0.82 : 1);
      for (var j = 0; j < arr.length; j += 2) {
        ctx.fillRect(arr[j] - s / 2, arr[j + 1] - s / 2, s, s);
      }
    }
    ctx.globalAlpha = 1;

    /* терминатор / затемнение края (как inset-shadow планеты в приложении) */
    var shade = ctx.createRadialGradient(
      cx - R * 0.28,
      cy - R * 0.3,
      R * 0.2,
      cx,
      cy,
      R
    );
    shade.addColorStop(0, "rgba(0,0,0,0)");
    shade.addColorStop(0.72, "rgba(0,0,0,0.28)");
    shade.addColorStop(1, "rgba(0,0,0,0.72)");
    ctx.fillStyle = shade;
    ctx.beginPath();
    ctx.arc(cx, cy, R, 0, TAU);
    ctx.fill();

    ctx.strokeStyle = "rgba(196,181,253,0.28)";
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.arc(cx, cy, R, 0, TAU);
    ctx.stroke();

    this.drawNetwork(now);
  };

  /* Фоновый трафик: много одновременных соединений со всего мира.
     Точки без подписей — это визуализация нагрузки, а не реальные узлы. */
  var CITIES = [
    [52.52, 13.4], [48.86, 2.35], [51.51, -0.13], [40.71, -74.01], [37.77, -122.42],
    [55.75, 37.62], [43.24, 76.89], [25.2, 55.27], [1.35, 103.82], [35.68, 139.69],
    [-33.87, 151.21], [-23.55, -46.63], [19.08, 72.88], [41.01, 28.98], [50.45, 30.52],
    [59.33, 18.07], [22.32, 114.17], [-1.29, 36.82], [45.46, 9.19], [39.9, 116.4],
    [-26.2, 28.04], [34.05, -118.24], [43.65, -79.38], [3.14, 101.69],
    /* южное полушарие и края карты — чтобы глобус жил целиком */
    [-34.6, -58.38], [-33.45, -70.67], [-12.05, -77.04], [4.71, -74.07], [10.5, -66.92],
    [-15.79, -47.88], [-22.91, -43.17], [-8.05, -34.88], [-25.43, -49.27],
    [-36.85, 174.77], [-41.29, 174.78], [-37.81, 144.96], [-31.95, 115.86], [-27.47, 153.02],
    [-6.21, 106.85], [14.6, 120.98], [13.75, 100.5], [21.03, 105.85], [-33.92, 18.42],
    [6.52, 3.38], [-4.44, 15.27], [30.04, 31.24], [33.57, -7.59], [9.03, 38.74],
    [-18.14, 178.44], [64.15, -21.94], [60.17, 24.94], [-16.5, -68.15], [19.43, -99.13],
    [23.13, -82.38], [18.47, -69.9], [61.22, -149.9], [21.31, -157.86], [-20.16, 57.5],
    [24.86, 67.01], [27.72, 85.32], [37.57, 126.98], [25.03, 121.57], [-9.44, 147.18],
    [69.65, 18.96], [-54.8, -68.3], [11.55, 104.92], [39.04, 125.76], [-33.02, 27.91]
  ];

  Globe.prototype.ambientRoutes = function () {
    if (this._amb) return this._amb;
    var o = this.o;
    var ends = (this.live || []).map(function (n) { return [n.lat, n.lon]; });
    var home = o.home ? [o.home.lat, o.home.lon] : [48, 68];
    if (!ends.length) ends = [home];
    var list = [];
    CITIES.forEach(function (c, i) {
      var tgt = ends[i % ends.length];
      list.push({
        a: unit(c[0], c[1]),
        b: unit(tgt[0], tgt[1]),
        dur: 4200 + ((i * 977) % 5200),
        off: (i * 1013) % 7000,
        green: i % 4 === 0
      });
    });
    ends.forEach(function (e, k) {
      list.push({
        a: unit(home[0], home[1]),
        b: unit(e[0], e[1]),
        dur: 5400 + k * 800,
        off: k * 1700,
        green: true
      });
    });

    /* сетка city ↔ city: трафик идёт не только к нашим узлам, но и по всему шару */
    var HOPS = [7, 13, 23, 31];
    for (var m = 0; m < CITIES.length; m++) {
      var hop = HOPS[m % HOPS.length];
      var pair = CITIES[(m + hop) % CITIES.length];
      list.push({
        a: unit(CITIES[m][0], CITIES[m][1]),
        b: unit(pair[0], pair[1]),
        dur: 5200 + ((m * 761) % 6400),
        off: (m * 587) % 9000,
        green: m % 7 === 0,
        faint: true
      });
    }

    this._amb = list;
    return list;
  };

  Globe.prototype.drawAmbient = function (now) {
    var ctx = this.ctx, R = this.R, cx = this.cx, cy = this.cy, self = this;
    var routes = this.ambientRoutes();
    ctx.save();
    ctx.lineCap = "round";
    for (var i = 0; i < routes.length; i++) {
      var r = routes[i];
      var ph = reduced ? 0.6 : ((now + r.off) % r.dur) / r.dur;
      var grow = Math.min(1, ph / 0.45);
      var fade = ph > 0.82 ? Math.max(0, 1 - (ph - 0.82) / 0.18) : Math.min(1, ph / 0.1);
      if (fade <= 0.02) continue;
      var started = false, drawn = 0, steps = 26;
      ctx.beginPath();
      for (var s = 0; s <= steps; s++) {
        var t = (s / steps) * grow;
        var p = slerp(r.a, r.b, t);
        var lift = 1 + 0.12 * Math.sin(Math.PI * t);
        var pr = self.project([p[0] * lift, p[1] * lift, p[2] * lift]);
        if (pr[2] < 0.02) { started = false; continue; }
        var sx = cx + pr[0] * R, sy = cy - pr[1] * R;
        if (!started) { ctx.moveTo(sx, sy); started = true; } else { ctx.lineTo(sx, sy); }
        drawn++;
      }
      var fa = r.faint ? 0.6 : 1;
      if (drawn > 1) {
        ctx.lineWidth = r.faint ? 0.6 : 0.9;
        ctx.strokeStyle = r.green
          ? "rgba(79,216,140," + (0.16 * fade * fa).toFixed(3) + ")"
          : "rgba(139,92,246," + (0.24 * fade * fa).toFixed(3) + ")";
        ctx.stroke();
      }
      if (!reduced && grow >= 1) {
        var tp = Math.min(1, (ph - 0.45) / 0.5);
        var pp = slerp(r.a, r.b, tp);
        var lift2 = 1 + 0.12 * Math.sin(Math.PI * tp);
        var prp = self.project([pp[0] * lift2, pp[1] * lift2, pp[2] * lift2]);
        if (prp[2] > 0.02) {
          var px = cx + prp[0] * R, py = cy - prp[1] * R;
          ctx.beginPath();
          ctx.fillStyle = r.green
            ? "rgba(140,246,190," + (0.75 * fade * fa).toFixed(3) + ")"
            : "rgba(206,192,255," + (0.8 * fade * fa).toFixed(3) + ")";
          ctx.arc(px, py, r.faint ? 1.15 : 1.7, 0, TAU);
          ctx.fill();
        }
      }
    }
    ctx.restore();
  };

  Globe.prototype.drawNetwork = function (now) {
    var ctx = this.ctx;
    var R = this.R;
    var cx = this.cx;
    var cy = this.cy;
    var o = this.o;
    if (!o.home || !this.live.length) return;

    /* цикл подключения: маршрут строится, пакет идёт, нода "зеленеет" */
    var cycle = reduced ? 1 : (now - this.routeStart) / o.cycle;
    if (!reduced && cycle >= 1) {
      this.routeStart = now;
      this.routeIndex = (this.routeIndex + 1) % this.live.length;
      cycle = 0;
      if (typeof o.onRoute === "function") o.onRoute(this.live[this.routeIndex]);
    }
    var active = this.live[this.routeIndex];
    var grow = Math.min(1, cycle / 0.34);
    var fade = cycle > 0.86 ? 1 - (cycle - 0.86) / 0.14 : 1;

    var home = unit(o.home.lat, o.home.lon);

    /* сначала фоновые соединения, чтобы основной маршрут оставался главным */
    this.drawAmbient(now);

    /* маршрут */
    var target = unit(active.lat, active.lon);
    var steps = 54;
    var visible = 0;
    ctx.save();
    ctx.lineWidth = 1.6;
    ctx.lineCap = "round";
    var grad = ctx.createLinearGradient(cx - R, cy, cx + R, cy);
    grad.addColorStop(0, "rgba(196,181,253," + 0.95 * fade + ")");
    grad.addColorStop(1, "rgba(79,216,140," + 0.95 * fade + ")");
    ctx.strokeStyle = grad;
    ctx.setLineDash([5, 5]);
    ctx.lineDashOffset = reduced ? 0 : -(now / 34) % 10;
    ctx.beginPath();
    var started = false;
    for (var s = 0; s <= steps; s++) {
      var t = s / steps;
      if (t > grow) break;
      var p = slerp(home, target, t);
      var lift = 1 + 0.19 * Math.sin(Math.PI * t);
      var pr = this.project([p[0] * lift, p[1] * lift, p[2] * lift]);
      var sx = cx + pr[0] * R;
      var sy = cy - pr[1] * R;
      if (pr[2] < -0.05) {
        started = false;
        continue;
      }
      visible++;
      if (!started) {
        ctx.moveTo(sx, sy);
        started = true;
      } else {
        ctx.lineTo(sx, sy);
      }
    }
    if (visible > 1) ctx.stroke();
    ctx.setLineDash([]);

    /* пакет по маршруту */
    if (!reduced && grow >= 1) {
      var tp = ((cycle - 0.34) / 0.66) % 1;
      var pp = slerp(home, target, tp);
      var lift2 = 1 + 0.19 * Math.sin(Math.PI * tp);
      var prp = this.project([pp[0] * lift2, pp[1] * lift2, pp[2] * lift2]);
      if (prp[2] > -0.05) {
        var px = cx + prp[0] * R;
        var py = cy - prp[1] * R;
        var g2 = ctx.createRadialGradient(px, py, 0, px, py, 7);
        g2.addColorStop(0, "rgba(255,255,255,0.95)");
        g2.addColorStop(0.4, "rgba(196,181,253,0.75)");
        g2.addColorStop(1, "rgba(196,181,253,0)");
        ctx.fillStyle = g2;
        ctx.beginPath();
        ctx.arc(px, py, 7, 0, TAU);
        ctx.fill();
      }
    }
    ctx.restore();

    /* ноды */
    var self = this;
    (o.nodes || []).forEach(function (n, idx) {
      var p = self.project(unit(n.lat, n.lon));
      if (p[2] <= 0.03) return;
      var sx = cx + p[0] * R;
      var sy = cy - p[1] * R;
      var soon = n.status === "soon";
      var isActive = !soon && n.id === active.id && grow >= 1;
      var depth = Math.min(1, 0.35 + p[2]);
      var color = soon
        ? "rgba(153,148,171,"
        : isActive
        ? "rgba(79,216,140,"
        : "rgba(196,181,253,";

      if (!soon && !reduced) {
        var ph = ((now / 1000 + idx * 0.7) % 2.4) / 2.4;
        ctx.strokeStyle = color + 0.5 * (1 - ph) * depth + ")";
        ctx.lineWidth = 1;
        ctx.beginPath();
        ctx.arc(sx, sy, 3 + ph * 13, 0, TAU);
        ctx.stroke();
      }

      if (isActive) {
        var gl = ctx.createRadialGradient(sx, sy, 0, sx, sy, 12);
        gl.addColorStop(0, "rgba(79,216,140,0.5)");
        gl.addColorStop(1, "rgba(79,216,140,0)");
        ctx.fillStyle = gl;
        ctx.beginPath();
        ctx.arc(sx, sy, 12, 0, TAU);
        ctx.fill();
      }

      ctx.fillStyle = color + (soon ? 0.45 : 0.95) * depth + ")";
      ctx.beginPath();
      ctx.arc(sx, sy, soon ? 1.8 : 2.6, 0, TAU);
      ctx.fill();
    });

    /* точка "вы" */
    var hp = this.project(home);
    if (hp[2] > 0.03) {
      var hx = cx + hp[0] * R;
      var hy = cy - hp[1] * R;
      if (!reduced) {
        var hph = ((now / 1000) % 2.4) / 2.4;
        ctx.strokeStyle = "rgba(196,181,253," + 0.55 * (1 - hph) + ")";
        ctx.lineWidth = 1.1;
        ctx.beginPath();
        ctx.arc(hx, hy, 3 + hph * 15, 0, TAU);
        ctx.stroke();
      }
      ctx.fillStyle = "#ffffff";
      ctx.beginPath();
      ctx.arc(hx, hy, 3, 0, TAU);
      ctx.fill();
      ctx.strokeStyle = "rgba(196,181,253,0.9)";
      ctx.lineWidth = 1.4;
      ctx.beginPath();
      ctx.arc(hx, hy, 5.4, 0, TAU);
      ctx.stroke();
    }
  };

  window.GlukGlobe = Globe;
})();
