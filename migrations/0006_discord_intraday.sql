CREATE TABLE discord_intraday_levels (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  msg_id      TEXT NOT NULL UNIQUE,
  source_date TEXT NOT NULL,
  levels      TEXT NOT NULL,
  fetched_at  TEXT NOT NULL DEFAULT (datetime('now'))
);
