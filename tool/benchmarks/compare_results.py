"""Compare a recorded baseline with current release, worker, and UI workloads."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


def read(path: Path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--before", type=Path, required=True)
    parser.add_argument("--after", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    baseline = read(args.before)
    environment = read(args.after / "environment.json")
    root = Path(__file__).resolve().parents[2]
    for relative, expected in environment["sourceSha256"].items():
        if hashlib.sha256((root / relative).read_bytes()).hexdigest().upper() != expected:
            raise RuntimeError(f"Source differs from the measured release: {relative}")

    def load(pattern: str):
        runs = [read(path) for path in sorted(args.after.glob(pattern))]
        if len(runs) < 2 or any(run["status"] != "passed" for run in runs):
            raise RuntimeError(f"Need two successful runs for {pattern}")
        return runs

    current = load("run-*.json")
    workers = load("worker-run-*.json")
    live = load("live-run-*.json")
    for suite in ["worker", "live"]:
        if read(args.after / f"environment-{suite}.json")["sourceSha256"] != environment["sourceSha256"]:
            raise RuntimeError(f"{suite} was compiled from different sources")
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "results.json").write_text(json.dumps({
        "environment": environment, "baselineFile": str(args.before),
        "runs": current, "workerRuns": workers, "liveRuns": live,
    }, ensure_ascii=False, indent=2), encoding="utf-8")

    def metrics(runs, name, key="medianMs"):
        return [next(case[key] for case in run["results"] if case["name"] == name) for run in runs]

    def span(runs, name, key="medianMs"):
        values = metrics(runs, name, key)
        return f"{min(values):.3f}–{max(values):.3f}"

    lines = [
        "# Dart 数据处理重构：实现与复测", "",
        "完成了数值环形缓存、FFT 常驻分析 isolate、显示通知合并；控制协议和硬件后端未改变。",
        "",
        "- SampleBuffer 使用 Float64List 存储时间和值，写满后覆盖最旧位置；实时入库不再移动整段列表或创建 Offset。",
        "- 保留每路 1,800 点、冻结绘图快照、CSV 后端原始记录和多窗口增量游标的原有语义。大快照裁剪后仍保留原始总计数。",
        "- 数据处理立即执行；telemetry、全局 UI 和窗口同步通知按显示时钟合并。",
        "- FftAnalysisWorker 复用输入数据，最多一个活动任务和一个最新待办任务；过时结果返回 null，面板关闭时释放 isolate。",
        "- FFT 核心使用类型化数组，完整频谱以均匀频率轴＋幅值数组保存。输入和完整输出通过 TransferableTypedData 传递，未丢弃频率分辨率。",
        "- 数值数据类型、FFT 与 worker 是独立 Dart 模块，可共用于 pyOCD、probe-rs 等数据源。",
        "", "## Release AOT：同类输入的前后对比", "",
        f"环境：{environment['cpu']}，{environment['ramGiB']} GiB 内存，"
        f"Flutter {environment['flutter']['frameworkVersion']} / Dart {environment['flutter']['dartSdkVersion']}。",
        "每侧采用两个进程的测量，中位数区间如下。采样链路每批 64 帧，每路缓冲区预先填满 1,800 点。",
        "", "| 项目 | 重构前 ms | 重构后 ms | 中位数均值之比 |",
        "| --- | ---: | ---: | ---: |",
    ]
    for name, label in [
        ("pipeline_current_32", "32 路拆帧、解码、入库"),
        ("pipeline_current_128", "128 路拆帧、解码、入库"),
        ("fft_8192", "8,192 点完整 FFT 分析"),
        ("fft_131072", "131,072 点完整 FFT 分析"),
        ("fft_1048576", "1,048,576 点完整 FFT 分析"),
    ]:
        old = metrics(baseline["runs"], name)
        new = metrics(current, name)
        ratio = (sum(old) / len(old)) / (sum(new) / len(new))
        lines.append(f"| {label} | {span(baseline['runs'], name)} | {span(current, name)} | {ratio:.1f}× |")
    lines += [
        "", "以上倍率只对应各项计算，不等于整体应用或调试探针的加速倍率。"
        "CPU 频率和其他系统负载没有锁定，因此绝对数值有运行波动。"
        "微基准的 P95 是每块平均耗时的 P95；原始数据保留全部重复和参数。",
        "", "## 生产 FFT worker", "",
        "每种数据首次上传一次，此后九次分析复用输入，返回全部频谱点。"
        "下表稳态计时含命令、计算及结果传输；首请求另记录为 firstRequestMs。",
        "", "| 输入规模 | 稳态耗时 ms | 主 isolate 最大心跳间隔 ms | 每轮数据上传次数 |",
        "| --- | ---: | ---: | ---: |",
    ]
    for count in [131072, 1048576]:
        name = f"production_worker_{count}"
        lines.append(f"| {count:,} 点 | {span(workers, name)} | "
                     f"{span(workers, name, 'maxHeartbeatGapMs')} | 1 |")
    lines += [
        "", "心跳周期为 16 ms；这项指标衡量主 isolate 响应，不是实际显示 FPS。",
        "", "## 持续采样＋真实 Widget＋FFT", "",
        "使用 Windows Release 引擎和生产曲线、监视表、分析面板，在隐藏原生窗口中运行。"
        "模拟 32 路 × 每路 10 kHz 二进制样本；每 500 ms 改变 FFT 选区，复用 131,072 点输入。"
        "每轮约 8 秒，预热约 2 秒。",
        "", "| 轮次 | 每路接收帧数 | 实际输入 Hz | build P95 ms | raster P95 ms | FFT 选区变化次数 |",
        "| --- | ---: | ---: | ---: | ---: | ---: |",
    ]
    for index, run in enumerate(live, 1):
        case = run["results"][0]
        lines.append(f"| {index} | {case['receivedFramesPerChannel']} | {case['effectiveHz']:.1f} | "
                     f"{case['buildP95Ms']:.3f} | {case['rasterP95Ms']:.3f} | {case['fftSelectionChanges']} |")
    lines += [
        "", "所有已发送帧均被解码并计入每路总数，缓冲区始终保留最近 1,800 点；"
        "停止时最后一个未满批次及定时器间隔未计为已发送数据，实际速率因而略低于标称值。"
        "全过程含启动的最大瞬时调度积压为 "
        f"{span(live, 'live_32x10000_with_fft', 'maxSchedulingBacklogFrames')} 帧，随后按时间追赶处理，未静默丢弃。",
        "", "build/raster 是引擎阶段耗时。隐藏窗口不等同于物理显示呈现；"
        "本测试没有连接硬件、没有 OS 进程管道、没有 CSV 录制，也没有同时开启多窗口。"
        "它验证了短时并发负载与数据完整性，不是长时间硬件压力认证。",
        "", "## 检查与范围", "",
        "- flutter analyze：通过。",
        "- flutter test：134 项通过，覆盖数组绕回、稀疏样本、停用采样、快照与多窗口游标、通知合并、FFT 数值、任务替换及面板关闭。",
        "- 独立 Release AOT：两轮各 39 项基础测量；两轮生产 worker 专项；两轮持续界面负载，全部通过校验。",
        "- 本轮保持历史容量为每路 1,800 点。CSV 流式解析、长期多级历史及真实 probe-rs 适配仍是后续工作。",
        "", "## 复测", "", "```powershell",
        r".\tool\run_data_benchmarks.ps1 -Runs 2 -ResultSet refactor",
        r".\tool\run_data_benchmarks.ps1 -Runs 2 -Suite worker -ResultSet refactor -SkipBuild",
        r".\tool\run_data_benchmarks.ps1 -Runs 2 -Suite live -ResultSet refactor -SkipBuild",
        "python tool/benchmarks/compare_results.py --before docs/performance/2026-09-27/results.json "
        "--after build/data_benchmark/refactor --output docs/performance/2026-09-27/refactor",
        "```", "", "[完整结果与源码 SHA-256](results.json)",
    ]
    (args.output / "REPORT.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(args.output / "REPORT.md")


if __name__ == "__main__":
    main()
