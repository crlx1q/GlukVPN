/* Dashboard data rules and summary. No synthetic usage or connection data. */
(function(root){
'use strict';
function subscription(sub,plans,now){
 now=now==null?Date.now():now;plans=plans||{};
 if(!sub)return {name:null,status:'NONE',end:null,left:null,days:null,percent:null,active:false};
 var code=String(sub.plan||sub.planCode||'').toLowerCase(),end=Date.parse(sub.expiresAt),status=String(sub.status||'').toUpperCase();
 if(!Number.isFinite(end))end=null;
 if(end!==null&&end<=now&&(status==='ACTIVE'||status==='TRIAL'))status='EXPIRED';
 var active=status==='ACTIVE'||status==='TRIAL',left=end!==null?Math.max(0,Math.ceil((end-now)/86400000)):null;
 var plan=plans[code]||{},days=Number(plan.days),start=Date.parse(sub.startsAt||sub.startedAt||'');
 if(Number.isFinite(start)&&end!==null&&end>start)days=(end-start)/86400000;
 if(!Number.isFinite(days)||days<=0)days=null;
 return {name:sub.planName||plan.name||code||null,status:status||'UNKNOWN',end:end,left:left,days:days,active:active,percent:active&&days!==null&&left!==null?Math.max(0,Math.min(100,(end-now)/86400000/days*100)):null};
}
function request(A,path,opts,publicRequest){return new Promise(function(resolve,reject){var timer=setTimeout(function(){reject({status:0,code:'timeout'});},15000);Promise.resolve().then(function(){return publicRequest?A.public(path,opts):A.call(path,opts);}).then(function(v){clearTimeout(timer);resolve(v);},function(e){clearTimeout(timer);reject(e);});});}
function vpn(data){
 var n=data&&data.activeTunnels,rows=data&&Array.isArray(data.devices)?data.devices:[];
 if(typeof n!=='number'||!Number.isFinite(n)||n<0)return 'unknown';
 if(n===0)return 'disconnected';
 if(rows.some(function(d){return d.status==='ACTIVE'||d.status==='CONNECTED';}))return 'connected';
 if(rows.length&&!data.truncated&&rows.every(function(d){return d.status==='PENDING';}))return 'pending';
 return 'unknown';
}
var api={subscription:subscription,request:request,vpn:vpn};root.GlukDashboard=api;
if(typeof module==='object'&&module.exports)module.exports=api;
if(!root.document)return;
var doc=root.document,EN=doc.documentElement.getAttribute('data-lang')==='en',tr=function(ru,en){return EN?en:ru;};
var dash=doc.querySelector('.dash-in');if(!dash)return;
doc.body.classList.add('dashboard-page');
var summary=doc.createElement('section');summary.className='dash-overview';summary.setAttribute('aria-label',tr('Сводка аккаунта','Account overview'));
summary.innerHTML='<article class="dash-summary dash-summary--plan"><span>'+tr('Ваш тариф','Your plan')+'</span><strong data-d="plan">—</strong><small data-d="sub-status">—</small></article><article class="dash-summary"><span>'+tr('Осталось','Time remaining')+'</span><strong data-d="sub-left">—</strong><small data-d="sub-date">—</small></article><article class="dash-summary"><span>'+tr('Устройства','Devices')+'</span><strong data-d="dev-count">—</strong><small>'+tr('Занято / лимит аккаунта','Used / account limit')+'</small></article><article class="dash-summary"><span>'+tr('VPN на устройствах','VPN on your devices')+'</span><strong data-live-state>—</strong><small data-live-note>'+tr('Проверяем подключения','Checking connections')+'</small></article>';
dash.insertBefore(summary,dash.querySelector('.dash-stats'));
function live(data){api.liveData=data;var out=summary.querySelector('[data-live-state]'),note=summary.querySelector('[data-live-note]'),n=data&&data.activeTunnels;
 var valid=typeof n==='number'&&Number.isFinite(n)&&n>=0;
 var status=vpn(data),labels={connected:tr('Подключён','Connected'),pending:tr('Подключается','Connecting'),disconnected:tr('Отключён','Disconnected'),unknown:tr('Нет данных','Unavailable')};
 out.textContent=labels[status];out.classList.toggle('is-ok',status==='connected');
 note.textContent=!valid?tr('Не удалось проверить. Повторите обновление.','Could not check. Refresh to retry.'):n>0?tr('Сессий на сервере: ','Server sessions: ')+n:tr('Подключитесь в приложении','Connect in the app');
 var card=doc.querySelector('[data-dash-conn]');if(card)card.hidden=false;
 var rows=data&&Array.isArray(data.devices)?data.devices:[],device=rows.find(function(d){return d.status==='ACTIVE';})||rows[0],node=device&&device.node;
 function text(key,value){doc.querySelectorAll('[data-d="'+key+'"]').forEach(function(el){el.textContent=value;});}
 text('conn-state',labels[status]);doc.querySelectorAll('[data-d="conn-state"]').forEach(function(el){el.classList.toggle('is-ok',status==='connected');});
 doc.querySelectorAll('[data-conn-row]').forEach(function(el){el.hidden=!valid||!device;});
 text('conn-node',node?[node.name||node.country,node.city].filter(Boolean).join(' · '):'—');text('conn-dev',device&&device.deviceName||'—');
 text('conn-since',device&&device.connectedAt?new Date(device.connectedAt).toLocaleString(EN?'en-GB':'ru-RU'):'—');var session=device&&(api.history||[]).find(function(s){return s.id===device.sessionId;});text('conn-ip',session&&session.ip||'—');text('conn-hs',session&&session.hs?new Date(session.hs).toLocaleString(EN?'en-GB':'ru-RU'):'—');
 text('conn-hint',tr('По данным сервера. Кабинет не включает VPN на этом устройстве.','Reported by the server. This dashboard does not enable VPN on this device.'));
 if(valid)doc.querySelectorAll('[data-d="sessions"]').forEach(function(el){el.textContent=n+' / '+((root.GlukAuth.state.user||{}).maxConcurrentSessions??'—');});
}
api.live=live;
var guard=setTimeout(function(){var A=root.GlukAuth;if(A&&A.state&&A.state.status!=='loading')return;doc.querySelectorAll('[data-dash-view]').forEach(function(el){el.hidden=el.getAttribute('data-dash-view')!=='guest';});var gate=doc.querySelector('.gate__main');if(gate){var note=doc.createElement('p');note.className='dash-empty';note.setAttribute('role','status');note.textContent=tr('Не удалось проверить вход. Обновите страницу или войдите снова.','Could not verify sign-in. Reload or sign in again.');gate.prepend(note);}},16000);
doc.addEventListener('gluk:auth',function(){var A=root.GlukAuth;if(A&&A.state.status!=='loading')clearTimeout(guard);if(!A||A.state.status!=='in')live(null);});
})(typeof window==='object'?window:globalThis);
