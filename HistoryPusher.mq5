//+------------------------------------------------------------------+
//| HistoryPusher.mq5                                                 |
//| One-shot historical backfill for marketCandles.                  |
//| Iterates H1/H4/D1/W1 bars in [StartDate, EndDate] and POSTs      |
//| each via the same /api/market-candles endpoint as DataPusher.    |
//|                                                                   |
//| SETUP:                                                            |
//|   1. Tools → Options → Expert Advisors → Allow WebRequest        |
//|      add https://trading.boredstudio.ai                          |
//|   2. Attach to any XAUUSD chart, set StartDate/EndDate, F7.      |
//|   3. EA self-removes when done. Watch Experts log for progress.  |
//+------------------------------------------------------------------+
#property strict
#property description "Backfills historical H1/H4/D1/W1 candles to trading.boredstudio.ai"

input string   ApiUrl       = "https://trading.boredstudio.ai/api/market-candles";
input string   EaSecret     = "";
input datetime StartDate    = D'2024.05.01 00:00';
input datetime EndDate      = D'2026.05.11 00:00';
input bool     EnableH1     = true;
input bool     EnableH4     = true;
input bool     EnableD1     = true;
input bool     EnableW1     = true;
input int      ThrottleMs   = 80;     // delay between POSTs
input int      Ma1Per       = 5;      // EMA5
input int      Ma2Per       = 21;     // SMA21
input int      Ma3Per       = 50;     // SMA50
input int      Ma4Per       = 100;    // SMA100
input int      Ma5Per       = 200;    // SMA200
input int      RsiPeriod    = 14;

#define MAX_TF 4

ENUM_TIMEFRAMES g_tfs[MAX_TF];
int             g_tfCount   = 0;
int             g_curTfIdx  = 0;

int      g_h1 = INVALID_HANDLE, g_h2 = INVALID_HANDLE, g_h3 = INVALID_HANDLE;
int      g_h4 = INVALID_HANDLE, g_h5 = INVALID_HANDLE, g_hRsi = INVALID_HANDLE;
int      g_curBars        = 0;     // total bars to push for current TF
int      g_curIdx         = 0;     // 0..g_curBars-1 (oldest→newest)
int      g_curStartShift  = 0;     // shift of oldest bar (= g_curBars-1+offset)
int      g_pushed         = 0;
int      g_failed         = 0;
int      g_skipped        = 0;
bool     g_done           = false;

//+------------------------------------------------------------------+
int OnInit()
{
   if (EaSecret == "")
   {
      Alert("HistoryPusher: EaSecret is empty. Set it in EA inputs.");
      return INIT_FAILED;
   }
   if (StartDate >= EndDate)
   {
      Alert("HistoryPusher: StartDate must be < EndDate.");
      return INIT_FAILED;
   }

   if (EnableH1) g_tfs[g_tfCount++] = PERIOD_H1;
   if (EnableH4) g_tfs[g_tfCount++] = PERIOD_H4;
   if (EnableD1) g_tfs[g_tfCount++] = PERIOD_D1;
   if (EnableW1) g_tfs[g_tfCount++] = PERIOD_W1;

   if (g_tfCount == 0)
   {
      Alert("HistoryPusher: no timeframes enabled.");
      return INIT_FAILED;
   }

   if (!PrepareTf(g_curTfIdx))
      return INIT_FAILED;

   PrintFormat("HistoryPusher: starting backfill %s → %s, %d TF(s), %d ms throttle",
               TimeToString(StartDate, TIME_DATE),
               TimeToString(EndDate,   TIME_DATE),
               g_tfCount, ThrottleMs);

   EventSetMillisecondTimer(MathMax(10, ThrottleMs));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   ReleaseHandles();
   EventKillTimer();
   PrintFormat("HistoryPusher: stopped. pushed=%d failed=%d skipped=%d",
               g_pushed, g_failed, g_skipped);
}

//+------------------------------------------------------------------+
void OnTimer()
{
   if (g_done) return;

   if (g_curIdx >= g_curBars)
   {
      // Current TF complete, advance
      ReleaseHandles();
      g_curTfIdx++;
      if (g_curTfIdx >= g_tfCount)
      {
         g_done = true;
         Comment(StringFormat("HistoryPusher DONE. pushed=%d failed=%d skipped=%d",
                              g_pushed, g_failed, g_skipped));
         PrintFormat("HistoryPusher: ALL DONE. pushed=%d failed=%d skipped=%d",
                     g_pushed, g_failed, g_skipped);
         ExpertRemove();
         return;
      }
      if (!PrepareTf(g_curTfIdx))
      {
         g_done = true;
         ExpertRemove();
         return;
      }
   }

   int shift = g_curStartShift - g_curIdx;   // oldest → newest
   if (PushBar(g_tfs[g_curTfIdx], shift))
      g_pushed++;
   else
      g_failed++;

   g_curIdx++;

   if ((g_curIdx % 25) == 0 || g_curIdx == g_curBars)
   {
      Comment(StringFormat("TF %s — %d / %d  (total pushed=%d failed=%d)",
                            EnumToString(g_tfs[g_curTfIdx]),
                            g_curIdx, g_curBars, g_pushed, g_failed));
   }
}

//+------------------------------------------------------------------+
bool PrepareTf(int idx)
{
   ENUM_TIMEFRAMES tf = g_tfs[idx];

   g_h1   = iMA (_Symbol, tf, Ma1Per, 0, MODE_EMA, PRICE_CLOSE);
   g_h2   = iMA (_Symbol, tf, Ma2Per, 0, MODE_SMA, PRICE_CLOSE);
   g_h3   = iMA (_Symbol, tf, Ma3Per, 0, MODE_SMA, PRICE_CLOSE);
   g_h4   = iMA (_Symbol, tf, Ma4Per, 0, MODE_SMA, PRICE_CLOSE);
   g_h5   = iMA (_Symbol, tf, Ma5Per, 0, MODE_SMA, PRICE_CLOSE);
   g_hRsi = iRSI(_Symbol, tf, RsiPeriod, PRICE_CLOSE);

   if (g_h1 == INVALID_HANDLE || g_h2 == INVALID_HANDLE || g_h3 == INVALID_HANDLE ||
       g_h4 == INVALID_HANDLE || g_h5 == INVALID_HANDLE || g_hRsi == INVALID_HANDLE)
   {
      PrintFormat("HistoryPusher: indicator handle fail on %s", EnumToString(tf));
      return false;
   }

   // Force history load by requesting a range copy
   MqlRates probe[];
   if (CopyRates(_Symbol, tf, StartDate, EndDate, probe) <= 0)
   {
      PrintFormat("HistoryPusher: CopyRates returned 0 for %s — broker may need more history. Retrying via series request.",
                  EnumToString(tf));
   }

   // Find shift bounds: newest bar at-or-before EndDate, oldest at-or-after StartDate
   int newestShift = iBarShift(_Symbol, tf, EndDate,   false);  // shift of bar containing EndDate
   int oldestShift = iBarShift(_Symbol, tf, StartDate, false);

   if (newestShift < 0 || oldestShift < 0 || oldestShift < newestShift)
   {
      PrintFormat("HistoryPusher: bad shift range for %s (oldest=%d newest=%d)",
                  EnumToString(tf), oldestShift, newestShift);
      g_curBars = 0;
      g_curStartShift = 0;
      g_curIdx = 0;
      return true;   // skip this TF but continue
   }

   g_curStartShift = oldestShift;
   g_curBars       = oldestShift - newestShift + 1;
   g_curIdx        = 0;

   PrintFormat("HistoryPusher: TF %s — %d bars (shift %d → %d)",
               EnumToString(tf), g_curBars, oldestShift, newestShift);

   // Allow indicator buffers to warm up
   Sleep(500);
   return true;
}

//+------------------------------------------------------------------+
void ReleaseHandles()
{
   if (g_h1   != INVALID_HANDLE) { IndicatorRelease(g_h1);   g_h1   = INVALID_HANDLE; }
   if (g_h2   != INVALID_HANDLE) { IndicatorRelease(g_h2);   g_h2   = INVALID_HANDLE; }
   if (g_h3   != INVALID_HANDLE) { IndicatorRelease(g_h3);   g_h3   = INVALID_HANDLE; }
   if (g_h4   != INVALID_HANDLE) { IndicatorRelease(g_h4);   g_h4   = INVALID_HANDLE; }
   if (g_h5   != INVALID_HANDLE) { IndicatorRelease(g_h5);   g_h5   = INVALID_HANDLE; }
   if (g_hRsi != INVALID_HANDLE) { IndicatorRelease(g_hRsi); g_hRsi = INVALID_HANDLE; }
}

//+------------------------------------------------------------------+
double ReadBuf(int handle, int shift)
{
   double buf[1];
   if (CopyBuffer(handle, 0, shift, 1, buf) > 0) return buf[0];
   return 0.0;
}

//+------------------------------------------------------------------+
bool PushBar(ENUM_TIMEFRAMES tf, int shift)
{
   MqlRates bars[];
   if (CopyRates(_Symbol, tf, shift, 1, bars) < 1)
   {
      g_skipped++;
      return false;
   }

   double ma1 = ReadBuf(g_h1,   shift);
   double ma2 = ReadBuf(g_h2,   shift);
   double ma3 = ReadBuf(g_h3,   shift);
   double ma4 = ReadBuf(g_h4,   shift);
   double ma5 = ReadBuf(g_h5,   shift);
   double rsi = ReadBuf(g_hRsi, shift);

   if (ma1 <= 0 || ma2 <= 0 || ma3 <= 0 || ma4 <= 0 || ma5 <= 0)
   {
      g_skipped++;
      return false;
   }

   // Pivot from prior daily (or weekly) bar at this point in time
   ENUM_TIMEFRAMES pivotTf = (tf == PERIOD_W1) ? PERIOD_W1 : PERIOD_D1;
   datetime barTime = bars[0].time;
   int pivotShiftNow = iBarShift(_Symbol, pivotTf, barTime, false);
   int pivotShift    = pivotShiftNow + 1;   // previous pivot-period bar

   MqlRates pivotBars[];
   double pivot = 0, r1 = 0, r2 = 0, r3 = 0, s1 = 0, s2 = 0, s3 = 0;
   if (pivotShift >= 0 && CopyRates(_Symbol, pivotTf, pivotShift, 1, pivotBars) >= 1)
   {
      double pH = pivotBars[0].high, pL = pivotBars[0].low, pC = pivotBars[0].close;
      pivot = (pH + pL + pC) / 3.0;
      r1 = 2*pivot - pL;     r2 = pivot + (pH - pL);     r3 = pH + 2*(pivot - pL);
      s1 = 2*pivot - pH;     s2 = pivot - (pH - pL);     s3 = pL - 2*(pH - pivot);
   }

   // Day open at the moment this bar started — D1 bar containing barTime
   double dayOpen = 0;
   int dShiftNow = iBarShift(_Symbol, PERIOD_D1, barTime, false);
   MqlRates dNow[];
   if (dShiftNow >= 0 && CopyRates(_Symbol, PERIOD_D1, dShiftNow, 1, dNow) >= 1)
      dayOpen = dNow[0].open;

   // Fib levels only for D1 and W1, from the same prior period used for pivot
   string fibPart = "";
   bool doFib = (tf == PERIOD_D1 || tf == PERIOD_W1);
   if (doFib && pivot > 0)
   {
      double fH = pivotBars[0].high, fL = pivotBars[0].low, range = fH - fL;
      fibPart = StringFormat(
         ",\"fibHigh\":%.5f,\"fibLow\":%.5f"
         ",\"fib0\":%.5f,\"fib236\":%.5f,\"fib382\":%.5f"
         ",\"fib500\":%.5f,\"fib618\":%.5f,\"fib786\":%.5f,\"fib100\":%.5f",
         fH, fL, fL,
         fL + range * 0.236, fL + range * 0.382,
         fL + range * 0.500, fL + range * 0.618,
         fL + range * 0.786, fH
      );
   }

   MqlDateTime dt;
   TimeToStruct(barTime, dt);
   string openTime = StringFormat("%04d-%02d-%02dT%02d:%02d:00Z",
                                  dt.year, dt.mon, dt.day, dt.hour, dt.min);
   int tfMinutes = (int)(PeriodSeconds(tf) / 60);

   string body = StringFormat(
      "{\"symbol\":\"%s\",\"timeframe\":%d,"
      "\"openTime\":\"%s\","
      "\"open\":%.5f,\"high\":%.5f,\"low\":%.5f,\"close\":%.5f,"
      "\"tickVolume\":%d,"
      "\"maFast\":%.5f,\"maFastPeriod\":%d,"
      "\"maMid\":%.5f,\"maMidPeriod\":%d,"
      "\"maSlow\":%.5f,\"maSlowPeriod\":%d,"
      "\"maFour\":%.5f,\"maFourPeriod\":%d,"
      "\"maFive\":%.5f,\"maFivePeriod\":%d,"
      "\"rsi\":%.2f,\"rsiPeriod\":%d,"
      "\"pivot\":%.5f,"
      "\"r1\":%.5f,\"r2\":%.5f,\"r3\":%.5f,"
      "\"s1\":%.5f,\"s2\":%.5f,\"s3\":%.5f,"
      "\"dayOpen\":%.5f%s}",
      _Symbol, tfMinutes, openTime,
      bars[0].open, bars[0].high, bars[0].low, bars[0].close,
      (int)bars[0].tick_volume,
      ma1, Ma1Per, ma2, Ma2Per, ma3, Ma3Per, ma4, Ma4Per, ma5, Ma5Per,
      rsi, RsiPeriod,
      pivot, r1, r2, r3, s1, s2, s3,
      dayOpen,
      fibPart
   );

   string headers = "Content-Type: application/json\r\nX-EA-Secret: " + EaSecret;
   char req[], res[];
   StringToCharArray(body, req, 0, StringLen(body));
   string resHeaders;

   int code = 0;
   for (int attempt = 1; attempt <= 3; attempt++)
   {
      code = WebRequest("POST", ApiUrl, headers, 5000, req, res, resHeaders);
      if (code == 200 || code == 201) return true;
      if (code >= 400 && code < 500)
      {
         PrintFormat("HistoryPusher: HTTP %d (4xx) on %s %s — body=%s",
                     code, EnumToString(tf), openTime, body);
         return false;
      }
      if (attempt < 3) Sleep(2000);
   }
   PrintFormat("HistoryPusher: HTTP %d (giving up) on %s %s",
               code, EnumToString(tf), openTime);
   return false;
}

void OnTick() {}
