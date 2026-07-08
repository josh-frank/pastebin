"""
Minimal UTF-8 pastebin.

  POST /        -> body is raw text (UTF-8). Returns the paste URL as plain text.
  GET  /<id>    -> returns raw paste content as text/plain, or 404.

No auth, no listing, no delete. Expired pastes are lazily deleted on GET
and also swept periodically by cleanup.py (see systemd timer unit).
"""

import os
import secrets
import sqlite3
import time
from contextlib import contextmanager

from flask import Flask, abort, request, Response

DB_PATH = os.environ.get("PASTEBIN_DB", os.path.join(os.path.dirname(__file__), "pastebin.db"))
MAX_BYTES = 1024 * 1024          # 1 MiB cap, matches schema.sql CHECK constraint
EXPIRY_SECONDS = 90 * 24 * 60 * 60  # 90 days
ID_BYTES = 6                      # -> 8 url-safe base64 chars, ~2^48 keyspace
MAX_ID_RETRIES = 5

app = Flask(__name__)


@contextmanager
def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


def new_id() -> str:
    return secrets.token_urlsafe(ID_BYTES)


@app.post("/")
def create_paste():
    raw = request.get_data()  # raw bytes, no size limit applied by Flask here;
                              # real enforcement is nginx client_max_body_size + the check below

    if len(raw) > MAX_BYTES:
        abort(413, description=f"Paste too large; max {MAX_BYTES} bytes")

    try:
        content = raw.decode("utf-8", errors="strict")
    except UnicodeDecodeError:
        abort(400, description="Body must be valid UTF-8 text")

    if not content:
        abort(400, description="Empty paste")

    now = int(time.time())
    expires_at = now + EXPIRY_SECONDS

    with get_db() as db:
        for _ in range(MAX_ID_RETRIES):
            paste_id = new_id()
            try:
                db.execute(
                    "INSERT INTO pastes (id, content, created_at, expires_at) VALUES (?, ?, ?, ?)",
                    (paste_id, content, now, expires_at),
                )
                break
            except sqlite3.IntegrityError:
                continue  # id collision, try again
        else:
            abort(500, description="Could not allocate paste id")

    base_url = request.host_url.rstrip("/")
    return Response(f"{base_url}/{paste_id}\n", mimetype="text/plain", status=201)


@app.get("/<paste_id>")
def get_paste(paste_id):
    now = int(time.time())

    with get_db() as db:
        row = db.execute(
            "SELECT content, expires_at FROM pastes WHERE id = ?", (paste_id,)
        ).fetchone()

        if row is None:
            abort(404, description="Paste not found")

        content, expires_at = row
        if expires_at < now:
            db.execute("DELETE FROM pastes WHERE id = ?", (paste_id,))
            abort(404, description="Paste not found")

    return Response(content, mimetype="text/plain", headers={
        'Content-Type': 'text/plain; charset=utf-8',
        'X-Content-Type-Options': 'nosniff'
    })


@app.errorhandler(400)
@app.errorhandler(404)
@app.errorhandler(413)
@app.errorhandler(500)
def plain_text_error(e):
    description = getattr(e, "description", "Error")
    code = getattr(e, "code", 500)
    return Response(f"{description}\n", mimetype="text/plain", status=code)


if __name__ == "__main__":
    # Dev server only. Use gunicorn (see wsgi.py) behind nginx in production.
    app.run(debug=True, port=5000)
