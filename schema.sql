-- schema.sql
-- Run once to initialize the database:
--   sqlite3 pastebin.db < schema.sql

PRAGMA journal_mode = WAL;

CREATE TABLE IF NOT EXISTS pastes (
    id          TEXT PRIMARY KEY,
    -- Opaque ciphertext: iv (12 bytes) || AES-256-GCM ciphertext+tag (16-byte
    -- tag included). The server never decrypts this and never validates its
    -- encoding — it's binary, not UTF-8 text, by design. 1 MiB cap on the
    -- plaintext plus the fixed 12+16=28 byte overhead.
    ciphertext  BLOB NOT NULL CHECK (length(ciphertext) <= 1048604),
    created_at  INTEGER NOT NULL,  -- unix epoch seconds
    expires_at  INTEGER NOT NULL   -- unix epoch seconds, created_at + 90 days
);

CREATE INDEX IF NOT EXISTS idx_pastes_expires_at ON pastes (expires_at);
