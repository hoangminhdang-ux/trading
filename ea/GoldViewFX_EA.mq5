//+------------------------------------------------------------------+
//|                                            GoldViewFX_EA.mq5     |
//|                         GoldViewFX Level-Bounce Strategy (H1)    |
//|                                                                    |
//|  THREE ENTRY MODES:                                                |
//|                                                                    |
//|  Mode A — Intraday Key candle touch:                               |
//|    H1 candle touches Intraday Key → enter immediately             |
//|    TP = next Intraday Key in direction                             |
//|                                                                    |
//|  Mode B — Turn Key EMA5 reversion:                                 |
//|    Price already past Turn Key, EMA5 pulls back to key            |
//|    Enter opposite to price move, TP = key value                   |
//|                                                                    |
//|  Mode C — EMA5 Lock Zone Play:                                     |
//|    Turn Key determines direction (EMA5 locked above/below)        |
//|    Intraday Keys define entry + TP (zone between 2 intraday keys) |
//|    Key strength (# Turn tiers matching intraday key) → double vol |
//|                                                                    |
//|  Data:                                                             |
//|    Intraday keys : /api/intraday-discord  (daily 05:30 VN)        |
//|    Turn Keys H1/H4/D1/W1 : /api/keys     (weekly, Sunday)        |
//+------------------------------------------------------------------+
#property copyright "BoredStudio"
#property version   "1.40"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

input group "=== API ==="
input string   InpApiBase            = "https://trading.boredstudio.ai";
input string   InpEaSecret           = "";

input group "=== Mode A — Intraday Key candle touch ==="
input bool     InpUseModeA           = true;
input double   InpModeATolPt         = 5.0;    // Candle wick tolerance to key (pt)

input group "=== Mode B — Turn Key EMA5 reversion ==="
input bool     InpUseModeB           = true;
input double   InpModeBEma5TolPt     = 3.0;    // EMA5 must be within N pt of Turn Key
input double   InpModeBPricePastPt   = 5.0;    // Price must be ≥ N pt past Turn Key

input group "=== Mode C — EMA5 Lock Zone Play ==="
input bool     InpUseModeC           = true;
input double   InpModeCEma5LockPt    = 5.0;    // EMA5 must be ≥ N pt past Turn Key to be "locked"
input double   InpModeCTolPt         = 5.0;    // Candle touch tolerance for intraday key entry
input int      InpModeCDoubleVolTiers = 2;     // Min Turn Key tiers matching intraday key → double vol

input group "=== EMA ==="
input int      InpEma5Period         = 5;

input group "=== Risk ==="
input double   InpRiskPctPerTrade    = 1.0;    // Base risk % per trade
input double   InpMaxDailyRiskPct    = 2.0;
input int      InpMaxTradesPerDay    = 2;
input double   InpSlPoints           = 20.0;
input bool     InpTrailToBreakeven   = true;
input double   InpKeyMatchTolPt      = 5.0;    // Tolerance to consider two keys "matching"

input group "=== Misc ==="
input int      InpMagic              = 20250530;
input int      InpKeyRefreshMins     = 60;

//--- State
CTrade        g_trade;
CPositionInfo g_pos;

double   g_h1Keys[];
double   g_h4Keys[];
double   g_d1Keys[];
double   g_w1Keys[];
double   g_intradayKeys[];

datetime g_lastKeyFetch    = 0;
datetime g_lastBarTime     = 0;
double   g_dayStartBalance = 0;
datetime g_dayStartDate    = 0;
int      g_tradesToday     = 0;
int      g_emaHandle       = INVALID_HANDLE;

//+------------------------------------------------------------------+
int OnInit()
{
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(10);
   g_emaHandle = iMA(_Symbol, PERIOD_H1, InpEma5Period, 0, MODE_EMA, PRICE_CLOSE);
   if(g_emaHandle == INVALID_HANDLE) { Print("[GVF EA] EMA handle failed"); return INIT_FAILED; }
   FetchAllKeys();
   ResetDailyCounters();
   PrintFormat("[GVF EA] v1.40 — H1:%d H4:%d D1:%d W1:%d Intraday:%d",
               ArraySize(g_h1Keys), ArraySize(g_h4Keys),
               ArraySize(g_d1Keys), ArraySize(g_w1Keys), ArraySize(g_intradayKeys));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_emaHandle != INVALID_HANDLE) IndicatorRelease(g_emaHandle);
}

//+------------------------------------------------------------------+
//| Main — acts on H1 bar close only                                 |
//+------------------------------------------------------------------+
void OnTick()
{
   datetime barTime = iTime(_Symbol, PERIOD_H1, 0);
   if(barTime == g_lastBarTime) return;
   g_lastBarTime = barTime;

   if(TimeCurrent() - g_lastKeyFetch > InpKeyRefreshMins * 60) FetchAllKeys();

   MqlDateTime now, ds;
   TimeToStruct(TimeCurrent(), now);
   TimeToStruct(g_dayStartDate, ds);
   if(now.day != ds.day || now.mon != ds.mon) ResetDailyCounters();

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if((balance - g_dayStartBalance) <= -(g_dayStartBalance * InpMaxDailyRiskPct / 100.0)) {
      Print("[GVF EA] Daily limit hit"); return;
   }
   if(g_tradesToday >= InpMaxTradesPerDay) return;
   if(HasOpenPosition()) { CheckBreakevenTrail(); return; }

   if(ArraySize(g_intradayKeys) == 0) return;

   double pt      = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double dayOpen = GetDayOpen();

   double emaBuf[1];
   if(CopyBuffer(g_emaHandle, 0, 1, 1, emaBuf) < 1) return;
   double ema5 = emaBuf[0];

   MqlRates h1[];
   if(CopyRates(_Symbol, PERIOD_H1, 1, 1, h1) < 1) return;

   bool bullBias = (bid > dayOpen);
   bool bearBias = (bid < dayOpen);

   // ── MODE A: Intraday Key candle touch ─────────────────────────
   if(InpUseModeA) {
      for(int i = 0; i < ArraySize(g_intradayKeys); i++) {
         double key = g_intradayKeys[i];
         bool touchBuy  = (h1[0].low  <= key + InpModeATolPt * pt) && (h1[0].close > key);
         bool touchSell = (h1[0].high >= key - InpModeATolPt * pt) && (h1[0].close < key);

         if(bullBias && touchBuy) {
            double tp = FindNextIntradayKey(key, 1);
            if(tp == 0) continue;
            double lots = CalcLots(InpSlPoints * pt, InpRiskPctPerTrade);
            double sl   = key - InpSlPoints * pt;
            PrintFormat("[GVF EA] MODE-A BUY key=%.2f sl=%.2f tp=%.2f lots=%.2f", key, sl, tp, lots);
            if(g_trade.Buy(lots, _Symbol, ask, sl, tp, "GVF-A")) { g_tradesToday++; return; }
         }
         if(bearBias && touchSell) {
            double tp = FindNextIntradayKey(key, -1);
            if(tp == 0) continue;
            double lots = CalcLots(InpSlPoints * pt, InpRiskPctPerTrade);
            double sl   = key + InpSlPoints * pt;
            PrintFormat("[GVF EA] MODE-A SELL key=%.2f sl=%.2f tp=%.2f lots=%.2f", key, sl, tp, lots);
            if(g_trade.Sell(lots, _Symbol, bid, sl, tp, "GVF-A")) { g_tradesToday++; return; }
         }
      }
   }

   // ── MODE B: Turn Key EMA5 reversion ──────────────────────────
   if(InpUseModeB && ArraySize(g_h1Keys) > 0) {
      for(int i = 0; i < ArraySize(g_h1Keys); i++) {
         double key      = g_h1Keys[i];
         double ema5Dist = MathAbs(ema5 - key);
         if(ema5Dist > InpModeBEma5TolPt * pt) continue;

         bool priceBelow = (bid < key - InpModeBPricePastPt * pt);
         bool priceAbove = (bid > key + InpModeBPricePastPt * pt);

         if(priceBelow && ema5 >= key) {
            double lots = CalcLots(InpSlPoints * pt, InpRiskPctPerTrade);
            double sl   = bid - InpSlPoints * pt;
            PrintFormat("[GVF EA] MODE-B BUY TurnKey=%.2f ema5=%.2f price=%.2f tp=%.2f", key, ema5, bid, key);
            if(g_trade.Buy(lots, _Symbol, ask, sl, key, "GVF-B")) { g_tradesToday++; return; }
         }
         if(priceAbove && ema5 <= key) {
            double lots = CalcLots(InpSlPoints * pt, InpRiskPctPerTrade);
            double sl   = bid + InpSlPoints * pt;
            PrintFormat("[GVF EA] MODE-B SELL TurnKey=%.2f ema5=%.2f price=%.2f tp=%.2f", key, ema5, bid, key);
            if(g_trade.Sell(lots, _Symbol, bid, sl, key, "GVF-B")) { g_tradesToday++; return; }
         }
      }
   }

   // ── MODE C: EMA5 Lock Zone Play ───────────────────────────────
   // Step 1: find Turn Key EMA5 is locked above/below
   // Step 2: find 2 Intraday Keys surrounding price (zone)
   // Step 3: enter at zone boundary in locked direction, TP = opposite boundary
   // Step 4: if entry Intraday Key matches ≥ InpModeCDoubleVolTiers Turn Key tiers → double vol
   if(InpUseModeC && ArraySize(g_h1Keys) > 0 && ArraySize(g_intradayKeys) > 0) {
      // Find the Turn Key EMA5 is locked relative to
      double lockedTurnKey = 0;
      bool   lockedBull    = false;
      bool   lockedBear    = false;
      for(int i = 0; i < ArraySize(g_h1Keys); i++) {
         double key = g_h1Keys[i];
         if(ema5 > key + InpModeCEma5LockPt * pt) {
            // EMA5 locked above this key — bullish
            // Use the highest such key (closest lock below EMA5)
            if(lockedTurnKey == 0 || key > lockedTurnKey) {
               lockedTurnKey = key; lockedBull = true; lockedBear = false;
            }
         }
         else if(ema5 < key - InpModeCEma5LockPt * pt) {
            // EMA5 locked below this key — bearish
            // Use the lowest such key (closest lock above EMA5)
            if(lockedTurnKey == 0 || key < lockedTurnKey) {
               lockedTurnKey = key; lockedBear = true; lockedBull = false;
            }
         }
      }
      if(lockedTurnKey == 0) goto skipModeC;

      // Find intraday zone: nearest key below and above price
      double zoneAbove = 0, zoneBelow = 0;
      double distAbove = 9e9, distBelow = 9e9;
      for(int i = 0; i < ArraySize(g_intradayKeys); i++) {
         double ik = g_intradayKeys[i];
         double diff = ik - bid;
         if(diff > 0 && diff < distAbove) { distAbove = diff; zoneAbove = ik; }
         if(diff < 0 && -diff < distBelow) { distBelow = -diff; zoneBelow = ik; }
      }
      if(zoneAbove == 0 || zoneBelow == 0) goto skipModeC;

      if(lockedBull) {
         // Direction = UP → BUY at zoneBelow (lower intraday key), TP = zoneAbove
         bool touchLower = (h1[0].low <= zoneBelow + InpModeCTolPt * pt) && (h1[0].close > zoneBelow);
         if(touchLower) {
            int    tiers = CountTurnKeyMatches(zoneBelow);
            double riskPct = (tiers >= InpModeCDoubleVolTiers) ? InpRiskPctPerTrade * 2.0 : InpRiskPctPerTrade;
            double lots    = CalcLots(InpSlPoints * pt, riskPct);
            double sl      = zoneBelow - InpSlPoints * pt;
            PrintFormat("[GVF EA] MODE-C BUY lock=%.2f zone=%.2f-%.2f tiers=%d lots=%.2f",
                        lockedTurnKey, zoneBelow, zoneAbove, tiers, lots);
            if(g_trade.Buy(lots, _Symbol, ask, sl, zoneAbove, "GVF-C")) { g_tradesToday++; return; }
         }
      }
      else if(lockedBear) {
         // Direction = DOWN → SELL at zoneAbove (upper intraday key), TP = zoneBelow
         bool touchUpper = (h1[0].high >= zoneAbove - InpModeCTolPt * pt) && (h1[0].close < zoneAbove);
         if(touchUpper) {
            int    tiers = CountTurnKeyMatches(zoneAbove);
            double riskPct = (tiers >= InpModeCDoubleVolTiers) ? InpRiskPctPerTrade * 2.0 : InpRiskPctPerTrade;
            double lots    = CalcLots(InpSlPoints * pt, riskPct);
            double sl      = zoneAbove + InpSlPoints * pt;
            PrintFormat("[GVF EA] MODE-C SELL lock=%.2f zone=%.2f-%.2f tiers=%d lots=%.2f",
                        lockedTurnKey, zoneBelow, zoneAbove, tiers, lots);
            if(g_trade.Sell(lots, _Symbol, bid, sl, zoneBelow, "GVF-C")) { g_tradesToday++; return; }
         }
      }
   }
   skipModeC:;
}

//+------------------------------------------------------------------+
//| Count how many Turn Key tiers (H1/H4/D1/W1) match given key     |
//+------------------------------------------------------------------+
int CountTurnKeyMatches(double key)
{
   double tol = InpKeyMatchTolPt * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int count  = 0;
   if(IsKeyIn(key, g_h1Keys, tol)) count++;
   if(IsKeyIn(key, g_h4Keys, tol)) count++;
   if(IsKeyIn(key, g_d1Keys, tol)) count++;
   if(IsKeyIn(key, g_w1Keys, tol)) count++;
   return count;
}

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
bool IsKeyIn(double key, const double &arr[], double tol)
{
   for(int i = 0; i < ArraySize(arr); i++)
      if(MathAbs(arr[i] - key) <= tol) return true;
   return false;
}

double FindNextIntradayKey(double fromKey, int dir)
{
   double best = 0, bestDist = 9e9;
   for(int i = 0; i < ArraySize(g_intradayKeys); i++) {
      double diff = g_intradayKeys[i] - fromKey;
      if(dir > 0 && diff > 0.5 && diff < bestDist) { bestDist = diff; best = g_intradayKeys[i]; }
      if(dir < 0 && diff < -0.5 && -diff < bestDist) { bestDist = -diff; best = g_intradayKeys[i]; }
   }
   return best;
}

double CalcLots(double slDist, double riskPct)
{
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmt  = balance * riskPct / 100.0;
   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickVal <= 0 || tickSize <= 0 || slDist <= 0) return 0;
   double lots = riskAmt / (slDist / tickSize * tickVal);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   return MathMax(minLot, MathMin(maxLot, MathFloor(lots / step) * step));
}

double GetDayOpen()
{
   MqlRates r[];
   return CopyRates(_Symbol, PERIOD_D1, 0, 1, r) > 0 ? r[0].open : 0;
}

bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(g_pos.SelectByIndex(i) && g_pos.Symbol() == _Symbol && g_pos.Magic() == InpMagic)
         return true;
   return false;
}

void CheckBreakevenTrail()
{
   if(!InpTrailToBreakeven) return;
   double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(!g_pos.SelectByIndex(i)) continue;
      if(g_pos.Symbol() != _Symbol || g_pos.Magic() != InpMagic) continue;
      double open = g_pos.PriceOpen(), sl = g_pos.StopLoss(), tp = g_pos.TakeProfit();
      if(g_pos.PositionType() == POSITION_TYPE_BUY) {
         if((SymbolInfoDouble(_Symbol, SYMBOL_BID) - open) / pt >= InpSlPoints && sl < open)
            g_trade.PositionModify(g_pos.Ticket(), open + pt, tp);
      } else {
         if((open - SymbolInfoDouble(_Symbol, SYMBOL_ASK)) / pt >= InpSlPoints && sl > open)
            g_trade.PositionModify(g_pos.Ticket(), open - pt, tp);
      }
   }
}

void ResetDailyCounters()
{
   g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_dayStartDate    = TimeCurrent();
   g_tradesToday     = 0;
}

//+------------------------------------------------------------------+
//| Key fetching                                                     |
//+------------------------------------------------------------------+
void FetchAllKeys()
{
   FetchTurnKeys();
   FetchIntradayKeys();
   g_lastKeyFetch = TimeCurrent();
}

void FetchTurnKeys()
{
   char post[], result[];
   string headers = "Content-Type: application/json\r\n", resH;
   int s = WebRequest("GET", InpApiBase + "/api/keys", headers, 5000, post, result, resH);
   if(s != 200) { PrintFormat("[GVF EA] /api/keys HTTP %d", s); return; }
   string json = CharArrayToString(result);
   ParseJsonArray(json, "\"h1Turn\"",    g_h1Keys);
   ParseJsonArray(json, "\"h4Turn\"",    g_h4Keys);
   ParseJsonArray(json, "\"dailyTurn\"", g_d1Keys);
   ParseJsonArray(json, "\"weekTurn\"",  g_w1Keys);
   PrintFormat("[GVF EA] TurnKeys H1:%d H4:%d D1:%d W1:%d",
               ArraySize(g_h1Keys), ArraySize(g_h4Keys),
               ArraySize(g_d1Keys), ArraySize(g_w1Keys));
}

void FetchIntradayKeys()
{
   char post[], result[];
   string headers = "Content-Type: application/json\r\n", resH;
   int s = WebRequest("GET", InpApiBase + "/api/intraday-discord", headers, 5000, post, result, resH);
   if(s != 200) { PrintFormat("[GVF EA] /api/intraday-discord HTTP %d", s); return; }
   string json = CharArrayToString(result);
   ParseJsonArray(json, "\"levels\"", g_intradayKeys);
   PrintFormat("[GVF EA] Intraday Discord keys: %d", ArraySize(g_intradayKeys));
}

void ParseJsonArray(const string &json, const string &key, double &out[])
{
   ArrayResize(out, 0);
   int kp = StringFind(json, key);
   if(kp < 0) return;
   int s = StringFind(json, "[", kp), e = StringFind(json, "]", s);
   if(s < 0 || e < 0) return;
   string parts[];
   int n = StringSplit(StringSubstr(json, s + 1, e - s - 1), ',', parts);
   for(int i = 0; i < n; i++) {
      StringTrimLeft(parts[i]); StringTrimRight(parts[i]);
      double v = StringToDouble(parts[i]);
      if(v > 0) { int sz = ArraySize(out); ArrayResize(out, sz + 1); out[sz] = v; }
   }
}
