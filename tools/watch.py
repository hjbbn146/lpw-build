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
    # Azure blob 上的 artifact 经常连不上，优先走 Release（github.com，稳）
    rels = call("GET", f"/repos/{OWNER}/{REPO}/releases?per_page=3")
    tag = None
    if isinstance(rels, list) and rels:
        tag = rels[0].get("tag_name")
    if tag:
        ipa_url = f"https://github.com/{OWNER}/{REPO}/releases/download/{tag}/LiveWallpaper.ipa"
        dest = OUT / "LiveWallpaper.ipa"
        for attempt in range(4):
            try:
                curl_raw(ipa_url, dest)
                if dest.exists() and dest.stat().st_size > 20000:
                    print(f"release {tag} → {dest} {dest.stat().st_size} bytes")
                    break
            except Exception as e:
                print(f"  下载重试 {attempt+1}: {e}", flush=True)
                time.sleep(3)
        probe = OUT / "probe.txt"
        try:
            curl_raw(f"https://github.com/{OWNER}/{REPO}/releases/download/{tag}/probe.txt", probe)
            print("probe.txt:", probe.stat().st_size, "bytes")
        except Exception as e:
            print("probe.txt 下载失败:", e)
        if dest.exists() and dest.stat().st_size > 20000:
            return 0

    # 兜底：artifact
    arts = call("GET", f"/repos/{OWNER}/{REPO}/actions/runs/{run['id']}/artifacts").get("artifacts", [])
    if not arts:
        print("成功但没 artifact 也没 release")
        return 4
    art = arts[0]
    print(f"artifact {art['name']} {art['size_in_bytes']}B", flush=True)
    zp = OUT / "artifact.zip"
    for attempt in range(3):
        try:
            curl_raw(f"{API}/repos/{OWNER}/{REPO}/actions/artifacts/{art['id']}/zip", zp)
            break
        except Exception as e:
            print("  artifact 重试:", e, flush=True)
            time.sleep(5)
    if not zp.exists():
        print("artifact 也下不动")
        return 5
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
