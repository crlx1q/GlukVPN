/* Единая система «подключения аккаунта».
 *
 * Одинаково на всех клиентах — Windows, Android, расширение Chrome и сайт /app:
 *  • карта это только визуал: точки мира, зелёная точка «вы», сиреневая точка
 *    узла выхода и тонкая пунктирная нитка между ними;
 *  • на карте ничего не кликается. Точка размером в пиксель — недостижимая
 *    цель для мыши и тем более для пальца, поэтому все подробности живут в
 *    панели «Устройства», которая открывается чипом над картой;
 *  • глифы устройств — готовые Material Icons из локального PNG-спрайта,
 *    подключённого маской, поэтому они окрашены темой, а не белые;
 *  • на телефоне карта скрыта (CSS), панель «Устройства» остаётся.
 */
(function(D){
 if(!D||typeof document==='undefined')return;

 // Готовые глифы Material Icons — те же, что Flutter Icons.devices/computer/
 // smartphone/web/dns. Один спрайт material-devices.png на все клиенты.
 D.deviceIcon=function(platform){
  var p=String(platform||'').toLowerCase(),kind=p==='devices'?'devices':/android|ios|phone/.test(p)?'phone':/chrome|browser|ext/.test(p)?'web':p==='server'?'server':'computer';
  return '<span class="material-device material-device--'+kind+'" aria-hidden="true"></span>';
 };

 D.drawAccountMap=function(data){
  var canvas=document.querySelector('[data-dash-map]');if(!canvas)return;
  var stage=canvas.parentElement,card=stage&&stage.parentElement;if(!card)return;
  var snapshot=data&&typeof data==='object'?data:null;
  var live=(snapshot&&Array.isArray(snapshot.devices)?snapshot.devices:[]).filter(function(d){return d&&d.status==='ACTIVE';});
  // Подсказка «Наведите или нажмите на точку» больше не имеет смысла: точки
  // не интерактивны, а список устройств всегда рядом.
  var stale=card.querySelector('[data-map-detail]');if(stale)stale.remove();
  paintWorld(canvas);
  paintThreads(stage,live);
  paintPanel(card,snapshot,live);
 };

 /* ------------------------------------------------------------ карта */

 function paintWorld(canvas){
  var box=canvas.getBoundingClientRect(),w=Math.max(1,box.width),h=Math.max(1,box.height);
  var dpr=Math.min(window.devicePixelRatio||1,2),c=canvas.getContext&&canvas.getContext('2d');
  if(!c||!w||!h)return;
  canvas.width=Math.round(w*dpr);canvas.height=Math.round(h*dpr);
  c.setTransform(dpr,0,0,dpr,0,0);c.clearRect(0,0,w,h);
  var land=window.GLUK_WORLD_DOTS;if(!land||!land.packed)return;
  var raw=atob(land.packed),r=Math.max(.6,w/780);
  c.fillStyle='rgba(139,124,246,.4)';
  for(var i=0;i<raw.length;i+=2){
   c.beginPath();
   c.arc(raw.charCodeAt(i)/2/land.vbW*w,raw.charCodeAt(i+1)*land.yStep/land.vbH*h,r,0,Math.PI*2);
   c.fill();
  }
 }

 // Нитки соединений и две точки. Карта живёт в системе координат 119x60 —
 // ровно как aspect-ratio сцены, поэтому масштаб равномерный и штрих не косой.
 function paintThreads(stage,live){
  var old=stage.querySelector('.gluk-threads');if(old)old.remove();
  var svg=node('svg',{'class':'gluk-threads',viewBox:'0 0 119 60',preserveAspectRatio:'none','aria-hidden':'true'});
  var defs=node('defs'),grad=node('linearGradient',{id:'gluk-thread-grad',x1:'0',y1:'0',x2:'1',y2:'0'});
  grad.appendChild(node('stop',{offset:'0%','stop-color':'#3ddc97'}));
  grad.appendChild(node('stop',{offset:'100%','stop-color':'#c4b5fd'}));
  defs.appendChild(grad);svg.appendChild(defs);
  var seen={},drawn=0;
  live.forEach(function(d){
   var exit=d.node&&d.node.location;
   if(!place(d.origin)||!place(exit))return;
   var a=project(d.origin),b=project(exit),lift=Math.max(3.5,Math.abs(b.x-a.x)*.16);
   svg.appendChild(node('path',{'class':'gluk-thread',d:'M'+fix(a.x)+' '+fix(a.y)+' Q'+fix((a.x+b.x)/2)+' '+fix(Math.max(1.5,Math.min(a.y,b.y)-lift))+' '+fix(b.x)+' '+fix(b.y)}));
   marker(svg,seen,a,'you');marker(svg,seen,b,'node');
   drawn++;
  });
  svg.classList.toggle('is-empty',drawn===0);
  stage.appendChild(svg);
 }

 function marker(svg,seen,p,kind){
  var key=kind+':'+fix(p.x)+':'+fix(p.y);if(seen[key])return;seen[key]=1;
  svg.appendChild(node('circle',{'class':'gluk-halo gluk-halo--'+kind,cx:fix(p.x),cy:fix(p.y),r:'2.5'}));
  svg.appendChild(node('circle',{'class':'gluk-dot gluk-dot--'+kind,cx:fix(p.x),cy:fix(p.y),r:'.95'}));
 }

 /* -------------------------------------------- панель «Устройства» */

 function paintPanel(card,snapshot,live){
  var top=card.querySelector('[data-gluk-top]');
  if(!top){
   top=document.createElement('div');
   top.className='gluk-top';top.setAttribute('data-gluk-top','');
   top.innerHTML='<span class="gluk-state" data-gluk-state><i></i><span></span></span>'+
    '<span class="gluk-chip-wrap">'+
     '<button type="button" class="gluk-chip" data-gluk-chip aria-expanded="false"></button>'+
     '<div class="gluk-panel" data-gluk-panel hidden></div>'+
    '</span>';
   card.insertBefore(top,card.firstChild);
   bind(top);
  }
  var chip=top.querySelector('[data-gluk-chip]'),panel=top.querySelector('[data-gluk-panel]'),state=top.querySelector('[data-gluk-state]');
  var active=snapshot&&isNum(snapshot.activeTunnels)?snapshot.activeTunnels:live.length;
  var pending=snapshot&&isNum(snapshot.pendingTunnels)?snapshot.pendingTunnels:0;

  chip.innerHTML=D.deviceIcon('devices')+
   '<span class="gluk-chip__label">'+esc(tr('Устройства','Devices'))+'</span>'+
   '<b class="gluk-chip__count">'+esc(active)+'</b>'+
   '<i class="gluk-chev" aria-hidden="true"></i>';
  chip.setAttribute('aria-label',tr('Устройства онлайн','Devices online')+': '+active);

  state.className='gluk-state'+(active>0?' is-on':'');
  state.querySelector('span').textContent=active>0
   ? tr('Активные подключения','Active connections')
   : (pending>0?tr('Подключение…','Connecting…'):tr('Активных подключений нет','No active connections'));

  panel.innerHTML='<div class="gluk-panel__head"><b>'+esc(tr('Устройства онлайн','Devices online'))+'</b><span>'+esc(summary(snapshot,active,pending))+'</span></div>'+
   '<div class="gluk-panel__list">'+(live.length?live.map(row).join(''):'<p class="gluk-empty">'+esc(snapshot?tr('Нет активных подключений','No active connections'):tr('Подключения сейчас недоступны','Connections unavailable'))+'</p>')+'</div>';
 }

 function summary(snapshot,active,pending){
  if(!snapshot)return tr('Подключения сейчас недоступны','Connections unavailable');
  var limit=isNum(snapshot.maxDevices)?snapshot.maxDevices:null;
  var text=active+' '+tr('подключено','connected');
  if(limit!=null)text+=' · '+tr('лимит устройств','device limit')+' '+limit;
  if(pending>0)text+=' · '+pending+' '+tr('подключаются','connecting');
  return text;
 }

 function row(d){
  var meta=[d.platform||'—',duration(d.durationSec)].filter(Boolean).join(' · ');
  return '<div class="gluk-dev">'+
   '<span class="gluk-dev__tile">'+D.deviceIcon(d.platform)+'</span>'+
   '<span class="gluk-dev__body">'+
    '<b>'+esc(d.deviceName||tr('Устройство','Device'))+'</b>'+
    '<span class="gluk-dev__meta">'+esc(meta)+'</span>'+
    '<span class="gluk-dev__route">'+esc('→ '+exitTitle(d.node))+'</span>'+
    (d.isCurrent?'<span class="gluk-dev__self">'+esc(tr('Это устройство','This device'))+'</span>':'')+
   '</span>'+
   '<span class="gluk-dev__end"><i class="gluk-live'+(d.status==='ACTIVE'?' is-on':'')+'"></i><i class="gluk-chev gluk-chev--right" aria-hidden="true"></i></span>'+
  '</div>';
 }

 function bind(top){
  var chip=top.querySelector('[data-gluk-chip]'),panel=top.querySelector('[data-gluk-panel]');
  function open(next){
   panel.hidden=!next;
   top.classList.toggle('is-open',!!next);
   chip.setAttribute('aria-expanded',next?'true':'false');
  }
  chip.addEventListener('click',function(e){e.stopPropagation();open(panel.hidden);});
  document.addEventListener('click',function(e){if(!top.contains(e.target))open(false);});
  document.addEventListener('keydown',function(e){if(e.key==='Escape'&&!panel.hidden){open(false);chip.focus();}});
 }

 /* --------------------------------------------------------- мелочи */

 var SVG_NS='http://www.w3.org/2000/svg';
 function node(name,attrs){
  var el=document.createElementNS(SVG_NS,name);
  for(var k in attrs)if(Object.prototype.hasOwnProperty.call(attrs,k)&&attrs[k]!=null)el.setAttribute(k,attrs[k]);
  return el;
 }
 function isNum(v){return typeof v==='number'&&isFinite(v);}
 function place(p){return !!p&&isNum(Number(p.lat))&&isNum(Number(p.lon))&&Math.abs(p.lat)<=90&&Math.abs(p.lon)<=180;}
 function project(p){return {x:(Number(p.lon)+180)/360*119,y:(90-Number(p.lat))/180*60};}
 function fix(v){return (Math.round(v*100)/100).toString();}
 function isEn(){return document.documentElement.getAttribute('data-lang')==='en';}
 function tr(ru,en){return isEn()?en:ru;}
 function esc(v){return String(v==null?'':v).replace(/[&<>"']/g,function(ch){return ch==='&'?'&amp;':ch==='<'?'&lt;':ch==='>'?'&gt;':ch==='"'?'&quot;':'&#39;';});}
 function pad(n){return (n<10?'0':'')+n;}
 function duration(sec){
  var s=Math.max(0,Math.round(Number(sec)||0)),h=Math.floor(s/3600),m=Math.floor(s%3600/60);
  return h?h+':'+pad(m)+':'+pad(s%60):pad(m)+':'+pad(s%60);
 }
 function exitTitle(exit){
  if(!exit)return tr('Узел неизвестен','Unknown node');
  var parts=[exit.city,exit.country].filter(Boolean);
  return parts.join(', ')||exit.name||tr('Узел неизвестен','Unknown node');
 }
})(window.GlukDashboard);
