//+------------------------------------------------------------------+
//|                                            GoldViewFX_EA.mq5     |
//|                         GoldViewFX Level-Bounce Strategy (H1)    |
//|                                                                    |
//|  Data sources:                                                     |
//|    - Intraday keys : /api/intraday-discord  (daily 05:00 VN)     |
//|    - Turn Keys H1/H4/D1/W1 : /api/keys     (weekly, Sunday)      |
//|                                                                    |
//|  Entry logic:                                                      |
//|    - Price within ±10pt of H1 Turn Key                            |
//|    - EMA5 H1 fresh cross & lock through the key                   |
//|    - Confluence score >= 4 (multi-tier source overlap)            |
//|    - SL = 20pt beyond key, TP = next H1 Turn Key                  |
//|    - R:R ~3.8:1  |  1%/trade  |  max 2%/day  |  max 2 trades    |
//+------------------------------------------------------------------+
#property copyright "BoredStudio"
#property version   "1.20"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//--- Inputs
input group "=== API ==="
input string   InpApiBase          = "https://trading.boredstudio.ai";
input string   InpEaSecret         = "";

input group "=== Entry ==="
input double   InpLevelTolerancePt = 10.0;    // Entry zone ±pt from key
input int      InpMinConfluence    = 4;        // Min confluence score (0–10)
input bool     InpRequireEma5Lock  = true;     // Require EMA5 H1 fresh cross
input int      InpEma5Period       = 5;

input group "=== Risk ==="
input double   InpRiskPctPerTrade  = 1.0;      // Risk % per trade
input double   InpMaxDailyRiskPct  = 2.0;      // Max daily loss %
input int      InpMaxTradesPerDay  = 2;
input double   InpSlPoints         = 20.0;     // SL distance in points from key
input bool     InpTrailToBreakeven = true;     // Move SL to BE after 1:1

input group "=== Misc ==="
input int      InpMagic            = 20250530;
input int      InpKeyRefreshMins   = 60;       // Refresh keys every N minutes

//--- State
CTrade        g_trade;
CPositionInfo g_pos;

// Turn Keys: updated weekly (Sunday) from /api/keys
double   g_h1Keys[];
double   g_h4Keys[];
double   g_d1Keys[];
double   g_w1Keys[];

// Intraday Keys: updated daily (05:00 VN) from /api/intraday-discord
double   g_intradayKeys[];

datetime g_lastKeyFetch = 0;
datetime g_lastBarTime  = 0;

double   g_dayStartBalance = 0;
datetime g_dayStartDate    = 0;
int      g_tradesToday     = 0;

int      g_emaHandle = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| Init                                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(10);

   g_emaHandle = iMA(_Symbol, PERIOD_H1, InpEma5Period, 0, MODE_EMA, PRICE_CLOSE);
   if(g_emaHandle == INVALID_HANDLE) {
      Print("[GVF EA] EMA handle failed");
      return INIT_FAILED;
   }

   FetchAllKeys();
   ResetDailyCounters();

   PrintFormat("[GVF EA] Init OK — H1:%d H4:%d D1:%d W1:%d Intraday:%d keys loaded",
               ArraySize(g_h1Keys), ArraySize(g_h4Keys),
               ArraySize(g_d1Keys), ArraySize(g_w1Keys),
               ArraySize(g_intradayKeys));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_emaHandle != INVALID_HANDLE) IndicatorRelease(g_emaHandle);
}

//+------------------------------------------------------------------+
//| Tick — only acts on H1 bar close                                 |
//+------------------------------------------------------------------+
void OnTick()
{
   datetime barTime = iTime(_Symbol, PERIOD_H1, 0);
   if(barTime == g_lastBarTime) return;
   g_lastBarTime = barTime;

   if(TimeCurrent() - g_lastKeyFetch > InpKeyRefreshMins * 60)
      FetchAllKeys();

   // New day check (UTC)
   MqlDateTime now, dayStart;
   TimeToStruct(TimeCurrent(), now);
   TimeToStruct(g_dayStartDate, dayStart);
   if(now.day != dayStart.day || now.mon != dayStart.mon)
      ResetDailyCounters();

   // Daily loss limit
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double dailyPnL = balance - g_dayStartBalance;
   if(dailyPnL <= -(g_dayStartBalance * InpMaxDailyRiskPct / 100.0)) {
      Print("[GVF EA] Daily limit hit — no more trades today");
      return;
   }

   if(g_tradesToday >= InpMaxTradesPerDay) return;

   if(HasOpenPosition()) {
      CheckBreakevenTrail();
      return;
   }

   if(ArraySize(g_h1Keys) == 0) return;

   double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double pt      = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double dayOpen = GetDayOpen();

   // EMA5 H1 last two closed bars
   double emaBuf[2];
   if(CopyBuffer(g_emaHandle, 0, 1, 2, emaBuf) < 2) return;
   double emaPrev = emaBuf[0]; // bar[2]
   double emaCurr = emaBuf[1]; // bar[1]

   // Find nearest H1 key within tolerance
   double nearestKey = 0;
   double bestDist   = 9e9;
   for(int i = 0; i < ArraySize(g_h1Keys); i++) {
      double d = MathAbs(bid - g_h1Keys[i]);
      if(d < bestDist) { bestDist = d; nearestKey = g_h1Keys[i]; }
   }
   if(nearestKey == 0 || bestDist > InpLevelTolerancePt * pt) return;

   bool bullBias    = (bid > dayOpen);
   bool bearBias    = (bid < dayOpen);
   bool ema5CrossUp = (emaPrev <= nearestKey && emaCurr > nearestKey);
   bool ema5CrossDn = (emaPrev >= nearestKey && emaCurr < nearestKey);

   if(InpRequireEma5Lock && !ema5CrossUp && !ema5CrossDn) return;

   int score = ComputeConfluence(bid, nearestKey, dayOpen, emaCurr);
   if(score < InpMinConfluence) {
      PrintFormat("[GVF EA] Key %.2f score=%d < %d, skip", nearestKey, score, InpMinConfluence);
      return;
   }

   double tpKey = FindNextH1Key(nearestKey, bullBias ? 1 : -1);
   if(tpKey == 0) return;

   double lots = CalcLots(InpSlPoints * pt, InpRiskPctPerTrade);
   if(lots <= 0) return;

   bool doLong  = bullBias && (InpRequireEma5Lock ? ema5CrossUp : emaCurr > nearestKey);
   bool doShort = bearBias && (InpRequireEma5Lock ? ema5CrossDn : emaCurr < nearestKey);

   if(doLong) {
      double sl = nearestKey - InpSlPoints * pt;
      PrintFormat("[GVF EA] BUY @ %.2f | key=%.2f SL=%.2f TP=%.2f score=%d lots=%.2f",
                  ask, nearestKey, sl, tpKey, score, lots);
      if(g_trade.Buy(lots, _Symbol, ask, sl, tpKey, "GVF")) g_tradesToday++;
   }
   else if(doShort) {
      double sl = nearestKey + InpSlPoints * pt;
      PrintFormat("[GVF EA] SELL @ %.2f | key=%.2f SL=%.2f TP=%.2f score=%d lots=%.2f",
                  bid, nearestKey, sl, tpKey, score, lots);
      if(g_trade.Sell(lots, _Symbol, bid, sl, tpKey, "GVF")) g_tradesToday++;
   }
}

//+------------------------------------------------------------------+
//| Confluence Score (0–10)                                          |
//|                                                                    |
//|  +1  Price on correct side of Day Open                           |
//|  +1  EMA5 aligned with direction                                 |
//|  +1  Key in H1 Turn Keys  (always true if we got here)           |
//|  +1  Key also in H4 Turn Keys                                    |
//|  +1  Key also in D1 Turn Keys                                    |
//|  +1  Key also in W1 Turn Keys                                    |
//|  +2  Key also in Intraday Discord keys (GVF daily confirmation)  |
//|  +1  Price distance 5–10pt (clean touch, not overextended)       |
//+------------------------------------------------------------------+
int ComputeConfluence(double price, double key, double dayOpen, double ema5)
{
   int    score  = 0;
   double pt     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   bool   bull   = (price > key);
   double dist   = MathAbs(price - key);
   double tol    = 5.0 * pt;

   if(bull  && price > dayOpen) score++;
   if(!bull && price < dayOpen) score++;

   if(bull  && ema5 > key) score++;
   if(!bull && ema5 < key) score++;

   // Turn Key source overlap
   score++;                                              // H1: always (entry condition)
   if(IsKeyIn(key, g_h4Keys, tol)) score++;             // H4 confluence
   if(IsKeyIn(key, g_d1Keys, tol)) score++;             // D1 confluence
   if(IsKeyIn(key, g_w1Keys, tol)) score++;             // W1 confluence

   // Intraday Discord confirmation (strongest signal: GVF posted it today)
   if(IsKeyIn(key, g_intradayKeys, tol)) score += 2;

   // Clean distance from key
   if(dist > 5.0 * pt && dist < InpLevelTolerancePt * pt) score++;

   return score;
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

double FindNextH1Key(double key, int dir)
{
   double best = 0, bestDist = 9e9;
   for(int i = 0; i < ArraySize(g_h1Keys); i++) {
      double diff = g_h1Keys[i] - key;
      if(dir > 0 && diff > 0 && diff < bestDist) { bestDist = diff; best = g_h1Keys[i]; }
      if(dir < 0 && diff < 0 && -diff < bestDist) { bestDist = -diff; best = g_h1Keys[i]; }
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
   double lots    = riskAmt / (slDist / tickSize * tickVal);
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
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
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if((bid - open) / pt >= InpSlPoints && sl < open)
            g_trade.PositionModify(g_pos.Ticket(), open + pt, tp);
      } else {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         if((open - ask) / pt >= InpSlPoints && sl > open)
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
//| Key Fetching                                                     |
//+------------------------------------------------------------------+
void FetchAllKeys()
{
   FetchTurnKeys();
   FetchIntradayKeys();
   g_lastKeyFetch = TimeCurrent();
}

void FetchTurnKeys()
{
   char postData[], result[];
   string headers = "Content-Type: application/json\r\n", resHeaders;
   int status = WebRequest("GET", InpApiBase + "/api/keys", headers, 5000, postData, result, resHeaders);
   if(status != 200) { PrintFormat("[GVF EA] /api/keys failed: %d", status); return; }
   string json = CharArrayToString(result);
   ParseJsonArray(json, "\"h1Turn\"",    g_h1Keys);
   ParseJsonArray(json, "\"h4Turn\"",    g_h4Keys);
   ParseJsonArray(json, "\"dailyTurn\"", g_d1Keys);
   ParseJsonArray(json, "\"weekTurn\"",  g_w1Keys);
   PrintFormat("[GVF EA] Turn Keys — H1:%d H4:%d D1:%d W1:%d",
               ArraySize(g_h1Keys), ArraySize(g_h4Keys),
               ArraySize(g_d1Keys), ArraySize(g_w1Keys));
}

void FetchIntradayKeys()
{
   char postData[], result[];
   string headers = "Content-Type: application/json\r\n", resHeaders;
   int status = WebRequest("GET", InpApiBase + "/api/intraday-discord", headers, 5000, postData, result, resHeaders);
   if(status != 200) { PrintFormat("[GVF EA] /api/intraday-discord failed: %d", status); return; }
   string json = CharArrayToString(result);
   ParseJsonArray(json, "\"levels\"", g_intradayKeys);
   PrintFormat("[GVF EA] Intraday Discord keys: %d", ArraySize(g_intradayKeys));
}

void ParseJsonArray(const string &json, const string &key, double &out[])
{
   ArrayResize(out, 0);
   int kPos = StringFind(json, key);
   if(kPos < 0) return;
   int s = StringFind(json, "[", kPos);
   int e = StringFind(json, "]", s);
   if(s < 0 || e < 0) return;
   string parts[];
   int n = StringSplit(StringSubstr(json, s + 1, e - s - 1), ',', parts);
   for(int i = 0; i < n; i++) {
      StringTrimLeft(parts[i]); StringTrimRight(parts[i]);
      double v = StringToDouble(parts[i]);
      if(v > 0) { int sz = ArraySize(out); ArrayResize(out, sz + 1); out[sz] = v; }
   }
}
