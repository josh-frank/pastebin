# pastebin

Minimal UTF-8-only pastebin. `POST` to create, `GET /<id>` to read. No auth, no listing, no delete. Pastes expire after 90 days.

## Layout

```
app.py                      Flask app (routes + logic)
wsgi.py                     gunicorn entry point
schema.sql                  SQLite schema (run once)
cleanup.py                  Deletes expired rows, run periodically
requirements.txt            Python deps
nginx.conf                  Example reverse-proxy site config
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

```bash
# create a paste
curl --data-binary @somefile.txt http://localhost:8000/
# -> http://localhost:8000/aB3xY9Qz

# read it back
curl http://localhost:8000/aB3xY9Qz
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

- Max paste size: 1 MiB (enforced by nginx `client_max_body_size`, a Flask
  check, and a SQLite `CHECK` constraint — belt and suspenders).
- Content must be valid UTF-8 or the POST is rejected with 400.
- IDs are 8-char url-safe random tokens (`secrets.token_urlsafe(6)`), not
  sequential, so pastes can't be enumerated.
- Expiration is enforced two ways: lazily on GET (expired rows are deleted
  and 404 returned), and via the daily `pastebin-cleanup.timer` sweep.
