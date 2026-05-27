//+------------------------------------------------------------------+
//| KeyCalculator.mq5                                                 |
//| Computes Turn Keys via 2+ source confluence algorithm and        |
//| compares output against live Google Sheet values from /api/keys. |
//|                                                                   |
//| Algorithm (per timeframe):                                        |
//|   - Collect H1/H4/D1/W1 swing highs/lows (fractal window=3-5)    |
//|   - Collect prior pivots (P, R1-3, S1-3) and fib levels           |
//|   - Round-10 grid across price range                              |
//|   - Cluster levels with ±5pt tolerance                            |
//|   - Keep clusters touched by ≥2 distinct source types             |
//|                                                                   |
//| TF mapping (self-similar fractal):                                |
//|   - Intraday Keys ← H1 fractal, 5-day lookback                    |
//|   - H1 Turn       ← H4 fractal, 30-day lookback                   |
//|   - H4 Turn       ← D1 fractal, 90-day lookback                   |
//|   - D1 Turn       ← W1 fractal, 365-day lookback                  |
//|                                                                   |
//| SETUP:                                                            |
//|   1. Tools → Options → Expert Advisors → Allow WebRequest        |
//|      Add https://trading.boredstudio.ai                          |
//|   2. Attach to XAUUSD chart.                                     |
//|   3. EA prints comparison on every new H1 bar.                   |
//+------------------------------------------------------------------+
#property strict
#property description "Compute Turn Keys + diff vs /api/keys sheet"

input string ApiKeysUrl    = "https://trading.boredstudio.ai/api/keys";
input string OutputFile    = "KeyCalculator_output.txt";  // in MQL5/Files/
input int    ClusterTolPts     = 15;  // ± points to merge into cluster
input int    MinSources        = 3;   // ≥ N sources for HISTORICAL keys (≤ price)
input int    MinSourcesForward = 2;   // ≥ N sources for FORWARD keys (> price)
input int    PrintTopN         = 100; // print top N per timeframe
input int    RefreshSec    = 60;      // recompute every N seconds
input bool   ShowComment   = true;    // also show overlay on chart
input string AsOfDate      = "";      // YYYY.MM.DD HH:MM (empty = live). Backtest at past date.
input bool   FetchSheet    = true;    // false in backtest (sheet only valid live)

#define MAX_LEVELS  2500
#define MAX_CLUSTER 300
#define SRC_H1_SWG  1
#define SRC_H4_SWG  2
#define SRC_D1_SWG  3
#define SRC_W1_SWG  4
#define SRC_D1_PIV  5
#define SRC_D1_FIB  6
#define SRC_W1_PIV  7
#define SRC_ROUND   8

datetime g_lastRun = 0;

//+------------------------------------------------------------------+
//| Resolve as-of shift for a given TF. 0 in live mode.              |
//+------------------------------------------------------------------+
int AsOfShift(ENUM_TIMEFRAMES tf)
{
   if (StringLen(AsOfDate) == 0) return 0;
   datetime t = StringToTime(AsOfDate);
   if (t <= 0) return 0;
   int s = iBarShift(_Symbol, tf, t, false);
   return (s < 0) ? 0 : s;
}

//+------------------------------------------------------------------+
int OnInit()
{
   EventSetTimer(1);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { EventKillTimer(); Comment(""); }

void OnTimer()
{
   if (TimeCurrent() - g_lastRun < RefreshSec) return;
   g_lastRun = TimeCurrent();
   Run();
}

void OnTick() {}

//+------------------------------------------------------------------+
//| Add level with source tag to arrays                              |
//+------------------------------------------------------------------+
void AddLevel(double &lvls[], int &srcs[], int &count, double v, int src)
{
   if (count >= MAX_LEVELS || v <= 0) return;
   lvls[count] = v; srcs[count] = src; count++;
}

//+------------------------------------------------------------------+
//| Fractal swing detection on TF over `bars` lookback               |
//| Adds detected swing highs and lows to output arrays              |
//+------------------------------------------------------------------+
void CollectSwings(ENUM_TIMEFRAMES tf, int bars, int window, int src,
                   double &lvls[], int &srcs[], int &count)
{
   MqlRates rates[];
   int got = CopyRates(_Symbol, tf, 1 + AsOfShift(tf), bars, rates);
   if (got < 2*window+1) return;
   // rates[0] = oldest, rates[got-1] = newest (default order)
   for (int i = window; i < got - window; i++)
   {
      bool isHigh = true, isLow = true;
      for (int j = i - window; j <= i + window; j++)
      {
         if (j == i) continue;
         if (rates[j].high >= rates[i].high) isHigh = false;
         if (rates[j].low  <= rates[i].low)  isLow  = false;
      }
      if (isHigh) AddLevel(lvls, srcs, count, rates[i].high, src);
      if (isLow)  AddLevel(lvls, srcs, count, rates[i].low,  src);
   }
}

//+------------------------------------------------------------------+
//| Add pivot (P, R1-3, S1-3) from prior bar of given TF              |
//+------------------------------------------------------------------+
void AddPivot(ENUM_TIMEFRAMES tf, int shiftStart, int barsCount, int src,
              double &lvls[], int &srcs[], int &count)
{
   MqlRates r[];
   if (CopyRates(_Symbol, tf, shiftStart + AsOfShift(tf), barsCount, r) < 1) return;
   for (int i = 0; i < ArraySize(r); i++)
   {
      double pH = r[i].high, pL = r[i].low, pC = r[i].close;
      double pivot = (pH + pL + pC) / 3.0;
      AddLevel(lvls, srcs, count, pivot, src);
      AddLevel(lvls, srcs, count, 2*pivot - pL,            src); // R1
      AddLevel(lvls, srcs, count, pivot + (pH - pL),       src); // R2
      AddLevel(lvls, srcs, count, pH + 2*(pivot - pL),     src); // R3
      AddLevel(lvls, srcs, count, 2*pivot - pH,            src); // S1
      AddLevel(lvls, srcs, count, pivot - (pH - pL),       src); // S2
      AddLevel(lvls, srcs, count, pL - 2*(pH - pivot),     src); // S3
   }
}

//+------------------------------------------------------------------+
//| Add fib levels (0/236/382/500/618/786/100) from prior bar of TF  |
//+------------------------------------------------------------------+
void AddFibs(ENUM_TIMEFRAMES tf, int shiftStart, int barsCount, int src,
             double &lvls[], int &srcs[], int &count)
{
   MqlRates r[];
   if (CopyRates(_Symbol, tf, shiftStart + AsOfShift(tf), barsCount, r) < 1) return;
   for (int i = 0; i < ArraySize(r); i++)
   {
      double fH = r[i].high, fL = r[i].low, rng = fH - fL;
      if (rng <= 0) continue;
      AddLevel(lvls, srcs, count, fL,                src);
      AddLevel(lvls, srcs, count, fL + rng * 0.236,  src);
      AddLevel(lvls, srcs, count, fL + rng * 0.382,  src);
      AddLevel(lvls, srcs, count, fL + rng * 0.500,  src);
      AddLevel(lvls, srcs, count, fL + rng * 0.618,  src);
      AddLevel(lvls, srcs, count, fL + rng * 0.786,  src);
      AddLevel(lvls, srcs, count, fH,                src);
   }
}

//+------------------------------------------------------------------+
//| Add round-10 grid covering current price ± rangePts               |
//+------------------------------------------------------------------+
void AddRoundGrid(double price, double rangePts, int step, int src,
                  double &lvls[], int &srcs[], int &count)
{
   int lo = (int)MathFloor((price - rangePts) / step) * step;
   int hi = (int)MathCeil ((price + rangePts) / step) * step;
   for (int v = lo; v <= hi; v += step)
      AddLevel(lvls, srcs, count, (double)v, src);
}

//+------------------------------------------------------------------+
//| Sort levels ascending (paired with srcs via index)               |
//+------------------------------------------------------------------+
void SortPaired(double &lvls[], int &srcs[], int count)
{
   for (int i = 1; i < count; i++)
   {
      double v = lvls[i]; int s = srcs[i];
      int j = i - 1;
      while (j >= 0 && lvls[j] > v) { lvls[j+1] = lvls[j]; srcs[j+1] = srcs[j]; j--; }
      lvls[j+1] = v; srcs[j+1] = s;
   }
}

//+------------------------------------------------------------------+
//| Cluster sorted levels within tol pts, return cluster centers     |
//| with distinct source count                                       |
//+------------------------------------------------------------------+
int ClusterAndFilter(double &lvls[], int &srcs[], int count,
                     double tol, int minSrc,
                     double &outLvls[], int &outSrcCount[])
{
   int outN = 0;
   int i = 0;
   while (i < count && outN < MAX_CLUSTER)
   {
      double anchor = lvls[i];
      int sources[8]; ArrayInitialize(sources, 0);
      sources[srcs[i] - 1] = 1;
      double sum = lvls[i];
      int memberN = 1;
      int j = i + 1;
      while (j < count && lvls[j] - anchor <= tol)
      {
         sources[srcs[j] - 1] = 1;
         sum += lvls[j];
         memberN++;
         j++;
      }
      int srcCount = 0;
      for (int k = 0; k < 8; k++) srcCount += sources[k];
      if (srcCount >= minSrc)
      {
         outLvls[outN]     = sum / memberN;
         outSrcCount[outN] = srcCount;
         outN++;
      }
      i = j;
   }
   return outN;
}

//+------------------------------------------------------------------+
//| Compute keys for a given TF tier and return formatted lines      |
//+------------------------------------------------------------------+
string ComputeKeys(string label,
                   ENUM_TIMEFRAMES swingTf, int swingBars, int swingWin,
                   ENUM_TIMEFRAMES pivotTf, int pivotBars,
                   bool addFib, bool addRound, double currentPrice, double gridRange,
                   double &tierLvls[], int &tierSrcN[], int &tierOutN)
{
   double lvls[MAX_LEVELS]; int srcs[MAX_LEVELS];
   ArrayInitialize(lvls, 0); ArrayInitialize(srcs, 0);
   int n = 0;

   // Multi-TF swing collection — primary + neighbors
   if (swingTf == PERIOD_H1)
   {
      CollectSwings(PERIOD_H1, swingBars, 3, SRC_H1_SWG, lvls, srcs, n);
      CollectSwings(PERIOD_H4, swingBars/2, 2, SRC_H4_SWG, lvls, srcs, n);
   }
   else if (swingTf == PERIOD_H4)
   {
      CollectSwings(PERIOD_H4, swingBars, 3, SRC_H4_SWG, lvls, srcs, n);
      CollectSwings(PERIOD_H1, swingBars*2, 5, SRC_H1_SWG, lvls, srcs, n);
   }
   else if (swingTf == PERIOD_D1)
   {
      CollectSwings(PERIOD_D1, swingBars, 3, SRC_D1_SWG, lvls, srcs, n);
      CollectSwings(PERIOD_H4, swingBars*4, 5, SRC_H4_SWG, lvls, srcs, n);
   }
   else if (swingTf == PERIOD_W1)
   {
      CollectSwings(PERIOD_W1, swingBars, 2, SRC_W1_SWG, lvls, srcs, n);
      CollectSwings(PERIOD_D1, swingBars*5, 3, SRC_D1_SWG, lvls, srcs, n);
   }

   // Pivots from prior bars
   if (pivotTf == PERIOD_D1)
      AddPivot(PERIOD_D1, 1, pivotBars, SRC_D1_PIV, lvls, srcs, n);
   else if (pivotTf == PERIOD_W1)
      AddPivot(PERIOD_W1, 1, pivotBars, SRC_W1_PIV, lvls, srcs, n);

   // Fibs (D1 always; W1 for higher tiers)
   if (addFib)
   {
      AddFibs(PERIOD_D1, 1, MathMin(pivotBars, 5), SRC_D1_FIB, lvls, srcs, n);
      if (swingTf == PERIOD_D1 || swingTf == PERIOD_W1)
         AddFibs(PERIOD_W1, 1, 3, SRC_D1_FIB, lvls, srcs, n);
   }

   // Round-10 grid
   if (addRound)
      AddRoundGrid(currentPrice, gridRange, 10, SRC_ROUND, lvls, srcs, n);

   SortPaired(lvls, srcs, n);

   ArrayInitialize(tierLvls, 0); ArrayInitialize(tierSrcN, 0);
   int gateMin = MathMin(MinSources, MinSourcesForward);
   tierOutN = ClusterAndFilter(lvls, srcs, n, ClusterTolPts, gateMin,
                               tierLvls, tierSrcN);

   string out = StringFormat("[%s] %d candidates from %d raw levels (hist≥%d, fwd≥%d)\n",
                              label, tierOutN, n, MinSources, MinSourcesForward);

   double maxDist = currentPrice * 0.10;

   // Historical section: clusters at or below current price, src≥MinSources
   out += "  -- Historical (≤ price, src≥" + IntegerToString(MinSources) + ") --\n";
   int shown = 0;
   for (int i = 0; i < tierOutN; i++)
   {
      if (tierLvls[i] > currentPrice) continue;
      if (tierSrcN[i] < MinSources) continue;
      if (MathAbs(tierLvls[i] - currentPrice) > maxDist) continue;
      out += StringFormat("  %8.2f  src=%d\n", tierLvls[i], tierSrcN[i]);
      shown++;
      if (shown >= PrintTopN) break;
   }

   // Forward section: clusters above current price, src≥MinSourcesForward
   out += "  -- Forward (> price, src≥" + IntegerToString(MinSourcesForward) + ") --\n";
   shown = 0;
   for (int i = 0; i < tierOutN; i++)
   {
      if (tierLvls[i] <= currentPrice) continue;
      if (tierSrcN[i] < MinSourcesForward) continue;
      if (MathAbs(tierLvls[i] - currentPrice) > maxDist) continue;
      out += StringFormat("  %8.2f  src=%d\n", tierLvls[i], tierSrcN[i]);
      shown++;
      if (shown >= PrintTopN) break;
   }
   return out;
}

//+------------------------------------------------------------------+
//| Fetch /api/keys JSON, parse Intraday/H1/H4/D1/W1 arrays           |
//+------------------------------------------------------------------+
bool FetchSheetKeys(double &intra[], int &intraN,
                    double &h1k[],   int &h1N,
                    double &h4k[],   int &h4N,
                    double &dk[],    int &dN,
                    double &wk[],    int &wN)
{
   char req[], res[];
   string resHeaders;
   int code = WebRequest("GET", ApiKeysUrl, "", 5000, req, res, resHeaders);
   if (code != 200)
   {
      PrintFormat("KeyCalc: /api/keys HTTP %d", code);
      return false;
   }
   string body = CharArrayToString(res);
   intraN = 0; h1N = 0; h4N = 0; dN = 0; wN = 0;
   return ParseJsonArrays(body, intra, intraN, h1k, h1N, h4k, h4N, dk, dN, wk, wN);
}

//+------------------------------------------------------------------+
//| Tiny JSON array parser — extracts numbers from named arrays      |
//+------------------------------------------------------------------+
bool ParseJsonArrays(string body,
                     double &a1[], int &n1,
                     double &a2[], int &n2,
                     double &a3[], int &n3,
                     double &a4[], int &n4,
                     double &a5[], int &n5)
{
   ParseArray(body, "\"intradayKeys\"", a1, n1);
   ParseArray(body, "\"h1Turn\"",       a2, n2);
   ParseArray(body, "\"h4Turn\"",       a3, n3);
   ParseArray(body, "\"dailyTurn\"",    a4, n4);
   ParseArray(body, "\"weekTurn\"",     a5, n5);
   return true;
}

void ParseArray(string body, string key, double &arr[], int &n)
{
   n = 0;
   int kpos = StringFind(body, key);
   if (kpos < 0) return;
   int lb = StringFind(body, "[", kpos);
   int rb = StringFind(body, "]", lb);
   if (lb < 0 || rb < 0) return;
   string inner = StringSubstr(body, lb+1, rb-lb-1);
   // Split by comma, parse each as double
   int len = StringLen(inner);
   string cur = "";
   for (int i = 0; i <= len; i++)
   {
      string ch = (i < len) ? StringSubstr(inner, i, 1) : ",";
      if (ch == ",")
      {
         StringTrimLeft(cur); StringTrimRight(cur);
         if (StringLen(cur) > 0 && n < MAX_LEVELS)
         {
            double v = StringToDouble(cur);
            if (v > 0) { arr[n] = v; n++; }
         }
         cur = "";
      }
      else cur += ch;
   }
}

//+------------------------------------------------------------------+
//| Format sheet array for printing (within ±5% of current price)    |
//+------------------------------------------------------------------+
string FormatSheet(string label, double &arr[], int n, double currentPrice)
{
   string out = StringFormat("[%s sheet] %d levels\n", label, n);
   double maxDist = currentPrice * 0.10;
   int shown = 0;
   for (int i = 0; i < n; i++)
   {
      if (MathAbs(arr[i] - currentPrice) > maxDist) continue;
      out += StringFormat("  %8.2f\n", arr[i]);
      shown++;
      if (shown >= PrintTopN) break;
   }
   return out;
}

//+------------------------------------------------------------------+
//| Master Keys: cross-tier union + dedup                            |
//+------------------------------------------------------------------+
#define MAX_MASTER (MAX_CLUSTER * 4)
#define TIER_I  1
#define TIER_H1 2
#define TIER_H4 4
#define TIER_D1 8

void AppendTier(double &lvls[], int &srcs[], int n, int tierBit,
                double &mLvls[], int &mTier[], int &mSrc[], int &mN)
{
   for (int i = 0; i < n; i++)
   {
      if (mN >= MAX_MASTER) return;
      mLvls[mN] = lvls[i];
      mTier[mN] = tierBit;
      mSrc[mN]  = srcs[i];
      mN++;
   }
}

void SortMaster(double &lvls[], int &tier[], int &srcs[], int n)
{
   for (int i = 1; i < n; i++)
   {
      double v = lvls[i]; int t = tier[i]; int s = srcs[i];
      int j = i - 1;
      while (j >= 0 && lvls[j] > v)
      {
         lvls[j+1] = lvls[j]; tier[j+1] = tier[j]; srcs[j+1] = srcs[j];
         j--;
      }
      lvls[j+1] = v; tier[j+1] = t; srcs[j+1] = s;
   }
}

int DedupeMaster(double &lvls[], int &tier[], int &srcs[], int n, double tol,
                 double &oLvls[], int &oTier[], int &oSrc[])
{
   int oN = 0;
   int i = 0;
   while (i < n && oN < MAX_MASTER)
   {
      double sum = lvls[i];
      int memberN = 1;
      int tierMask = tier[i];
      int maxSrc = srcs[i];
      int j = i + 1;
      while (j < n && lvls[j] - lvls[i] <= tol)
      {
         sum += lvls[j];
         memberN++;
         tierMask |= tier[j];
         if (srcs[j] > maxSrc) maxSrc = srcs[j];
         j++;
      }
      oLvls[oN] = sum / memberN;
      oTier[oN] = tierMask;
      oSrc[oN]  = maxSrc;
      oN++;
      i = j;
   }
   return oN;
}

int TierCount(int mask)
{
   int c = 0;
   if (mask & TIER_I)  c++;
   if (mask & TIER_H1) c++;
   if (mask & TIER_H4) c++;
   if (mask & TIER_D1) c++;
   return c;
}

string TierMaskToString(int mask)
{
   string s = "";
   if (mask & TIER_I)  s += "I,";
   if (mask & TIER_H1) s += "H1,";
   if (mask & TIER_H4) s += "H4,";
   if (mask & TIER_D1) s += "D1,";
   int len = StringLen(s);
   if (len > 0 && StringSubstr(s, len-1, 1) == ",") s = StringSubstr(s, 0, len-1);
   return s;
}

string BuildMaster(double currentPrice,
                   double &iLvls[], int &iSrc[], int iN,
                   double &h1Lvls[], int &h1Src[], int h1N,
                   double &h4Lvls[], int &h4Src[], int h4N,
                   double &d1Lvls[], int &d1Src[], int d1N)
{
   double mLvls[MAX_MASTER]; int mTier[MAX_MASTER]; int mSrc[MAX_MASTER];
   ArrayInitialize(mLvls, 0); ArrayInitialize(mTier, 0); ArrayInitialize(mSrc, 0);
   int mN = 0;

   AppendTier(iLvls,  iSrc,  iN,  TIER_I,  mLvls, mTier, mSrc, mN);
   AppendTier(h1Lvls, h1Src, h1N, TIER_H1, mLvls, mTier, mSrc, mN);
   AppendTier(h4Lvls, h4Src, h4N, TIER_H4, mLvls, mTier, mSrc, mN);
   AppendTier(d1Lvls, d1Src, d1N, TIER_D1, mLvls, mTier, mSrc, mN);

   SortMaster(mLvls, mTier, mSrc, mN);

   double oLvls[MAX_MASTER]; int oTier[MAX_MASTER]; int oSrc[MAX_MASTER];
   ArrayInitialize(oLvls, 0); ArrayInitialize(oTier, 0); ArrayInitialize(oSrc, 0);
   int oN = DedupeMaster(mLvls, mTier, mSrc, mN, 5.0, oLvls, oTier, oSrc);

   string out = StringFormat("=== Master Keys (cross-tier union, dedup ±5pt) %d levels ===\n", oN);
   double maxDist = currentPrice * 0.10;

   out += "  -- Historical (≤ price, src≥" + IntegerToString(MinSources) + ") --\n";
   for (int i = 0; i < oN; i++)
   {
      if (oLvls[i] > currentPrice) continue;
      if (oSrc[i] < MinSources) continue;
      if (MathAbs(oLvls[i] - currentPrice) > maxDist) continue;
      out += StringFormat("  %8.2f  src=%d  tiers=[%s]  conf=%d\n",
                          oLvls[i], oSrc[i], TierMaskToString(oTier[i]), TierCount(oTier[i]));
   }

   out += "  -- Forward (> price, src≥" + IntegerToString(MinSourcesForward) + ") --\n";
   for (int i = 0; i < oN; i++)
   {
      if (oLvls[i] <= currentPrice) continue;
      if (oSrc[i] < MinSourcesForward) continue;
      if (MathAbs(oLvls[i] - currentPrice) > maxDist) continue;
      out += StringFormat("  %8.2f  src=%d  tiers=[%s]  conf=%d\n",
                          oLvls[i], oSrc[i], TierMaskToString(oTier[i]), TierCount(oTier[i]));
   }
   return out;
}

//+------------------------------------------------------------------+
//| Diff: for each sheet level, find nearest computed within ±5pts   |
//+------------------------------------------------------------------+
string DiffOne(string label, double &sheet[], int sn,
               double &computed[], int cn, double tolPts)
{
   int matched = 0;
   double sumErr = 0;
   for (int i = 0; i < sn; i++)
   {
      double best = 1e9;
      for (int j = 0; j < cn; j++)
      {
         double d = MathAbs(sheet[i] - computed[j]);
         if (d < best) best = d;
      }
      if (best <= tolPts) { matched++; sumErr += best; }
   }
   double pct = (sn > 0) ? 100.0 * matched / sn : 0;
   double avg = (matched > 0) ? sumErr / matched : 0;
   return StringFormat("  %s: matched %d/%d (%.0f%%), avg err %.2f\n",
                       label, matched, sn, pct, avg);
}

//+------------------------------------------------------------------+
//| Main run: compute, fetch, diff, render                            |
//+------------------------------------------------------------------+
void Run()
{
   bool backtest = (StringLen(AsOfDate) > 0);
   datetime refTime = TimeCurrent();
   double price = 0;
   if (backtest)
   {
      refTime = StringToTime(AsOfDate);
      MqlRates h1r[];
      int s = iBarShift(_Symbol, PERIOD_H1, refTime, false);
      if (s < 0 || CopyRates(_Symbol, PERIOD_H1, s, 1, h1r) < 1) {
         PrintFormat("KeyCalc backtest: no H1 bar at %s", AsOfDate);
         return;
      }
      price = h1r[0].close;
   }
   else
   {
      price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   }
   if (price <= 0) return;

   // Compute each tier
   string out = "";
   out += "=== KeyCalculator ===\n";
   out += StringFormat("Symbol: %s  %s: %.2f  Time: %s%s\n",
                       _Symbol,
                       backtest ? "Close" : "Bid",
                       price,
                       TimeToString(refTime, TIME_DATE|TIME_MINUTES),
                       backtest ? "  [BACKTEST]" : "");
   out += StringFormat("Config: cluster=±%dpts, hist≥%d, fwd≥%d, topN=%d\n\n",
                       ClusterTolPts, MinSources, MinSourcesForward, PrintTopN);

   // Per-tier cluster arrays (kept for Master Keys build)
   double iLvls[MAX_CLUSTER];  int iSrc[MAX_CLUSTER];  int iN  = 0;
   double h1Lvls[MAX_CLUSTER]; int h1Src[MAX_CLUSTER]; int h1N = 0;
   double h4Lvls[MAX_CLUSTER]; int h4Src[MAX_CLUSTER]; int h4N = 0;
   double d1Lvls[MAX_CLUSTER]; int d1Src[MAX_CLUSTER]; int d1N = 0;

   string intradayOut = ComputeKeys("Intraday Keys",
                                     PERIOD_H1, 240, 3,
                                     PERIOD_D1, 10,
                                     true, true, price, 300,
                                     iLvls, iSrc, iN);
   string h1Out = ComputeKeys("H1 Turn Keys",
                               PERIOD_H4, 360, 3,
                               PERIOD_D1, 14,
                               true, true, price, 500,
                               h1Lvls, h1Src, h1N);
   string h4Out = ComputeKeys("H4 Turn Keys",
                               PERIOD_D1, 180, 3,
                               PERIOD_W1, 8,
                               true, true, price, 800,
                               h4Lvls, h4Src, h4N);
   string d1Out = ComputeKeys("D1 Turn Keys",
                               PERIOD_W1, 104, 2,
                               PERIOD_W1, 16,
                               true, true, price, 1500,
                               d1Lvls, d1Src, d1N);

   out += intradayOut + "\n" + h1Out + "\n" + h4Out + "\n" + d1Out + "\n";

   // Master Keys: cross-tier union, dedup ±5pt
   out += BuildMaster(price,
                      iLvls,  iSrc,  iN,
                      h1Lvls, h1Src, h1N,
                      h4Lvls, h4Src, h4N,
                      d1Lvls, d1Src, d1N);
   out += "\n";

   // Fetch sheet (live mode only — sheet reflects current state)
   if (!backtest && FetchSheet)
   {
      double intra[MAX_LEVELS], h1s[MAX_LEVELS], h4s[MAX_LEVELS], dks[MAX_LEVELS], wks[MAX_LEVELS];
      int iN, h1N, h4N, dN, wN;
      ArrayInitialize(intra, 0); ArrayInitialize(h1s, 0);
      ArrayInitialize(h4s, 0);   ArrayInitialize(dks, 0); ArrayInitialize(wks, 0);

      bool ok = FetchSheetKeys(intra, iN, h1s, h1N, h4s, h4N, dks, dN, wks, wN);
      if (ok)
      {
         out += "=== Sheet levels (from /api/keys, within ±5% of price) ===\n";
         out += FormatSheet("Intraday", intra, iN, price);
         out += FormatSheet("H1",       h1s,   h1N, price);
         out += FormatSheet("H4",       h4s,   h4N, price);
         out += FormatSheet("D1",       dks,   dN, price);
         out += FormatSheet("W1",       wks,   wN, price);
      }
      else
      {
         out += "[Sheet fetch failed — comparison skipped]\n";
      }
   }
   else if (backtest)
   {
      out += "=== Backtest mode — sheet fetch skipped ===\n";
      out += "Diff against goldviewfx_history.json bullish/bearish levels manually.\n";
   }

   // Write to file
   WriteOutputFile(out);

   // Print to log and (optionally) overlay
   Print(out);
   if (ShowComment) Comment(out);
}

//+------------------------------------------------------------------+
//| Write snapshot to MQL5/Files/<OutputFile>. Overwrites each run.   |
//+------------------------------------------------------------------+
void WriteOutputFile(string text)
{
   int h = FileOpen(OutputFile, FILE_WRITE | FILE_TXT | FILE_ANSI);
   if (h == INVALID_HANDLE)
   {
      PrintFormat("KeyCalc: FileOpen failed for %s (err=%d)", OutputFile, GetLastError());
      return;
   }
   FileWriteString(h, text);
   FileClose(h);
   PrintFormat("KeyCalc: wrote snapshot to MQL5/Files/%s (%d bytes)",
               OutputFile, StringLen(text));
}
//+------------------------------------------------------------------+
