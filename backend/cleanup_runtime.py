import os
import time
from pathlib import Path

from app.db import get_conn

EXPORT_DIR = Path(os.getenv("PHOTO_EXPORT_DIR", Path(__file__).resolve().parent / "exported_faces"))


def run_cleanup() -> tuple[int, int]:
    now = int(time.time())
    with get_conn() as conn:
        deactivated = conn.execute(
            "UPDATE qr_sessions SET active = FALSE WHERE active = TRUE AND expires_at < %s",
            (now,),
        ).rowcount or 0

    removed = 0
    if EXPORT_DIR.exists():
        for img in EXPORT_DIR.glob("*.jpg"):
            try:
                if img.stat().st_mtime < (now - 7 * 24 * 3600):
                    img.unlink()
                    removed += 1
            except Exception:
                continue

    return deactivated, removed


if __name__ == "__main__":
    deactivated, removed = run_cleanup()
    print(f"Cleanup done: deactivated_sessions={deactivated}, removed_exported_files={removed}")
