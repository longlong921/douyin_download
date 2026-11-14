import asyncio
import json
import socket
from unittest.mock import patch, AsyncMock
import pytest
from fastapi.testclient import TestClient
from backend.app import parser, main
from backend.app.errors import AppError
from backend.app.network import PublicResolver, validate_url, request as fetch

ID='7707698168485708904'
def html(item):
    return 'window._ROUTER_DATA = '+json.dumps({'loaderData':{'video_(id)/page':{'videoInfoRes':{'item_list':[item]}}}})+';</script>'

def test_share_and_id():
    assert parser.extract_url('3.14 复制打开抖音 https://v.douyin.com/abc/ 你好')=='https://v.douyin.com/abc/'
    assert parser.video_id(f'https://www.douyin.com/video/{ID}')==ID
    assert parser.video_id(f'https://www.iesdouyin.com/share/video/{ID}/')==ID
    assert parser.video_id(f'https://www.douyin.com/?modal_id={ID}')==ID

@pytest.mark.parametrize('url',['http://127.0.0.1','http://[::1]','http://169.254.169.254','https://www.douyin.com.evil.com/a','https://x@www.douyin.com/a','https://www.douyin.com:123/a','file:///etc/passwd'])
def test_ssrf(url):
    with pytest.raises(AppError):validate_url(url,True)

@pytest.mark.parametrize('address',['127.0.0.1','10.0.0.1','169.254.169.254','::1','::ffff:127.0.0.1'])
def test_dns(address):
    async def run():
        with patch.object(asyncio.get_running_loop(),'getaddrinfo',AsyncMock(return_value=[(socket.AF_INET,1,6,'',(address,443))])):
            with pytest.raises(AppError):await PublicResolver().resolve('www.douyin.com',443)
    asyncio.run(run())

def test_redirect_ssrf():
    async def run():
        class Response:
            status=302
            headers={'Location':'http://127.0.0.1/secret'}
            def release(self):pass
        client=AsyncMock()
        client.get.return_value=Response()
        with pytest.raises(AppError):await fetch(client,'https://www.douyin.com/',media=True)
        assert client.get.await_count==1
    asyncio.run(run())

def test_parser_metadata_and_identity():
    page=html({'aweme_id':ID,'video':{'play_addr':{'url_list':['https://v.example.douyinvod.com/a']}}})
    video=parser.parse_page(page,ID)
    assert video.author is None and video.duration is None and video.cover is None
    with pytest.raises(AppError):parser.parse_page(page,'1234567890123456789')
    with pytest.raises(AppError) as err:parser.parse_page('window._ROUTER_DATA = {"loaderData":{}}',ID)
    assert err.value.code=='data_missing'

def test_api_errors_and_success():
    with TestClient(main.app) as c:
        assert c.post('/api/parse',json={'text':'hello'}).json()['error']['code']=='invalid_input'
        assert c.get('/api/media/arbitrary?url=http://127.0.0.1').status_code==410
        with patch.object(parser,'resolve',AsyncMock(side_effect=AppError('verification_required','需要验证'))):
            assert c.post('/api/parse',json={'text':'https://v.douyin.com/abc/'}).json()['error']['code']=='verification_required'
        with patch.object(parser,'resolve',AsyncMock(side_effect=asyncio.TimeoutError)):
            assert c.post('/api/parse',json={'text':'https://v.douyin.com/abc/'}).status_code==504
        with patch.object(parser,'resolve',AsyncMock(return_value=parser.Video(ID,'测试',None,None,None,['https://v.douyinvod.com/a']))):
            data=c.post('/api/parse',json={'text':'https://v.douyin.com/abc/'}).json()
            assert 'media' not in data and data['id']==ID
            assert c.get(data['preview_url'],headers={'Range':'bytes=0-1,3-5'}).status_code==416

class Content:
    async def iter_chunked(self,size):
        yield b'1234'
        yield b'5678'
class Media:
    status=200
    content_length=8
    headers={'Content-Type':'video/mp4','Content-Length':'8','Accept-Ranges':'bytes'}
    content=Content()
    def release(self):pass
    def close(self):pass

def test_stream_headers_limits_refresh_and_concurrency():
    video=parser.Video(ID,'中文标题 / 测试',None,None,None,['https://v.douyinvod.com/a'])
    with TestClient(main.app) as c, patch.object(parser,'resolve',AsyncMock(return_value=video)) as resolve:
        data=c.post('/api/parse',json={'text':'https://v.douyin.com/abc/'}).json()
        with patch.object(main,'upstream_request',AsyncMock(return_value=Media())):
            r=c.get(data['download_url'])
            assert r.content==b'12345678'
            assert 'attachment;' in r.headers['content-disposition']
            assert "filename*=UTF-8''" in r.headers['content-disposition']
            assert r.headers['content-type']=='video/mp4'
            with patch.object(main,'MAX_BYTES',4):
                assert c.get(data['download_url']).status_code==413
            with patch.object(main,'slots',asyncio.Semaphore(0)):
                assert c.get(data['download_url']).status_code==429
        denied=Media();denied.status=403
        with patch.object(main,'upstream_request',AsyncMock(side_effect=[denied,Media()])):
            assert c.get(data['download_url']).status_code==200
            assert resolve.await_count==2

def test_cookie_shell_retry():
    class Page:
        status=200
        async def __aenter__(self):return self
        async def __aexit__(self,*args):pass
    content=html({'aweme_id':ID,'video':{'play_addr':{'url_list':['https://v.douyinvod.com/a']}}})
    async def run():
        with patch.object(parser,'request',AsyncMock(return_value=Page())) as get, patch.object(parser,'read_page',AsyncMock(side_effect=['window._ROUTER_DATA = {"loaderData":{}}',content])):
            v=await parser.resolve(None,f'https://www.douyin.com/video/{ID}')
            assert v.id==ID and get.await_count==2
    asyncio.run(run())
