"""Fixed-workload recording throughput, without sampler/timer/probe overhead."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--runs', type=int, default=3)
    parser.add_argument('--batches', type=int, default=160)
    args = parser.parse_args()
    sys.path.insert(0, str(args.source_root.resolve() / 'backend'))
    from take_a_look_backend.services.recording import RawRecording
    labels = {f'ch{i}': f'Channel {i}' for i in range(32)}
    batches = [[((batch * 64 + frame) / 10000, {key: frame for key in labels})
                for frame in range(64)] for batch in range(args.batches)]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    results = []
    for run in range(args.runs):
        with tempfile.TemporaryDirectory(dir=args.output.parent) as directory:
            recording = RawRecording(Path(directory))
            started, cpu = time.perf_counter(), time.process_time()
            for frames in batches:
                recording.append(frames, labels)
            recording.close()
            elapsed, used = time.perf_counter() - started, time.process_time() - cpu
            assert recording.sample_count == args.batches * 64
            row = dict(run=run + 1, elapsedSeconds=elapsed, cpuSeconds=used,
                       frames=recording.sample_count, bytes=recording.committed_bytes,
                       framesPerSecond=recording.sample_count / elapsed)
            results.append(row)
            print(json.dumps(row), flush=True)
    args.output.write_text(json.dumps(dict(status='passed', sourceRoot=str(args.source_root.resolve()),
                          scope='32 channels, 64 frames per append, raw journal and exact history indexes, '
                                'including close/fsync; no sampling or probe', results=results), indent=2))


if __name__ == '__main__':
    main()
