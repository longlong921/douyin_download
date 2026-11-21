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

const downloadLink = document.querySelector('#download-link');
const downloadStatus = document.querySelector('#download-status');
if (downloadLink && downloadStatus) {
  const initialLabel = downloadLink.textContent;
  let retryTimer;

  downloadLink.addEventListener('click', (event) => {
    if (event.defaultPrevented || event.button !== 0 || event.ctrlKey ||
        event.metaKey || event.shiftKey || event.altKey) return;
    if (downloadLink.getAttribute('aria-disabled') === 'true') {
      event.preventDefault();
      return;
    }

    // Keep the first click's native download action and acknowledge the request immediately.
    downloadLink.textContent = '已请求下载';
    downloadLink.setAttribute('aria-disabled', 'true');
    downloadStatus.textContent = '请在浏览器的「下载」列表中查看进度。';
    retryTimer = window.setTimeout(() => {
      downloadLink.removeAttribute('aria-disabled');
      downloadLink.textContent = '↓ 再次下载';
    }, 2500);
  });

  window.addEventListener('pageshow', (event) => {
    if (event.persisted) {
      window.clearTimeout(retryTimer);
      downloadLink.removeAttribute('aria-disabled');
      downloadLink.textContent = initialLabel;
      downloadStatus.textContent = '';
    }
  });
}

const script = document.querySelector('script[src$="enhance.js"]');
if ('serviceWorker' in navigator && script) navigator.serviceWorker.register(new URL('sw.js', script.src)).catch(() => {});
