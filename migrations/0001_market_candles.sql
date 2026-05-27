CREATE TABLE IF NOT EXISTS market_candles (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  symbol      TEXT    NOT NULL,
  timeframe   INTEGER NOT NULL DEFAULT 15,
  open_time   TEXT    NOT NULL,
  open        REAL    NOT NULL,
  high        REAL    NOT NULL,
  low         REAL    NOT NULL,
  close       REAL    NOT NULL,
  tick_volume INTEGER NOT NULL DEFAULT 0,

  ma_fast         REAL,
  ma_mid          REAL,
  ma_slow         REAL,
  ma_fast_period  INTEGER,
  ma_mid_period   INTEGER,
  ma_slow_period  INTEGER,

  rsi         REAL,
  rsi_period  INTEGER,

  pivot       REAL,
  r1          REAL,
  r2          REAL,
  r3          REAL,
  s1          REAL,
  s2          REAL,
  s3          REAL,

  fib_high    REAL,
  fib_low     REAL,
  fib_0       REAL,
  fib_236     REAL,
  fib_382     REAL,
  fib_500     REAL,
  fib_618     REAL,
  fib_786     REAL,
  fib_100     REAL,

  created_at  TEXT NOT NULL DEFAULT (datetime('now')),

  UNIQUE(symbol, timeframe, open_time)
);

CREATE INDEX IF NOT EXISTS idx_market_candles_symbol_time
  ON market_candles (symbol, timeframe, open_time DESC);
