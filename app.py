"""
Minimal end-to-end encrypted pastebin.

  POST /        -> body is raw ciphertext bytes (iv || AES-256-GCM ciphertext+tag),
                   produced client-side by pastebin.html. Returns the paste URL
                   (pointing at the frontend viewer, with the key in the URL
                   fragment) as plain text.
  GET  /<id>    -> returns raw ciphertext bytes as application/octet-stream, or 404.
                   Decryption happens entirely in the browser (see view.html) —
                   this server never sees plaintext or the key.

No auth, no listing, no delete. Expired pastes are lazily deleted on GET
and also swept periodically by cleanup.py (see systemd timer unit).

The server is intentionally blind to content: it stores and serves opaque
bytes, and has no way to distinguish one paste's content from another's.
"""

import os
import secrets
import sqlite3
import time
from contextlib import contextmanager

from flask import Flask, abort, request, Response

DB_PATH = os.environ.get("PASTEBIN_DB", os.path.join(os.path.dirname(__file__), "pastebin.db"))
MAX_BYTES = 1024 * 1024 + 28      # 1 MiB plaintext cap + 12-byte IV + 16-byte GCM tag,
                                  # matches schema.sql CHECK constraint
EXPIRY_SECONDS = 90 * 24 * 60 * 60  # 90 days
ID_BYTES = 6                      # -> 8 url-safe base64 chars, ~2^48 keyspace
MAX_ID_RETRIES = 5

# The static frontend (pastebin.html / view.html) is deployed on a separate
# origin from this API — see nginx.conf's second server block. The create
# response needs to point there, not at this backend's own host, and the
# GET route needs to grant that origin CORS access so view.html can fetch
# ciphertext cross-origin. Set this explicitly in prod (pastebin.service);
# falls back to the request's own origin for local single-host dev.
FRONTEND_ORIGIN = os.environ.get("PASTEBIN_FRONTEND_ORIGIN")

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
    ciphertext = request.get_data()  # raw bytes: iv (12) || AES-256-GCM ciphertext+tag,
                                      # produced client-side. No size limit applied by
                                      # Flask here; real enforcement is nginx
                                      # client_max_body_size + the check below.

    if len(ciphertext) > MAX_BYTES:
        abort(413, description=f"Paste too large; max {MAX_BYTES} bytes")

    if not ciphertext:
        abort(400, description="Empty paste")

    # No UTF-8 validation: ciphertext is opaque binary by design. The server
    # cannot and does not attempt to interpret paste content.

    now = int(time.time())
    expires_at = now + EXPIRY_SECONDS

    with get_db() as db:
        for _ in range(MAX_ID_RETRIES):
            paste_id = new_id()
            try:
                db.execute(
                    "INSERT INTO pastes (id, ciphertext, created_at, expires_at) VALUES (?, ?, ?, ?)",
                    (paste_id, ciphertext, now, expires_at),
                )
                break
            except sqlite3.IntegrityError:
                continue  # id collision, try again
        else:
            abort(500, description="Could not allocate paste id")

    # Points at the static frontend (view.html handles the id + decrypts using
    # the key the caller appends as a URL fragment), not at this API host.
    frontend_origin = (FRONTEND_ORIGIN or request.host_url).rstrip("/")
    return Response(f"{frontend_origin}/{paste_id}\n", mimetype="text/plain", status=201)


@app.get("/<paste_id>")
def get_paste(paste_id):
    now = int(time.time())

    with get_db() as db:
        row = db.execute(
            "SELECT ciphertext, expires_at FROM pastes WHERE id = ?", (paste_id,)
        ).fetchone()

        if row is None:
            abort(404, description="Paste not found")

        ciphertext, expires_at = row
        if expires_at < now:
            db.execute("DELETE FROM pastes WHERE id = ?", (paste_id,))
            abort(404, description="Paste not found")

    # Served as opaque bytes — this route has no idea what it's returning.
    # Decryption (using the key from the URL fragment, which never reaches
    # this server) happens entirely in view.html.
    #
    # CORS: view.html is served from a different origin (see nginx.conf), so
    # it needs explicit permission to fetch() this cross-origin. A plain GET
    # with no custom request headers is a "simple request" under the CORS
    # spec, so no preflight (OPTIONS) is needed — this response header alone
    # is sufficient.
    headers = {
        'Content-Type': 'application/octet-stream',
        'X-Content-Type-Options': 'nosniff',
    }
    if FRONTEND_ORIGIN:
        headers['Access-Control-Allow-Origin'] = FRONTEND_ORIGIN
    else:
        # Local single-host dev fallback: reflect the requesting origin so
        # `python3 app.py` + opening pastebin.html from the same box works
        # without extra config. Set PASTEBIN_FRONTEND_ORIGIN explicitly in
        # prod instead of relying on this.
        headers['Access-Control-Allow-Origin'] = request.headers.get('Origin', '*')
        headers['Vary'] = 'Origin'

    return Response(ciphertext, headers=headers)


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
