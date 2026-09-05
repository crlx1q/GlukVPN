/* Dotted-world asset shared with the desktop app. Decorative, not live telemetry. */
(function () {
  'use strict';
  var tg = document.querySelector('[data-sso-telegram]');
  if (tg) tg.innerHTML = '<svg viewBox="0 0 240 240" aria-hidden="true"><defs><linearGradient id="auth-tg" x2="0" y2="1"><stop stop-color="#2AABEE"/><stop offset="1" stop-color="#229ED9"/></linearGradient></defs><circle cx="120" cy="120" r="120" fill="url(#auth-tg)"/><path fill="#fff" d="M54.3 118.8c35-15.2 58.3-25.3 69.9-30.2 33.3-13.8 40.2-16.2 44.7-16.3 1 0 3.2.2 4.7 1.4 1.2 1 1.5 2.3 1.7 3.3.2 1 .4 3.1.2 4.8-1.8 19.4-9.9 66.4-14 88.1-1.7 9.2-5.1 12.3-8.4 12.6-7.1.7-12.5-4.7-19.4-9.2-10.8-7.1-16.9-11.5-27.4-18.4-12.1-8-4.3-12.4 2.7-19.6 1.8-1.9 33.4-30.6 34-33.2.1-.3.1-1.5-.6-2.1-.7-.6-1.8-.4-2.6-.2-1.1.2-18.6 11.8-52.5 34.8-5 3.4-9.5 5.1-13.5 5-4.4-.1-12.9-2.5-19.2-4.6-7.7-2.5-13.8-3.8-13.3-8.1.3-2.2 3.3-4.5 9-6.9z"/></svg>Telegram';
  var canvas = document.querySelector('[data-cosmos]'), data = window.GLUK_WORLD_DOTS;
  if (!canvas || !data) return;
  var ctx = canvas.getContext('2d'); if (!ctx) return;
  var bytes = atob(data.packed), points = [], reduced = matchMedia('(prefers-reduced-motion: reduce)');
  for (var i=0;i<bytes.length;i+=2) {
    var lon=(bytes.charCodeAt(i)/2/data.vbW*360-180)*Math.PI/180;
    var lat=(90-bytes.charCodeAt(i+1)*data.yStep/data.vbH*180)*Math.PI/180;
    points.push([Math.cos(lat)*Math.cos(lon),Math.sin(lat),Math.cos(lat)*Math.sin(lon)]);
  }
  var raf=0,last=0,angle=.8,visible=true;
  function draw(time) {
    raf=0;
    var rect=canvas.getBoundingClientRect();
    if(document.hidden||!visible||!rect.width||!rect.height)return;
    var w=rect.width,h=rect.height,dpr=Math.min(devicePixelRatio||1,2);
    if(canvas.width!==Math.round(w*dpr)||canvas.height!==Math.round(h*dpr)){canvas.width=Math.round(w*dpr);canvas.height=Math.round(h*dpr);}
    if(!reduced.matches&&last)angle+=Math.min(time-last,60)*.000045;
    last=time;ctx.setTransform(dpr,0,0,dpr,0,0);ctx.clearRect(0,0,w,h);
    var r=Math.min(w*.39,h*.44),cx=w*.54,cy=h*.5;
    var gradient=ctx.createRadialGradient(cx-r*.35,cy-r*.5,0,cx,cy,r);
    gradient.addColorStop(0,'rgba(180,133,255,.36)');gradient.addColorStop(1,'rgba(19,7,47,.44)');
    ctx.fillStyle=gradient;ctx.beginPath();ctx.arc(cx,cy,r,0,Math.PI*2);ctx.fill();
    var cos=Math.cos(angle),sin=Math.sin(angle);
    points.forEach(function(p){var x=p[0]*cos+p[2]*sin,z=p[2]*cos-p[0]*sin;if(z<0)return;ctx.fillStyle='rgba(214,185,255,'+(.24+z*.66)+')';ctx.beginPath();ctx.arc(cx+x*r,cy-p[1]*r,Math.max(1,r/95)*(.65+z*.35),0,Math.PI*2);ctx.fill();});
    ctx.strokeStyle='rgba(222,197,255,.2)';ctx.lineWidth=1;ctx.beginPath();ctx.ellipse(cx,cy,r*1.14,r*.26,-.25,0,Math.PI*2);ctx.stroke();
    if(!reduced.matches)raf=requestAnimationFrame(draw);
  }
  function restart(){cancelAnimationFrame(raf);last=0;draw(performance.now());}
  if('IntersectionObserver' in window)new IntersectionObserver(function(entries){visible=entries[0].isIntersecting;restart();}).observe(canvas);
  window.addEventListener('resize',restart);document.addEventListener('visibilitychange',restart);reduced.addEventListener('change',restart);restart();
})();
