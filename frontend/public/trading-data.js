/* ════════════════════════════════════════════════════════════
   trading-data.js — DATA LAYER
   ────────────────────────────────────────────────────────────
   Plain JS, no Astro processing. Served from /trading-data.js.
   Loaded as a classic <script src="..."> before the inline UI
   script in index.astro.

   Exposes window.TradingData with:
     getMaData()        → mutable maData object (UI may write to it)
     getIntradayKeys()  → mutable INTRADAY_KEYS array
     getTurnKeys()      → mutable TURN_KEYS object
     getLatestPrice()   → current latest H1 price (number)
     setLatestPrice(p)  → update latest price (fires priceUpdate callbacks)
     getManualDailyMAs(), getManualWeeklyMAs() → fallback constants
     onUpdate(fn)       → register callback fired after refresh()
     onPriceUpdate(fn)  → register callback fired by setLatestPrice
     refresh()          → fetch all timeframes from internal API
     init()             → loadKeysFromSheet + refresh(false) + scheduleRefresh
     scheduleRefresh()  → align to HH:01 auto-refresh

   The data layer owns: API URLs, cache, fetch logic, scheduler.
   The UI layer owns:   render functions, DOM updates, tooltips.
   ════════════════════════════════════════════════════════════ */
(function () {
  'use strict';

  /* ── constants ── */
  const MA_SOURCE = 'internal';
  const INTERNAL_API_BASE = 'https://trading.boredstudio.ai/api/market-candles';
  const INTERNAL_SYMBOL   = 'XAUUSD';
  const TF_MINUTES = { H1: 60, H4: 240, D: 1440, W: 10080 };

  const MA_CACHE_KEY    = 'ma_cache_v21_internal';
  const MA_CACHE_TTL_MS = 7 * 24 * 60 * 60 * 1000;  // 1 week

  const MA_PERIODS = [5, 21, 50, 100, 200];
  const MA_TYPE    = { 5: 'EMA', 21: 'SMA', 50: 'SMA', 100: 'SMA', 200: 'SMA' };

  // Manual D/W MA fallback constants (used when API fails)
  const MANUAL_DAILY_MAS = {
    EMA5:   4665,
    SMA21:  4697,
    SMA50:  4780,
    SMA100: 4778,
    SMA200: 4308,
  };
  const MANUAL_WEEKLY_MAS = {
    EMA5:   4707,
    SMA21:  4764,
    SMA50:  4134,
    SMA100: 3436,
    SMA200: 2690,
  };

  /* ── state ── */
  // maData is the central object — both data and UI layers read/write it.
  // The UI gets a live reference via getMaData(), so direct property writes
  // (e.g. maData.fibD = ...) propagate transparently.
  let maData = {};

  // Intraday levels — fallback hardcoded values overwritten by /api/keys.
  let INTRADAY_KEYS = [
    4886.24, 4851.37, 4822.26, 4790.81, 4756.62,
    4684.33, 4646.51, 4605.77, 4564.14,
  ];

  // Turn-key levels per timeframe.
  let TURN_KEYS = {
    H1: [5025, 4927, 4837, 4749, 4673, 4587, 4503, 4425, 4351, 4263],
    H4: [5350, 5250, 5134, 4972, 4852, 4730, 4592, 4468, 4343, 4221, 4074],
    D:  [5236, 4900, 4587, 4362, 4128, 3719],
    W:  [5104, 4763, 4462, 4338],
  };

  let LATEST_PRICE = 4687;

  let refreshTimer = null;
  const updateCallbacks = [];
  const priceCallbacks = [];

  /* ── small math helpers ── */
  function classifySignal(price, ma) {
    if (ma == null) return { sig: '—', sigClass: 'sig-neut' };
    const diff = (price - ma) / ma;
    if (diff >  0.02)  return { sig: 'Strong Buy',  sigClass: 'sig-sbuy'  };
    if (diff >  0.005) return { sig: 'Buy',         sigClass: 'sig-buy'   };
    if (diff < -0.02)  return { sig: 'Strong Sell', sigClass: 'sig-ssell' };
    if (diff < -0.005) return { sig: 'Sell',        sigClass: 'sig-sell'  };
    return                    { sig: 'Neutral',     sigClass: 'sig-neut'  };
  }
  function fmtPrice(n) {
    if (n == null || !isFinite(n)) return '—';
    return Math.round(n).toLocaleString('en-US');
  }

  function buildInternalMaResult(row) {
    const price = row.close;
    const maValues = [row.maFast, row.maMid, row.maSlow, row.maFour, row.maFive];
    const rows = MA_PERIODS.map((period, i) => {
      const value = maValues[i];
      const name = `${MA_TYPE[period]}${period}`;
      if (value == null || !isFinite(value)) return { name, value: '—', sig: '—', sigClass: 'sig-neut' };
      const { sig, sigClass } = classifySignal(price, value);
      return { name, value: fmtPrice(value), sig, sigClass };
    });
    return { rows, price };
  }

  function buildManualMaResult(manualMas, tfLabel) {
    const price = LATEST_PRICE;
    console.log(`[MA ${tfLabel}] provider=manual  using constants from MANUAL_${tfLabel}_MAS`);
    const rows = MA_PERIODS.map(period => {
      const name = `${MA_TYPE[period]}${period}`;
      const value = manualMas[name];
      const valid = value != null && isFinite(value);
      const { sig, sigClass } = valid
        ? classifySignal(price, value)
        : { sig: '—', sigClass: 'sig-neut' };
      return {
        name,
        value: valid ? fmtPrice(value) : '—',
        sig, sigClass,
      };
    });
    return { rows, price, highs: [], lows: [], closes: [] };
  }

  /* ── cache ── */
  function readCache() {
    try {
      const raw = localStorage.getItem(MA_CACHE_KEY);
      if (!raw) return null;
      const { ts, payload } = JSON.parse(raw);
      if (Date.now() - ts > MA_CACHE_TTL_MS) return null;
      return { ts, payload };
    } catch (e) { return null; }
  }
  function writeCache(payload) {
    try {
      localStorage.setItem(MA_CACHE_KEY, JSON.stringify({ ts: Date.now(), payload }));
    } catch (e) { /* quota exceeded — ignore */ }
  }

  /* ── fetch ── */
  async function fetchInternal(tfLabel) {
    const minutes = TF_MINUTES[tfLabel];
    const url = `${INTERNAL_API_BASE}?symbol=${INTERNAL_SYMBOL}&timeframe=${minutes}&limit=1`;
    const res = await fetch(url);
    if (!res.ok) throw new Error(`Internal API HTTP ${res.status}`);
    const json = await res.json();
    const row = json.data?.[0];
    if (!row) throw new Error(`No ${tfLabel} data from internal API`);
    return row;
  }

  async function loadKeysFromSheet() {
    try {
      const res = await fetch('/api/keys');
      if (!res.ok) return false;
      const d = await res.json();
      if (d.intradayKeys?.length) {
        INTRADAY_KEYS.length = 0;
        for (const v of d.intradayKeys) INTRADAY_KEYS.push(v);
      }
      if (d.h1Turn?.length)    TURN_KEYS.H1 = d.h1Turn;
      if (d.h4Turn?.length)    TURN_KEYS.H4 = d.h4Turn;
      if (d.dailyTurn?.length) TURN_KEYS.D  = d.dailyTurn;
      if (d.weekTurn?.length)  TURN_KEYS.W  = d.weekTurn;
      return true;
    } catch (e) {
      console.warn('[Keys] Sheet fetch failed:', e.message);
      return false;
    }
  }

  /* ── main refresh: fetch all timeframes + populate maData ── */
  async function refresh(forceRefresh = false) {
    // 1) Load cache if present
    const cached = readCache();
    if (cached) {
      // Replace maData contents in place to preserve external refs
      for (const k of Object.keys(maData)) delete maData[k];
      Object.assign(maData, cached.payload);
    }

    // 2) On non-forced calls, return cached data without fetching.
    //    Fresh data only arrives via the HH:01 scheduled timer (force=true).
    if (!forceRefresh && cached) {
      const tfTs = (maData && maData._tfTs) || {};
      // Backfill latestH1 from cached H1 closes array if direct field missing
      if (maData.latestH1 == null && maData.closes && Array.isArray(maData.closes.H1) && maData.closes.H1.length) {
        maData.latestH1 = maData.closes.H1[maData.closes.H1.length - 1];
      }
      if (maData.latestH1 != null && !maData.latestH1Source) {
        maData.latestH1Source = MA_SOURCE;
      }
      if (maData.dailyOpen != null && !maData.dailyOpenTs && tfTs.D) {
        maData.dailyOpenTs = tfTs.D;
      }
      _fireUpdate({ source: 'cache', cachedAt: cached.ts });
      return;
    }

    // 3) Fetch from internal API (all timeframes in parallel)
    _fireUpdate({ source: 'loading' });
    try {
      const [h1Res, h4Res, d1Res, w1Res] = await Promise.allSettled([
        fetchInternal('H1'),
        fetchInternal('H4'),
        fetchInternal('D'),
        fetchInternal('W'),
      ]);

      const newTs = { ...((maData && maData._tfTs) || {}) };
      if (!maData.closes) maData.closes = {};
      if (!maData.rsiPrecomputed) maData.rsiPrecomputed = {};

      if (h1Res.status === 'fulfilled') {
        const row = h1Res.value;
        maData['H1'] = buildInternalMaResult(row).rows;
        maData.closes['H1'] = [row.close];
        maData.rsiPrecomputed['H1'] = row.rsi;
        maData.latestH1 = row.close;
        maData.latestH1Source = 'internal';
        if (row.dayOpen != null) {
          maData.dailyOpen = row.dayOpen;
          maData.dailyOpenSource = 'h1-embedded';
          maData.dailyOpenTs = Date.now();
        }
        if (row.pivot != null) {
          maData.pivotsD = [
            { label: 'R3', value: row.r3 },
            { label: 'R2', value: row.r2 },
            { label: 'R1', value: row.r1 },
            { label: 'P',  value: row.pivot, isPivot: true },
            { label: 'S1', value: row.s1 },
            { label: 'S2', value: row.s2 },
            { label: 'S3', value: row.s3 },
          ];
        }
        newTs['H1'] = Date.now();
      } else {
        console.warn('[Internal API] H1 failed:', h1Res.reason?.message);
      }

      if (h4Res.status === 'fulfilled') {
        const row = h4Res.value;
        maData['H4'] = buildInternalMaResult(row).rows;
        maData.closes['H4'] = [row.close];
        maData.rsiPrecomputed['H4'] = row.rsi;
        newTs['H4'] = Date.now();
      } else {
        console.warn('[Internal API] H4 failed:', h4Res.reason?.message);
      }

      if (d1Res.status === 'fulfilled') {
        const row = d1Res.value;
        maData['D'] = buildInternalMaResult(row).rows;
        maData.closes['D'] = [row.close];
        maData.rsiPrecomputed['D'] = row.rsi;
        maData.dailyOpen = row.open;
        maData.dailyOpenSource = 'internal';
        maData.dailyOpenTs = Date.now();
        if (row.pivot) {
          maData.pivotsD = [
            { label: 'R2', value: row.r2 },
            { label: 'R1', value: row.r1 },
            { label: 'P',  value: row.pivot, isPivot: true },
            { label: 'S1', value: row.s1 },
            { label: 'S2', value: row.s2 },
          ];
        }
        if (row.fibHigh && row.fibLow) {
          maData.fibD = {
            high: row.fibHigh, low: row.fibLow,
            isUptrend: row.fibHigh > row.fibLow,
            rows: [
              { pct: 0.236, value: row.fib236 },
              { pct: 0.382, value: row.fib382 },
              { pct: 0.500, value: row.fib500 },
              { pct: 0.618, value: row.fib618 },
              { pct: 0.786, value: row.fib786 },
            ],
          };
        }
        newTs['D'] = Date.now();
      } else {
        console.warn('[Internal API] D failed:', d1Res.reason?.message);
        maData.D = buildManualMaResult(MANUAL_DAILY_MAS, 'D').rows;
      }

      if (w1Res.status === 'fulfilled') {
        const row = w1Res.value;
        maData['W'] = buildInternalMaResult(row).rows;
        maData.closes['W'] = [row.close];
        if (row.pivot) {
          maData.pivotsW = [
            { label: 'R2', value: row.r2 },
            { label: 'R1', value: row.r1 },
            { label: 'P',  value: row.pivot, isPivot: true },
            { label: 'S1', value: row.s1 },
            { label: 'S2', value: row.s2 },
          ];
        }
        if (row.fibHigh && row.fibLow) {
          maData.fibW = {
            high: row.fibHigh, low: row.fibLow,
            isUptrend: row.fibHigh > row.fibLow,
            rows: [
              { pct: 0.236, value: row.fib236 },
              { pct: 0.382, value: row.fib382 },
              { pct: 0.500, value: row.fib500 },
              { pct: 0.618, value: row.fib618 },
              { pct: 0.786, value: row.fib786 },
            ],
          };
        }
        newTs['W'] = Date.now();
      } else {
        console.warn('[Internal API] W failed:', w1Res.reason?.message);
        maData.W = buildManualMaResult(MANUAL_WEEKLY_MAS, 'W').rows;
      }

      maData._tfTs = newTs;
      writeCache(maData);

      _fireUpdate({ source: 'internal', fetchedAt: newTs.H1 || Date.now() });
    } catch (e) {
      console.error('[Internal API] fatal:', e);
      _fireUpdate({ source: 'error', error: e });
    }
  }

  /* ── scheduler: align to next HH:01:00 ── */
  function scheduleRefresh() {
    if (refreshTimer) clearTimeout(refreshTimer);
    const now = new Date();
    const next = new Date(now);
    next.setMinutes(1, 0, 0);
    if (next <= now) {
      next.setHours(next.getHours() + 1);
    }
    const delay = next - now;
    refreshTimer = setTimeout(() => {
      refresh(true).finally(scheduleRefresh);
    }, delay);
  }

  /* ── callbacks ── */
  function onUpdate(fn) {
    if (typeof fn === 'function') updateCallbacks.push(fn);
  }
  function onPriceUpdate(fn) {
    if (typeof fn === 'function') priceCallbacks.push(fn);
  }
  function _fireUpdate(info) {
    for (const fn of updateCallbacks) {
      try { fn(info); } catch (e) { console.error('[TradingData] update callback failed:', e); }
    }
  }
  function _firePriceUpdate(price) {
    for (const fn of priceCallbacks) {
      try { fn(price); } catch (e) { console.error('[TradingData] price callback failed:', e); }
    }
  }

  /* ── init: kick off keys + first refresh + scheduler ── */
  async function init() {
    // Kick keys fetch in parallel; do not await, but fire update when it lands
    loadKeysFromSheet().then(ok => {
      if (ok) _fireUpdate({ source: 'keys' });
    });
    await refresh(false);
    scheduleRefresh();
  }

  /* ── public API ── */
  window.TradingData = {
    // Live mutable references
    getMaData:        () => maData,
    getIntradayKeys:  () => INTRADAY_KEYS,
    getTurnKeys:      () => TURN_KEYS,

    // Primitive accessors
    getLatestPrice:   () => LATEST_PRICE,
    setLatestPrice:   (p) => {
      if (p == null || !isFinite(p)) return;
      const changed = p !== LATEST_PRICE;
      LATEST_PRICE = p;
      if (changed) _firePriceUpdate(p);
    },

    // Manual fallback constants
    getManualDailyMAs:  () => MANUAL_DAILY_MAS,
    getManualWeeklyMAs: () => MANUAL_WEEKLY_MAS,

    // Subscriptions
    onUpdate,
    onPriceUpdate,

    // Lifecycle
    refresh,
    init,
    scheduleRefresh,

    // Internal helpers exported so UI can reuse the same formatting/signal logic
    fmtPrice,
    classifySignal,
    buildInternalMaResult,
    buildManualMaResult,

    // Source label (for status pill)
    MA_SOURCE,
  };
})();
