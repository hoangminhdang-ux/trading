//+------------------------------------------------------------------+
//|                                            GoldViewFX_EA.mq5     |
//|                         GoldViewFX Level-Bounce Strategy (H1)    |
//|                                                                    |
//|  TWO ENTRY MODES:                                                  |
//|                                                                    |
//|  Mode A — Intraday Key (fast):                                     |
//|    Candle body touches Intraday Key → enter immediately            |
//|    TP = next intraday/turn key in direction                        |
//|                                                                    |
//|  Mode B — Turn Key (EMA5 reversion):                               |
//|    Price already past Turn Key                                     |
//|    Wait for EMA5 H1 to pull back and TOUCH the key                |
//|    Enter opposite to price move, TP = the key value itself         |
//|    e.g. price < key, EMA5 touches key from above → BUY, TP = key  |
//|                                                                    |
//|  Data:                                                             |
//|    Intraday keys : /api/intraday-discord  (daily 05:30 VN)        |
//|    Turn Keys H1/H4/D1/W1 : /api/keys     (weekly, Sunday)        |
//+------------------------------------------------------------------+
#property copyright "BoredStudio"
#property version   "1.30"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

input group "=== API ==="
input string   InpApiBase           = "https://trading.boredstudio.ai";
input string   InpEaSecret          = "";

input group "=== Intraday Key Entry (Mode A) ==="
input bool     InpUseIntradayMode   = true;
input double   InpIntradayTolPt     = 5.0;   // Candle wick tolerance to touch key (pt)

input group "=== Turn Key Entry (Mode B) ==="
input bool     InpUseTurnKeyMode    = true;
input double   InpEma5TolPt         = 3.0;   // EMA5 must be within N pt of key
input double   InpPricePastKeyPt    = 5.0;   // Price must be at least N pt past key
input int      InpEma5Period        = 5;

input group "=== Risk ==="
input double   InpRiskPctPerTrade   = 1.0;
input double   InpMaxDailyRiskPct   = 2.0;
input int      InpMaxTradesPerDay   = 2;
input double   InpSlPoints          = 20.0;
input bool     InpTrailToBreakeven  = true;

input group "=== Misc ==="
input int      InpMagic             = 20250530;
input int      InpKeyRefreshMins    = 60;

//--- State
CTrade        g_trade;
CPositionInfo g_pos;

double   g_h1Keys[];
double   g_h4Keys[];
double   g_d1Keys[];
double   g_w1Keys[];
double   g_intradayKeys[];

datetime g_lastKeyFetch = 0;
datetime g_lastBarTime  = 0;
double   g_dayStartBalance = 0;
datetime g_dayStartDate    = 0;
int      g_tradesToday     = 0;
int      g_emaHandle = INVALID_HANDLE;

//+------------------------------------------------------------------+
int OnInit()
{
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(10);
   g_emaHandle = iMA(_Symbol, PERIOD_H1, InpEma5Period, 0, MODE_EMA, PRICE_CLOSE);
   if(g_emaHandle == INVALID_HANDLE) { Print("[GVF EA] EMA handle failed"); return INIT_FAILED; }
   FetchAllKeys();
   ResetDailyCounters();
   PrintFormat("[GVF EA] v1.30 Init — H1:%d H4:%d D1:%d W1:%d Intraday:%d",
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

   double pt      = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double dayOpen = GetDayOpen();

   // EMA5 last closed bar
   double emaBuf[1];
   if(CopyBuffer(g_emaHandle, 0, 1, 1, emaBuf) < 1) return;
   double ema5 = emaBuf[0];

   // Last closed H1 candle OHLC
   MqlRates h1[];
   if(CopyRates(_Symbol, PERIOD_H1, 1, 1, h1) < 1) return;

   bool bullBias = (bid > dayOpen);
   bool bearBias = (bid < dayOpen);

   // ── MODE A: Intraday Key — candle touch ───────────────────────
   if(InpUseIntradayMode && ArraySize(g_intradayKeys) > 0) {
      for(int i = 0; i < ArraySize(g_intradayKeys); i++) {
         double key = g_intradayKeys[i];
         bool candleTouchBuy  = (h1[0].low  <= key + InpIntradayTolPt * pt) && (h1[0].close > key);
         bool candleTouchSell = (h1[0].high >= key - InpIntradayTolPt * pt) && (h1[0].close < key);

         if(bullBias && candleTouchBuy) {
            double tp = FindNextKey(key, 1);
            if(tp == 0) continue;
            double lots = CalcLots(InpSlPoints * pt, InpRiskPctPerTrade);
            double sl   = key - InpSlPoints * pt;
            PrintFormat("[GVF EA] MODE-A BUY Intraday key=%.2f sl=%.2f tp=%.2f lots=%.2f", key, sl, tp, lots);
            if(g_trade.Buy(lots, _Symbol, ask, sl, tp, "GVF-intraday")) { g_tradesToday++; return; }
         }
         if(bearBias && candleTouchSell) {
            double tp = FindNextKey(key, -1);
            if(tp == 0) continue;
            double lots = CalcLots(InpSlPoints * pt, InpRiskPctPerTrade);
            double sl   = key + InpSlPoints * pt;
            PrintFormat("[GVF EA] MODE-A SELL Intraday key=%.2f sl=%.2f tp=%.2f lots=%.2f", key, sl, tp, lots);
            if(g_trade.Sell(lots, _Symbol, bid, sl, tp, "GVF-intraday")) { g_tradesToday++; return; }
         }
      }
   }

   // ── MODE B: Turn Key — EMA5 reversion ────────────────────────
   // BUY: price already dropped BELOW key, EMA5 now touches key from above → enter BUY, TP = key
   // SELL: price already rose ABOVE key,   EMA5 now touches key from below → enter SELL, TP = key
   if(InpUseTurnKeyMode && ArraySize(g_h1Keys) > 0) {
      for(int i = 0; i < ArraySize(g_h1Keys); i++) {
         double key     = g_h1Keys[i];
         double ema5Dist = MathAbs(ema5 - key);
         if(ema5Dist > InpEma5TolPt * pt) continue; // EMA5 not near key yet

         bool priceBelow = (bid < key - InpPricePastKeyPt * pt); // price already past key downward
         bool priceAbove = (bid > key + InpPricePastKeyPt * pt); // price already past key upward
         bool ema5Above  = (ema5 >= key);                         // EMA5 at/above key (touching from above)
         bool ema5Below  = (ema5 <= key);                         // EMA5 at/below key (touching from below)

         // BUY: price below key, EMA5 touches key from above
         if(priceBelow && ema5Above) {
            double lots = CalcLots(InpSlPoints * pt, InpRiskPctPerTrade);
            double sl   = bid - InpSlPoints * pt;
            double tp   = key; // return to key
            PrintFormat("[GVF EA] MODE-B BUY TurnKey=%.2f ema5=%.2f price=%.2f sl=%.2f tp=%.2f lots=%.2f",
                        key, ema5, bid, sl, tp, lots);
            if(g_trade.Buy(lots, _Symbol, ask, sl, tp, "GVF-turnkey")) { g_tradesToday++; return; }
         }

         // SELL: price above key, EMA5 touches key from below
         if(priceAbove && ema5Below) {
            double lots = CalcLots(InpSlPoints * pt, InpRiskPctPerTrade);
            double sl   = bid + InpSlPoints * pt;
            double tp   = key; // return to key
            PrintFormat("[GVF EA] MODE-B SELL TurnKey=%.2f ema5=%.2f price=%.2f sl=%.2f tp=%.2f lots=%.2f",
                        key, ema5, bid, sl, tp, lots);
            if(g_trade.Sell(lots, _Symbol, bid, sl, tp, "GVF-turnkey")) { g_tradesToday++; return; }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+

// Find next key in direction across ALL sources (intraday + h1 turn)
double FindNextKey(double fromKey, int dir)
{
   double best = 0, bestDist = 9e9;
   // Merge h1 turn + intraday into search
   int total = ArraySize(g_h1Keys) + ArraySize(g_intradayKeys);
   double merged[];
   ArrayResize(merged, total);
   int idx = 0;
   for(int i = 0; i < ArraySize(g_h1Keys);      i++) merged[idx++] = g_h1Keys[i];
   for(int i = 0; i < ArraySize(g_intradayKeys); i++) merged[idx++] = g_intradayKeys[i];

   for(int i = 0; i < total; i++) {
      double diff = merged[i] - fromKey;
      if(dir > 0 && diff > 0.5 && diff < bestDist) { bestDist = diff; best = merged[i]; }
      if(dir < 0 && diff < -0.5 && -diff < bestDist) { bestDist = -diff; best = merged[i]; }
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
