from __future__ import annotations

import argparse
import json
import os
import queue
import shutil
import subprocess
import sys
import threading
import time
import traceback
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def write_json_atomic(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + "." + os.urandom(8).hex() + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, ensure_ascii=False), encoding="utf-8")
    os.replace(temporary, path)


def csharp_string(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


class McpClient:
    def __init__(self, python_executable: str, server_path: str) -> None:
        self._process = subprocess.Popen(
            [python_executable, server_path],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
        )
        self._lines: queue.Queue[str | None] = queue.Queue()
        self._stderr: list[str] = []
        self._request_id = 0
        threading.Thread(target=self._read_stdout, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()

    def _read_stdout(self) -> None:
        assert self._process.stdout is not None
        for line in self._process.stdout:
            self._lines.put(line)
        self._lines.put(None)

    def _read_stderr(self) -> None:
        assert self._process.stderr is not None
        for line in self._process.stderr:
            self._stderr.append(line.rstrip())

    def _send(self, payload: dict[str, Any]) -> None:
        if self._process.stdin is None:
            raise RuntimeError("MCP standard input is unavailable")
        self._process.stdin.write(json.dumps(payload, separators=(",", ":")) + "\n")
        self._process.stdin.flush()

    def request(self, method: str, parameters: dict[str, Any], timeout: float) -> dict[str, Any]:
        self._request_id += 1
        request_id = self._request_id
        self._send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": parameters})
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"Timed out waiting for MCP response to {method}")
            try:
                line = self._lines.get(timeout=remaining)
            except queue.Empty as exception:
                raise TimeoutError(f"Timed out waiting for MCP response to {method}") from exception
            if line is None:
                raise RuntimeError("MCP server stopped unexpectedly: " + "\n".join(self._stderr[-20:]))
            response = json.loads(line)
            if response.get("id") == request_id:
                return response

    def start(self, timeout: float) -> None:
        response = self.request(
            "initialize",
            {
                "protocolVersion": "2025-11-25",
                "capabilities": {},
                "clientInfo": {"name": "bim-bridge-autocad-live-test", "version": "2.0"},
            },
            timeout,
        )
        if "result" not in response:
            raise RuntimeError("MCP initialization failed: " + json.dumps(response))
        self._send({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})

    def call_tool(
        self,
        name: str,
        arguments: dict[str, Any],
        timeout: float,
        allow_error: bool = False,
    ) -> dict[str, Any]:
        response = self.request("tools/call", {"name": name, "arguments": arguments}, timeout)
        if "error" in response:
            raise RuntimeError(f"MCP protocol error from {name}: {response['error']}")
        result = response["result"]
        structured = result.get("structuredContent")
        if not isinstance(structured, dict):
            raise RuntimeError(f"MCP tool {name} returned no structured content")
        if result.get("isError") and not allow_error:
            raise RuntimeError(f"MCP tool {name} failed: {structured}")
        return structured

    def close(self) -> None:
        try:
            if self._process.stdin is not None:
                self._process.stdin.close()
        except OSError:
            pass
        try:
            self._process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self._process.kill()
            self._process.wait(timeout=5)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def add_check(report: dict[str, Any], name: str, message: str, evidence: Any = None) -> None:
    check: dict[str, Any] = {"name": name, "passed": True, "message": message}
    if evidence is not None:
        check["evidence"] = evidence
    report["checks"].append(check)


def wait_for_instance(
    mcp: McpClient,
    process: subprocess.Popen[Any],
    version: str,
    timeout: float,
) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"AutoCAD exited before connector discovery (exit code {process.returncode})")
        listed = mcp.call_tool(
            "aec_list_instances",
            {"application": "autocad", "applicationVersion": version},
            min(30.0, timeout),
        )
        for instance in listed.get("instances", []):
            if instance.get("processId") == process.pid and instance.get("document"):
                return instance
        time.sleep(0.5)
    raise TimeoutError("Timed out waiting for the exact AutoCAD connector instance and active document")


def wait_for_exit(process: subprocess.Popen[Any], timeout: float) -> None:
    try:
        process.wait(timeout=timeout)
    except subprocess.TimeoutExpired as exception:
        raise TimeoutError("Timed out waiting for clean AutoCAD shutdown") from exception


def archive_stale_descriptor(run_directory: Path, process_id: int) -> str | None:
    app_data = os.environ.get("APPDATA")
    if not app_data:
        return None
    descriptor = Path(app_data) / "BIM Bridge" / "instances" / f"autocad-2024-{process_id}.json"
    if not descriptor.is_file():
        return None
    try:
        value = json.loads(descriptor.read_text(encoding="utf-8-sig"))
        if value.get("processId") != process_id:
            return None
        destination = run_directory / "stale-descriptor-after-forced-exit.json"
        shutil.move(str(descriptor), str(destination))
        return str(destination)
    except (OSError, ValueError, json.JSONDecodeError):
        return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--autocad-exe", required=True)
    parser.add_argument("--adapter-assembly", required=True)
    parser.add_argument("--mcp-server", required=True)
    parser.add_argument("--script", required=True)
    parser.add_argument("--run-directory", required=True)
    parser.add_argument("--certification-root", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--timeout-seconds", required=True, type=int)
    options = parser.parse_args()

    run_directory = Path(options.run_directory).resolve()
    certification_root = Path(options.certification_root).resolve()
    require(run_directory.is_relative_to(certification_root), "Run directory escaped certification root")
    require(options.version == "2024", "The current AutoCAD live driver supports only the 2024 baseline")
    require(Path(options.autocad_exe).is_file(), "AutoCAD executable does not exist")
    require(Path(options.adapter_assembly).is_file(), "AutoCAD adapter assembly does not exist")
    require(Path(options.mcp_server).is_file(), "BIM Bridge MCP server does not exist")
    require(Path(options.script).is_file(), "AutoCAD startup script does not exist")

    report_path = run_directory / "report.json"
    drawing_path = run_directory / f"BIM-Bridge-AutoCAD-{options.run_id}.dwg"
    shutdown_failure_path = run_directory / "shutdown-failure.txt"
    report: dict[str, Any] = {
        "schemaVersion": 1,
        "runId": options.run_id,
        "status": "running",
        "application": "autocad",
        "applicationVersion": options.version,
        "startedAtUtc": utc_now(),
        "runDirectory": str(run_directory),
        "autocadExecutable": str(Path(options.autocad_exe).resolve()),
        "adapterAssembly": str(Path(options.adapter_assembly).resolve()),
        "drawingPath": str(drawing_path),
        "forcedProcessTermination": False,
        "checks": [],
    }
    write_json_atomic(report_path, report)

    process: subprocess.Popen[Any] | None = None
    mcp: McpClient | None = None
    try:
        add_check(report, "preflight", "All AutoCAD live-test inputs passed safety validation.")
        mcp = McpClient(sys.executable, options.mcp_server)
        mcp.start(min(30.0, float(options.timeout_seconds)))
        process = subprocess.Popen(
            [options.autocad_exe, "/nologo", "/b", options.script],
            cwd=str(Path(options.autocad_exe).parent),
        )
        report["processId"] = process.pid
        write_json_atomic(report_path, report)

        instance = wait_for_instance(mcp, process, options.version, float(options.timeout_seconds))
        report["instanceId"] = instance["instanceId"]
        report["documentTitle"] = instance["document"]["title"]
        add_check(report, "connector_discovery", "The exact AutoCAD connector process was discovered through MCP.", instance)

        target = {
            "application": "autocad",
            "applicationVersion": options.version,
            "instanceId": instance["instanceId"],
            "documentTitle": instance["document"]["title"],
        }
        info = mcp.call_tool("aec_get_document_info", target, 30.0)
        require(info.get("application") == "autocad", "Connector routed to the wrong application")
        require(info.get("applicationVersion") == options.version, "Connector routed to the wrong AutoCAD version")
        require(info.get("processId") == process.pid, "Connector routed to the wrong process")
        add_check(report, "exact_routing", "Application, version, process, and document routing all matched.", info)

        selection = mcp.call_tool("aec_get_selection", target, 30.0)
        require(selection.get("count") == 0, "Disposable AutoCAD drawing did not start with an empty selection")
        add_check(report, "selection", "The disposable drawing started with an empty selection.", selection)

        read = mcp.call_tool(
            "aec_execute_read",
            {
                **target,
                "description": "Read AutoCAD live-test identity and adapter location",
                "code": (
                    "return new { title = document.Name, filename = database.Filename, "
                    "version = Autodesk.AutoCAD.ApplicationServices.Core.Application.Version.ToString(), "
                    "processId = System.Diagnostics.Process.GetCurrentProcess().Id, "
                    "adapter = AppDomain.CurrentDomain.GetAssemblies().Where(assembly => "
                    "assembly.GetName().Name == \"BimBridge.AutoCAD2024\").Select(assembly => assembly.Location).Single() };"
                ),
            },
            30.0,
        )
        require(read.get("status") == "succeeded", "AutoCAD identity read did not succeed")
        read_result = read["result"]
        require(read_result.get("processId") == process.pid, "Dynamic read executed in the wrong process")
        require(
            Path(read_result["adapter"]).resolve() == Path(options.adapter_assembly).resolve(),
            "AutoCAD loaded the adapter from an unexpected location",
        )
        report["autocadBuild"] = read_result.get("version")
        add_check(report, "read", "Dynamic read executed in the exact test adapter and AutoCAD process.", read)

        layer_name = "BIM_BRIDGE_LIVE_" + options.run_id.upper()
        layer_literal = csharp_string(layer_name)
        write = mcp.call_tool(
            "aec_execute_write",
            {
                **target,
                "description": "Create one disposable AutoCAD certification marker",
                "code": (
                    f"var layerName = {layer_literal}; "
                    "var layerTable = (LayerTable)transaction.GetObject(database.LayerTableId, OpenMode.ForRead); "
                    "if (!layerTable.Has(layerName)) { layerTable.UpgradeOpen(); var layer = new LayerTableRecord(); "
                    "layer.Name = layerName; layerTable.Add(layer); transaction.AddNewlyCreatedDBObject(layer, true); } "
                    "var blockTable = (BlockTable)transaction.GetObject(database.BlockTableId, OpenMode.ForRead); "
                    "var modelSpace = (BlockTableRecord)transaction.GetObject(blockTable[BlockTableRecord.ModelSpace], OpenMode.ForWrite); "
                    "var marker = new DBPoint(new Autodesk.AutoCAD.Geometry.Point3d(12345.678, 87654.321, 0)); "
                    "marker.Layer = layerName; modelSpace.AppendEntity(marker); transaction.AddNewlyCreatedDBObject(marker, true); "
                    "return new { handle = marker.Handle.ToString(), layer = layerName, type = marker.GetRXClass().Name };"
                ),
            },
            30.0,
        )
        require(write.get("status") == "succeeded", "AutoCAD marker write did not succeed")
        require(write.get("rolledBack") is False, "Successful AutoCAD write incorrectly reported rollback")
        add_check(report, "write", "Disposable AutoCAD marker committed successfully.", write)

        count_code = (
            f"var layerName = {layer_literal}; var blockTable = (BlockTable)transaction.GetObject(database.BlockTableId, OpenMode.ForRead); "
            "var modelSpace = (BlockTableRecord)transaction.GetObject(blockTable[BlockTableRecord.ModelSpace], OpenMode.ForRead); "
            "var count = 0; foreach (ObjectId id in modelSpace) { var entity = transaction.GetObject(id, OpenMode.ForRead, false) as Entity; "
            "if (entity != null && entity.Layer == layerName) count++; } return new { count = count, layer = layerName };"
        )
        read_back = mcp.call_tool(
            "aec_execute_read",
            {**target, "description": "Read back the committed AutoCAD certification marker", "code": count_code},
            30.0,
        )
        require(read_back.get("result", {}).get("count") == 1, "Committed AutoCAD marker was not found exactly once")
        add_check(report, "write_readback", "Committed AutoCAD marker was found exactly once.", read_back)

        rollback = mcp.call_tool(
            "aec_execute_write",
            {
                **target,
                "description": "Verify complete AutoCAD rollback after intentional failure",
                "code": (
                    f"var layerName = {layer_literal}; var blockTable = (BlockTable)transaction.GetObject(database.BlockTableId, OpenMode.ForRead); "
                    "var modelSpace = (BlockTableRecord)transaction.GetObject(blockTable[BlockTableRecord.ModelSpace], OpenMode.ForWrite); "
                    "var marker = new DBPoint(new Autodesk.AutoCAD.Geometry.Point3d(54321.123, 98765.432, 0)); marker.Layer = layerName; "
                    "modelSpace.AppendEntity(marker); transaction.AddNewlyCreatedDBObject(marker, true); "
                    'throw new InvalidOperationException("BIM_BRIDGE_EXPECTED_AUTOCAD_ROLLBACK");'
                ),
            },
            30.0,
            allow_error=True,
        )
        require(rollback.get("status") == "failed", "Intentional AutoCAD write failure did not report failed status")
        require(rollback.get("rolledBack") is True, "Intentional AutoCAD write failure did not report rollback")
        add_check(report, "rollback_signal", "Intentional AutoCAD failure returned failed with rolledBack=true.", rollback)

        rollback_read_back = mcp.call_tool(
            "aec_execute_read",
            {**target, "description": "Verify failed AutoCAD write left no drawing changes", "code": count_code},
            30.0,
        )
        require(rollback_read_back.get("result", {}).get("count") == 1, "AutoCAD rollback changed the committed marker count")
        add_check(report, "rollback_readback", "Failed AutoCAD write left no entity behind.", rollback_read_back)

        cleanup = mcp.call_tool(
            "aec_execute_write",
            {
                **target,
                "description": "Delete the disposable AutoCAD certification marker",
                "code": (
                    f"var layerName = {layer_literal}; var blockTable = (BlockTable)transaction.GetObject(database.BlockTableId, OpenMode.ForRead); "
                    "var modelSpace = (BlockTableRecord)transaction.GetObject(blockTable[BlockTableRecord.ModelSpace], OpenMode.ForRead); "
                    "var deleted = 0; foreach (ObjectId id in modelSpace) { var entity = transaction.GetObject(id, OpenMode.ForRead, false) as Entity; "
                    "if (entity != null && entity.Layer == layerName) { entity.UpgradeOpen(); entity.Erase(); deleted++; } } "
                    "return new { deleted = deleted, layer = layerName };"
                ),
            },
            30.0,
        )
        require(cleanup.get("result", {}).get("deleted") == 1, "AutoCAD marker cleanup did not delete exactly one entity")
        add_check(report, "cleanup", "Disposable AutoCAD marker was deleted.", cleanup)

        shutdown_code = (
            f"var drawingPath = {csharp_string(str(drawing_path))}; var failurePath = {csharp_string(str(shutdown_failure_path))}; "
            "System.EventHandler handler = null; handler = delegate(object sender, EventArgs args) { "
            "Autodesk.AutoCAD.ApplicationServices.Core.Application.Idle -= handler; try { "
            "database.SaveAs(drawingPath, DwgVersion.Current); "
            "Autodesk.AutoCAD.ApplicationServices.DocumentExtension.CloseAndDiscard(document); "
            "Autodesk.AutoCAD.ApplicationServices.Core.Application.Quit(); } catch (Exception exception) { "
            "System.IO.File.WriteAllText(failurePath, exception.ToString()); } }; "
            "Autodesk.AutoCAD.ApplicationServices.Core.Application.Idle += handler; return new { shutdownQueued = true, drawingPath = drawingPath };"
        )
        shutdown = mcp.call_tool(
            "aec_execute_write",
            {**target, "description": "Save and close the disposable AutoCAD certification drawing", "code": shutdown_code},
            30.0,
        )
        require(shutdown.get("status") == "succeeded", "AutoCAD shutdown request did not queue successfully")
        wait_for_exit(process, min(120.0, float(options.timeout_seconds)))
        if shutdown_failure_path.exists():
            raise RuntimeError("AutoCAD shutdown callback failed: " + shutdown_failure_path.read_text(encoding="utf-8"))
        require(drawing_path.is_file(), "Disposable AutoCAD drawing was not saved before shutdown")
        add_check(report, "clean_shutdown", "AutoCAD saved the disposable drawing and shut down cleanly.")

        listed_after = mcp.call_tool(
            "aec_list_instances",
            {"application": "autocad", "applicationVersion": options.version},
            30.0,
        )
        remains = any(item.get("processId") == process.pid for item in listed_after.get("instances", []))
        require(not remains, "AutoCAD connector descriptor remained after clean shutdown")
        add_check(report, "descriptor_cleanup", "Connector descriptor was removed during AutoCAD shutdown.", listed_after)

        report["status"] = "passed"
        report["endedAtUtc"] = utc_now()
        write_json_atomic(report_path, report)
        print(json.dumps(report, indent=2, ensure_ascii=False))
        return 0
    except Exception as exception:
        report["status"] = "failed"
        report["failureCode"] = "autocad_live_acceptance_failed"
        report["failureMessage"] = str(exception)
        report["failureTrace"] = traceback.format_exc()
        if process is not None and process.poll() is None:
            process.kill()
            process.wait(timeout=15)
            report["forcedProcessTermination"] = True
        if process is not None:
            archived = archive_stale_descriptor(run_directory, process.pid)
            if archived:
                report["archivedStaleDescriptor"] = archived
        report["endedAtUtc"] = utc_now()
        write_json_atomic(report_path, report)
        print(json.dumps(report, indent=2, ensure_ascii=False))
        return 1
    finally:
        if mcp is not None:
            mcp.close()


if __name__ == "__main__":
    raise SystemExit(main())
