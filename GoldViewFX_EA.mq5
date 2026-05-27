//+------------------------------------------------------------------+
//| GoldViewFX_EA.mq5                                                 |
//|                                                                   |
//| Auto-trades XAUUSD using reverse-engineered GVF Turn Key formula.|
//| Algorithm matches KeyCalculator.mq5 (78/78 historical match).    |
//|                                                                   |
//| Strategy:                                                         |
//|   - On every new H1 bar close, rebuild Master Keys.              |
//|   - Find nearest historical key BELOW price (support).           |
//|   - Entry conditions (BUY only):                                 |
//|       * Price within EntryToleranceUSD of support                |
//|       * Support key confluence (tier count) >= MinEntryConf      |
//|       * EMA5 H1 (last closed bar) > support key (lock)           |
//|       * Bias: price > today's daily open                         |
//|   - SL = support - StopLossPts                                   |
//|   - TP = next forward key above                                  |
//|   - Lot size from confluence table                               |
//|                                                                   |
//| Risk:                                                             |
//|   - Daily loss cap (% of start-of-day balance)                   |
//|   - Max trades per day                                           |
//|   - Optional breakeven move                                       |
//|                                                                   |
//| SETUP:                                                            |
//|   1. Attach to XAUUSD H1 chart.                                  |
//|   2. Allow Live Trading in EA inputs.                            |
//|   3. Verify Magic number unique.                                 |
//+------------------------------------------------------------------+
#property strict
#property description "GoldViewFX-based BUY-only EA using cross-tier Master Keys"

#include <Trade\Trade.mqh>

//================= INPUTS =====================
input group "=== Trading ==="
input int    MagicNumber       = 20260511;
input bool   EnableTrade       = false;   // start in DEMO observation mode
input bool   BuyOnly           = true;
input int    StopLossPts       = 20;      // pts below support
input int    EntryToleranceUSD = 10;      // price within $X of support
input int    MinEntryConf      = 4;       // ≥ N tiers must confluence
input int    EmaPeriod         = 5;
input bool   AllowBreakeven    = true;
input int    BreakevenPts      = 50;      // move SL to entry after +N pts
input bool   LogSkipReasons    = true;    // print why TryEntry skipped each bar

input group "=== Lot Sizing ==="
input double LotConf4 = 0.05;
input double LotConf5 = 0.05;
input double LotConf6 = 0.075;
input double LotConf7 = 0.075;
input double LotConf8 = 0.10;

input group "=== Risk Limits ==="
input double DailyLossPct      = 2.0;     // stop after -X% from day start
input int    MaxTradesPerDay   = 2;

input group "=== Key Algorithm ==="
input int    ClusterTolPts     = 15;
input int    MinSrcHist        = 3;
input int    MinSrcFwd         = 2;

input group "=== Key Pushing ==="
input bool   EnableKeyPush     = true;
input string KeyApiUrl         = "https://trading.boredstudio.ai/api/computed-keys";
input string EaSecret          = "";
input int    KeyPushTimeoutMs  = 10000;

//================= CONSTANTS =====================
#define MAX_LEVELS  2500
#define MAX_CLUSTER 300
#define MAX_MASTER  (MAX_CLUSTER * 4)
#define SRC_H1_SWG  1
#define SRC_H4_SWG  2
#define SRC_D1_SWG  3
#define SRC_W1_SWG  4
#define SRC_D1_PIV  5
#define SRC_D1_FIB  6
#define SRC_W1_PIV  7
#define SRC_ROUND   8
#define TIER_I  1
#define TIER_H1 2
#define TIER_H4 4
#define TIER_D1 8

//================= STATE =====================
CTrade   g_trade;
datetime g_lastH1Bar       = 0;
datetime g_dayKey          = 0;
double   g_dayStartBalance = 0;
int      g_tradesToday     = 0;
int      g_emaHandle       = INVALID_HANDLE;

// Intraday tier cache: rebuilt once per day at first H1 close of new day
double   g_iLvls[MAX_CLUSTER];
int      g_iSrc[MAX_CLUSTER];
int      g_iN  = 0;
datetime g_iDay = 0;

//================= ALGORITHM (copied from KeyCalculator.mq5) =====================
void AddLevel(double &lvls[], int &srcs[], int &count, double v, int src)
{
   if (count >= MAX_LEVELS || v <= 0) return;
   lvls[count] = v; srcs[count] = src; count++;
}

void CollectSwings(ENUM_TIMEFRAMES tf, int bars, int window, int src,
                   double &lvls[], int &srcs[], int &count)
{
   MqlRates rates[];
   int got = CopyRates(_Symbol, tf, 1, bars, rates);
   if (got < 2*window+1) return;
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

void AddPivot(ENUM_TIMEFRAMES tf, int shiftStart, int barsCount, int src,
              double &lvls[], int &srcs[], int &count)
{
   MqlRates r[];
   if (CopyRates(_Symbol, tf, shiftStart, barsCount, r) < 1) return;
   for (int i = 0; i < ArraySize(r); i++)
   {
      double pH = r[i].high, pL = r[i].low, pC = r[i].close;
      double pivot = (pH + pL + pC) / 3.0;
      AddLevel(lvls, srcs, count, pivot, src);
      AddLevel(lvls, srcs, count, 2*pivot - pL,            src);
      AddLevel(lvls, srcs, count, pivot + (pH - pL),       src);
      AddLevel(lvls, srcs, count, pH + 2*(pivot - pL),     src);
      AddLevel(lvls, srcs, count, 2*pivot - pH,            src);
      AddLevel(lvls, srcs, count, pivot - (pH - pL),       src);
      AddLevel(lvls, srcs, count, pL - 2*(pH - pivot),     src);
   }
}

void AddFibs(ENUM_TIMEFRAMES tf, int shiftStart, int barsCount, int src,
             double &lvls[], int &srcs[], int &count)
{
   MqlRates r[];
   if (CopyRates(_Symbol, tf, shiftStart, barsCount, r) < 1) return;
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

void AddRoundGrid(double price, double rangePts, int step, int src,
                  double &lvls[], int &srcs[], int &count)
{
   int lo = (int)MathFloor((price - rangePts) / step) * step;
   int hi = (int)MathCeil ((price + rangePts) / step) * step;
   for (int v = lo; v <= hi; v += step)
      AddLevel(lvls, srcs, count, (double)v, src);
}

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

int ComputeTier(ENUM_TIMEFRAMES swingTf, int swingBars, int swingWin,
                ENUM_TIMEFRAMES pivotTf, int pivotBars,
                bool addFib, bool addRound, double currentPrice, double gridRange,
                double &outLvls[], int &outSrcN[])
{
   double lvls[MAX_LEVELS]; int srcs[MAX_LEVELS];
   ArrayInitialize(lvls, 0); ArrayInitialize(srcs, 0);
   int n = 0;

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

   if (pivotTf == PERIOD_D1)
      AddPivot(PERIOD_D1, 1, pivotBars, SRC_D1_PIV, lvls, srcs, n);
   else if (pivotTf == PERIOD_W1)
      AddPivot(PERIOD_W1, 1, pivotBars, SRC_W1_PIV, lvls, srcs, n);

   if (addFib)
   {
      AddFibs(PERIOD_D1, 1, MathMin(pivotBars, 5), SRC_D1_FIB, lvls, srcs, n);
      if (swingTf == PERIOD_D1 || swingTf == PERIOD_W1)
         AddFibs(PERIOD_W1, 1, 3, SRC_D1_FIB, lvls, srcs, n);
   }

   if (addRound)
      AddRoundGrid(currentPrice, gridRange, 10, SRC_ROUND, lvls, srcs, n);

   SortPaired(lvls, srcs, n);

   int gateMin = MathMin(MinSrcHist, MinSrcFwd);
   return ClusterAndFilter(lvls, srcs, n, ClusterTolPts, gateMin, outLvls, outSrcN);
}

//================= MASTER KEYS BUILD =====================
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

//================= KEY PUSH (DB API) =====================
string EscapeNum(double v) { return DoubleToString(v, 5); }

void AppendTierJson(string &out, double &lvls[], int &srcs[], int n,
                    string tierName, double bid)
{
   for (int i = 0; i < n; i++)
   {
      bool hist = (lvls[i] <= bid);
      int gate  = hist ? MinSrcHist : MinSrcFwd;
      if (srcs[i] < gate) continue;
      string side = hist ? "historical" : "forward";
      if (StringLen(out) > 0) out += ",";
      out += StringFormat(
         "{\"tier\":\"%s\",\"level\":%s,\"side\":\"%s\",\"sourceCount\":%d}",
         tierName, EscapeNum(lvls[i]), side, srcs[i]);
   }
}

void AppendMasterJson(string &out, double &lvls[], int &tiers[], int &srcs[],
                      int n, double bid)
{
   for (int i = 0; i < n; i++)
   {
      bool hist = (lvls[i] <= bid);
      int gate  = hist ? MinSrcHist : MinSrcFwd;
      if (srcs[i] < gate) continue;
      string side = hist ? "historical" : "forward";
      int conf = TierCount(tiers[i]);
      if (StringLen(out) > 0) out += ",";
      out += StringFormat(
         "{\"tier\":\"master\",\"level\":%s,\"side\":\"%s\","
         "\"sourceCount\":%d,\"tierMask\":%d,\"confluence\":%d}",
         EscapeNum(lvls[i]), side, srcs[i], tiers[i], conf);
   }
}

bool PostKeys(string body)
{
   if (MQLInfoInteger(MQL_TESTER)) return true;  // skip network in Strategy Tester
   if (EaSecret == "")
   {
      Print("EA: EaSecret empty — skipping push");
      return false;
   }
   string headers = "Content-Type: application/json\r\nX-EA-Secret: " + EaSecret;
   char req[], res[];
   StringToCharArray(body, req, 0, StringLen(body));
   string resHeaders;
   int code = 0;
   for (int attempt = 1; attempt <= 3; attempt++)
   {
      code = WebRequest("POST", KeyApiUrl, headers, KeyPushTimeoutMs,
                        req, res, resHeaders);
      if (code == 200 || code == 201) break;
      PrintFormat("EA: key push attempt %d HTTP %d", attempt, code);
      if (code >= 400 && code < 500) break;
      if (attempt < 3) Sleep(2000);
   }
   if (code == 200 || code == 201)
   {
      PrintFormat("EA: keys pushed OK (%d bytes payload)", StringLen(body));
      return true;
   }
   PrintFormat("EA: keys push FAIL final http=%d", code);
   return false;
}

// Compute all 4 tiers + Master once per day and push to API.
// Updates Intraday cache (g_iLvls) for runtime BuildMasterKeys consumption.
// Triggered at first H1 close of new day = moment last H1 of prior day finished.
void MaybeRefreshIntraday()
{
   datetime now = TimeCurrent();
   MqlDateTime mdt; TimeToStruct(now, mdt);
   mdt.hour = 0; mdt.min = 0; mdt.sec = 0;
   datetime today = StructToTime(mdt);
   if (today == g_iDay && g_iN > 0) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if (bid <= 0) return;

   // Compute all 4 tiers at the day boundary snapshot.
   double h1Lvls[MAX_CLUSTER]; int h1Src[MAX_CLUSTER];
   double h4Lvls[MAX_CLUSTER]; int h4Src[MAX_CLUSTER];
   double d1Lvls[MAX_CLUSTER]; int d1Src[MAX_CLUSTER];

   ArrayInitialize(g_iLvls, 0); ArrayInitialize(g_iSrc, 0);
   ArrayInitialize(h1Lvls,  0); ArrayInitialize(h1Src,  0);
   ArrayInitialize(h4Lvls,  0); ArrayInitialize(h4Src,  0);
   ArrayInitialize(d1Lvls,  0); ArrayInitialize(d1Src,  0);

   g_iN     = ComputeTier(PERIOD_H1, 240, 3, PERIOD_D1, 10, true, true, bid, 300,
                          g_iLvls, g_iSrc);
   int h1N  = ComputeTier(PERIOD_H4, 360, 3, PERIOD_D1, 14, true, true, bid, 500,
                          h1Lvls, h1Src);
   int h4N  = ComputeTier(PERIOD_D1, 180, 3, PERIOD_W1, 8,  true, true, bid, 800,
                          h4Lvls, h4Src);
   int d1N  = ComputeTier(PERIOD_W1, 104, 2, PERIOD_W1, 16, true, true, bid, 1500,
                          d1Lvls, d1Src);
   g_iDay = today;

   PrintFormat("EA: Daily key compute @ bid=%.2f — I:%d H1:%d H4:%d D1:%d",
               bid, g_iN, h1N, h4N, d1N);

   if (!EnableKeyPush) return;

   // Build Master (cross-tier union → sort → dedup ±5pt).
   double mLvls[MAX_MASTER]; int mTier[MAX_MASTER]; int mSrc[MAX_MASTER];
   ArrayInitialize(mLvls, 0); ArrayInitialize(mTier, 0); ArrayInitialize(mSrc, 0);
   int mN = 0;
   AppendTier(g_iLvls, g_iSrc, g_iN, TIER_I,  mLvls, mTier, mSrc, mN);
   AppendTier(h1Lvls,  h1Src,  h1N,  TIER_H1, mLvls, mTier, mSrc, mN);
   AppendTier(h4Lvls,  h4Src,  h4N,  TIER_H4, mLvls, mTier, mSrc, mN);
   AppendTier(d1Lvls,  d1Src,  d1N,  TIER_D1, mLvls, mTier, mSrc, mN);
   SortMaster(mLvls, mTier, mSrc, mN);

   double dLvls[MAX_MASTER]; int dTier[MAX_MASTER]; int dSrc[MAX_MASTER];
   ArrayInitialize(dLvls, 0); ArrayInitialize(dTier, 0); ArrayInitialize(dSrc, 0);
   int dN = DedupeMaster(mLvls, mTier, mSrc, mN, 5.0, dLvls, dTier, dSrc);

   // Build levels JSON array.
   string levelsJson = "";
   AppendTierJson  (levelsJson, g_iLvls, g_iSrc, g_iN, "intraday", bid);
   AppendTierJson  (levelsJson, h1Lvls,  h1Src,  h1N,  "h1",       bid);
   AppendTierJson  (levelsJson, h4Lvls,  h4Src,  h4N,  "h4",       bid);
   AppendTierJson  (levelsJson, d1Lvls,  d1Src,  d1N,  "d1",       bid);
   AppendMasterJson(levelsJson, dLvls,   dTier,  dSrc, dN,         bid);

   string computedAt = StringFormat(
      "%04d-%02d-%02dT%02d:%02d:%02dZ",
      mdt.year, mdt.mon, mdt.day, mdt.hour, mdt.min, mdt.sec);

   string body = StringFormat(
      "{\"symbol\":\"%s\",\"computedAt\":\"%s\",\"bidRef\":%s,\"levels\":[%s]}",
      _Symbol, computedAt, EscapeNum(bid), levelsJson);

   PostKeys(body);
}

int BuildMasterKeys(double currentPrice,
                    double &outLvls[], int &outConf[], int &outSrc[])
{
   // Intraday: use day-locked cache. Caller must ensure MaybeRefreshIntraday()
   // has run at least once (OnInit + OnTimer handle this).
   double h1Lvls[MAX_CLUSTER]; int h1Src[MAX_CLUSTER];
   double h4Lvls[MAX_CLUSTER]; int h4Src[MAX_CLUSTER];
   double d1Lvls[MAX_CLUSTER]; int d1Src[MAX_CLUSTER];

   int h1N = ComputeTier(PERIOD_H4, 360, 3, PERIOD_D1, 14, true, true, currentPrice, 500,
                         h1Lvls, h1Src);
   int h4N = ComputeTier(PERIOD_D1, 180, 3, PERIOD_W1, 8,  true, true, currentPrice, 800,
                         h4Lvls, h4Src);
   int d1N = ComputeTier(PERIOD_W1, 104, 2, PERIOD_W1, 16, true, true, currentPrice, 1500,
                         d1Lvls, d1Src);

   double mLvls[MAX_MASTER]; int mTier[MAX_MASTER]; int mSrc[MAX_MASTER];
   ArrayInitialize(mLvls, 0); ArrayInitialize(mTier, 0); ArrayInitialize(mSrc, 0);
   int mN = 0;

   AppendTier(g_iLvls, g_iSrc, g_iN, TIER_I,  mLvls, mTier, mSrc, mN);
   AppendTier(h1Lvls,  h1Src,  h1N,  TIER_H1, mLvls, mTier, mSrc, mN);
   AppendTier(h4Lvls,  h4Src,  h4N,  TIER_H4, mLvls, mTier, mSrc, mN);
   AppendTier(d1Lvls,  d1Src,  d1N,  TIER_D1, mLvls, mTier, mSrc, mN);

   SortMaster(mLvls, mTier, mSrc, mN);

   int dedupTier[MAX_MASTER];
   int dN = DedupeMaster(mLvls, mTier, mSrc, mN, 5.0, outLvls, dedupTier, outSrc);
   for (int i = 0; i < dN; i++) outConf[i] = TierCount(dedupTier[i]);
   return dN;
}

//================= ENTRY LOGIC =====================
// Returns true if EMA5 of last closed H1 bar > level (lock above)
bool EmaLockAbove(double level)
{
   double buf[1];
   if (CopyBuffer(g_emaHandle, 0, 1, 1, buf) < 1) return false;
   return buf[0] > level;
}

double DayOpen()
{
   MqlRates d[];
   if (CopyRates(_Symbol, PERIOD_D1, 0, 1, d) < 1) return 0;
   return d[0].open;
}

double LotForConf(int conf)
{
   if (conf >= 8) return LotConf8;
   if (conf == 7) return LotConf7;
   if (conf == 6) return LotConf6;
   if (conf == 5) return LotConf5;
   if (conf == 4) return LotConf4;
   return 0;
}

bool HasOpenForSymbol()
{
   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if (tk == 0) continue;
      if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if (PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      return true;
   }
   return false;
}

void ResetIfNewDay()
{
   datetime now = TimeCurrent();
   MqlDateTime mdt; TimeToStruct(now, mdt);
   mdt.hour = 0; mdt.min = 0; mdt.sec = 0;
   datetime today = StructToTime(mdt);
   if (today != g_dayKey)
   {
      g_dayKey = today;
      g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      g_tradesToday = 0;
      PrintFormat("EA: new day %s, startBalance=%.2f",
                  TimeToString(today, TIME_DATE), g_dayStartBalance);
   }
}

bool DailyLossExceeded()
{
   double current = AccountInfoDouble(ACCOUNT_BALANCE) + AccountInfoDouble(ACCOUNT_PROFIT);
   double loss = g_dayStartBalance - current;
   double cap  = g_dayStartBalance * DailyLossPct / 100.0;
   return loss >= cap;
}

void LogSkip(string reason)
{
   if (!LogSkipReasons) return;
   PrintFormat("EA SKIP: %s", reason);
}

void TryEntry()
{
   if (!EnableTrade)                       { LogSkip("EnableTrade=false (DEMO mode — flip ON in Inputs)"); return; }
   if (HasOpenForSymbol())                 { LogSkip("position open");   return; }
   if (g_tradesToday >= MaxTradesPerDay)   { LogSkip("max trades/day");  return; }
   if (DailyLossExceeded())                { LogSkip("daily loss cap");  return; }

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if (bid <= 0)                           { LogSkip("bid<=0");          return; }

   // Bias: only buy when above day open
   double dayOpen = DayOpen();
   if (dayOpen <= 0)                       { LogSkip("dayOpen<=0");      return; }
   if (bid <= dayOpen)
   {
      if (LogSkipReasons)
         PrintFormat("EA SKIP: bid<=dayOpen (bid=%.2f dayOpen=%.2f)", bid, dayOpen);
      return;
   }

   // Build Master Keys
   double mLvls[MAX_MASTER]; int mConf[MAX_MASTER]; int mSrc[MAX_MASTER];
   ArrayInitialize(mLvls, 0); ArrayInitialize(mConf, 0); ArrayInitialize(mSrc, 0);
   int mN = BuildMasterKeys(bid, mLvls, mConf, mSrc);
   if (mN == 0)                            { LogSkip("master empty");    return; }

   // Find nearest support (≤ bid) with conf >= MinEntryConf
   int supIdx = -1;
   for (int i = mN - 1; i >= 0; i--)
   {
      if (mLvls[i] > bid) continue;
      if (mConf[i] < MinEntryConf) continue;
      supIdx = i;
      break;
   }
   if (supIdx < 0)
   {
      if (LogSkipReasons)
         PrintFormat("EA SKIP: no support<=bid w/ conf>=%d (bid=%.2f mN=%d)",
                     MinEntryConf, bid, mN);
      return;
   }

   double sup = mLvls[supIdx];
   if (bid - sup > EntryToleranceUSD)
   {
      if (LogSkipReasons)
         PrintFormat("EA SKIP: sup too far (bid=%.2f sup=%.2f Δ=%.2f tol=%d)",
                     bid, sup, bid - sup, EntryToleranceUSD);
      return;
   }

   // EMA lock: EMA5 H1 last closed > support
   if (!EmaLockAbove(sup))
   {
      if (LogSkipReasons) PrintFormat("EA SKIP: EMA lock fail (sup=%.2f)", sup);
      return;
   }

   // Find next forward key > bid for TP
   double tpLvl = 0;
   for (int i = 0; i < mN; i++)
   {
      if (mLvls[i] <= bid + 5) continue;  // skip very close
      if (mConf[i] < 2) continue;
      tpLvl = mLvls[i];
      break;
   }
   if (tpLvl <= 0)
   {
      if (LogSkipReasons)
         PrintFormat("EA SKIP: no TP forward key w/ conf>=2 (bid=%.2f)", bid);
      return;
   }

   double sl = sup - StopLossPts;
   double lot = LotForConf(mConf[supIdx]);
   if (lot <= 0)                           { LogSkip("lot<=0");          return; }

   PrintFormat("EA BUY: sup=%.2f conf=%d sl=%.2f tp=%.2f lot=%.2f bid=%.2f",
               sup, mConf[supIdx], sl, tpLvl, lot, bid);

   if (g_trade.Buy(lot, _Symbol, ask, sl, tpLvl, "GVF conf=" + IntegerToString(mConf[supIdx])))
   {
      g_tradesToday++;
   }
   else
   {
      PrintFormat("EA BUY fail: retcode=%d %s", g_trade.ResultRetcode(), g_trade.ResultComment());
   }
}

void ManageOpen()
{
   if (!AllowBreakeven) return;
   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if (tk == 0) continue;
      if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if (PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if (PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY) continue;

      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL = PositionGetDouble(POSITION_SL);
      double curTP = PositionGetDouble(POSITION_TP);
      double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if (bid - entry < BreakevenPts) continue;
      if (curSL >= entry) continue;  // already at/above BE
      g_trade.PositionModify(tk, entry, curTP);
   }
}

//================= EA LIFECYCLE =====================
int OnInit()
{
   g_trade.SetExpertMagicNumber(MagicNumber);
   g_trade.SetMarginMode();
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_emaHandle = iMA(_Symbol, PERIOD_H1, EmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if (g_emaHandle == INVALID_HANDLE)
   {
      PrintFormat("EA: iMA failed");
      return INIT_FAILED;
   }
   ResetIfNewDay();
   MaybeRefreshIntraday();   // prime cache on attach
   EventSetTimer(5);  // poll every 5s
   PrintFormat("GoldViewFX_EA started. Magic=%d Trade=%s BuyOnly=%s",
               MagicNumber, EnableTrade ? "ON" : "OFF", BuyOnly ? "YES" : "NO");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   if (g_emaHandle != INVALID_HANDLE) IndicatorRelease(g_emaHandle);
}

void OnTimer()
{
   ResetIfNewDay();
   datetime curH1 = iTime(_Symbol, PERIOD_H1, 0);
   if (curH1 != g_lastH1Bar)
   {
      g_lastH1Bar = curH1;
      // First H1 of a new day == moment the prior day's last H1 just closed.
      // MaybeRefreshIntraday() no-ops if the date hasn't changed, so it runs
      // exactly once per day at the correct boundary.
      MaybeRefreshIntraday();
      TryEntry();
   }
   ManageOpen();
}

void OnTick()
{
   // Strategy Tester does NOT fire OnTimer. Mirror OnTimer's new-H1-bar
   // trigger here so backtest exercises the full entry path.
   ResetIfNewDay();
   datetime curH1 = iTime(_Symbol, PERIOD_H1, 0);
   if (curH1 != g_lastH1Bar)
   {
      g_lastH1Bar = curH1;
      MaybeRefreshIntraday();
      TryEntry();
   }
   ManageOpen();
}
