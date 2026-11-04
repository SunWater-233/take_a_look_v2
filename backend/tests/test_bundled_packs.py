"""Exercise compact pack generation with real pyOCD parsing and offline cache reuse."""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path
from unittest.mock import patch
from xml.etree import ElementTree
import zipfile

import pytest

SPEC = importlib.util.spec_from_file_location(
    "prepare_bundled_packs", Path(__file__).resolve().parents[2] / "tool/prepare_bundled_packs.py")
packs = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(packs)


def fixture(tmp_path, *, base="", missing=None):
    output = tmp_path / "bundled"
    output.mkdir()
    original = output / "Test.STM32F1xx_DFP.1.0.0.pack"
    descriptor = '''<package schemaVersion="1.7.7">
<vendor>Test</vendor><name>STM32F1xx_DFP</name><license>LICENSE.txt</license>
<releases><release version="1.0.0">Fixture</release></releases>
<devices><family Dfamily="STM32F1" Dvendor="Test:999">
<processor Dcore="Cortex-M3"/>
<memory id="IROM1" start="0x08000000" size="0x10000" access="rx" startup="1"/>
<memory id="IRAM1" start="0x20000000" size="0x5000" access="rwx"/>
<algorithm name="Flash\\internal.FLM" start="0x08000000" size="0x10000" default="1"/>
<debugvars configfile="Debug/device.dbgconf">__var Example = 0;</debugvars>
<sequences><sequence name="ResetSystem"><block>Write32(0xE000ED0C, 0x05FA0004);</block></sequence></sequences>
<subFamily DsubFamily="F103"><debug svd="SVD/f103.svd"/>
<device Dname="STM32F103C8"><book name="Documents/manual.pdf"/>
<compile header="Device/driver.h"/></device>
<device Dname="STM32F103CB"/></subFamily>
<subFamily DsubFamily="F105"><debug svd="SVD/f105.svd"/>
<device Dname="STM32F105RB"/></subFamily>
</family></devices><components><component/></components><examples/></package>'''
    contents = {"Test.STM32F1xx_DFP.pdsc": descriptor, "LICENSE.txt": "Fixture license",
                "Device/LICENSE-extra.txt": "Retained notice", "Flash/internal.FLM": "algorithm",
                "Flash/unused.FLM": "unused", "SVD/f103.svd": "<device/>", "SVD/f105.svd": "<device/>",
                "Debug/device.dbgconf": "__var Example = 0;", "Documents/manual.pdf": "manual",
                "Device/driver.h": "header", "Boards/example.c": "example"}
    with zipfile.ZipFile(original, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, data in contents.items():
            if name != missing:
                archive.writestr(base + name, data)
    source = {"vendor": "Test", "name": "STM32F1xx_DFP", "version": "1.0.0",
              "url": "https://example.invalid/Test.STM32F1xx_DFP.1.0.0.pack",
              "sha256": packs.digest(original), "requiredPrefix": "stm32f103",
              "targetPrefixes": ["stm32f103"], "expectedTargetCount": 2}
    lockfile = tmp_path / "lock.json"
    lockfile.write_text(json.dumps({"version": 1, "packs": [source]}), encoding="utf-8")
    return output, original, source, lockfile, tmp_path / "cache"


@pytest.mark.parametrize("base", ["", "nested/"])
def test_preparation_retains_inherited_resources_and_licenses_and_is_reproducible(tmp_path, base):
    output, original, source, lockfile, cache = fixture(tmp_path, base=base)
    with patch.object(packs.urllib.request, "urlopen", side_effect=AssertionError("must stay offline")):
        first = packs.prepare(output, lockfile, cache)
        identity, metadata = next(iter(first["packs"].items()))
        compact = output / f"{identity}.pack"
        data = compact.read_bytes()
        assert identity == packs.digest(compact) != source["sha256"]
        assert metadata["sourceSha256"] == source["sha256"]
        assert metadata["targetCount"] == 2
        assert {t["partNumber"] for t in metadata["targets"]} == {"STM32F103C8", "STM32F103CB"}
        assert (cache / f"{source['sha256']}.pack").is_file()
        assert not original.exists()
        with zipfile.ZipFile(compact) as archive:
            assert set(archive.namelist()) == {base + name for name in (
                "Test.STM32F1xx_DFP.pdsc", "LICENSE.txt", "Device/LICENSE-extra.txt",
                "Flash/internal.FLM", "SVD/f103.svd", "Debug/device.dbgconf")}
            root = ElementTree.fromstring(archive.read(base + "Test.STM32F1xx_DFP.pdsc"))
            assert root.find("devices/family/sequences/sequence").get("name") == "ResetSystem"
            assert root.find("devices/family/memory").get("start") == "0x08000000"
            assert root.find("components") is None
        # Corrupt a generated artifact: restore it deterministically from the verified cache.
        compact.write_bytes(b"corrupt")
        second = packs.prepare(output, lockfile, cache)
        assert second == first
        assert compact.read_bytes() == data
        assert {p.name for p in output.iterdir()} == {compact.name, "index.json"}


@pytest.mark.parametrize("missing", ["Flash/internal.FLM", "SVD/f103.svd", "Debug/device.dbgconf"])
def test_missing_runtime_files_fail_without_replacing_existing_index(tmp_path, missing):
    output, _, _, lockfile, cache = fixture(tmp_path, missing=missing)
    index = output / "index.json"
    index.write_text("previous successful build", encoding="utf-8")
    with pytest.raises(ValueError, match="Missing runtime resource"):
        packs.prepare(output, lockfile, cache)
    assert index.read_text(encoding="utf-8") == "previous successful build"
    assert not list(output.glob("*.tmp"))


def test_wrong_download_digest_is_rejected_without_publishing(tmp_path):
    import io
    output, original, _, lockfile, cache = fixture(tmp_path)
    original.unlink()
    with patch.object(packs.urllib.request, "urlopen", return_value=io.BytesIO(b"wrong content")):
        with pytest.raises(ValueError, match="SHA-256 mismatch"):
            packs.prepare(output, lockfile, cache)
    assert not list(cache.iterdir())
    assert not (output / "index.json").exists()


def test_incomplete_chip_family_is_rejected(tmp_path):
    output, _, source, lockfile, cache = fixture(tmp_path)
    source["expectedTargetCount"] = 3
    lockfile.write_text(json.dumps({"packs": [source]}), encoding="utf-8")
    with pytest.raises(ValueError, match="Unexpected compact target catalogue"):
        packs.prepare(output, lockfile, cache)
    assert not (output / "index.json").exists()


def test_upstream_cache_cannot_be_shipped_inside_output(tmp_path):
    with pytest.raises(ValueError, match="cache must be outside"):
        packs.prepare(tmp_path, tmp_path / "unused.json", tmp_path / "cache")
