/* Релизные инварианты сайта: страницы и скрипты не знают номера версии.

   Баг, из-за которого этот файл существует: в ui.js стоял
   download="GlukVPN-Setup-1.5.0.exe", и после выхода 1.6.0 браузер сохранял
   новый установщик под старым именем. Версия жила в семи местах, одно из них
   всегда забывали. Теперь единственный источник правды - имена двух файлов в
   /var/www/vpn.gluk.tech/downloads/, а всё остальное (version.json и редиректы
   nginx) генерирует site/deploy/sync-downloads.sh.

   Отдельный файл, а не правка site.test.cjs: те тесты про UI дашборда, эти -
   про релизный контракт. Запускается тем же раннером: node --test site/tests
*/
const {test}=require('node:test');const assert=require('node:assert/strict');const fs=require('fs');const path=require('path');
const site=path.resolve(__dirname,'..');const read=f=>fs.readFileSync(path.join(site,f),'utf8');
const pages=[];(function walk(dir){for(const e of fs.readdirSync(path.join(site,dir),{withFileTypes:true})){const rel=dir?dir+'/'+e.name:e.name;if(e.isDirectory()){if(e.name!=='tests'&&e.name!=='deploy'&&e.name!=='downloads')walk(rel);}else if(e.name.endsWith('.html'))pages.push(rel);}})('');
const scripts=fs.readdirSync(path.join(site,'assets/js')).filter(n=>n.endsWith('.js')).map(n=>'assets/js/'+n);

test('no installer file name is hardcoded in pages or scripts',()=>{
 assert.ok(pages.length>0&&scripts.length>0);
 for(const f of pages.concat(scripts))assert.ok(!/GlukVPN-Setup|glukvpn-release/.test(read(f)),f);
});

test('download buttons point at the permanent endpoints',()=>{
 let windows=0,android=0;
 for(const f of pages)for(const tag of read(f).match(/<a\b[^>]*>/g)||[]){
  /* Windows-кнопка всегда ведёт на эндпоинт: редирект отдаёт актуальный exe */
  if(tag.indexOf('data-download-windows')!==-1){windows++;assert.match(tag,/href="\/download\/windows"/,f+': '+tag);}
  /* Android-кнопки в шапке ведут на /download/ и подменяются скриптом под ОС
     клиента, поэтому проверяем только отсутствие имени файла в разметке */
  if(tag.indexOf('data-download-android')!==-1){android++;assert.ok(!/\.apk|\.exe/.test(tag),f+': '+tag);}
 }
 assert.ok(windows>0,'no windows buttons found');assert.ok(android>0,'no android buttons found');
});

test('version.json keeps endpoints and file names in one version',()=>{
 const m=JSON.parse(read('api/version.json'));
 assert.match(m.version,/^\d+\.\d+\.\d+$/);
 assert.equal(typeof m.build,'number');
 assert.deepEqual(m.endpoints,{windows:'/download/windows',android:'/download/android'});
 assert.equal(m.downloads.windows,'/downloads/GlukVPN-Setup-'+m.version+'.exe');
 assert.equal(m.downloads.android,'/downloads/glukvpn-release-'+m.version+'.apk');
});

test('sync-downloads owns the whole release wiring',()=>{
 const sh=read('deploy/sync-downloads.sh');
 for(const needle of ['GlukVPN-Setup-*.exe','glukvpn-release-*.apk','location = /download/windows {','location = /download/android {','www-data:www-data'])assert.ok(sh.indexOf(needle)!==-1,needle);
});
