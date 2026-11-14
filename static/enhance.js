// Progressive enhancement only. Parsing, rendering and all application state are Haskell.
const form = document.querySelector('#parse-form');
form?.addEventListener('submit', () => {
  document.querySelector('#parse-button').disabled = true;
  document.querySelector('#parse-button').textContent = '正在解析，请稍候…';
  document.querySelector('#notice').textContent = '正在读取抖音作品信息，通常需要几秒钟。';
});
window.addEventListener('pageshow', () => { const b=document.querySelector('#parse-button'); if(b){b.disabled=false;b.textContent='解析视频 →';} });
document.querySelector('#paste')?.addEventListener('click', async () => {
  try { document.querySelector('#share').value = await navigator.clipboard.readText(); }
  catch { document.querySelector('#notice').textContent = '请长按输入框，选择“粘贴”。'; document.querySelector('#share').focus(); }
});
const script = document.querySelector('script[src$="enhance.js"]');
if ('serviceWorker' in navigator && script) navigator.serviceWorker.register(new URL('sw.js', script.src)).catch(() => {});
