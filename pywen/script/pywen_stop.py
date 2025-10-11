#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Pywen Stop/SubagentStop hook:
- 读取 session_id -> 尝试从 /tmp/agent-done/session_cases/<session_id>.case 取 case_id
- 将 "<case_id> DONE\n" 写入 FIFO: /tmp/agent-done/pywen.done
  * POSIX: 非阻塞写入 FIFO；失败则写入 fallback 日志文件
  * 非 POSIX(Windows): 直接写入 fallback 日志文件
- 通过 JSON stdout 返回 systemMessage，提示用户该 hook 已执行（不阻断）
"""

import os
import sys
import json
from pathlib import Path

FIFO_DIR = Path(os.environ.get("FIFO_DIR", "/tmp/agent-done"))
FIFO_PATH = FIFO_DIR / "pywen.done"
FALLBACK_LOG = FIFO_DIR / "pywen.done.log"
CASE_DIR = FIFO_DIR / "session_cases"
CASE_DIR.mkdir(parents=True, exist_ok=True)
FIFO_DIR.mkdir(parents=True, exist_ok=True)


def parse_stdin_json() -> dict:
    raw = sys.stdin.read()
    try:
        return json.loads(raw) if raw else {}
    except Exception:
        return {}


def extract_session_id(data: dict) -> str:
    for k in ("session_id", "sessionId", "sessionID", "sid"):
        v = data.get(k)
        if isinstance(v, str) and v:
            return v
    sess = data.get("session")
    if isinstance(sess, dict):
        v = sess.get("id")
        if isinstance(v, str) and v:
            return v
    return f"pid_{os.getpid()}"


def read_case_id(session_id: str) -> str:
    p = CASE_DIR / f"{session_id}.case"
    try:
        if p.exists():
            txt = p.read_text(encoding="utf-8", errors="ignore").strip()
            if txt:
                return txt.splitlines()[0].strip()
    except Exception:
        pass
    return "UNKNOWN"


def write_done(case_id: str) -> str:
    """
    返回写入方式的描述：'fifo' 或 'file'
    """
    try:
        if not FIFO_PATH.exists() or not FIFO_PATH.is_fifo():
            if FIFO_PATH.exists():
                FIFO_PATH.unlink(missing_ok=True)
            os.mkfifo(str(FIFO_PATH))
    except Exception:
        try:
            with open(FALLBACK_LOG, "a", encoding="utf-8") as w:
                w.write(f"{case_id} DONE\n")
            return "file"
        except Exception:
            return "file"

    try:
        fd = os.open(str(FIFO_PATH), os.O_WRONLY | os.O_NONBLOCK)
        try:
            os.write(fd, f"{case_id} DONE\n".encode("utf-8"))
        finally:
            os.close(fd)
        return "fifo"
    except OSError as e:
        try:
            with open(FALLBACK_LOG, "a", encoding="utf-8") as w:
                w.write(f"{case_id} DONE\n")
            return "file"
        except Exception:
            return "file"


def main() -> int:
    data = parse_stdin_json()
    session_id = extract_session_id(data)
    case_id = read_case_id(session_id)
    mode = write_done(case_id)

    print(json.dumps({
        "systemMessage": f"✅ [Stop] Recorded DONE for CASE_ID={case_id} (via {mode})."
    }))
    return 0

if __name__ == "__main__":
    sys.exit(main())

