"""Real acceptance check; never substitutes fixtures. Requires ffprobe and ffmpeg."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import urllib.request

urllib.request.install_opener(urllib.request.build_opener(urllib.request.ProxyHandler({})))
p=argparse.ArgumentParser()
p.add_argument('--base',default='http://127.0.0.1:8000')
p.add_argument('--text',default='复制打开抖音，看看这个视频 https://v.douyin.com/1znUsjZNolc/')
p.add_argument('--output',default='/tmp/douyin-live.mp4')
a=p.parse_args()
r=urllib.request.Request(a.base+'/api/parse',data=json.dumps({'text':a.text}).encode(),headers={'Content-Type':'application/json'})
try:
    with urllib.request.urlopen(r,timeout=70) as response: info=json.load(response)
except urllib.error.HTTPError as e:
    print(e.read().decode());raise SystemExit(1)
print(json.dumps({k:v for k,v in info.items() if not k.endswith('_url')},ensure_ascii=False,indent=2))
h=hashlib.sha256();size=0
with urllib.request.urlopen(a.base+info['download_url'],timeout=60) as response,open(a.output,'wb') as out:
    print('content-type:',response.headers.get('Content-Type'))
    while chunk:=response.read(65536):
        out.write(chunk);h.update(chunk);size+=len(chunk)
print('bytes:',size,'sha256:',h.hexdigest())
subprocess.run(['ffprobe','-v','error','-show_entries','format=duration:stream=codec_name,width,height','-of','json',a.output],check=True)
subprocess.run(['ffmpeg','-v','error','-xerror','-i',a.output,'-f','null','-'],check=True)
print('PASS: downloaded and fully decoded',Path(a.output))
