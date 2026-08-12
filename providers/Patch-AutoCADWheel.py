#!/usr/bin/env python3
"""Apply AEC Codex's pinned AutoCAD MCP 1.5.1 COM fixes to a wheel."""

from __future__ import annotations

import argparse
import base64
import csv
import hashlib
import io
import os
from pathlib import Path
import tempfile
import zipfile


TARGET = "backends/com_backend.py"
MARKER = "# AEC_CODEX_PATCH: autocad-pro-v1.5.1-live-com-fixes-v2"
LEGACY_MARKER = "# AEC_CODEX_PATCH: autocad-pro-v1.5.1-live-com-fixes"


def replace_once(source: str, old: str, new: str, label: str) -> str:
    count = source.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one source block, found {count}")
    return source.replace(old, new, 1)


def patch_source(source: str) -> str:
    if MARKER in source:
        verify_source(source)
        return source
    if LEGACY_MARKER in source:
        source = source.replace(LEGACY_MARKER, MARKER, 1)
        source = replace_once(
            source,
            'self._safe_send_command(doc, "_.UNDO\\n_BACK\\n", deadline_s=30.0)',
            'self._safe_send_command(doc, "_.UNDO\\n_1\\n", deadline_s=30.0)',
            "upgrade rollback from UNDO Back to one grouped undo",
        )
        verify_source(source)
        return source

    get_count = source.count("app.GetVariable(")
    set_count = source.count("app.SetVariable(")
    if get_count != 11 or set_count != 7:
        raise RuntimeError(
            "AutoCAD provider system-variable call surface changed: "
            f"expected 11 GetVariable and 7 SetVariable calls, found {get_count} and {set_count}"
        )
    source = source.replace("app.GetVariable(", "doc.GetVariable(")
    source = source.replace("app.SetVariable(", "doc.SetVariable(")

    source = replace_once(
        source,
        """    async def system_get_variable(self, name) -> Any:
        def _sync():
            app = _acad_app()
            return doc.GetVariable(name)
""",
        """    async def system_get_variable(self, name) -> Any:
        def _sync():
            doc = _acad_doc()
            return doc.GetVariable(name)
""",
        "system_get_variable document routing",
    )
    source = replace_once(
        source,
        """    async def system_set_variable(self, name, value) -> dict:
        def _sync():
            app = _acad_app()
""",
        """    async def system_set_variable(self, name, value) -> dict:
        def _sync():
            doc = _acad_doc()
""",
        "system_set_variable document routing",
    )

    source = replace_once(
        source,
        '                doc.SendCommand("_AUDIT Y\\n")',
        '                self._safe_send_command(doc, "_.AUDIT\\n_YES\\n", deadline_s=60.0)',
        "AUDIT command completion",
    )
    source = replace_once(
        source,
        """                    "AUDIT was dispatched to AutoCAD with fixing enabled. SendCommand "
                    "queues the command and returns immediately, so this call cannot "
                    "confirm that it ran, let alone what it changed: the repair and "
                    "error counts are unknown, not zero. AutoCAD writes an .adt log "
                    "beside the drawing when AUDITCTL is on — that is the only place "
                    "the detail exists."
""",
        """                    "AUDIT completed in AutoCAD with fixing enabled. The COM API "
                    "does not expose repair/error counts, so they remain unknown rather "
                    "than being reported as zero. When available, the .adt log contains "
                    "the detailed audit result."
""",
        "AUDIT result description",
    )

    source = replace_once(
        source,
        '            self._safe_send_command(doc, "_UNDO B")',
        '            self._safe_send_command(doc, "_.UNDO\\n_1\\n", deadline_s=30.0)',
        "UNDO command syntax",
    )

    source = replace_once(
        source,
        """    async def entity_trim(self, target_handle, cutter_handle, keep_x, keep_y) -> EntityInfo:
        def _sync():
            doc = _acad_doc()
            cmd = f'_TRIM\\n(handent "{cutter_handle}")\\n\\n{float(keep_x)},{float(keep_y)}\\n\\n'
            self._safe_send_command(doc, cmd)
            ent = doc.HandleToObject(target_handle)
            return _entity_info(ent)

        return await self._run(_sync)
""",
        """    async def entity_trim(self, target_handle, cutter_handle, keep_x, keep_y) -> EntityInfo:
        def _sync():
            doc = _acad_doc()
            target = doc.HandleToObject(target_handle)
            cutter = doc.HandleToObject(cutter_handle)
            if target.ObjectName != "AcDbLine" or cutter.ObjectName != "AcDbLine":
                raise ValueError("entity_trim currently supports LINE + LINE only")

            start = target.StartPoint
            end = target.EndPoint
            cut_start = cutter.StartPoint
            cut_end = cutter.EndPoint
            dx = float(end[0]) - float(start[0])
            dy = float(end[1]) - float(start[1])
            cdx = float(cut_end[0]) - float(cut_start[0])
            cdy = float(cut_end[1]) - float(cut_start[1])
            denominator = dx * cdy - dy * cdx
            if abs(denominator) < 1e-12:
                raise ValueError("Cannot trim parallel lines")

            ox = float(cut_start[0]) - float(start[0])
            oy = float(cut_start[1]) - float(start[1])
            target_parameter = (ox * cdy - oy * cdx) / denominator
            if target_parameter <= 1e-9 or target_parameter >= 1.0 - 1e-9:
                raise ValueError("The cutter does not intersect the interior of the target line")

            length_squared = dx * dx + dy * dy
            if length_squared <= 1e-18:
                raise ValueError("Cannot trim a zero-length line")
            keep_parameter = (
                (float(keep_x) - float(start[0])) * dx
                + (float(keep_y) - float(start[1])) * dy
            ) / length_squared
            if abs(keep_parameter - target_parameter) <= 1e-9:
                raise ValueError("keep point lies on the trim intersection")

            z = float(start[2]) + target_parameter * (float(end[2]) - float(start[2]))
            intersection = _apoint(
                float(start[0]) + target_parameter * dx,
                float(start[1]) + target_parameter * dy,
                z,
            )
            if keep_parameter < target_parameter:
                target.EndPoint = intersection
            else:
                target.StartPoint = intersection
            target.Update()
            _regen()
            return _entity_info(target)

        return await self._run(_sync)
""",
        "deterministic LINE trim",
    )

    source = MARKER + "\n" + source
    verify_source(source)
    return source


def verify_source(source: str) -> None:
    required = (
        MARKER,
        'self._safe_send_command(doc, "_.AUDIT\\n_YES\\n", deadline_s=60.0)',
        'self._safe_send_command(doc, "_.UNDO\\n_1\\n", deadline_s=30.0)',
        "target.EndPoint = intersection",
        "target.StartPoint = intersection",
        "doc.GetVariable(name)",
        "doc.SetVariable(name, coerced)",
    )
    missing = [item for item in required if item not in source]
    if missing:
        raise RuntimeError(f"AutoCAD provider patch verification failed; missing {missing}")
    if "app.GetVariable(" in source or "app.SetVariable(" in source:
        raise RuntimeError("AutoCAD Application-level system-variable calls remain")
    compile(source, TARGET, "exec")


def wheel_record(entries: dict[str, bytes], record_name: str) -> bytes:
    stream = io.StringIO(newline="")
    writer = csv.writer(stream, lineterminator="\n")
    for name in sorted(entries):
        if name == record_name:
            continue
        data = entries[name]
        digest = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode("ascii")
        writer.writerow((name, f"sha256={digest}", str(len(data))))
    writer.writerow((record_name, "", ""))
    return stream.getvalue().encode("utf-8")


def process_wheel(path: Path, verify_only: bool) -> None:
    with zipfile.ZipFile(path, "r") as archive:
        infos = archive.infolist()
        entries = {info.filename: archive.read(info.filename) for info in infos}
    if TARGET not in entries:
        raise RuntimeError(f"{TARGET} is missing from {path}")

    source = entries[TARGET].decode("utf-8")
    if verify_only:
        verify_source(source)
        print(f"Verified patched AutoCAD provider wheel: {path}")
        return

    entries[TARGET] = patch_source(source).encode("utf-8")
    record_names = [name for name in entries if name.endswith(".dist-info/RECORD")]
    if len(record_names) != 1:
        raise RuntimeError(f"Expected one wheel RECORD, found {len(record_names)}")
    record_name = record_names[0]
    entries[record_name] = wheel_record(entries, record_name)

    info_by_name = {info.filename: info for info in infos}
    handle, temporary = tempfile.mkstemp(prefix=path.stem + ".", suffix=".whl", dir=path.parent)
    os.close(handle)
    temporary_path = Path(temporary)
    try:
        with zipfile.ZipFile(temporary_path, "w") as archive:
            for info in infos:
                archive.writestr(info, entries[info.filename])
        os.replace(temporary_path, path)
    finally:
        temporary_path.unlink(missing_ok=True)
    print(f"Patched AutoCAD provider wheel: {path}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("wheel", type=Path)
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()
    process_wheel(args.wheel.resolve(), args.verify)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
