/* ==========================================================================
   GlukVPN - интерактивная карта сети (canvas, equirectangular)

   Те же точки, что и в приложении (world-dots.js), те же состояния:
   фиолетовый you-маркер, зелёные ноды, dashFlow-маршрут, netPulse-кольца.
   Используется и в секции «Global network», и внутри экрана приложения.
   ========================================================================== */

(function () {
  "use strict";

  var TAU = Math.PI * 2;
  var reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var dots = null;

  function worldDots() {
    if (dots) return dots;
    var data = window.GLUK_WORLD_DOTS;
    if (!data) return (dots = new Float32Array(0));
    var bin = atob(data.packed);
    var n = bin.length / 2;
    var out = new Float32Array(n * 2);
    for (var i = 0; i < n; i++) {
      out[i * 2] = bin.charCodeAt(i * 2) / 2; // x в единицах viewBox (0..119)
      out[i * 2 + 1] = bin.charCodeAt(i * 2 + 1) * data.yStep; // y (0..60)
    }
    dots = out;
    return out;
  }

  function toMap(lat, lon) {
    return { x: ((lon + 180) / 360) * 119, y: ((90 - lat) / 180) * 60 };
  }

  function NetworkMap(canvas, opts) {
    this.canvas = canvas;
    this.ctx = canvas.getContext("2d");
    this.o = Object.assign(
      {
        home: null,
        nodes: [],
        cycle: 5200,
        dotSize: 1.25,
        compact: false, // вариант для экрана приложения
        interactive: false,
        fixedRoute: null, // id ноды: постоянный маршрут без переключения
                          // (экран приложения: одна сессия)
        onHover: null,
        onSelect: null,
        view: { x: 6, y: 1, w: 108, h: 46 }, // кадрирование viewBox
      },
      opts || {}
    );
    this.live = (this.o.nodes || []).filter(function (n) {
      return n.status !== "soon";
    });
    this.routeIndex = 0;
    this.routeStart = performance.now();
    this.hoverId = null;
    this.forcedId = null;
    this.resize();
    this.bind();
  }

  NetworkMap.prototype.bind = function () {
    var self = this;
    window.addEventListener(
      "resize",
      function () {
        self.resize();
        if (reduced) self.draw(performance.now());
      },
      { passive: true }
    );

    if (this.o.interactive) {
      this.canvas.addEventListener("pointermove", function (e) {
        var hit = self.hitTest(e);
        var id = hit ? hit.node.id : null;
        if (id !== self.hoverId) {
          self.hoverId = id;
          self.canvas.style.cursor = id ? "pointer" : "crosshair";
          if (self.o.onHover) self.o.onHover(hit ? hit.node : null, hit);
          if (reduced) self.draw(performance.now());
        }
      });
      this.canvas.addEventListener("pointerleave", function () {
        self.hoverId = null;
        if (self.o.onHover) self.o.onHover(null, null);
        if (reduced) self.draw(performance.now());
      });
      this.canvas.addEventListener("click", function (e) {
        var hit = self.hitTest(e);
        if (hit && self.o.onSelect) self.o.onSelect(hit.node);
      });
    }

    if ("IntersectionObserver" in window) {
      this.io = new IntersectionObserver(
        function (entries) {
          entries.forEach(function (en) {
            en.isIntersecting ? self.start() : self.stop();
          });
        },
        { rootMargin: "140px" }
      );
      this.io.observe(this.canvas);
    } else {
      this.start();
    }

    document.addEventListener("visibilitychange", function () {
      document.hidden ? self.stop() : self.start();
    });
  };

  NetworkMap.prototype.resize = function () {
    var dpr = Math.min(window.devicePixelRatio || 1, 2);
    var r = this.canvas.getBoundingClientRect();
    var w = Math.max(1, Math.round(r.width));
    var h = Math.max(1, Math.round(r.height));
    this.canvas.width = Math.round(w * dpr);
    this.canvas.height = Math.round(h * dpr);
    this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    this.w = w;
    this.h = h;

    var v = this.o.view;
    // cover-fit кадра viewBox в canvas
    this.scale = Math.max(w / v.w, h / v.h);
    this.offX = (w - v.w * this.scale) / 2 - v.x * this.scale;
    this.offY = (h - v.h * this.scale) / 2 - v.y * this.scale;
  };

  NetworkMap.prototype.px = function (x, y) {
    return [x * this.scale + this.offX, y * this.scale + this.offY];
  };

  NetworkMap.prototype.hitTest = function (e) {
    var r = this.canvas.getBoundingClientRect();
    var mx = e.clientX - r.left;
    var my = e.clientY - r.top;
    var best = null;
    var bestD = 26;
    var self = this;
    (this.o.nodes || []).forEach(function (n) {
      var m = toMap(n.lat, n.lon);
      var p = self.px(m.x, m.y);
      var d = Math.hypot(p[0] - mx, p[1] - my);
      if (d < bestD) {
        bestD = d;
        best = { node: n, x: p[0], y: p[1] };
      }
    });
    return best;
  };

  NetworkMap.prototype.nodePoint = function (id) {
    var n = (this.o.nodes || []).filter(function (x) {
      return x.id === id;
    })[0];
    if (!n) return null;
    var m = toMap(n.lat, n.lon);
    return this.px(m.x, m.y);
  };

  NetworkMap.prototype.start = function () {
    if (this.raf) return;
    if (reduced) {
      this.draw(performance.now());
      return;
    }
    var self = this;
    var loop = function (now) {
      self.draw(now);
      self.raf = requestAnimationFrame(loop);
    };
    this.raf = requestAnimationFrame(loop);
  };

  NetworkMap.prototype.stop = function () {
    if (this.raf) cancelAnimationFrame(this.raf);
    this.raf = null;
  };

  NetworkMap.prototype.focus = function (id) {
    this.forcedId = id;
    if (id) {
      for (var i = 0; i < this.live.length; i++) {
        if (this.live[i].id === id) {
          this.routeIndex = i;
          this.routeStart = performance.now();
          break;
        }
      }
    }
    if (reduced) this.draw(performance.now());
  };

  NetworkMap.prototype.activeNode = function (now) {
    if (this.o.fixedRoute) {
      for (var k = 0; k < this.live.length; k++) {
        if (this.live[k].id === this.o.fixedRoute) return this.live[k];
      }
    }
    if (!this.live.length) return null;
    if (!reduced && !this.forcedId && now - this.routeStart > this.o.cycle) {
      this.routeStart = now;
      this.routeIndex = (this.routeIndex + 1) % this.live.length;
    }
    return this.live[this.routeIndex];
  };

  NetworkMap.prototype.draw = function (now) {
    var ctx = this.ctx;
    var o = this.o;
    ctx.clearRect(0, 0, this.w, this.h);

    /* точки суши */
    var pts = worldDots();
    var s = o.dotSize * Math.max(0.75, Math.min(1.6, this.scale / 9));
    ctx.fillStyle = "#8b7cf6";
    ctx.globalAlpha = o.compact ? 0.4 : 0.34;
    for (var i = 0; i < pts.length; i += 2) {
      var p = this.px(pts[i], pts[i + 1]);
      if (p[0] < -4 || p[0] > this.w + 4 || p[1] < -4 || p[1] > this.h + 4) continue;
      ctx.fillRect(p[0] - s / 2, p[1] - s / 2, s, s);
    }
    ctx.globalAlpha = 1;

    if (!o.home) return;
    var hm = toMap(o.home.lat, o.home.lon);
    var hp = this.px(hm.x, hm.y);
    var active = this.activeNode(now);

    /* фоновые орбиты (тихие нити между нодами, как .orbit-thread) */
    var self = this;
    ctx.save();
    ctx.strokeStyle = "rgba(196,181,253,0.18)";
    ctx.lineWidth = 1;
    ctx.setLineDash([2, 4]);
    this.live.forEach(function (n) {
      if (active && n.id === active.id) return;
      var m = toMap(n.lat, n.lon);
      var p = self.px(m.x, m.y);
      self.arc(ctx, hp, p, 0.16);
      ctx.stroke();
    });
    ctx.restore();

    /* активный маршрут */
    if (active) {
      var ap = this.nodePoint(active.id);
      var grad = ctx.createLinearGradient(hp[0], hp[1], ap[0], ap[1]);
      grad.addColorStop(0, "rgba(196,181,253,0.95)");
      grad.addColorStop(1, "rgba(94,231,163,0.95)");
      ctx.save();
      ctx.strokeStyle = grad;
      ctx.lineWidth = o.compact ? 1.3 : 1.8;
      ctx.setLineDash([6, 5]);
      ctx.lineDashOffset = reduced ? 0 : -(now / 30) % 11;
      ctx.shadowColor = "rgba(196,181,253,0.6)";
      ctx.shadowBlur = 8;
      this.arc(ctx, hp, ap, 0.22);
      ctx.stroke();
      ctx.restore();

      if (!reduced) {
        var t = ((now - this.routeStart) / 1600) % 1;
        var pk = this.arcPoint(hp, ap, 0.22, t);
        var g = ctx.createRadialGradient(pk[0], pk[1], 0, pk[0], pk[1], 8);
        g.addColorStop(0, "rgba(255,255,255,0.95)");
        g.addColorStop(0.35, "rgba(196,181,253,0.7)");
        g.addColorStop(1, "rgba(196,181,253,0)");
        ctx.fillStyle = g;
        ctx.beginPath();
        ctx.arc(pk[0], pk[1], 8, 0, TAU);
        ctx.fill();
      }
    }

    /* ноды */
    (o.nodes || []).forEach(function (n, idx) {
      var m = toMap(n.lat, n.lon);
      var p = self.px(m.x, m.y);
      var soon = n.status === "soon";
      var isActive = active && n.id === active.id;
      var hovered = self.hoverId === n.id;
      var base = soon ? "153,148,171" : isActive ? "79,216,140" : "196,181,253";

      if (!soon && !reduced) {
        var ph = ((now / 1000 + idx * 0.6) % 3.2) / 3.2;
        ctx.strokeStyle = "rgba(" + base + "," + 0.45 * (1 - ph) + ")";
        ctx.lineWidth = 1;
        ctx.beginPath();
        ctx.arc(p[0], p[1], 3 + ph * (o.compact ? 11 : 18), 0, TAU);
        ctx.stroke();
      }

      if (isActive || hovered) {
        var gl = ctx.createRadialGradient(p[0], p[1], 0, p[0], p[1], 16);
        gl.addColorStop(0, "rgba(" + base + ",0.42)");
        gl.addColorStop(1, "rgba(" + base + ",0)");
        ctx.fillStyle = gl;
        ctx.beginPath();
        ctx.arc(p[0], p[1], 16, 0, TAU);
        ctx.fill();
      }

      if (soon) {
        ctx.strokeStyle = "rgba(" + base + ",0.65)";
        ctx.lineWidth = 1.2;
        ctx.beginPath();
        ctx.arc(p[0], p[1], o.compact ? 2 : 3, 0, TAU);
        ctx.stroke();
      } else {
        ctx.fillStyle = "rgba(" + base + ",1)";
        ctx.beginPath();
        ctx.arc(p[0], p[1], o.compact ? 2.4 : 3.4, 0, TAU);
        ctx.fill();
      }

      if (!o.compact && !soon) {
        ctx.font = "600 11px " + (o.font || "system-ui, sans-serif");
        ctx.fillStyle = hovered || isActive ? "rgba(245,243,251,0.95)" : "rgba(153,148,171,0.8)";
        ctx.textAlign = "center";
        ctx.fillText(n.name, p[0], p[1] - 12);
      }
    });

    /* маркер "вы" */
    if (!reduced) {
      var hph = ((now / 1000) % 2.6) / 2.6;
      ctx.strokeStyle = "rgba(196,181,253," + 0.5 * (1 - hph) + ")";
      ctx.lineWidth = 1.1;
      ctx.beginPath();
      ctx.arc(hp[0], hp[1], 3 + hph * (o.compact ? 12 : 20), 0, TAU);
      ctx.stroke();
    }
    ctx.fillStyle = "#ffffff";
    ctx.beginPath();
    ctx.arc(hp[0], hp[1], o.compact ? 2.6 : 3.4, 0, TAU);
    ctx.fill();
    ctx.strokeStyle = "rgba(196,181,253,0.9)";
    ctx.lineWidth = 1.4;
    ctx.beginPath();
    ctx.arc(hp[0], hp[1], o.compact ? 5 : 6.4, 0, TAU);
    ctx.stroke();
    if (!o.compact) {
      ctx.font = "600 11px " + (o.font || "system-ui, sans-serif");
      ctx.fillStyle = "rgba(245,243,251,0.9)";
      ctx.textAlign = "center";
      ctx.fillText(o.home.name, hp[0], hp[1] - 14);
    }
  };

  /* дуга между двумя точками (квадратичная кривая, как Q в мокапе) */
  NetworkMap.prototype.ctrl = function (a, b, lift) {
    var mx = (a[0] + b[0]) / 2;
    var my = (a[1] + b[1]) / 2;
    var dx = b[0] - a[0];
    var dy = b[1] - a[1];
    var len = Math.hypot(dx, dy);
    return [mx - dy * 0 - 0, my - len * lift];
  };

  NetworkMap.prototype.arc = function (ctx, a, b, lift) {
    var c = this.ctrl(a, b, lift);
    ctx.beginPath();
    ctx.moveTo(a[0], a[1]);
    ctx.quadraticCurveTo(c[0], c[1], b[0], b[1]);
  };

  NetworkMap.prototype.arcPoint = function (a, b, lift, t) {
    var c = this.ctrl(a, b, lift);
    var mt = 1 - t;
    return [
      mt * mt * a[0] + 2 * mt * t * c[0] + t * t * b[0],
      mt * mt * a[1] + 2 * mt * t * c[1] + t * t * b[1],
    ];
  };

  window.GlukNetworkMap = NetworkMap;
})();
