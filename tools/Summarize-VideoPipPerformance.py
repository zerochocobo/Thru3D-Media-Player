"""Assess recorded 0/3/0 PiP windows using engine timing and in-window VrApi FPS.

This is a short-run regression check on the tested device, not a thermal or
minimum-device certification. Test-VideoPipMatrix collects the measurements.
"""
import argparse
import json
from pathlib import Path
import re
import statistics

p=argparse.ArgumentParser(description=__doc__)
p.add_argument("directory",type=Path)
args=p.parse_args()
source=json.loads((args.directory/"summary.json").read_text())
assert source["mode"]=="performance" and source["state"]=="passed" and not source.get("cleanup_error"),source
results=[]
for case in source["results"]:
    windows=[]
    for pair in case["pair"]:
        sample=pair["sample"]
        log=args.directory/(sample["label"]+"-vrapi.log")
        fps=[];stale=0
        for line in log.read_text(errors="replace").splitlines():
            row=re.search(r"^\s*(\d+\.\d+) .*FPS=(\d+)/(\d+).*?Stale=(\d+),",line)
            if row and sample["epoch_start"]<=float(row[1])<=sample["epoch_end"]:
                fps.append(int(row[2]));stale+=int(row[4])
        assert len(fps)>=5,(case["case"],sample["label"],fps)
        windows.append(dict(count=pair["count"],p95_ms=sample["delta_ms"]["p95"],late=sample["late_frames"],
            fps_median=statistics.median(fps),fps_min=min(fps),stale=stale,vrapi_samples=len(fps),
            main_gpu_us=pair["pip"]["metrics"].get("main_gpu_p95_us",0),
            atlas_gpu_us=pair["pip"]["metrics"].get("gpu_p95_us",0)))
    assert [w["count"] for w in windows]==[0,3,0],windows
    baseline_fps=statistics.mean(w["fps_median"] for w in (windows[0],windows[2]))
    baseline_p95=max(windows[0]["p95_ms"],windows[2]["p95_ms"])
    checks=dict(fps=windows[1]["fps_median"]>=baseline_fps*.95,
        frame_p95=windows[1]["p95_ms"]<=baseline_p95*1.25+1.)
    result=dict(case=case["case"],windows=windows,checks=checks,state="passed" if all(checks.values()) else "failed")
    results.append(result)
    print(case["case"],result["state"],"FPS",[w["fps_median"] for w in windows],
        "p95",[w["p95_ms"] for w in windows],"late",[w["late"] for w in windows])
report=dict(state="passed" if all(r["state"]=="passed" for r in results) else "failed",results=results,
    scope="12s-class 0/3/0 device comparisons; FPS >=95% of baseline and frame p95 <=125% baseline +1ms; not thermal certification")
(args.directory/"performance-assessment.json").write_text(json.dumps(report,indent=2))
raise SystemExit(0 if report["state"]=="passed" else 1)
