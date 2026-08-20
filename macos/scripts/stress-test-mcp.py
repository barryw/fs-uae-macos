#!/usr/bin/env python3
import base64
import json
import re
import sys
import time
import urllib.request
from pathlib import Path

URL = "http://127.0.0.1:6800/mcp"
CONFIGURATION = sys.argv[1] if len(sys.argv) > 1 else "A4000"
DIAGNOSTIC = Path(__file__).resolve().parents[2] / ".build/amiga/FSUAE-Diag"
request_id = 0


def call(name, arguments, timeout=330):
    global request_id
    request_id += 1
    body = json.dumps({
        "jsonrpc": "2.0", "id": request_id, "method": "tools/call",
        "params": {"name": name, "arguments": arguments},
    }).encode()
    request = urllib.request.Request(URL, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        payload = json.load(response)
    result = payload["result"]
    text = "\n".join(row.get("text", "") for row in result.get("content", []))
    if result.get("isError"):
        raise RuntimeError(text)
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return text


def start():
    assert call("fsuae_machines_list", {}) == []
    result = call("fsuae_machine_start", {"configuration": CONFIGURATION})
    return re.search(r"machine_id ([0-9a-f-]+)", result).group(1)


def wait_ready(machine):
    call("fsuae_machine_wait", {
        "machine_id": machine, "condition": "workbench", "timeout_seconds": 120,
    }, 150)


def stop(machine):
    call("fsuae_machine_stop", {"machine_id": machine}, 30)
    assert call("fsuae_machines_list", {}) == []


def execute(machine, command, timeout=30):
    result = call("fsuae_command_execute", {
        "machine_id": machine, "command": command, "timeout_seconds": timeout,
    }, timeout + 20)
    assert result["status"] == "completed", result
    return result


def install_diagnostic(machine):
    if not DIAGNOSTIC.is_file():
        raise RuntimeError("run macos/scripts/build-amiga-tools.sh first")
    call("fsuae_exchange_put", {
        "machine_id": machine, "name": "FSUAE-Diag",
        "data_base64": base64.b64encode(DIAGNOSTIC.read_bytes()).decode(),
    })


def poll(request, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = call("fsuae_command_result", {"request_id": request})
        if result["status"] != "running":
            return result
        time.sleep(0.05)
    raise TimeoutError(request)


machine = None
try:
    print(f"{CONFIGURATION}: boot", flush=True)
    machine = start()
    wait_ready(machine)
    install_diagnostic(machine)
    for index in range(50):
        result = execute(machine, "MCP:FSUAE-Diag PING")
        assert result["succeeded"]
        assert not result["exit_code_known"] or result["exit_code"] == 0
        assert result["output"].strip() == "PING ok"
        if index % 10 == 9:
            print(f"{CONFIGURATION}: {index + 1}/50 commands", flush=True)

    print(f"{CONFIGURATION}: file round-trip", flush=True)
    data = bytes(range(256)) * 16
    put = call("fsuae_file_put", {
        "machine_id": machine, "path": "MCP:guest-stress.bin",
        "data_base64": base64.b64encode(data).decode(),
    })
    assert poll(put["request_id"])["succeeded"]
    get = call("fsuae_file_get", {"machine_id": machine, "path": "MCP:guest-stress.bin"})
    fetched = poll(get["request_id"])
    assert fetched["succeeded"] and base64.b64decode(fetched["data_base64"]) == data

    print(f"{CONFIGURATION}: stale response and timeout recovery", flush=True)
    slow = call("fsuae_command_run", {
        "machine_id": machine, "command": "MCP:FSUAE-Diag WAIT",
    })
    stale = bytes([0x31, 0x31, 0, 0, 0, 0, 0xde, 0xad, 0xbe, 0xef])
    call("fsuae_exchange_put", {
        "machine_id": machine, "name": "FSUAE-Control-Status",
        "data_base64": base64.b64encode(stale).decode(),
    })
    stale_result = call("fsuae_command_result", {"request_id": slow["request_id"]})
    assert stale_result["status"] == "running", stale_result
    assert poll(slow["request_id"], 10)["succeeded"]

    timed_out = call("fsuae_command_execute", {
        "machine_id": machine, "command": "MCP:FSUAE-Diag WAIT", "timeout_seconds": 1,
    }, 20)
    assert timed_out["status"] == "timeout"
    diagnostics = call("fsuae_machine_diagnostics", {"machine_id": machine})
    assert diagnostics["guest_command_status"] == "timeout"
    call("fsuae_machine_reset", {"machine_id": machine, "hard": True})
    call("fsuae_machine_wait", {
        "machine_id": machine, "condition": "workbench", "timeout_seconds": 120,
    }, 150)
    assert execute(machine, "MCP:FSUAE-Diag PING")["output"].strip() == "PING ok"
    stop(machine)
    machine = None

    for cycle in range(3):
        print(f"{CONFIGURATION}: lifecycle {cycle + 1}/3", flush=True)
        machine = start()
        wait_ready(machine)
        install_diagnostic(machine)
        assert execute(machine, "MCP:FSUAE-Diag PING")["output"].strip() == "PING ok"
        stop(machine)
        machine = None
    print(f"{CONFIGURATION} guest service stress passed: 50 repeated commands, file round-trip, stale status, timeout recovery, 4 lifecycle cycles")
finally:
    if machine:
        try:
            stop(machine)
        except Exception as error:
            print(f"cleanup failed: {error}")
