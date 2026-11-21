"""Real Haskell SSR browser acceptance. Requires playwright and ffmpeg."""
import argparse
import asyncio
import hashlib
import subprocess
from pathlib import Path
from urllib.parse import urlsplit
from playwright.async_api import async_playwright, expect

p=argparse.ArgumentParser()
p.add_argument('--base',default='http://127.0.0.1:8187')
p.add_argument('--resolve-ip',help='Optional browser-only DNS pin for the base hostname')
a=p.parse_args()
ROOT=Path('/tmp/douyin-haskell-ui');ROOT.mkdir(exist_ok=True)
async def main():
    async with async_playwright() as p:
        browser=await p.chromium.launch(headless=True,channel='chromium',args=['--no-sandbox','--no-proxy-server']+([f'--host-resolver-rules=MAP {urlsplit(a.base).hostname} {a.resolve_ip}'] if a.resolve_ip else []))
        context=await browser.new_context(viewport={'width':390,'height':844},is_mobile=True,has_touch=True,accept_downloads=True,service_workers='block')
        page=await context.new_page()
        await page.goto(a.base+'/',wait_until='domcontentloaded',timeout=60000)
        assert 'Haskell' not in await page.locator('body').inner_text()
        assert await page.title() == '拾影 · 抖音视频下载'
        manifest = await page.evaluate("fetch(document.querySelector('link[rel=manifest]').href).then(r => r.json())")
        assert manifest['name'] == await page.title()
        for width in [360,390,430,1280]:
            await page.set_viewport_size({'width':width,'height':844})
            assert await page.evaluate('document.documentElement.scrollWidth <= innerWidth'),width
        await page.set_viewport_size({'width':390,'height':844})
        await page.screenshot(path=str(ROOT/'mobile-empty.png'),full_page=True)
        await page.get_by_label('抖音分享链接或文案').fill('无效的文字')
        await page.get_by_role('button',name='解析视频').click()
        await page.get_by_role('alert').wait_for()
        assert '请粘贴抖音' in await page.get_by_role('alert').inner_text()
        await page.get_by_label('抖音分享链接或文案').fill('复制打开抖音 https://v.douyin.com/1znUsjZNolc/')
        await page.get_by_role('button',name='解析视频').click()
        await page.locator('video').wait_for(timeout=70000)
        await page.wait_for_function('document.querySelector("video").readyState >= 1',timeout=45000)
        await page.locator('video').evaluate('(v)=>v.play()')
        await page.wait_for_function('document.querySelector("video").currentTime > 0.1')
        print('PASS real preview playback',flush=True)
        await page.screenshot(path=str(ROOT/'mobile-live-success.png'),full_page=True)
        await page.locator('video').evaluate('(v)=>{v.pause();v.removeAttribute("src");v.load();}')
        downloads = []
        page.on('download', lambda download: downloads.append(download))
        link = page.locator('#download-link')
        async with page.expect_download(timeout=60000) as live_dl:
            await link.tap()
            await expect(link).to_have_text('已请求下载', timeout=1000)
            await expect(link).to_be_disabled()
            await expect(page.locator('#download-status')).to_have_text('请在浏览器的「下载」列表中查看进度。')
            # A second physical tap is possible even when assistive technology reports disabled.
            rect = await link.bounding_box()
            await page.touchscreen.tap(rect['x'] + rect['width'] / 2, rect['y'] + rect['height'] / 2)
            await page.screenshot(path=str(ROOT/'mobile-download-requested.png'))
        download=await live_dl.value
        print('Browser download started',flush=True)
        await asyncio.wait_for(download.save_as(ROOT/'live-download.mp4'),timeout=310)
        await expect(page.get_by_role('link', name='再次下载')).to_be_enabled()
        assert len(downloads) == 1, 'Two quick taps must create one browser download'
        print('PASS: immediate tap feedback, one native download, retry enabled', flush=True)
        subprocess.run(['ffmpeg','-v','error','-xerror','-i',str(ROOT/'live-download.mp4'),'-f','null','-'],check=True)
        data=(ROOT/'live-download.mp4').read_bytes()
        print('LIVE PASS',len(data),hashlib.sha256(data).hexdigest())
        # App's actual server-rendered invalid-input error remains useful without JS.
        nojs=await browser.new_context(java_script_enabled=False)
        doc=await nojs.new_page();await doc.goto(a.base+'/')
        await doc.get_by_label('抖音分享链接或文案').fill('not a link')
        await doc.get_by_role('button',name='解析视频').click();await doc.get_by_role('alert').wait_for()
        print('PASS: responsive widths, invalid input, real playback/download, no-JS form')
        await browser.close()
asyncio.run(main())
