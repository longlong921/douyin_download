const CACHE='shiying-haskell-v3';
const root=new URL('./',self.location.href);
const shell=['','style.css','enhance.js','manifest.webmanifest','icon-192.png','icon-512.png'].map(x=>new URL(x,root).href);
self.addEventListener('install',e=>{e.waitUntil(caches.open(CACHE).then(c=>c.addAll(shell)));self.skipWaiting();});
self.addEventListener('activate',e=>e.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(k=>k.startsWith('shiying-haskell-')&&k!==CACHE).map(k=>caches.delete(k)))).then(()=>self.clients.claim())));
self.addEventListener('fetch',e=>{
 if(e.request.method!=='GET'||!shell.includes(e.request.url))return;
 e.respondWith(fetch(e.request).then(r=>{if(r.ok){const copy=r.clone();caches.open(CACHE).then(c=>c.put(e.request,copy));}return r;}).catch(()=>caches.match(e.request).then(r=>r||new Response('当前离线，请联网后重试。',{status:503}))));
});
