(function(D){
 if(!D||typeof document==='undefined')return;
 D.deviceIcon=function(platform){
  var p=String(platform||'').toLowerCase(),body;
  if(/android/.test(p))body='<path d="m7 5-2-3m12 3 2-3M4 11a8 8 0 0 1 16 0v7H4z"/><path d="M8 18v3m8-3v3M1 11v6m22-6v6"/><circle cx="8" cy="9" r=".8" fill="currentColor"/><circle cx="16" cy="9" r=".8" fill="currentColor"/>';
  else if(/ios|iphone|ipad/.test(p))body='<rect x="6" y="2" width="12" height="20" rx="3"/><path d="M10 5h4m-3 14h2"/>';
  else if(/chrome|browser|ext/.test(p))body='<rect x="2" y="3" width="20" height="18" rx="3"/><path d="M2 8h20M6 5.5h.1m3 0h.1"/>';
  else if(/server/.test(p))body='<rect x="3" y="2" width="18" height="8" rx="2"/><rect x="3" y="14" width="18" height="8" rx="2"/><path d="M7 6h.1M7 18h.1M12 6h5M12 18h5"/>';
  else if(/win/.test(p))body='<path d="M3 4h18v16H3zM12 4v16M3 12h18"/>';
  else body='<rect x="2" y="3" width="20" height="14" rx="2"/><path d="M12 17v4m-5 0h10"/>';
  return '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">'+body+'</svg>';
 };
 D.drawAccountMap=function(data){
  var canvas=document.querySelector('[data-dash-map]'),overlay=document.querySelector('[data-dash-pins]'),note=document.querySelector('[data-s2-map-note]');if(!canvas||!overlay)return;
  var stage=canvas.parentElement,info=stage.parentElement.querySelector('[data-map-detail]');if(!info){info=document.createElement('p');info.className='map-detail';info.setAttribute('data-map-detail','');info.setAttribute('aria-live','polite');stage.insertAdjacentElement('afterend',info);}
  var en=document.documentElement.getAttribute('data-lang')==='en',hint=en?'Hover or tap a point to inspect its connections.':'Наведите или нажмите на точку, чтобы увидеть подключения.';info.textContent=hint;
  var w=Math.max(1,canvas.getBoundingClientRect().width),h=Math.max(1,canvas.getBoundingClientRect().height),dpr=Math.min(window.devicePixelRatio||1,2),c=canvas.getContext('2d');if(!c)return;
  canvas.width=Math.round(w*dpr);canvas.height=Math.round(h*dpr);c.setTransform(dpr,0,0,dpr,0,0);c.clearRect(0,0,w,h);c.fillStyle='#151020';c.fillRect(0,0,w,h);
  var land=window.GLUK_WORLD_DOTS;if(land){var raw=atob(land.packed);c.fillStyle='#79639f';for(var i=0;i<raw.length;i+=2){c.beginPath();c.arc(raw.charCodeAt(i)/2/land.vbW*w,raw.charCodeAt(i+1)*land.yStep/land.vbH*h,Math.max(.7,w/650),0,Math.PI*2);c.fill();}}
  function valid(p){return p&&Number.isFinite(p.lat)&&Number.isFinite(p.lon)&&Math.abs(p.lat)<=90&&Math.abs(p.lon)<=180;}
  function xy(p){return {x:(p.lon+180)/360*w,y:(90-p.lat)/180*h};}
  var rows=Array.isArray(data.devices)?data.devices.filter(function(d){return d.status==='ACTIVE';}):[],markers={},paths=[],missing=0;
  function marker(p,kind,icon,label){if(!valid(p))return;var pos=xy(p),key=kind+':'+p.lat+':'+p.lon;var nearby=Object.keys(markers).find(function(k){var m=markers[k];return m.kind===kind&&Math.hypot(m.p.x-pos.x,m.p.y-pos.y)<30;});if(nearby)key=nearby;if(!markers[key])markers[key]={key:key,p:pos,kind:kind,icon:icon,labels:[]};if(markers[key].labels.indexOf(label)<0)markers[key].labels.push(label);}
  rows.forEach(function(d){var n=d.node,location=n&&n.location,server=n&&(n.name||[n.city,n.country].filter(Boolean).join(', '))||(en?'Unknown node':'Узел неизвестен'),label=(d.deviceName||'Device')+' · '+(d.platform||'—')+' → '+server;
   marker(d.origin,'device',D.deviceIcon(d.platform),label);marker(location,'node',D.deviceIcon('server'),server+' ← '+(d.deviceName||'Device'));
   if(!valid(d.origin)||!valid(location)){missing++;return;}var a=xy(d.origin),b=xy(location),mid=(a.x+b.x)/2,top=Math.max(3,Math.min(a.y,b.y)-Math.max(14,Math.abs(a.x-b.x)*.15));paths.push('M'+a.x+','+a.y+' Q'+mid+','+top+' '+b.x+','+b.y);
  });
  var focused=document.activeElement&&document.activeElement.getAttribute('data-map-key');overlay.replaceChildren();
  var ns='http://www.w3.org/2000/svg',svg=document.createElementNS(ns,'svg');svg.setAttribute('class','s2-routes');svg.setAttribute('viewBox','0 0 '+w+' '+h);svg.setAttribute('preserveAspectRatio','none');svg.setAttribute('aria-hidden','true');paths.forEach(function(d){var p=document.createElementNS(ns,'path');p.setAttribute('d',d);svg.appendChild(p);});overlay.appendChild(svg);
  Object.keys(markers).forEach(function(key){var m=markers[key],b=document.createElement('button');b.type='button';b.className='account-map-point account-map-point--'+m.kind;b.style.left=m.p.x/w*100+'%';b.style.top=m.p.y/h*100+'%';b.setAttribute('data-map-key',key);b.setAttribute('aria-label',m.labels.join('; '));b.title=m.labels.join('\n');b.innerHTML=m.icon;if(m.labels.length>1){var count=document.createElement('small');count.textContent=String(m.labels.length);b.appendChild(count);}function show(){info.textContent=m.labels.join(' • ');}b.addEventListener('mouseenter',show);b.addEventListener('focus',show);b.addEventListener('click',show);overlay.appendChild(b);if(key===focused)b.focus({preventScroll:true});});
  if(note)note.textContent=(Number.isFinite(data.activeTunnels)?data.activeTunnels:rows.length)+(en?' active connections':' активных подключений')+(Number(data.pendingTunnels)>0?' · '+data.pendingTunnels+(en?' connecting':' подключаются'):'')+(missing?' · '+missing+(en?' without coordinates':' без координат'):'')+(en?' · approximate IP location':' · приблизительно по IP');
 };
})(window.GlukDashboard);
