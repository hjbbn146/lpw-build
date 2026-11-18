"""排队超过 15 分钟会被 GitHub 取消。这里自动 dispatch + 盯，最多 N 轮。"""
import sys, time, subprocess, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).parent))
from gh import OWNER, REPO, call, TOK

ROUNDS = 6
OUT = pathlib.Path(__file__).parent.parent / "out"
OUT.mkdir(exist_ok=True)

def latest():
    return call('GET', f'/repos/{OWNER}/{REPO}/actions/runs?per_page=1')['workflow_runs'][0]

for rnd in range(1, ROUNDS + 1):
    try:
        call('POST', f'/repos/{OWNER}/{REPO}/actions/workflows/build.yml/dispatches', {'ref': 'main'})
        print(f'--- round {rnd} dispatched', flush=True)
    except Exception as e:
        print('dispatch 失败', e, flush=True)
    time.sleep(8)
    rid = latest()['id']
    deadline = time.time() + 20 * 60
    last = None
    while time.time() < deadline:
        w = call('GET', f'/repos/{OWNER}/{REPO}/actions/runs/{rid}')
        st, cc = w['status'], w.get('conclusion')
        if (st, cc) != last:
            print(f'[{time.strftime("%H:%M:%S")}] {st} {cc or ""}', flush=True)
            last = (st, cc)
        if st == 'completed':
            print('conclusion =', cc, flush=True)
            if cc == 'success':
                print('BUILD_OK', rid, flush=True)
                sys.exit(0)
            # 失败：拉日志
            j = call('GET', f'/repos/{OWNER}/{REPO}/actions/runs/{rid}/jobs')
            for jb in j.get('jobs', []):
                url = f'https://api.github.com/repos/{OWNER}/{REPO}/actions/jobs/{jb["id"]}/logs'
                for _ in range(5):
                    subprocess.run(['curl', '-sSL', '--max-time', '90',
                                    '-H', f'Authorization: token {TOK}',
                                    '-o', str(OUT / 'retry_job.log'), url])
                    f = OUT / 'retry_job.log'
                    if f.exists() and f.stat().st_size > 1000:
                        break
                    time.sleep(3)
            txt = (OUT / 'retry_job.log').read_text(errors='replace')
            errs = [l for l in txt.splitlines() if 'error:' in l]
            print('=== 编译错误 ===')
            for l in errs[:12]:
                print(l.split('Z ', 1)[-1], flush=True)
            if errs:
                sys.exit(2)          # 真的是编译错，别再重试
            break                    # 只是排队被 cancel，继续下一轮
        time.sleep(12)
    else:
        print('round 超时', flush=True)

print('ALL_ROUNDS_EXHAUSTED', flush=True)
sys.exit(3)
