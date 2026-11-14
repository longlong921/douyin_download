"""Douyin share-page adapter. No third-party parsing service or invented media URL."""
import json
import os
import re
from dataclasses import dataclass
from urllib.parse import urlsplit, parse_qs
from .network import validate_url, request, read_page
from .errors import AppError, upstream_status


@dataclass
class Video:
    id: str
    title: str
    author: str | None
    duration: float | None
    cover: str | None
    media: list[str]


def extract_url(text):
    for match in re.finditer(r'https?://[^\s<>"\u3000]+', text):
        url = match.group().rstrip('.,!;:，。！；：、）)]}】')
        try:
            validate_url(url)
            return url
        except AppError:
            continue
    raise AppError('invalid_input', '请粘贴抖音分享文案、短链接或视频链接。', 400)


def video_id(url):
    p = urlsplit(url)
    m = re.search(r'/(?:share/)?video/(\d{10,25})(?:/|$)', p.path)
    if m:
        return m[1]
    value = parse_qs(p.query).get('modal_id', [''])[0]
    return value if re.fullmatch(r'\d{10,25}', value) else None


def urls(value):
    return [u for u in (value or {}).get('url_list', []) if isinstance(u, str)]


def parse_page(html, expected_id):
    match = re.search(r'(?:window\.)?_ROUTER_DATA\s*=\s*', html)
    if not match:
        if any(s in html.lower() for s in ('captcha', 'verifycenter', 'argus', '验证', '登录')):
            raise AppError('verification_required', '分享页要求登录或验证，请在抖音打开原链接，或由部署者配置 Cookie 后重试。')
        raise AppError('parser_changed', '未找到分享页数据，抖音页面可能已更新，请联系部署者更新解析模块。')
    try:
        data = json.JSONDecoder().raw_decode(html[match.end():])[0]
        nodes = data['loaderData'].values()
    except (ValueError, KeyError, TypeError, AttributeError):
        raise AppError('parser_changed', '分享页数据格式发生变化，请联系部署者更新解析模块。')
    for node in nodes:
        if not isinstance(node, dict) or 'videoInfoRes' not in node:
            continue
        info = node['videoInfoRes'] or {}
        items = info.get('item_list') or []
        if not items:
            raise AppError('unavailable', '上游未提供此作品，可能已删除、私密或不可访问，请在抖音确认。', 404)
        item = next((i for i in items if str(i.get('aweme_id', i.get('item_id'))) == expected_id), None)
        if item is None:
            raise AppError('parser_changed', '上游作品 ID 与请求不一致，已停止下载。')
        video = item.get('video') or {}
        media = urls(video.get('play_addr'))
        if not media:
            raise AppError('unavailable', '此作品没有可下载的视频资源，可能是图文作品。', 404)
        for u in media:
            validate_url(u, True)
        cover = urls(video.get('cover')) or urls(video.get('origin_cover'))
        duration = video.get('duration')
        return Video(expected_id, item.get('desc') or f'抖音视频 {expected_id}',
                     (item.get('author') or {}).get('nickname'),
                     duration / 1000 if isinstance(duration, (int, float)) else None,
                     cover[0] if cover else None, media)
    raise AppError('data_missing', '抖音只返回页面框架，未提供视频数据；可能受登录、地区或访问策略限制。请在抖音确认可播放，并由部署者检查网络或配置 Cookie。')


async def resolve(client, text):
    url = extract_url(text)
    ident = video_id(url)
    headers = {'Cookie': os.environ['DOUYIN_COOKIE']} if os.environ.get('DOUYIN_COOKIE') else {}
    if not ident:
        async with await request(client, url, headers=headers) as r:
            upstream_status(r.status)
            ident = video_id(str(r.url))
        if not ident:
            raise AppError('invalid_input', '该链接未指向抖音视频，请重新复制作品分享链接。', 400)
    last = None
    # The first response may only set a fresh anonymous platform cookie.
    # Retry a shell once in the same session; never loop on a challenge or rate limit.
    for host in ('www.iesdouyin.com', 'www.douyin.com'):
        for attempt in range(2):
            async with await request(client, f'https://{host}/share/video/{ident}/', headers=headers) as r:
                upstream_status(r.status)
                html = await read_page(r)
            try:
                return parse_page(html, ident)
            except AppError as exc:
                last = exc
                if exc.code != 'data_missing':
                    break
    raise last
