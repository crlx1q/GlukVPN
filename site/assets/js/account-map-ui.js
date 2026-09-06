/* Единая система «подключения аккаунта».
 *
 * Одинаково на всех клиентах — Windows, Android, расширение Chrome и сайт /app:
 *  • ФИОЛЕТОВЫЙ маркер с глифом пк / телефона / браузера — это устройство
 *    по его местоположению, ЗЕЛЁНАЯ точка — выбранный сервер, нитка течёт от
 *    меня к серверу и при появлении «вырисовывается» — точно как в старом
 *    клиенте на Windows;
 *  • три устройства в одной точке — один маркер с бейджем «3», а не куча
 *    наложенных точек. Одна нитка на пару «точка → сервер»: если второе
 *    устройство ушло на другой сервер — вторая нитка;
 *  • на карте ничего не кликается. Все подробности живут в компактной
 *    панели, которая открывается маленькой кнопкой-значком над картой;
 *  • стрелка «>» в строке — настоящая кнопка, она открывает подробности
 *    об устройстве внутри той же панели;
 *  • глифы устройств — готовые Material Icons из локального PNG-спрайта,
 *    подключённого маской, поэтому они окрашены темой, а не белые;
 *  • на телефоне карта скрыта (CSS), панель устройств остаётся.
 */
(function(D){
 if(!D||typeof document==='undefined')return;

 // Готовые глифы Material Icons — те же, что Flutter Icons.devices/computer/
 // smartphone/web/dns. Один спрайт material-devices.png на все клиенты.
 D.deviceIcon=function(platform){
  var p=String(platform||'').toLowerCase(),kind=p==='devices'?'devices':/android|ios|phone/.test(p)?'phone':/chrome|browser|ext/.test(p)?'ext':p==='server'?'server':'computer';
  return '<span class="material-device material-device--'+kind+'" aria-hidden="true"></span>';
 };

 D.drawAccountMap=function(data){
  var canvas=document.querySelector('[data-dash-map]');if(!canvas)return;
  var stage=canvas.parentElement,card=stage&&stage.parentElement;if(!card)return;
  var snapshot=data&&typeof data==='object'?data:null;
  // Последний снимок нужен, чтобы перерисовать панель при переходе
  // в подробности и обратно, не дожидаясь следующего поллинга.
  D.lastAccountMap=snapshot;
  var live=(snapshot&&Array.isArray(snapshot.devices)?snapshot.devices:[]).filter(function(d){return d&&d.status==='ACTIVE';});
  // Подсказка «Наведите или нажмите на точку» больше не имеет смысла: точки
  // не интерактивны, а список устройств всегда рядом.
  var stale=card.querySelector('[data-map-detail]');if(stale)stale.remove();
  var routes=group(live);
  var anchors=ends(snapshot,routes);
  // ЭТАП 3: сцена пересобирается ТОЛЬКО при изменении данных.
  //
  // Опрос идёт раз в 5 секунд, а старый код каждый раз удалял и
  // заново создавал <svg> и маркеры, поэтому CSS-анимации
  // gluk-draw и pin-in стартовали снова: нитка бесконечно пропадала и
  // «прилетала». Сравниваем отпечаток и не трогаем DOM без нужды.
  var sig=JSON.stringify([routes.map(function(r){return [spot(r.a),spot(r.b),r.count,r.device.platform||'',!!r.device.isCurrent];}),
   anchors.self?spot(anchors.self):null,anchors.selfPlatform||'',anchors.node?spot(anchors.node):null]);
  paintWorld(canvas);
  if(sig!==D.lastAccountMapSig||!stage.querySelector('.gluk-threads')){
   D.lastAccountMapSig=sig;
   paintThreads(stage,routes,anchors);
   paintPins(stage,routes,anchors);
  }
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

 // Группировка устройств по точкам карты.
 //
 // `spots` — сколько всего устройств стоит в точке (цифра в бейдже).
 // `pairs` — одна запись на пару «точка → сервер» (одна нитка).
 function group(live){
  var spots={},pairs={},order=[];
  live.forEach(function(d){
   var exit=d.node&&d.node.location;
   if(!place(d.origin)||!place(exit))return;
   var a=project(d.origin),b=project(exit),from=spot(a),key=from+'>'+spot(b);
   spots[from]=(spots[from]||0)+1;
   if(!pairs[key]){pairs[key]={a:a,b:b,from:from,device:d};order.push(key);}
   else if(d.isCurrent&&!pairs[key].device.isCurrent)pairs[key].device=d;
  });
  return order.map(function(key){
   var pair=pairs[key];
   return {a:pair.a,b:pair.b,device:pair.device,count:spots[pair.from]||1};
  });
 }

 // ЭТАП 3, главное требование: «вошёл — вижу себя на карте».
 //
 // Раньше рисовались только живые нитки, и без подключения сцена была
 // пустой. Текущее устройство сервер отдаёт в снимке всегда — origin
 // считается по IP сессии или по стране устройства, независимо от
 // туннеля, — поэтому берём его оттуда. Если моя нитка уже живая,
 // маркер придёт вместе с ней и здесь не дублируется.
 function ends(snapshot,routes){
  var all=snapshot&&Array.isArray(snapshot.devices)?snapshot.devices:[],mine=null;
  all.forEach(function(d){if(d&&d.isCurrent&&!mine)mine=d;});
  var own=routes.some(function(r){return r.device&&r.device.isCurrent;});
  var exit=mine&&mine.node?mine.node.location:null;
  var me=!own&&mine&&place(mine.origin)?project(mine.origin):null;
  // И второе условие: если в той же точке уже стоит маркер
  // другого устройства, свой кружок без туннеля не добавляем —
  // два маркера в одном городе налезают друг на друга. Он
  // появится при подключении, вместе со своей ниткой.
  if(me&&routes.some(function(r){return Math.hypot(r.a.x-me.x,r.a.y-me.y)<2.5;}))me=null;
  return {
   self:me,
   selfPlatform:mine?mine.platform:'',
   node:place(exit)?project(exit):null
  };
 }

 // Нитки соединений и зелёные точки серверов. Карта живёт в системе
 // координат 119x60 — ровно как aspect-ratio сцены, поэтому масштаб
 // равномерный и штрих не косой.
 function paintThreads(stage,routes,anchors){
  var old=stage.querySelector('.gluk-threads');if(old)old.remove();
  var svg=node('svg',{'class':'gluk-threads',viewBox:'0 0 119 60',preserveAspectRatio:'none','aria-hidden':'true'});
  var defs=node('defs'),grad=node('linearGradient',{id:'gluk-thread-grad',x1:'0',y1:'0',x2:'1',y2:'0'});
  // От меня (фиолетовый) к серверу (зелёный) — как в старом клиенте.
  grad.appendChild(node('stop',{offset:'0%','stop-color':'#c4b5fd'}));
  grad.appendChild(node('stop',{offset:'100%','stop-color':'#3ddc97'}));
  defs.appendChild(grad);svg.appendChild(defs);
  var seen={},drawn=0;
  routes.forEach(function(r){
   var a=r.a,b=r.b,lift=Math.max(3.5,Math.abs(b.x-a.x)*.16);
   svg.appendChild(node('path',{'class':'gluk-thread',d:'M'+fix(a.x)+' '+fix(a.y)+' Q'+fix((a.x+b.x)/2)+' '+fix(Math.max(1.5,Math.min(a.y,b.y)-lift))+' '+fix(b.x)+' '+fix(b.y)}));
   var key='node:'+fix(b.x)+':'+fix(b.y);
   if(!seen[key]){
    seen[key]=1;
    svg.appendChild(node('circle',{'class':'gluk-halo gluk-halo--node',cx:fix(b.x),cy:fix(b.y),r:'2.5'}));
    svg.appendChild(node('circle',{'class':'gluk-dot gluk-dot--node',cx:fix(b.x),cy:fix(b.y),r:'1'}));
   }
   drawn++;
  });
  // Выбранный сервер — зелёная точка даже без туннеля.
  if(anchors&&anchors.node){
   var nk='node:'+fix(anchors.node.x)+':'+fix(anchors.node.y);
   if(!seen[nk]){
    seen[nk]=1;
    svg.appendChild(node('circle',{'class':'gluk-halo gluk-halo--node',cx:fix(anchors.node.x),cy:fix(anchors.node.y),r:'2.5'}));
    svg.appendChild(node('circle',{'class':'gluk-dot gluk-dot--node',cx:fix(anchors.node.x),cy:fix(anchors.node.y),r:'1'}));
    drawn++;
   }
  }
  svg.classList.toggle('is-empty',drawn===0);
  stage.appendChild(svg);
 }

 // Маркеры устройств — обычные HTML-элементы поверх карты, а не SVG:
 // так внутри них работает ровно тот же глиф Material Icons, что и в списке
 // устройств и в расширении — одна маска, один цвет, без белых квадратов.
 function paintPins(stage,routes,anchors){
  var old=stage.querySelector('.gluk-pins');if(old)old.remove();
  var box=document.createElement('div');
  box.className='gluk-pins';box.setAttribute('aria-hidden','true');
  var seen={},html=[];
  routes.forEach(function(r){
   var key=fix(r.a.x)+':'+fix(r.a.y);if(seen[key])return;seen[key]=1;
   html.push('<span class="gluk-pin'+(r.device.isCurrent?' is-self':'')+'" style="left:'+fix(r.a.x/119*100)+'%;top:'+fix(r.a.y/60*100)+'%">'+
    D.deviceIcon(r.device.platform)+
    (r.count>1?'<b class="gluk-pin__count">'+esc(r.count)+'</b>':'')+
   '</span>');
  });
  // И я сам — фиолетовый маркер с глифом своей платформы.
  if(anchors&&anchors.self&&!seen[fix(anchors.self.x)+':'+fix(anchors.self.y)]){
   html.push('<span class="gluk-pin is-self" style="left:'+fix(anchors.self.x/119*100)+'%;top:'+fix(anchors.self.y/60*100)+'%">'+
    D.deviceIcon(anchors.selfPlatform)+'</span>');
  }
  box.innerHTML=html.join('');
  box.classList.toggle('is-empty',html.length===0);
  stage.appendChild(box);
 }

 /* -------------------------------------------- панель устройств */

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

  // ЭТАП 2: только значок. Слова «Устройства» больше нет, шеврона тоже,
  // а цифра сидит бейджем НА значке, а не рядом с ним.
  chip.innerHTML=D.deviceIcon('devices')+(active>0?'<b class="gluk-chip__count">'+esc(active)+'</b>':'');
  chip.setAttribute('aria-label',tr('Устройства онлайн','Devices online')+': '+active);
  chip.title=tr('Подключения аккаунта','Account connections');

  state.className='gluk-state'+(active>0?' is-on':'');
  state.querySelector('span').textContent=active>0
   ? tr('Активные подключения','Active connections')
   : (pending>0?tr('Подключение…','Connecting…'):tr('Активных подключений нет','No active connections'));

  // Пока открыты подробности, обновление поллинга не выбрасывает из них —
  // перерисовывается тот же экран с новыми данными.
  panel.dataset.glukSummary=summary(snapshot,active,pending);
  var opened=panel.dataset.glukDetail||'';
  var current=opened?live.filter(function(d){return String(d.id)===opened;})[0]:null;
  if(opened&&!current){opened='';delete panel.dataset.glukDetail;}
  panel.innerHTML=current?detail(current):list(snapshot,live,panel.dataset.glukSummary);
 }

 function list(snapshot,live,note){
  return '<div class="gluk-panel__head"><b>'+esc(tr('Устройства онлайн','Devices online'))+'</b><span>'+esc(note)+'</span></div>'+
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
   '<span class="gluk-dev__end">'+
    '<i class="gluk-live'+(d.status==='ACTIVE'?' is-on':'')+'"></i>'+
    // ЭТАП 2: стрелка — кнопка 34x34, а не картинка.
    '<button type="button" class="gluk-more" data-gluk-more="'+esc(d.id)+'" title="'+esc(tr('Подробнее об устройстве','Device details'))+'" aria-label="'+esc(tr('Подробнее об устройстве','Device details'))+'"><i class="gluk-chev gluk-chev--right" aria-hidden="true"></i></button>'+
   '</span>'+
  '</div>';
 }

 /* --------------------------- подробности одного устройства */

 function detail(d){
  var live=d.status==='ACTIVE',origin=d.origin||null;
  var where=origin?[origin.country,origin.countryCode].filter(Boolean).join(' · '):'';
  var rows=[
   [tr('Сервер выхода','Exit server'),exitTitle(d.node)],
   [tr('Город узла','Node city'),(d.node&&d.node.location&&d.node.location.city)||(d.node&&d.node.city)||'—'],
   [tr('В сети','Uptime'),duration(d.durationSec)],
   [tr('Местоположение','Location'),where||tr('Не определено','Unknown')]
  ];
  if(origin)rows.push([tr('Точность','Accuracy'),origin.source==='device-estimate'
   ? tr('≈ оценка региона устройства','≈ device region estimate')
   : tr('≈ страна по IP','≈ IP country')]);
  return '<div class="gluk-panel__head">'+
    '<button type="button" class="gluk-back" data-gluk-back title="'+esc(tr('Назад','Back'))+'" aria-label="'+esc(tr('Назад','Back'))+'"><i class="gluk-chev gluk-chev--left" aria-hidden="true"></i></button>'+
    '<b>'+esc(d.deviceName||tr('Устройство','Device'))+'</b>'+
   '</div>'+
   '<div class="gluk-detail">'+
    '<div class="gluk-detail__top">'+
     '<span class="gluk-dev__tile">'+D.deviceIcon(d.platform)+'</span>'+
     '<span class="gluk-detail__id">'+
      '<b>'+esc(d.platform||'—')+'</b>'+
      '<span class="gluk-detail__state'+(live?' is-on':'')+'">'+esc(live?tr('Подключено','Connected'):tr('Подключение…','Connecting…'))+'</span>'+
     '</span>'+
    '</div>'+
    rows.map(function(pair){
     return '<div class="gluk-detail__row"><span>'+esc(pair[0])+'</span><b>'+esc(pair[1])+'</b></div>';
    }).join('')+
    (d.isCurrent?'<p class="gluk-detail__note">'+esc(tr('Это устройство, с которого ты сейчас смотришь.','This is the device you are looking at now.'))+'</p>':'')+
    // Кнопки «Отключить» и «Выйти»: первая гасит только туннель,
    // вторая ещё и убирает устройство из аккаунта. Такая же пара есть
    // во Flutter и в расширении — поведение одинаковое на всех площадках.
    '<div class="gluk-acts">'+
     '<button type="button" class="gluk-act" data-gluk-off="'+esc(d.sessionId||'')+'" data-gluk-device="'+esc(d.id)+'"'+(d.sessionId||d.status==='ACTIVE'||d.connected?'':' disabled')+'>'+esc(tr('Отключить','Disconnect'))+'</button>'+
     '<button type="button" class="gluk-act gluk-act--danger" data-gluk-out="'+esc(d.id)+'" data-gluk-session="'+esc(d.sessionId||'')+'">'+esc(tr('Выйти','Sign out'))+'</button>'+
    '</div>'+
    '<p class="gluk-detail__hint">'+esc(tr('«Отключить» гасит только VPN. «Выйти» ещё и выкидывает устройство из аккаунта.','“Disconnect” only drops the VPN. “Sign out” also removes the device from the account.'))+'</p>'+
    '<p class="gluk-detail__error" data-gluk-error hidden></p>'+
   '</div>';
 }

 function bind(top){
  var chip=top.querySelector('[data-gluk-chip]'),panel=top.querySelector('[data-gluk-panel]');
  function open(next){
   panel.hidden=!next;
   top.classList.toggle('is-open',!!next);
   chip.setAttribute('aria-expanded',next?'true':'false');
   if(!next)delete panel.dataset.glukDetail;
  }
  chip.addEventListener('click',function(e){e.stopPropagation();open(panel.hidden);});
  // Клики внутри панели ловятся делегированием: содержимое пересобирается
  // каждый поллинг, и вешать слушатели на каждую строку было бы утечкой.
  panel.addEventListener('click',function(e){
   var more=e.target.closest&&e.target.closest('[data-gluk-more]');
   if(more){e.stopPropagation();panel.dataset.glukDetail=more.getAttribute('data-gluk-more');D.drawAccountMap(D.lastAccountMap);return;}
   var back=e.target.closest&&e.target.closest('[data-gluk-back]');
   if(back){e.stopPropagation();delete panel.dataset.glukDetail;D.drawAccountMap(D.lastAccountMap);return;}
   var off=e.target.closest&&e.target.closest('[data-gluk-off]');
   var out=off?null:(e.target.closest&&e.target.closest('[data-gluk-out]'));
   if(off||out){
    e.stopPropagation();
    var btn=off||out;
    // Сами запросы живут в sprint2.js: только там есть авторизованный клиент.
    if(btn.disabled||typeof D.deviceAction!=='function')return;
    var slot=panel.querySelector('[data-gluk-error]'),label=btn.textContent;
    var acts=panel.querySelectorAll('.gluk-act');
    Array.prototype.forEach.call(acts,function(b){b.disabled=true;});
    btn.textContent=tr('Секунду…','One moment…');
    if(slot){slot.hidden=true;slot.textContent='';}
    D.deviceAction(off?'disconnect':'signout',{
     sessionId:(off?off.getAttribute('data-gluk-off'):out.getAttribute('data-gluk-session'))||null,
     deviceId:out?out.getAttribute('data-gluk-out'):(off?off.getAttribute('data-gluk-device'):null)
    }).then(function(){
     delete panel.dataset.glukDetail;
    },function(message){
     Array.prototype.forEach.call(panel.querySelectorAll('.gluk-act'),function(b){b.disabled=false;});
     btn.textContent=label;
     if(slot){slot.textContent=String(message||tr('Не получилось — попробуйте ещё раз','That did not work — try again'));slot.hidden=false;}
    });
    return;
   }
   e.stopPropagation();
  });
  document.addEventListener('click',function(e){if(!top.contains(e.target))open(false);});
  document.addEventListener('keydown',function(e){
   if(e.key!=='Escape'||panel.hidden)return;
   if(panel.dataset.glukDetail){delete panel.dataset.glukDetail;D.drawAccountMap(D.lastAccountMap);return;}
   open(false);chip.focus();
  });
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
 // Десятая доля единицы карты — тот же шаг группировки, что и в Flutter.
 function spot(p){return Math.round(p.x*10)+':'+Math.round(p.y*10);}
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
