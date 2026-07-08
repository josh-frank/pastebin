"""
Deletes expired pastes. Intended to be run periodically (see
pastebin-cleanup.timer). Lazy expiration in app.py already hides expired
pastes from readers; this just reclaims disk space.

Usage:
    python3 cleanup.py
"""

import os
import sqlite3
import time

DB_PATH = os.environ.get("PASTEBIN_DB", os.path.join(os.path.dirname(__file__), "pastebin.db"))


def main():
    now = int(time.time())
    conn = sqlite3.connect(DB_PATH)
    try:
        cur = conn.execute("DELETE FROM pastes WHERE expires_at < ?", (now,))
        conn.commit()
        print(f"Deleted {cur.rowcount} expired paste(s)")
        conn.execute("VACUUM")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
