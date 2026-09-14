/* ==========================================================================
   GlukVPN — живой глобус (canvas, без внешних библиотек)

   v0.7: планета читается как карта устройств, а не как клубок линий.
   - Точки суши берутся из того же dotted-map ассета, что и в приложении.
   - Поверх суши разложены устройства: они рассыпаны по всей планете
     (включая южное полушарие), сгущаясь у крупных городов.
   - Линий мало: одновременно живут максимум 3 тонкие дуги плюс основной
     маршрут подключения.
   ========================================================================== */

(function () {
  "use strict";

  var TAU = Math.PI * 2;
  var DEG = Math.PI / 180;
  var reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var ARC_SLOTS = reduced ? 2 : 3;

  var cache = null;

  function worldPoints() {
    if (cache) return cache;
    var data = window.GLUK_WORLD_DOTS;
    if (!data) return (cache = new Float32Array(0));
    var bin = atob(data.packed);
    var n = bin.length / 2;
    var pts = new Float32Array(n * 3);
    for (var i = 0; i < n; i++) {
      var x2 = bin.charCodeAt(i * 2);
      var row = bin.charCodeAt(i * 2 + 1);
      var lon = ((x2 / 2 / data.vbW) * 360 - 180) * DEG;
      var lat = (90 - ((row * data.yStep) / data.vbH) * 180) * DEG;
      var cl = Math.cos(lat);
      pts[i * 3] = cl * Math.cos(lon);
      pts[i * 3 + 1] = Math.sin(lat);
      pts[i * 3 + 2] = cl * Math.sin(lon);
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

  /* детерминированный генератор: картинка одинаковая при каждой загрузке */
  function seeded(seed) {
    var s = seed >>> 0;
    return function () {
      s = (s * 1664525 + 1013904223) >>> 0;
      return s / 4294967296;
    };
  }

  /* Крупные города — центры сгущения устройств (весь шар, оба полушария). */
  var CITIES = [
    [52.52, 13.4], [48.86, 2.35], [51.51, -0.13], [40.71, -74.01], [37.77, -122.42],
    [55.75, 37.62], [43.24, 76.89], [25.2, 55.27], [1.35, 103.82], [35.68, 139.69],
    [-33.87, 151.21], [-23.55, -46.63], [19.08, 72.88], [41.01, 28.98], [50.45, 30.52],
    [59.33, 18.07], [22.32, 114.17], [-1.29, 36.82], [45.46, 9.19], [39.9, 116.4],
    [-26.2, 28.04], [34.05, -118.24], [43.65, -79.38], [3.14, 101.69], [-34.6, -58.38],
    [-33.45, -70.67], [-12.05, -77.04], [4.71, -74.07], [10.5, -66.92], [-15.79, -47.88],
    [-22.91, -43.17], [-8.05, -34.88], [-25.43, -49.27], [-36.85, 174.77], [-41.29, 174.78],
    [-37.81, 144.96], [-31.95, 115.86], [-27.47, 153.02], [-6.21, 106.85], [14.6, 120.98],
    [13.75, 100.5], [21.03, 105.85], [-33.92, 18.42], [6.52, 3.38], [-4.44, 15.27],
    [30.04, 31.24], [33.57, -7.59], [9.03, 38.74], [-18.14, 178.44], [64.15, -21.94],
    [60.17, 24.94], [-16.5, -68.15], [19.43, -99.13], [23.13, -82.38], [18.47, -69.9],
    [61.22, -149.9], [21.31, -157.86], [-20.16, 57.5], [24.86, 67.01], [27.72, 85.32],
    [37.57, 126.98], [25.03, 121.57], [-9.44, 147.18], [69.65, 18.96], [-54.8, -68.3],
    [11.55, 104.92], [39.04, 125.76], [-33.02, 27.91], [47.5, 19.05], [52.23, 21.01],
    [41.9, 12.5], [40.42, -3.7], [38.72, -9.14], [53.35, -6.26], [55.68, 12.57],
    [59.91, 10.75], [50.08, 14.44], [44.43, 26.1], [42.7, 23.32], [37.98, 23.73],
    [41.72, 44.79], [40.18, 44.51], [41.31, 69.28], [42.87, 74.59], [38.56, 68.79],
    [37.95, 58.38], [35.69, 51.39], [33.31, 44.36], [24.71, 46.68], [29.37, 47.98],
    [31.95, 35.93], [32.09, 34.78], [36.75, 3.06], [36.8, 10.18], [15.5, 32.56],
    [14.72, -17.47], [5.56, -0.2], [-1.94, 30.06], [-6.79, 39.21], [-17.83, 31.05],
    [-25.97, 32.58], [-22.56, 17.08], [12.65, -8], [30.27, -97.74], [41.88, -87.63],
    [39.74, -104.99], [47.61, -122.33], [25.76, -80.19], [29.76, -95.37], [45.5, -73.57],
    [49.28, -123.12], [51.05, -114.07], [20.67, -103.35], [10.96, -74.8], [-2.19, -79.89],
    [-25.3, -57.64], [-34.9, -56.16], [-31.42, -64.18], [28.61, 77.21], [12.97, 77.59],
    [22.57, 88.36], [13.08, 80.27], [23.81, 90.41], [6.93, 79.86], [16.87, 96.2],
    [10.82, 106.63], [3.6, 98.68], [-7.8, 110.37], [31.23, 121.47], [23.13, 113.26],
    [30.57, 104.07], [45.75, 126.63], [43.83, 87.62], [34.69, 135.5], [43.06, 141.35],
    [35.18, 129.08], [-8.65, 115.22], [64.54, 40.54], [56.83, 60.6], [55.03, 82.92],
    [52.29, 104.3], [43.12, 131.89], [46.35, 48.04], [51.16, 71.43], [42.34, 69.6],
    [47.1, 51.92], [53.2, 63.62]
  ];

  function Globe(canvas, opts) {
    this.canvas = canvas;
    this.ctx = canvas.getContext("2d");
    this.o = Object.assign(
      { tilt: 16, spin: 0.014, dotSize: 1.5, radius: 0.78, home: null, nodes: [], cycle: 6200, onRoute: null },
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
    return [x, y * ct - z * st, y * st + z * ct];
  };

  Globe.prototype.draw = function (now) {
    var ctx = this.ctx;
    var R = this.R;
    var cx = this.cx;
    var cy = this.cy;
    ctx.clearRect(0, 0, this.w, this.h);

    /* атмосфера / rim light — только фиолетовый, без синевы */
    var atm = ctx.createRadialGradient(cx, cy, R * 0.86, cx, cy, R * 1.16);
    atm.addColorStop(0, "rgba(139,92,246,0.20)");
    atm.addColorStop(0.55, "rgba(109,40,217,0.09)");
    atm.addColorStop(1, "rgba(76,29,149,0)");
    ctx.fillStyle = atm;
    ctx.beginPath();
    ctx.arc(cx, cy, R * 1.16, 0, TAU);
    ctx.fill();

    /* тело планеты */
    var body = ctx.createRadialGradient(cx - R * 0.32, cy - R * 0.36, R * 0.12, cx, cy, R);
    body.addColorStop(0, "rgba(42,22,74,0.94)");
    body.addColorStop(0.62, "rgba(16,9,32,0.95)");
    body.addColorStop(1, "rgba(5,3,11,0.98)");
    ctx.fillStyle = body;
    ctx.beginPath();
    ctx.arc(cx, cy, R, 0, TAU);
    ctx.fill();

    /* суша */
    var pts = worldPoints();
    var size = this.o.dotSize;
    var buckets = [[], [], [], []];
    for (var i = 0; i < pts.length; i += 3) {
      var pr = this.project([pts[i], pts[i + 1], pts[i + 2]]);
      if (pr[2] <= 0.02) continue;
      buckets[pr[2] > 0.78 ? 0 : pr[2] > 0.5 ? 1 : pr[2] > 0.24 ? 2 : 3].push(
        cx + pr[0] * R,
        cy - pr[1] * R
      );
    }
    var alphas = [0.6, 0.44, 0.3, 0.16];
    var colors = ["#8b7ad6", "#7a68c4", "#6353a6", "#4c3f80"];
    for (var b = 0; b < 4; b++) {
      var arr = buckets[b];
      if (!arr.length) continue;
      ctx.globalAlpha = alphas[b];
      ctx.fillStyle = colors[b];
      var s = size * (b === 0 ? 1.05 : b === 3 ? 0.8 : 0.95);
      for (var j = 0; j < arr.length; j += 2) ctx.fillRect(arr[j] - s / 2, arr[j + 1] - s / 2, s, s);
    }
    ctx.globalAlpha = 1;

    /* затемнение края */
    var shade = ctx.createRadialGradient(cx - R * 0.28, cy - R * 0.3, R * 0.2, cx, cy, R);
    shade.addColorStop(0, "rgba(0,0,0,0)");
    shade.addColorStop(0.72, "rgba(0,0,0,0.26)");
    shade.addColorStop(1, "rgba(0,0,0,0.7)");
    ctx.fillStyle = shade;
    ctx.beginPath();
    ctx.arc(cx, cy, R, 0, TAU);
    ctx.fill();

    ctx.strokeStyle = "rgba(167,139,250,0.26)";
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.arc(cx, cy, R, 0, TAU);
    ctx.stroke();

    this.drawDevices(now);
    this.drawNetwork(now);
  };

  /* Устройства по всей планете: часть рассыпана по всей суше, часть сгущается
     вокруг крупных городов. Это масштаб сети, а не список узлов. */
  Globe.prototype.devices = function () {
    if (this._dev) return this._dev;
    var rnd = seeded(20260825);
    var list = [];
    var pts = worldPoints();
    var total = pts.length / 3;

    for (var i = 0; i < total; i += 5) {
      var v = [
        pts[i * 3] + (rnd() - 0.5) * 0.012,
        pts[i * 3 + 1] + (rnd() - 0.5) * 0.012,
        pts[i * 3 + 2] + (rnd() - 0.5) * 0.012
      ];
      var len = Math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]) || 1;
      list.push({
        p: [v[0] / len, v[1] / len, v[2] / len],
        r: 0.85 + rnd() * 0.35,
        a: 0.3 + rnd() * 0.3,
        ph: rnd() * TAU,
        hot: false,
        live: false
      });
    }

    for (var c = 0; c < CITIES.length; c++) {
      var lat = CITIES[c][0];
      var lon = CITIES[c][1];
      var count = 4 + Math.floor(rnd() * 5);
      for (var k = 0; k < count; k++) {
        var spread = k === 0 ? 0 : 1.2 + rnd() * 6.2;
        var ang = rnd() * TAU;
        var dLat = Math.sin(ang) * spread;
        var dLon = (Math.cos(ang) * spread) / Math.max(0.25, Math.cos(lat * DEG));
        list.push({
          p: unit(Math.max(-84, Math.min(84, lat + dLat)), ((lon + dLon + 540) % 360) - 180),
          r: k === 0 ? 1.7 : 1.05 + rnd() * 0.5,
          a: k === 0 ? 0.95 : 0.55 + rnd() * 0.3,
          ph: rnd() * TAU,
          hot: k === 0,
          live: rnd() < 0.16
        });
      }
    }

    this._dev = list;
    return list;
  };

  Globe.prototype.drawDevices = function (now) {
    var ctx = this.ctx;
    var R = this.R;
    var cx = this.cx;
    var cy = this.cy;
    var list = this.devices();
    var t = now / 1000;
    ctx.save();
    for (var i = 0; i < list.length; i++) {
      var d = list[i];
      var pr = this.project(d.p);
      if (pr[2] <= 0.05) continue;
      var sx = cx + pr[0] * R;
      var sy = cy - pr[1] * R;
      var depth = Math.min(1, 0.28 + pr[2] * 0.95);
      var tw = reduced ? 0.72 : 0.62 + 0.38 * Math.sin(t * 0.9 + d.ph);
      var alpha = d.a * depth * (0.66 + 0.34 * tw);
      var rad = Math.max(0.55, d.r * (0.72 + 0.45 * pr[2]) * (R / 210));

      ctx.fillStyle = d.live
        ? "rgba(94,231,163," + Math.min(1, alpha + 0.12).toFixed(3) + ")"
        : d.hot
        ? "rgba(222,211,255," + alpha.toFixed(3) + ")"
        : "rgba(178,152,255," + alpha.toFixed(3) + ")";
      ctx.beginPath();
      ctx.arc(sx, sy, rad, 0, TAU);
      ctx.fill();

      if (d.live && pr[2] > 0.42) {
        var pulse = reduced ? 0.5 : (Math.sin(t * 1.6 + d.ph) + 1) / 2;
        var g = ctx.createRadialGradient(sx, sy, 0, sx, sy, rad * 5.5);
        g.addColorStop(0, "rgba(94,231,163," + (0.2 * pulse * depth).toFixed(3) + ")");
        g.addColorStop(1, "rgba(94,231,163,0)");
        ctx.fillStyle = g;
        ctx.beginPath();
        ctx.arc(sx, sy, rad * 5.5, 0, TAU);
        ctx.fill();
      }
    }
    ctx.restore();
  };

  /* Пул маршрутов большой, но одновременно видно максимум ARC_SLOTS дуг. */
  Globe.prototype.arcPool = function () {
    if (this._pool) return this._pool;
    var rnd = seeded(777001);
    var ends = (this.live || []).map(function (n) {
      return unit(n.lat, n.lon);
    });
    if (!ends.length && this.o.home) ends = [unit(this.o.home.lat, this.o.home.lon)];
    var pool = [];
    for (var i = 0; i < CITIES.length; i++) {
      pool.push({ a: unit(CITIES[i][0], CITIES[i][1]), b: ends[i % Math.max(1, ends.length)] });
    }
    for (var j = pool.length - 1; j > 0; j--) {
      var k = Math.floor(rnd() * (j + 1));
      var tmp = pool[j];
      pool[j] = pool[k];
      pool[k] = tmp;
    }
    this._pool = pool;
    this._slots = null;
    return pool;
  };

  Globe.prototype.arcSlots = function () {
    if (this._slots) return this._slots;
    var pool = this.arcPool();
    var slots = [];
    for (var s = 0; s < ARC_SLOTS; s++) {
      slots.push({ idx: (s * 7) % Math.max(1, pool.length), dur: 5200 + s * 1400, off: s * 1900 });
    }
    this._slots = slots;
    return slots;
  };

  Globe.prototype.drawArcs = function (now) {
    var ctx = this.ctx;
    var R = this.R;
    var cx = this.cx;
    var cy = this.cy;
    var pool = this.arcPool();
    if (!pool.length) return;
    var slots = this.arcSlots();
    ctx.save();
    ctx.lineCap = "round";

    for (var s = 0; s < slots.length; s++) {
      var slot = slots[s];
      var raw = (now + slot.off) / slot.dur;
      var loop = Math.floor(raw);
      var ph = reduced ? 0.55 : raw - loop;
      if (slot._loop !== loop) {
        slot._loop = loop;
        slot.idx = (slot.idx + slots.length) % pool.length;
      }
      var arc = pool[slot.idx];
      var grow = Math.min(1, ph / 0.4);
      var fade = ph < 0.12 ? ph / 0.12 : ph > 0.78 ? Math.max(0, 1 - (ph - 0.78) / 0.22) : 1;
      if (fade <= 0.02) continue;

      var started = false;
      var drawn = 0;
      var steps = 30;
      ctx.beginPath();
      for (var i = 0; i <= steps; i++) {
        var t = (i / steps) * grow;
        var p = slerp(arc.a, arc.b, t);
        var lift = 1 + 0.14 * Math.sin(Math.PI * t);
        var pr = this.project([p[0] * lift, p[1] * lift, p[2] * lift]);
        if (pr[2] < 0.02) {
          started = false;
          continue;
        }
        var sx = cx + pr[0] * R;
        var sy = cy - pr[1] * R;
        if (!started) {
          ctx.moveTo(sx, sy);
          started = true;
        } else {
          ctx.lineTo(sx, sy);
        }
        drawn++;
      }
      if (drawn > 1) {
        ctx.lineWidth = 0.85;
        ctx.strokeStyle = "rgba(167,139,250," + (0.26 * fade).toFixed(3) + ")";
        ctx.stroke();
      }

      if (!reduced && grow >= 1) {
        var tp = Math.min(1, (ph - 0.4) / 0.42);
        var pp = slerp(arc.a, arc.b, tp);
        var lift2 = 1 + 0.14 * Math.sin(Math.PI * tp);
        var prp = this.project([pp[0] * lift2, pp[1] * lift2, pp[2] * lift2]);
        if (prp[2] > 0.02) {
          ctx.fillStyle = "rgba(226,214,255," + (0.85 * fade).toFixed(3) + ")";
          ctx.beginPath();
          ctx.arc(cx + prp[0] * R, cy - prp[1] * R, 1.5, 0, TAU);
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

    this.drawArcs(now);

    var target = unit(active.lat, active.lon);
    var steps = 54;
    var visible = 0;
    ctx.save();
    ctx.lineWidth = 1.6;
    ctx.lineCap = "round";
    var grad = ctx.createLinearGradient(cx - R, cy, cx + R, cy);
    grad.addColorStop(0, "rgba(214,199,255," + 0.95 * fade + ")");
    grad.addColorStop(1, "rgba(94,231,163," + 0.95 * fade + ")");
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
      if (pr[2] < -0.05) {
        started = false;
        continue;
      }
      visible++;
      if (!started) {
        ctx.moveTo(cx + pr[0] * R, cy - pr[1] * R);
        started = true;
      } else {
        ctx.lineTo(cx + pr[0] * R, cy - pr[1] * R);
      }
    }
    if (visible > 1) ctx.stroke();
    ctx.setLineDash([]);

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
        g2.addColorStop(0.4, "rgba(214,199,255,0.75)");
        g2.addColorStop(1, "rgba(214,199,255,0)");
        ctx.fillStyle = g2;
        ctx.beginPath();
        ctx.arc(px, py, 7, 0, TAU);
        ctx.fill();
      }
    }
    ctx.restore();

    var self = this;
    (o.nodes || []).forEach(function (n, idx) {
      var p = self.project(unit(n.lat, n.lon));
      if (p[2] <= 0.03) return;
      var sx = cx + p[0] * R;
      var sy = cy - p[1] * R;
      var soon = n.status === "soon";
      var isActive = !soon && n.id === active.id && grow >= 1;
      var depth = Math.min(1, 0.35 + p[2]);
      var color = soon ? "rgba(153,148,171," : isActive ? "rgba(94,231,163," : "rgba(214,199,255,";

      if (!soon && !reduced) {
        var ph = ((now / 1000 + idx * 0.7) % 2.4) / 2.4;
        ctx.strokeStyle = color + 0.45 * (1 - ph) * depth + ")";
        ctx.lineWidth = 1;
        ctx.beginPath();
        ctx.arc(sx, sy, 3 + ph * 13, 0, TAU);
        ctx.stroke();
      }

      if (isActive) {
        var gl = ctx.createRadialGradient(sx, sy, 0, sx, sy, 12);
        gl.addColorStop(0, "rgba(94,231,163,0.5)");
        gl.addColorStop(1, "rgba(94,231,163,0)");
        ctx.fillStyle = gl;
        ctx.beginPath();
        ctx.arc(sx, sy, 12, 0, TAU);
        ctx.fill();
      }

      ctx.fillStyle = color + (soon ? 0.45 : 0.95) * depth + ")";
      ctx.beginPath();
      ctx.arc(sx, sy, soon ? 1.8 : 2.9, 0, TAU);
      ctx.fill();
    });

    var hp = this.project(home);
    if (hp[2] > 0.03) {
      var hx = cx + hp[0] * R;
      var hy = cy - hp[1] * R;
      if (!reduced) {
        var hph = ((now / 1000) % 2.4) / 2.4;
        ctx.strokeStyle = "rgba(214,199,255," + 0.55 * (1 - hph) + ")";
        ctx.lineWidth = 1.1;
        ctx.beginPath();
        ctx.arc(hx, hy, 3 + hph * 15, 0, TAU);
        ctx.stroke();
      }
      ctx.fillStyle = "#ffffff";
      ctx.beginPath();
      ctx.arc(hx, hy, 3, 0, TAU);
      ctx.fill();
      ctx.strokeStyle = "rgba(214,199,255,0.9)";
      ctx.lineWidth = 1.4;
      ctx.beginPath();
      ctx.arc(hx, hy, 5.4, 0, TAU);
      ctx.stroke();
    }
  };

  window.GlukGlobe = Globe;
})();
