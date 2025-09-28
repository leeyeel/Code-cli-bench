import os

FIFO_DIR = os.environ.get("FIFO_DIR", "/tmp/agent-done")
FIFO_PATH = os.path.join(FIFO_DIR, "pywen.done")

def notify_pywen_done(case_id: str) -> None:
    """在 Pywen 的“本轮完全结束”处调用，向 FIFO 写入 '<CASE_ID> DONE'。"""
    try:
        os.makedirs(FIFO_DIR, exist_ok=True)
        if not os.path.exists(FIFO_PATH):
            os.mkfifo(FIFO_PATH)
        with open(FIFO_PATH, "w", encoding="utf-8") as w:
            w.write(f"{case_id} DONE\n")
    except Exception:
        pass
