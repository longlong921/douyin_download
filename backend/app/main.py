import asyncio
import logging
import os
import re
import secrets
import time
from contextlib import asynccontextmanager
from dataclasses import asdict
from pathlib import Path
from urllib.parse import quote
import aiohttp
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field
from . import parser
from .errors import AppError, upstream_status
from .network import session, request as upstream_request

MAX_BYTES = int(os.getenv('MAX_VIDEO_BYTES', 512 * 1024 * 1024))
TTL = int(os.getenv('TOKEN_TTL_SECONDS', 1800))
cache = {}
slots = asyncio.Semaphore(int(os.getenv('MAX_CONCURRENT_STREAMS', 4)))
parse_slots = asyncio.Semaphore(4)


@asynccontextmanager
async def lifespan(app):
    async with session() as client:
        app.state.client = client
        yield


app = FastAPI(title='抖音视频下载', lifespan=lifespan)


@app.exception_handler(AppError)
async def app_error(request, exc):
    return JSONResponse({'error': {'code': exc.code, 'message': exc.message}}, status_code=exc.status)


@app.exception_handler(asyncio.TimeoutError)
async def timeout_error(request, exc):
    return await app_error(request, AppError('timeout', '上游请求超时，请检查网络后重试。', 504))


@app.exception_handler(aiohttp.ClientError)
async def network_error(request, exc):
    return await app_error(request, AppError('upstream_error', '无法连接抖音服务，请检查部署网络后重试。'))


class ParseInput(BaseModel):
    text: str = Field(min_length=1, max_length=8192)


@app.get('/api/health')
async def health():
    return {'status': 'ok'}


@app.post('/api/parse')
async def parse(body: ParseInput, request: Request):
    if parse_slots.locked():
        raise AppError('rate_limited', '解析任务较多，请稍后重试。', 429)
    async with parse_slots, asyncio.timeout(60):
        video = await parser.resolve(request.app.state.client, body.text)
    now = time.monotonic()
    for k in list(cache):
        if now - cache[k]['created'] > TTL:
            del cache[k]
    if len(cache) >= 500:
        del cache[next(iter(cache))]
    token = secrets.token_urlsafe(32)
    cache[token] = {'video': video, 'created': now, 'refreshed': now, 'lock': asyncio.Lock()}
    result = asdict(video)
    del result['media']
    result['cover'] = f'/api/media/{token}?kind=cover' if video.cover else None
    return {**result, 'preview_url': f'/api/media/{token}', 'download_url': f'/api/media/{token}?download=1', 'expires_in': TTL}


@app.get('/api/media/{token}')
async def media(token: str, request: Request, download: bool = False, kind: str = 'video'):
    item = cache.get(token)
    if not item or time.monotonic() - item['created'] > TTL:
        raise AppError('expired', '解析结果已过期，请重新解析后下载。', 410)
    if kind not in ('video', 'cover'):
        raise AppError('invalid_input', '资源类型无效。', 400)
    range_header = request.headers.get('range') if kind == 'video' else None
    if range_header and not re.fullmatch(r'bytes=(?:\d+-\d*|-\d+)', range_header):
        raise AppError('invalid_range', '仅支持单段视频范围请求。', 416)
    if slots.locked():
        raise AppError('rate_limited', '下载任务较多，请稍后重试。', 429)
    await slots.acquire()
    response = None
    handed_off = False
    try:
        client = request.app.state.client
        async with item['lock']:
            if time.monotonic() - item['refreshed'] > 240:
                item['video'] = await parser.resolve(client, f'https://www.douyin.com/video/{item["video"].id}')
                item['refreshed'] = time.monotonic()
        for attempt in range(2):
            video = item['video']
            candidates = [video.cover] if kind == 'cover' else video.media
            for url in candidates:
                if not url:
                    raise AppError('unavailable', '没有可用封面。', 404)
                response = await upstream_request(client, url, media=True, headers={'Range': range_header} if range_header else {})
                if response.status < 400:
                    break
                response.release()
            if response.status not in (401, 403, 404, 410) or attempt:
                break
            async with item['lock']:
                item['video'] = await parser.resolve(client, f'https://www.douyin.com/video/{video.id}')
                item['refreshed'] = time.monotonic()
        if response.status == 416:
            raise AppError('invalid_range', '视频范围无效，请重新加载预览。', 416)
        upstream_status(response.status)
        mime = response.headers.get('Content-Type', '').split(';')[0].lower()
        allowed = {'video/mp4': 'mp4', 'video/webm': 'webm', 'video/quicktime': 'mov'}
        if kind == 'cover':
            if mime not in ('image/jpeg', 'image/png', 'image/webp'):
                raise AppError('upstream_error', '封面资源不可用。')
        elif mime not in allowed:
            raise AppError('parser_changed', '上游未返回支持的视频文件，请重新解析或更新解析模块。')
        limit = MAX_BYTES if kind == 'video' else 8 * 1024 * 1024
        length = response.content_length
        cr = response.headers.get('Content-Range', '')
        total = int(cr.rsplit('/', 1)[1]) if re.fullmatch(r'bytes \d+-\d+/\d+', cr) else length
        if (length is not None and length > limit) or (total is not None and total > limit):
            raise AppError('too_large', '文件超过服务器下载大小限制。', 413)
        headers = {'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff'}
        for h in ('Content-Length', 'Content-Range', 'Accept-Ranges'):
            if h in response.headers:
                headers[h] = response.headers[h]
        if kind == 'video':
            name = re.sub(r'[\x00-\x1f\x7f/\\:*?"<>|]', '_', video.title)[:80].strip('. ') or video.id
            name = f'{name}_{video.id}.{allowed[mime]}'
            headers['Content-Disposition'] = f'{"attachment" if download else "inline"}; filename="douyin_{video.id}.{allowed[mime]}"; filename*=UTF-8\'\'{quote(name)}'
        async def chunks():
            count = 0
            try:
                async for chunk in response.content.iter_chunked(65536):
                    count += len(chunk)
                    if count > limit:
                        raise RuntimeError('stream size limit exceeded')
                    yield chunk
            except (aiohttp.ClientError, asyncio.TimeoutError, RuntimeError):
                logging.warning('Media stream interrupted; client must retry', exc_info=False)
                raise
            finally:
                response.close()
                slots.release()
        result = StreamingResponse(chunks(), status_code=response.status, media_type=mime, headers=headers)
        handed_off = True
        return result
    finally:
        if not handed_off:
            if response is not None:
                response.close()
            slots.release()


web = Path(os.getenv('FRONTEND_DIST', 'frontend/dist'))
if web.is_dir():
    app.mount('/', StaticFiles(directory=web, html=True), name='web')
