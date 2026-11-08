from take_a_look_backend.services.firmware_watch import FirmwareWatcher


def test_debounces_continuous_writes_deletion_and_atomic_replacement(tmp_path):
    path = tmp_path / 'motor.axf'
    path.write_bytes(b'first')
    refreshed = []
    watcher = FirmwareWatcher(lambda: str(path), lambda p: refreshed.append(p.read_bytes()) or True)
    watcher.poll(0)
    path.write_bytes(b'partial')
    watcher.poll(.5)
    watcher.poll(1)
    assert refreshed == []
    path.unlink()
    watcher.poll(1.5)
    watcher.poll(3)
    assert refreshed == []
    path.write_bytes(b'complete')
    watcher.poll(4)
    watcher.poll(5)
    watcher.poll(10)
    assert refreshed == [b'complete']
    replacement = tmp_path / 'replacement.axf'
    replacement.write_bytes(b'replaced')
    replacement.replace(path)
    watcher.poll(11)
    watcher.poll(12)
    assert refreshed == [b'complete', b'replaced']


def test_retries_incomplete_or_busy_output_then_stops_until_next_change(tmp_path):
    path = tmp_path / 'motor.axf'
    path.write_bytes(b'build')
    attempts = []
    def refresh(p):
        attempts.append(p)
        return len(attempts) > 1
    watcher = FirmwareWatcher(lambda: str(path), refresh)
    watcher.poll(0)
    watcher.poll(1)
    watcher.poll(2)
    assert attempts == [path]
    watcher.poll(4)
    watcher.poll(10)
    assert attempts == [path, path]


def test_tracks_only_current_selection_including_missing_outputs(tmp_path):
    first, second = tmp_path / 'a.axf', tmp_path / 'b.elf'
    first.write_bytes(b'first')
    selected = str(first)
    refreshed = []
    watcher = FirmwareWatcher(lambda: selected, lambda p: refreshed.append(p) or True)
    watcher.poll(0)
    selected = str(second)
    watcher.poll(.5)
    watcher.poll(2)
    assert refreshed == []
    second.write_bytes(b'second')
    watcher.poll(3)
    watcher.poll(4)
    assert refreshed == [second]
    selected = ''
    watcher.poll(5)
    first.write_bytes(b'changed')
    watcher.poll(10)
    assert refreshed == [second]
