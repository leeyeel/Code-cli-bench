#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Pywen UserPromptSubmit hook:
- 识别形如 "CASE_ID=xxxx" 的提示词
- 将 case_id 落盘到 $FIFO_DIR/session_cases/<session_id>.case
- 以 JSON 协议返回 {"decision":"block","reason": "..."} 来阻断本次 prompt（内容不进入上下文）
"""

import os
import sys
import json
import re
from pathlib import Path

FIFO_BASE = Path(os.environ.get("FIFO_DIR", "/tmp/agent-done"))
CASE_DIR = FIFO_BASE / "session_cases"
CASE_DIR.mkdir(parents=True, exist_ok=True)

PROMPT_KEYS_IN = ("prompt", "user_prompt", "userPrompt")
CASE_RE = re.compile(r"^CASE_ID=([^\s\"']+)\s*$", re.IGNORECASE)


def parse_stdin_json() -> dict:
    raw = sys.stdin.read()
    try:
        return json.loads(raw)
    except Exception:
        return {}


def extract_prompt(data: dict) -> str:
    for k in PROMPT_KEYS_IN:
        v = data.get(k)
        if isinstance(v, str):
            return v
    inp = data.get("input")
    if isinstance(inp, dict):
        for k in PROMPT_KEYS_IN:
            v = inp.get(k)
            if isinstance(v, str):
                return v
    return ""


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


def write_session_case(session_id: str, case_id: str) -> None:
    path = CASE_DIR / f"{session_id}.case"
    try:
        path.write_text(case_id + "\n", encoding="utf-8")
    except Exception:
        pass

def main() -> int:
    data = parse_stdin_json()
    prompt = extract_prompt(data)
    session_id = extract_session_id(data)

    m = CASE_RE.match(prompt or "")
    if not m:
        print(json.dumps({}))
        return 0

    case_id = m.group(1)
    write_session_case(session_id, case_id)

    print(json.dumps({
        "decision": "block",
        "reason": f"已记录 CASE_ID={case_id}，本条提示不会进入上下文。"
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())

