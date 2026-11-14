"""UI integration checks: real Douyin parse/play/download and injected upstream failure.
Install `pip install playwright` and `python -m playwright install chromium`.
Run with the app on localhost:8000. The real flow must pass before the injected upstream failure check.
"""
import asyncio
import json
import subprocess
from pathlib import Path
from playwright.async_api import async_playwright

ROOT=Path('/tmp/douyin-ui-check');ROOT.mkdir(exist_ok=True)
async def main():
    async with async_playwright() as p:
        browser=await p.chromium.launch(headless=True,channel='chromium',args=['--no-sandbox'])
        context=await browser.new_context(viewport={'width':390,'height':844},is_mobile=True,has_touch=True,accept_downloads=True,service_workers='block')
        page=await context.new_page()
        await page.goto('http://127.0.0.1:8000/')
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
        async with page.expect_download(timeout=60000) as live_dl:
            await page.get_by_role('link',name='下载到本地').click()
        live_download=await live_dl.value
        await live_download.save_as(ROOT/'live-download.mp4')
        subprocess.run(['ffmpeg','-v','error','-xerror','-i',str(ROOT/'live-download.mp4'),'-f','null','-'],check=True)
        print('LIVE PASS: real share text, preview, playback, download, complete decode', (ROOT/'live-download.mp4').stat().st_size)
        await page.screenshot(path=str(ROOT/'mobile-live-success.png'),full_page=True)
        async def upstream_failure(route):
            await route.fulfill(status=502,json={'error':{'code':'verification_required','message':'上游要求登录或验证，请先在抖音打开原链接。'}})
        await page.route('**/api/parse',upstream_failure)
        await page.get_by_role('button',name='解析视频').click()
        await page.get_by_text('上游要求登录或验证，请先在抖音打开原链接。',exact=True).wait_for()
        await page.screenshot(path=str(ROOT/'mobile-error.png'),full_page=True)
        print('PASS: responsive widths, invalid text, real parse/play/download, injected verification failure')
        await browser.close()
asyncio.run(main())
