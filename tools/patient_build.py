"""GitHub 限流期间：每隔 N 分钟试一次，成功就下载 IPA。"""
import sys, time, subprocess, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).parent))
from gh import OWNER, REPO, call, TOK

OUT = pathlib.Path(__file__).parent.parent / "dist"
OUT.mkdir(exist_ok=True)
GAP = 12 * 60          # 每轮间隔
ROUNDS = 8

def latest():
    return call('GET', f'/repos/{OWNER}/{REPO}/actions/runs?per_page=1')['workflow_runs'][0]

for rnd in range(1, ROUNDS + 1):
    print(f'=== round {rnd} @ {time.strftime("%H:%M:%S")}', flush=True)
    try:
        call('POST', f'/repos/{OWNER}/{REPO}/actions/workflows/build.yml/dispatches', {'ref': 'main'})
    except Exception as e:
        print('dispatch err', e, flush=True)
    time.sleep(10)
    try:
        rid = latest()['id']
    except Exception:
        time.sleep(GAP); continue
    deadline = time.time() + 22 * 60
    while time.time() < deadline:
        try:
            w = call('GET', f'/repos/{OWNER}/{REPO}/actions/runs/{rid}')
        except Exception:
            time.sleep(20); continue
        st, cc = w['status'], w.get('conclusion')
        if st == 'completed':
            print(f'  {rid} -> {cc}', flush=True)
            if cc == 'success':
                # 下载 release 里的 IPA
                rel = call('GET', f'/repos/{OWNER}/{REPO}/releases?per_page=1')
                tag = rel[0]['tag_name']
                assets = {a['name']: a['id'] for a in rel[0].get('assets', [])}
                if 'LiveWallpaper.ipa' in assets:
                    url = f'https://api.github.com/repos/{OWNER}/{REPO}/releases/assets/{assets["LiveWallpaper.ipa"]}'
                    dst = OUT / 'LiveWallpaper-v4.0.ipa'
                    for _ in range(8):
                        subprocess.run(['curl', '-sSL', '--max-time', '180',
                                        '-H', f'Authorization: token {TOK}',
                                        '-H', 'Accept: application/octet-stream',
                                        '-o', str(dst), url])
                        if dst.exists() and dst.stat().st_size > 500_000:
                            print('IPA_OK', dst, dst.stat().st_size, flush=True)
                            sys.exit(0)
                        time.sleep(5)
                print('构建成功但下载失败', tag, flush=True)
                sys.exit(4)
            break
        time.sleep(20)
    else:
        print('  仍在跑/排队', flush=True)
    if rnd < ROUNDS:
        time.sleep(GAP)

print('GIVE_UP', flush=True)
sys.exit(3)
