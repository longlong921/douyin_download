"""Only allow known platform hosts; validate DNS at connection time, including redirects."""
import asyncio
import ipaddress
import socket
from urllib.parse import urlsplit, urljoin
import aiohttp
from .errors import AppError

PAGE_HOSTS = {'v.douyin.com', 'www.douyin.com', 'douyin.com', 'www.iesdouyin.com', 'm.douyin.com'}
MEDIA_DOMAINS = ('douyin.com', 'iesdouyin.com', 'douyinvod.com', 'douyincdn.com', 'douyinpic.com', 'bytecdn.cn', 'bytecdn.com', 'snssdk.com', 'amemv.com', 'pstatp.com', 'byteimg.com', 'ibytedtos.com', 'bytedance.com', 'bytedance.net')
UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1'
HEADERS = {'User-Agent': UA, 'Referer': 'https://www.douyin.com/', 'Accept-Encoding': 'identity'}


def validate_url(url, media=False):
    try:
        p = urlsplit(url)
        host = (p.hostname or '').lower()
        allowed = any(host == d or host.endswith('.' + d) for d in MEDIA_DOMAINS) if media else host in PAGE_HOSTS
        if p.scheme not in ('https', 'http') or p.username or p.password or p.port not in (None, 80, 443) or not allowed:
            raise ValueError()
        return url
    except (ValueError, TypeError):
        raise AppError('unsafe_url', '链接或重定向地址不在允许范围内。', 400)


class PublicResolver(aiohttp.abc.AbstractResolver):
    async def resolve(self, host, port=0, family=socket.AF_INET):
        records = await asyncio.get_running_loop().getaddrinfo(host, port, family=family, type=socket.SOCK_STREAM)
        result = []
        for fam, _, proto, _, addr in records:
            ip = ipaddress.ip_address(addr[0])
            if not ip.is_global or (getattr(ip, 'ipv4_mapped', None) and not ip.ipv4_mapped.is_global):
                raise AppError('unsafe_url', '已阻止访问非公网地址。', 400)
            result.append(dict(hostname=host, host=str(ip), port=port, family=fam, proto=proto, flags=socket.AI_NUMERICHOST))
        return result

    async def close(self):
        pass


def session():
    # No environment proxies: DNS validation must govern the actual connection.
    return aiohttp.ClientSession(connector=aiohttp.TCPConnector(resolver=PublicResolver(), use_dns_cache=False, limit=20),
                                 timeout=aiohttp.ClientTimeout(total=300, connect=10, sock_read=30),
                                 headers=HEADERS, trust_env=False, auto_decompress=False)


async def request(client, url, *, media=False, headers=None):
    for _ in range(6):
        validate_url(url, media)
        response = await client.get(url, allow_redirects=False, headers=headers or {})
        if response.status not in (301, 302, 303, 307, 308):
            return response
        location = response.headers.get('Location')
        response.release()
        if not location:
            break
        url = urljoin(url, location)
    raise AppError('upstream_error', '上游跳转异常，请稍后重试。')


async def read_page(response, limit=4 * 1024 * 1024):
    data = bytearray()
    async for chunk in response.content.iter_chunked(65536):
        data.extend(chunk)
        if len(data) > limit:
            raise AppError('parser_changed', '上游页面超出解析限制，请联系部署者更新解析器。')
    return data.decode('utf-8', errors='replace')
