#!/usr/bin/env python3
"""GitHub API 小工具：取凭据、建仓库、推代码、盯 CI、下 artifact。"""
import base64
import json
import pathlib
import subprocess
import time
import sys

OWNER = "hjbbn146"
REPO = "lpw-build"          # 目标仓库（public 跑免费 Actions，跑完可转 private）
BRANCH = "main"
API = "https://api.github.com"


def token() -> str:
    p = subprocess.run(["git", "credential", "fill"],
                       input="protocol=https\nhost=github.com\n\n",
                       capture_output=True, text=True, cwd=r"C:/Users/Administrator")
    for line in p.stdout.splitlines():
        if line.startswith("password="):
            return line.split("=", 1)[1].strip()
    sys.exit("no token")


TOK = token()


def call(method: str, path: str, payload=None, raw=False):
    cmd = ["curl", "-sSL",  "--max-time", "90",
           "-X", method,
           "-H", f"Authorization: token {TOK}",
           "-H", "Accept: application/vnd.github+json",
           "-H", "X-GitHub-Api-Version: 2022-11-28",
           "-H", "Content-Type: application/json"]
    data = None
    if payload is not None:
        cmd += ["--data-binary", "@-"]
        data = json.dumps(payload)
    if raw:
        cmd += ["-o", path[1]]
        cmd.append(path[0])
        p = subprocess.run(cmd, input=data, capture_output=True, text=True)
        if p.returncode != 0:
            raise RuntimeError(f"curl rc={p.returncode}: {p.stderr[:200]}")
        return None
    cmd.append(API + path)
    # 走本地代理时常被 502 打断，重试几轮再放弃
    last = None
    for attempt in range(6):
        p = subprocess.run(cmd, input=data, capture_output=True, text=True,
                           encoding="utf-8", errors="replace")
        if p.returncode == 0:
            last = p
            break
        last = p
        time.sleep(1.2 * (attempt + 1))
    p = last
    if p.returncode != 0:
        raise RuntimeError(f"curl rc={p.returncode}: {p.stderr[:200]}")
    if not p.stdout.strip():
        return {}
    try:
        body = json.loads(p.stdout)
    except json.JSONDecodeError:
        raise RuntimeError(f"非 JSON: {p.stdout[:300]}")
    return body


def curl_raw(url: str, dest: pathlib.Path):
    """带 token 下载二进制（artifact / 日志）。"""
    cmd = ["curl", "-sSL",  "--retry", "4", "--retry-delay", "3",
           "--max-time", "180", "-H", f"Authorization: token {TOK}",
           "-H", "Accept: application/vnd.github+json",
           "-H", "X-GitHub-Api-Version: 2022-11-28",
           "-o", str(dest), url]
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError(f"curl rc={p.returncode}: {p.stderr[:200]}")
    return dest


def ensure_repo():
    info = call("GET", f"/repos/{OWNER}/{REPO}")
    if info.get("full_name"):
        print(f"仓库已存在: {info['full_name']} private={info['private']}")
        if info["private"]:
            print("→ 转 public 以便使用免费 Actions")
            call("PATCH", f"/repos/{OWNER}/{REPO}", {"private": False})
        return
    print("创建仓库…")
    r = call("POST", "/user/repos", {
        "name": REPO,
        "private": False,
        "auto_init": True,
        "description": "build-only repo for LiveWallpaper iOS IPA",
    })
    if not r.get("full_name"):
        sys.exit(f"创建失败: {r}")
    print("已创建:", r["full_name"])


def push(root: pathlib.Path, message: str):
    files = []
    for f in sorted(root.rglob("*")):
        if not f.is_file():
            continue
        rel = f.relative_to(root).as_posix()
        if rel.startswith(".git/") or "/out/" in rel or rel.startswith("out/") \
                or "__pycache__" in rel or rel.endswith(".pyc") \
                or rel.startswith("dist/") or rel.endswith(".ipa"):
            continue
        files.append((rel, f))
    print(f"待同步 {len(files)} 个文件")

    entries = []
    for rel, f in files:
        blob = call("POST", f"/repos/{OWNER}/{REPO}/git/blobs",
                    {"content": base64.b64encode(f.read_bytes()).decode(),
                     "encoding": "base64"})
        if not blob.get("sha"):
            sys.exit(f"blob 失败 {rel}: {blob}")
        entries.append({"path": rel, "mode": "100644", "type": "blob", "sha": blob["sha"]})

    head = call("GET", f"/repos/{OWNER}/{REPO}/git/ref/heads/{BRANCH}")
    head_sha = head["object"]["sha"]
    tree = call("POST", f"/repos/{OWNER}/{REPO}/git/trees", {"tree": entries})
    commit = call("POST", f"/repos/{OWNER}/{REPO}/git/commits",
                  {"message": message, "tree": tree["sha"], "parents": [head_sha]})
    call("PATCH", f"/repos/{OWNER}/{REPO}/git/refs/heads/{BRANCH}",
         {"sha": commit["sha"], "force": False})
    print(f"✅ pushed {commit['sha'][:7]}")


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "scopes":
        p = subprocess.run(["curl", "-sSI",  "-H", f"Authorization: token {TOK}",
                            "https://api.github.com/user"], capture_output=True, text=True)
        for line in p.stdout.splitlines():
            if line.lower().startswith(("x-oauth-scopes", "x-accepted")):
                print(line.strip())
    elif cmd == "repo":
        ensure_repo()
    elif cmd == "push":
        push(pathlib.Path(sys.argv[2]), sys.argv[3])
