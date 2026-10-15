"""Bake-off orchestrator: runs every metric for every candidate, prints JSON.

Usage: python3 run_all.py <bakeoff_dir>
Re-run this after any version bump; it is the regression suite.
"""
import json
import os
import subprocess
import sys
import tempfile
import time

BAKEOFF = os.path.abspath(sys.argv[1])
HARNESS = os.path.join(BAKEOFF, "harness")
LOGS = os.path.join(BAKEOFF, "logs")
CANDIDATES = {
    "pydantic-ai-slim": {
        "python": os.path.join(BAKEOFF, "venvs", "pydai", "bin", "python"),
        "runner": os.path.join(BAKEOFF, "candidates", "run_pydai.py"),
        "import_module": "pydantic_ai",
        "result_prefix": "PYDAI_RESULT=",
    },
    "no-framework": {
        "python": os.path.join(BAKEOFF, "venvs", "nofw", "bin", "python"),
        "runner": os.path.join(BAKEOFF, "candidates", "run_nofw.py"),
        "import_module": "pydantic",
        "result_prefix": "NOFW_RESULT=",
    },
}


def import_time(py, module, runs=3):
    best = None
    slowest = []
    for _ in range(runs):
        t0 = time.perf_counter()
        p = subprocess.run([py, "-X", "importtime", "-c", f"import {module}"],
                           capture_output=True, text=True)
        dt = time.perf_counter() - t0
        if p.returncode != 0:
            return {"error": p.stderr[-500:]}
        if best is None or dt < best:
            best = dt
            rows = []
            for line in p.stderr.splitlines():
                parts = line.split("|")
                if len(parts) == 3 and parts[1].strip().isdigit():
                    rows.append((int(parts[1]), parts[2].strip()))
            slowest = sorted(rows, reverse=True)[:5]
    return {"best_of_3_wall_s": round(best, 3),
            "top5_cumulative_us": [{"us": u, "module": m} for u, m in slowest]}


def footprint(py):
    site = subprocess.run(
        [py, "-c", "import sysconfig; print(sysconfig.get_paths()['purelib'])"],
        capture_output=True, text=True).stdout.strip()
    dists = sorted(
        d[:-len(".dist-info")].rsplit("-", 1)[0]
        for d in os.listdir(site) if d.endswith(".dist-info")
        and not d.startswith(("pip-", "setuptools-", "wheel-")))
    du = subprocess.run(["du", "-sh", site], capture_output=True, text=True)
    return {"packages": len(dists), "site_packages_size": du.stdout.split()[0],
            "package_list": dists}


def run_task(py, runner, mode, log_path):
    # AF_UNIX sun_path is ~104 chars on macOS; keep the socket somewhere short.
    sock = os.path.join(tempfile.mkdtemp(prefix="bko_", dir="/tmp"), f"{mode}.sock")
    for pth in (sock, sock + ".ready"):
        if os.path.exists(pth):
            os.unlink(pth)
    broker = subprocess.Popen(
        [sys.executable, os.path.join(HARNESS, "broker.py"), sock, log_path, mode],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        for _ in range(200):
            if os.path.exists(sock + ".ready"):
                break
            time.sleep(0.02)
        p = subprocess.run([py, runner, sock, log_path, mode],
                           capture_output=True, text=True, timeout=60)
        result = None
        for line in p.stdout.splitlines():
            if "_RESULT=" in line:
                result = json.loads(line.split("=", 1)[1])
        with open(log_path) as f:
            requests = sum(1 for ln in f if ln.strip())
        return {"result": result, "broker_requests": requests,
                "stderr_tail": p.stderr[-300:] if p.returncode != 0 else ""}
    finally:
        broker.kill()


def main():
    os.makedirs(LOGS, exist_ok=True)
    summary = {}
    for name, c in CANDIDATES.items():
        entry = {"import_time": import_time(c["python"], c["import_module"]),
                 "footprint": footprint(c["python"])}
        slug = name.replace("-", "_")
        entry["golden_normal"] = run_task(
            c["python"], c["runner"], "normal",
            os.path.join(LOGS, f"{slug}_normal.jsonl"))
        entry["malformed_retries"] = run_task(
            c["python"], c["runner"], "malformed",
            os.path.join(LOGS, f"{slug}_malformed.jsonl"))
        summary[name] = entry
    print(json.dumps(summary, indent=1))


if __name__ == "__main__":
    main()
