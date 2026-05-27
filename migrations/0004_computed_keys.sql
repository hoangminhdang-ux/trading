CREATE TABLE IF NOT EXISTS computed_keys (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  symbol        TEXT    NOT NULL,
  tier          TEXT    NOT NULL,        -- 'intraday' | 'h1' | 'h4' | 'd1' | 'master'
  level         REAL    NOT NULL,
  side          TEXT    NOT NULL,        -- 'historical' | 'forward'
  source_count  INTEGER NOT NULL,
  tier_mask     INTEGER,                 -- bitmask of contributing tiers (master rows only)
  confluence    INTEGER,                 -- popcount(tier_mask) for master rows
  bid_ref       REAL    NOT NULL,
  computed_at   TEXT    NOT NULL,
  created_at    TEXT    NOT NULL DEFAULT (datetime('now')),
  UNIQUE(symbol, tier, level, computed_at)
);

CREATE INDEX IF NOT EXISTS idx_computed_keys_symbol_time
  ON computed_keys (symbol, computed_at DESC);
CREATE INDEX IF NOT EXISTS idx_computed_keys_tier_time
  ON computed_keys (symbol, tier, computed_at DESC);
