CREATE TABLE IF NOT EXISTS sheet_keys_snapshot (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  snapshot_date TEXT    NOT NULL,            -- YYYY-MM-DD (Vietnam date)
  tier          TEXT    NOT NULL,            -- 'intraday' | 'h1' | 'h4' | 'daily' | 'week'
  level         REAL    NOT NULL,
  created_at    TEXT    NOT NULL DEFAULT (datetime('now')),
  UNIQUE(snapshot_date, tier, level)
);

CREATE INDEX IF NOT EXISTS idx_sheet_keys_date
  ON sheet_keys_snapshot (snapshot_date DESC);
CREATE INDEX IF NOT EXISTS idx_sheet_keys_date_tier
  ON sheet_keys_snapshot (snapshot_date DESC, tier);
