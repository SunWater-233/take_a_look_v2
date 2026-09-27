"""Summarize the release benchmark, preserving the source fingerprints and raw data."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


def read_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def main() -> None:
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--results", type=Path, default=root / "build/data_benchmark/results")
    parser.add_argument("--output", type=Path, help="Report directory; defaults to the dated current/ directory")
    args = parser.parse_args()
    environment = read_json(args.results / "environment.json")
    runs = [read_json(path) for path in sorted(args.results.glob("run-*.json"))]
    if len(runs) < 2 or any(run.get("status") != "passed" for run in runs):
        raise RuntimeError("At least two completed, successful benchmark runs are required.")
    for relative, expected in environment["sourceSha256"].items():
        actual = hashlib.sha256((root / relative).read_bytes()).hexdigest().upper()
        if actual != expected:
            raise RuntimeError(f"Source changed after build: {relative}")
    indexed = [{item["name"]: item for item in run["results"]} for run in runs]
    if any(len(items) != 39 for items in indexed):
        raise RuntimeError("Incomplete benchmark matrix; expected 39 measurements per run.")
    if any(set(items) != set(indexed[0]) for items in indexed):
        raise RuntimeError("Run scenarios differ.")
    isolated_runs = [read_json(path) for path in sorted(args.results.glob("heartbeat-run-*.json"))]
    if isolated_runs:
        isolated_environment = read_json(args.results / "environment-heartbeat.json")
        if isolated_environment["sourceSha256"] != environment["sourceSha256"]:
            raise RuntimeError("The independent heartbeat suite used different sources.")
        if any(run.get("status") != "passed" or len(run["results"]) != 4 for run in isolated_runs):
            raise RuntimeError("An independent heartbeat run failed or is incomplete.")
    heartbeat_index = [
        {item["name"]: item for item in run["results"]}
        for run in (isolated_runs or runs)
    ]
    date = runs[0]["startedAt"][:10]
    directory = args.output or root / "docs/performance" / date / "current"
    directory.mkdir(parents=True, exist_ok=True)
    raw_path = directory / "results.json"
    raw_path.write_text(json.dumps({"environment": environment, "runs": runs,
                                   "independentHeartbeatRuns": isolated_runs},
                                   ensure_ascii=False, indent=2), encoding="utf-8")

    def number(value: float) -> str:
        return f"{value:.3f}" if value < 1 else f"{value:.2f}"

    def values(name: str, field: str = "medianMs") -> list[float]:
        return [items[name][field] for items in indexed]

    def span(name: str, field: str = "medianMs") -> str:
        sequence = values(name, field)
        return f"{number(min(sequence))}–{number(max(sequence))}"

    def average(name: str) -> float:
        sequence = values(name)
        return sum(sequence) / len(sequence)

    def heartbeat_span(name: str) -> str:
        sequence = [items[name]["maxGapMs"] for items in heartbeat_index]
        return f"{number(min(sequence))}–{number(max(sequence))}"

    lines = [
        f"# Flutter / Dart 数据处理实测（{date}）",
        "",
        "测试直接导入本项目的生产函数，在独立 Windows Flutter **Release AOT** 程序中执行。"
        "没有修改业务实现。环形数值缓存仅是基准程序中的对照原型。",
        "",
        f"硬件：{environment['cpu']}，{environment['cores']} 核 / "
        f"{environment['logicalProcessors']} 线程，内存 {environment['ramGiB']} GiB。",
        f"软件：Flutter {environment['flutter']['frameworkVersion']}，"
        f"Dart {environment['flutter']['dartSdkVersion']}；{runs[0]['os']}。",
        f"最终共 {len(runs)} 个独立进程、每轮 39 项测量；各轮均通过显式校验。",
        f"另执行 {len(isolated_runs)} 个独立进程的心跳专项，每轮 4 项测量。",
        "",
        "## 结论",
        "",
        "以下分别测量数据接收、缓存、FFT、CSV 和绘图。判断持续吞吐时，应将每批处理时间与数据到达间隔比较；大计算应避免阻塞界面线程。"
        "多后端兼容仍适合采用统一数据协议：pyOCD / probe-rs 负责硬件，共用 Dart 数据与分析层。",
        "",
        "## 采样链路：每批 64 帧，每路已保留 1,800 点",
        "",
        "计时包含 4 KiB 分块输入的流拆帧、二进制解码、监视通道匹配及缓存写入。"
        "所有通道开启采样、所有值有效；数据生成不计时。表中区间是各轮中位数的最小值至最大值。",
        "",
        "| 通道数 | 当前链路 ms/批 | 环形数值缓存对照 ms/批 | 两轮中位数均值之比 |",
        "| --- | ---: | ---: | ---: |",
    ]
    for channels in [8, 32, 64, 128]:
        current = f"pipeline_current_{channels}"
        ring = f"pipeline_ring_{channels}"
        lines.append(f"| {channels} | {span(current)} | {span(ring)} | "
                     f"{average(current) / average(ring):.0f}× |")
    load = average("pipeline_current_32") * 10000 / 64
    lines += [
        "",
        f"若未来后端能提供 **32 路 × 每路 10 kHz**，每 6.4 ms 就产生一批数据。"
        f"按当前实测，处理 1 秒的数据约需 **{load / 1000:.3f} 秒**串行处理时间，"
        + ("这条链路超过数据到达的时间预算。" if load > 1000 else "这条计算链路低于数据到达的时间预算。")
        + "尚未计入绘图和其他界面工作。1 kHz 的对应负载为其十分之一。",
        "",
        "环形数值缓存是同输入的参考对照；倍率只适用于这项满缓存写入测试，"
        "不能解释为整个应用能加速同样倍数。对照使用 Float64List 环形缓存，避免 List<Offset> "
        "头删造成的逐点搬移及 Offset 分配。已校验环形历史的时间和值与生产缓存一致，并检查所有链路的帧数、计数和末值。",
        "",
        "| 通道数 | 仅二进制解码 ms/批 | 仅当前缓存写入 ms/批 |",
        "| --- | ---: | ---: |",
    ]
    for channels in [8, 32, 64, 128]:
        lines.append(f"| {channels} | {span(f'decode_{channels}')} | {span(f'cache_current_{channels}')} |")
    lines += ["", "## FFT、显示降采样与 CSV", "",
              "FFT 包含现有函数的输入校验、时间间隔处理、去直流、Hann 加窗、变换和频谱生成；"
              "没有使用界面层的结果缓存。默认输入为均匀时间轴，未覆盖抖动重采样路径。",
              "", "| 项目 | 每次中位耗时 ms（各轮区间） | 各轮 P95 最大值 ms |",
              "| --- | ---: | ---: |"]
    scenarios = [
        *[(f"fft_{n}", f"FFT {n:,} 点") for n in [2048, 8192, 32768, 131072, 262144, 1048576]],
        ("fft_separate_timebase_131072", "FFT 131,072 点，独立时间列"),
        *[(f"downsample_{n}", f"{n:,} 点降采样至 1,000 像素宽") for n in [1800, 100000, 1000000]],
        *[(f"csv_{n}_8", f"CSV {n:,} 行 × 8 数值列") for n in [10000, 100000, 500000]],
    ]
    for name, label in scenarios:
        lines.append(f"| {label} | {span(name)} | {number(max(values(name, 'p95Ms')))} |")
    lines += [
        "", "60 Hz 的单帧预算约 16.7 ms，120 Hz 约 8.3 ms，且还需留出界面其他工作时间。"
        "较大的 FFT 和百万点扫描应移出主 isolate，并控制重算频率。CSV 当前已有 compute 后台路径；"
        "本表计时其解析函数本身，不含磁盘读取和 isolate 传输。",
        "", "## 主 isolate 响应", "",
        "以 16 ms 定时器模拟事件循环心跳，连续执行三次 262,144 点 FFT。"
        "以下是每轮最大心跳间隔的区间，**不是实际界面帧时间**。"
        "优先采用独立进程的心跳专项结果，避免前序大 CSV / 百万点 FFT 及其内存回收的干扰；"
        "完整矩阵中的心跳观测也保留在原始 JSON 中。",
        "", "| 场景 | 最大心跳间隔 ms（各轮区间） |",
        "| --- | ---: |",
    ]
    for name, label in [
        ("idle", "空闲基线"),
        ("main_isolate", "主 isolate 同步执行"),
        ("worker_isolate", "每次 Isolate.run，传入点列表并返回完整频谱"),
        ("resident_worker_summary", "常驻 worker，预载点列表，仅返回峰值摘要"),
    ]:
        lines.append(f"| {label} | {heartbeat_span('heartbeat_' + name)} |")
    lines += [
        "", "后台执行改善了响应，但大对象传输、内存分配和 GC 仍可能带来停顿，不能据此保证稳定 60 FPS。"
        "常驻 worker 的初始输入装载时间单独记录为 workerStartupMs，未计入该场景的心跳测量；"
        "它也没有返回完整频谱，所以与一次性 isolate 场景的传输成本不同。",
        "", "## 实际绘图代码的离屏测试", "",
        "调用生产 TelemetryPainter，画布 1,200 × 600，每路 1,800 点，所有曲线显式开启，包含自动 Y 轴。"
        "CPU 记录和 toImage 离屏栅格化分别计时；离屏截图路径与屏幕呈现不同，不能直接换算应用 FPS。",
        "", "| 曲线数 | CPU 绘图记录 ms | 记录＋离屏栅格化 ms |",
        "| --- | ---: | ---: |",
    ]
    for channels in [8, 32, 64]:
        lines.append(f"| {channels} | {span(f'paint_record_{channels}')} | {span(f'paint_offscreen_{channels}')} |")
    rss_text = ", ".join(
        f"{run['maxRssBytes'] / 1024**2:.0f} MiB" for run in runs
    )
    lines += [
        "", "## 测量方法与边界", "",
        "- 三次预热，按预热时间选择每块重复次数，目标每块约 20 ms；15 块为主，大任务为 7 或 9 块。",
        "- 中位数及 P95 来自“每块平均每次耗时”；P95 不是逐次延迟 P95。绘图离屏项为预热三次后的九次单独测量。",
        "- 输入生成、初始缓存填充不计时，计时期间的内存分配与 GC 计入。两轮为不同进程，顺序执行，未并发跑其他基准。",
        "- 所有函数结果被消费；校验二进制帧计数、环形历史一致性、FFT 峰值、CSV 行列数和绘图曲线开启状态。",
        "- 没有连接真实探针，没有计入 Python/Rust 数据生产、USB/SWD、进程管道 I/O、文件录制、Widget 构建、多窗口同步或屏幕呈现。",
        "- 单台机器的合成数据测试，后台系统负载、供电和调度未严格控制；不能当作语言排名或全应用的端到端容量认证。",
        f"- 各轮整个进程峰值 RSS：{rss_text}。"
        "这是包含百万点 FFT 和大 CSV 场景的进程峰值，不是日常采样缓存占用。",
        "", "## 复现", "", "在仓库根目录运行：", "", "```powershell",
        r".\tool\run_data_benchmarks.ps1 -Runs 2",
        r".\tool\run_data_benchmarks.ps1 -Runs 3 -Suite heartbeat -SkipBuild",
        r"python .\tool\benchmarks\summarize_results.py", "```", "",
        "生成的独立程序与临时结果位于 build/data_benchmark/，不会覆盖主应用的 Release 产物。",
        "", "[完整原始结果、环境和生产源码 SHA-256](results.json)",
    ]
    report = directory / "REPORT.md"
    report.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(report)


if __name__ == "__main__":
    main()
