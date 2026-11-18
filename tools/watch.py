#!/usr/bin/env python3
"""盯 GitHub Actions：成功就下 artifact 里的 IPA；失败就把每个 step 的日志抓下来。"""
import pathlib
import sys
import time
import zipfile

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from gh import OWNER, REPO, API, call, curl_raw  # noqa

OUT = pathlib.Path(__file__).parent.parent / "out"
OUT.mkdir(parents=True, exist_ok=True)


def main() -> int:
    deadline = time.time() + 60 * 60
    seen = None
    while time.time() < deadline:
        try:
            runs = call("GET", f"/repos/{OWNER}/{REPO}/actions/runs?per_page=5")
        except Exception as e:
            print("查询失败:", e, flush=True)
            time.sleep(20)
            continue
        items = [r for r in runs.get("workflow_runs", [])]
        if not items:
            print("还没有 run…", flush=True)
            time.sleep(15)
            continue
        run = items[0]
        if seen != run["id"]:
            seen = run["id"]
            print(f"run #{run['run_number']} id={run['id']}", flush=True)
        print(f"[{time.strftime('%H:%M:%S')}] {run['status']} {run.get('conclusion') or ''}", flush=True)

        if run["status"] != "completed":
            time.sleep(20)
            continue

        if run.get("conclusion") == "success":
            return grab(run)

        jobs = call("GET", f"/repos/{OWNER}/{REPO}/actions/runs/{run['id']}/jobs").get("jobs", [])
        for j in jobs:
            print(f"job: {j['name']} -> {j.get('conclusion')}", flush=True)
            for s in j.get("steps", []):
                print(f"   {s.get('number')}. {s.get('name')}: {s.get('conclusion')}", flush=True)
        # 抓失败日志
        for j in jobs:
            dest = OUT / f"job_{j['id']}.log"
            try:
                curl_raw(f"{API}/repos/{OWNER}/{REPO}/actions/jobs/{j['id']}/logs", dest)
                txt = dest.read_text(encoding="utf-8", errors="replace")
                print(f"\n===== {j['name']} (tail) =====", flush=True)
                print("\n".join(txt.splitlines()[-120:]), flush=True)
            except Exception as e:
                print("抓日志失败:", e, flush=True)
        return 2

    print("TIMEOUT")
    return 3


def grab(run) -> int:
    arts = call("GET", f"/repos/{OWNER}/{REPO}/actions/runs/{run['id']}/artifacts").get("artifacts", [])
    if not arts:
        print("成功但没 artifact")
        return 4
    art = arts[0]
    print(f"artifact {art['name']} {art['size_in_bytes']}B", flush=True)
    zp = OUT / "artifact.zip"
    curl_raw(f"{API}/repos/{OWNER}/{REPO}/actions/artifacts/{art['id']}/zip", zp)
    print("下载", zp.stat().st_size, "bytes")
    with zipfile.ZipFile(zp) as z:
        z.extractall(OUT)
    ipas = sorted(OUT.rglob("*.ipa"), key=lambda p: -p.stat().st_size)
    if not ipas:
        print("zip 内无 ipa")
        return 6
    print("OK", ipas[0], f"{ipas[0].stat().st_size/1024/1024:.2f} MB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
