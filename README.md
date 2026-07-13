# pastebin

End-to-end encrypted pastebin. `POST` to create (client encrypts before sending), `GET /<id>` to fetch ciphertext (client decrypts after receiving). No auth, no listing, no delete. Pastes expire after 90 days.

The server only ever stores and serves opaque ciphertext bytes — it never sees plaintext content or the decryption key.

## Layout

```
app.py                      Flask app (routes + logic) -- stores/serves ciphertext only
wsgi.py                     gunicorn entry point
schema.sql                  SQLite schema (run once)
cleanup.py                  Deletes expired rows, run periodically
requirements.txt            Python deps
nginx.conf                  Example reverse-proxy site config (API + static frontend)
pastebin.html               Static frontend: create a paste (encrypts client-side)
view.html                   Static frontend: view a paste (decrypts client-side)
pastebin.service            systemd unit: gunicorn app server
pastebin-cleanup.service    systemd unit: one-shot cleanup run
pastebin-cleanup.timer      systemd timer: runs cleanup.service daily
```

## Local setup

```bash
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt

sqlite3 pastebin.db < schema.sql

# dev server
python3 app.py
# or, closer to prod:
gunicorn --workers 2 --bind 127.0.0.1:8000 wsgi:app
```

## Usage

Encryption/decryption is client-side JS (`pastebin.html` / `view.html`), so raw `curl` against the API alone can no longer produce a readable paste -- you'd be posting/reading ciphertext. To try it end to end, open `pastebin.html` in a browser (with `BACKEND_URL` pointed at your running API), paste some text, and follow the link it gives you.

```bash
# what curl sees is ciphertext, not text -- useful for checking the API is up,
# not for actually reading a paste:
curl --data-binary @encrypted-blob http://localhost:8000/
# -> http://localhost:8000/aB3xY9Qz   (real deploys: https://paste.example.com/aB3xY9Qz)

curl http://localhost:8000/aB3xY9Qz   # returns opaque bytes, not text
```

## Production deploy sketch

1. `mkdir -p /opt/pastebin`, copy this directory there, create a venv, `pip install -r requirements.txt`.
2. `sqlite3 /opt/pastebin/pastebin.db < schema.sql`
3. Create a dedicated `pastebin` user/group owning `/opt/pastebin`.
4. Copy `pastebin.service`, `pastebin-cleanup.service`, `pastebin-cleanup.timer`
   into `/etc/systemd/system/`, then:
   ```bash
   systemctl daemon-reload
   systemctl enable --now pastebin.service
   systemctl enable --now pastebin-cleanup.timer
   ```
5. Copy `nginx.conf` into `/etc/nginx/sites-available/pastebin`, symlink into
   `sites-enabled`, add the `limit_req_zone` line to the `http {}` block in
   your main nginx.conf, then `nginx -t && systemctl reload nginx`.
6. Point DNS at the box, optionally add TLS (certbot) in the nginx server
   block.

## Notes / limits

- **End-to-end encryption**: `pastebin.html` generates a random AES-256-GCM key
  per paste, encrypts client-side, and appends the key to the share URL as a
  fragment (`#...`) -- fragments are never sent in HTTP requests, so the key
  never reaches this server or its logs. `view.html` fetches the ciphertext
  and decrypts using that fragment. Losing the link means losing the paste;
  there's no recovery path, by design.
- Max ciphertext size: 1 MiB + 28 bytes (IV + GCM tag) — enforced by nginx
  `client_max_body_size`, a Flask check, and a SQLite `CHECK` constraint —
  belt and suspenders.
- Content is opaque binary; the server does not validate or interpret it in
  any way (previously required valid UTF-8 — that check is gone, since
  ciphertext isn't text).
- IDs are 8-char url-safe random tokens (`secrets.token_urlsafe(6)`), not
  sequential, so pastes can't be enumerated.
- Expiration is enforced two ways: lazily on GET (expired rows are deleted
  and 404 returned), and via the daily `pastebin-cleanup.timer` sweep.
- The API (`p.example.com`) and the static frontend (`paste.example.com`) are
  different origins in the example nginx config, so `GET /<id>` sets
  `Access-Control-Allow-Origin` (via `PASTEBIN_FRONTEND_ORIGIN`) to let
  `view.html` fetch cross-origin.
