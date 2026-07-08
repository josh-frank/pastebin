-- schema.sql
-- Run once to initialize the database:
--   sqlite3 pastebin.db < schema.sql

PRAGMA journal_mode = WAL;

CREATE TABLE IF NOT EXISTS pastes (
    id          TEXT PRIMARY KEY,
    content     TEXT NOT NULL CHECK (length(content) <= 1048576), -- 1 MiB cap
    created_at  INTEGER NOT NULL,  -- unix epoch seconds
    expires_at  INTEGER NOT NULL   -- unix epoch seconds, created_at + 90 days
);

CREATE INDEX IF NOT EXISTS idx_pastes_expires_at ON pastes (expires_at);
