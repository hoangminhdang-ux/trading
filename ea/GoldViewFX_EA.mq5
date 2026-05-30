//+------------------------------------------------------------------+
//|                                            GoldViewFX_EA.mq5     |
//|                         GoldViewFX Level-Bounce Strategy (H1)    |
//|                                                                    |
//|  Logic:                                                            |
//|    - Price bounces between H1 Turn Keys (GoldViewFX levels)       |
//|    - Entry when price touches key + EMA5 H1 locks direction       |
//|    - Confluence >= 4 required (multi-factor score)                |
//|    - SL = 20 pts beyond key, TP = next Turn Key                   |
//|    - R:R ~3.8:1, risk 1% per trade, max 2%/day                   |
//+------------------------------------------------------------------+
#property copyright "BoredStudio"
#property version   "1.10"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Arrays\ArrayDouble.mqh>

//--- Inputs
input group "=== API ==="
input string   InpApiBase          = "https://trading.boredstudio.ai";
input string   InpEaSecret         = "";              // X-EA-Secret (for /sync endpoint)

input group "=== Entry ==="
input double   InpLevelTolerancePt = 10.0;            // Entry zone ±points from key
input int      InpMinConfluence    = 4;               // Minimum confluence score (1–10)
input bool     InpRequireEma5Lock  = true;            // Require EMA5 H1 lock confirmation
input int      InpEma5Period       = 5;               // EMA period (default 5)

input group "=== Risk ==="
input double   InpRiskPctPerTrade  = 1.0;             // Risk % per trade (of balance)
input double   InpMaxDailyRiskPct  = 2.0;             // Max daily drawdown %
input int      InpMaxTradesPerDay  = 2;               // Max trades per calendar day
input double   InpSlPoints         = 20.0;            // SL distance in points from key
input bool     InpTrailToBreakeven = true;            // Move SL to BE after 1:1

input group "=== Misc ==="
input int      InpMagic            = 20250530;
input int      InpKeyRefreshMins   = 60;              // How often to refresh keys from API

//--- State
CTrade         g_trade;
CPositionInfo  g_pos;

double   g_turnKeys[];       // H1 Turn Keys from API
double   g_intradayKeys[];   // Intraday Discord keys from API
datetime g_lastKeyFetch  = 0;
datetime g_lastBarTime   = 0;

double   g_dayStartBalance = 0;
datetime g_dayStartDate    = 0;
int      g_tradesToday     = 0;
datetime g_lastTradeDate   = 0;

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
      Print("[GVF EA] Failed to create EMA handle");
      return INIT_FAILED;
   }

   FetchKeys();
   ResetDailyCounters();
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Deinit                                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_emaHandle != INVALID_HANDLE) IndicatorRelease(g_emaHandle);
}

//+------------------------------------------------------------------+
//| Tick                                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Only act on H1 bar close
   datetime barTime = iTime(_Symbol, PERIOD_H1, 0);
   if(barTime == g_lastBarTime) return;
   g_lastBarTime = barTime;

   // Refresh keys periodically
   if(TimeCurrent() - g_lastKeyFetch > InpKeyRefreshMins * 60)
      FetchKeys();

   // Reset daily counters at new day (UTC)
   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);
   MqlDateTime dayStart;
   TimeToStruct(g_dayStartDate, dayStart);
   if(now.day != dayStart.day || now.mon != dayStart.mon)
      ResetDailyCounters();

   // Check daily loss limit
   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double dailyPnL   = balance - g_dayStartBalance;
   double maxLoss    = g_dayStartBalance * InpMaxDailyRiskPct / 100.0;
   if(dailyPnL <= -maxLoss) {
      Print("[GVF EA] Daily loss limit hit. No new trades today.");
      return;
   }

   // Check max trades/day
   if(g_tradesToday >= InpMaxTradesPerDay) return;

   // No new entries if position open for this symbol+magic
   if(HasOpenPosition()) {
      CheckBreakevenTrail();
      return;
   }

   // Get H1 close and EMA5
   double close1 = iClose(_Symbol, PERIOD_H1, 1); // last closed candle
   double ema5Buf[2];
   if(CopyBuffer(g_emaHandle, 0, 1, 2, ema5Buf) < 2) return;
   double ema5Prev = ema5Buf[0]; // bar[2]
   double ema5Curr = ema5Buf[1]; // bar[1] (last closed)

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double dayOpen = GetDayOpen();
   double pt      = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   // Find nearest key level within tolerance
   double nearestKey = 0;
   double bestDist   = 9999;
   int    totalKeys  = ArraySize(g_turnKeys);
   for(int i = 0; i < totalKeys; i++) {
      double dist = MathAbs(bid - g_turnKeys[i]);
      if(dist < bestDist) {
         bestDist   = dist;
         nearestKey = g_turnKeys[i];
      }
   }

   if(nearestKey == 0 || bestDist > InpLevelTolerancePt * pt) return;

   // Determine bias
   bool bullBias = (bid > dayOpen);
   bool bearBias = (bid < dayOpen);

   // EMA5 lock: last H1 candle closed above/below the key
   bool ema5AboveKey = (ema5Curr > nearestKey);
   bool ema5BelowKey = (ema5Curr < nearestKey);
   bool ema5CrossUp  = (ema5Prev <= nearestKey && ema5Curr > nearestKey);
   bool ema5CrossDn  = (ema5Prev >= nearestKey && ema5Curr < nearestKey);

   if(InpRequireEma5Lock) {
      if(!ema5CrossUp && !ema5CrossDn) return; // No fresh EMA5 lock
   }

   // Confluence score
   int score = ComputeConfluence(bid, nearestKey, dayOpen, ema5Curr, ema5AboveKey, ema5BelowKey);
   if(score < InpMinConfluence) {
      PrintFormat("[GVF EA] Key %.2f confluence=%d < min=%d, skip", nearestKey, score, InpMinConfluence);
      return;
   }

   // Find TP = next key in direction
   double tpKey = FindNextKey(nearestKey, bullBias ? 1 : -1);
   if(tpKey == 0) return;

   // Lot size
   double lots = CalcLots(InpSlPoints * pt, InpRiskPctPerTrade);
   if(lots <= 0) return;

   if(bullBias && (InpRequireEma5Lock ? ema5CrossUp : ema5AboveKey)) {
      double sl = nearestKey - InpSlPoints * pt;
      double tp = tpKey;
      PrintFormat("[GVF EA] BUY @ %.2f | Key=%.2f SL=%.2f TP=%.2f confluence=%d lots=%.2f",
                  ask, nearestKey, sl, tp, score, lots);
      if(g_trade.Buy(lots, _Symbol, ask, sl, tp, "GVF-bounce")) {
         g_tradesToday++;
         g_lastTradeDate = TimeCurrent();
      }
   }
   else if(bearBias && (InpRequireEma5Lock ? ema5CrossDn : ema5BelowKey)) {
      double sl = nearestKey + InpSlPoints * pt;
      double tp = tpKey;
      PrintFormat("[GVF EA] SELL @ %.2f | Key=%.2f SL=%.2f TP=%.2f confluence=%d lots=%.2f",
                  bid, nearestKey, sl, tp, score, lots);
      if(g_trade.Sell(lots, _Symbol, bid, sl, tp, "GVF-bounce")) {
         g_tradesToday++;
         g_lastTradeDate = TimeCurrent();
      }
   }
}

//+------------------------------------------------------------------+
//| Confluence score (0–10)                                          |
//|  +1  Price on correct side of Day Open                          |
//|  +1  EMA5 aligned with trade direction                          |
//|  +2  Key level in both Turn Keys AND Intraday keys              |
//|  +1  Key level in Turn Keys only                                |
//|  +1  Key level in Intraday keys only                            |
//|  +1  Price > 10 pts from key (not overextended)                 |
//|  +1  EMA5 fresh cross (not lingering)                           |
//|  +2  Score bonus if confluence with 2+ sources                  |
//+------------------------------------------------------------------+
int ComputeConfluence(double price, double key, double dayOpen,
                       double ema5, bool ema5Above, bool ema5Below)
{
   int score = 0;
   double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   bool bullSide = (price > key);

   // Day open bias aligned
   if(bullSide  && price > dayOpen) score++;
   if(!bullSide && price < dayOpen) score++;

   // EMA5 aligned
   if(bullSide  && ema5Above) score++;
   if(!bullSide && ema5Below) score++;

   // Key in Turn Keys
   bool inTurn     = IsKeyIn(key, g_turnKeys,    5.0 * pt);
   bool inIntraday = IsKeyIn(key, g_intradayKeys, 5.0 * pt);
   if(inTurn && inIntraday) score += 2;
   else if(inTurn)          score += 1;
   else if(inIntraday)      score += 1;

   // Distance from key (not overextended)
   double dist = MathAbs(price - key);
   if(dist > 5.0 * pt && dist < InpLevelTolerancePt * pt) score++;

   // Multi-source bonus
   if(inTurn && inIntraday) score += 2;

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

double FindNextKey(double currentKey, int direction)
{
   double best = 0;
   double bestDist = 9999999;
   for(int i = 0; i < ArraySize(g_turnKeys); i++) {
      double diff = g_turnKeys[i] - currentKey;
      if(direction > 0 && diff > 0 && diff < bestDist) {
         bestDist = diff; best = g_turnKeys[i];
      }
      if(direction < 0 && diff < 0 && MathAbs(diff) < bestDist) {
         bestDist = MathAbs(diff); best = g_turnKeys[i];
      }
   }
   return best;
}

double CalcLots(double slDistancePrice, double riskPct)
{
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmt  = balance * riskPct / 100.0;
   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickVal <= 0 || tickSize <= 0 || slDistancePrice <= 0) return 0;
   double lots = riskAmt / (slDistancePrice / tickSize * tickVal);
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lots = MathFloor(lots / stepLot) * stepLot;
   return MathMax(minLot, MathMin(maxLot, lots));
}

double GetDayOpen()
{
   MqlRates rates[];
   if(CopyRates(_Symbol, PERIOD_D1, 0, 1, rates) > 0)
      return rates[0].open;
   return 0;
}

bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(g_pos.SelectByIndex(i) &&
         g_pos.Symbol() == _Symbol &&
         g_pos.Magic()  == InpMagic)
         return true;
   }
   return false;
}

void CheckBreakevenTrail()
{
   if(!InpTrailToBreakeven) return;
   double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(!g_pos.SelectByIndex(i)) continue;
      if(g_pos.Symbol() != _Symbol || g_pos.Magic() != InpMagic) continue;
      double open  = g_pos.PriceOpen();
      double sl    = g_pos.StopLoss();
      double profit = g_pos.Profit();
      if(g_pos.PositionType() == POSITION_TYPE_BUY) {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double moved = (bid - open) / pt;
         if(moved >= InpSlPoints && sl < open)
            g_trade.PositionModify(g_pos.Ticket(), open + pt, g_pos.TakeProfit());
      } else {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double moved = (open - ask) / pt;
         if(moved >= InpSlPoints && sl > open)
            g_trade.PositionModify(g_pos.Ticket(), open - pt, g_pos.TakeProfit());
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
//| Fetch H1 Turn Keys + Intraday Discord keys from API              |
//+------------------------------------------------------------------+
void FetchKeys()
{
   FetchTurnKeys();
   FetchIntradayKeys();
   g_lastKeyFetch = TimeCurrent();
}

void FetchTurnKeys()
{
   string url     = InpApiBase + "/api/keys";
   string headers = "Content-Type: application/json\r\n";
   char   postData[];
   char   result[];
   string resHeaders;
   int    timeout = 5000;

   int status = WebRequest("GET", url, headers, timeout, postData, result, resHeaders);
   if(status != 200) {
      PrintFormat("[GVF EA] /api/keys failed: %d", status);
      return;
   }

   string json = CharArrayToString(result);
   ParseJsonDoubleArray(json, "\"h1Turn\"", g_turnKeys);
   PrintFormat("[GVF EA] Loaded %d H1 Turn Keys", ArraySize(g_turnKeys));
}

void FetchIntradayKeys()
{
   string url     = InpApiBase + "/api/intraday-discord";
   string headers = "Content-Type: application/json\r\n";
   char   postData[];
   char   result[];
   string resHeaders;
   int    timeout = 5000;

   int status = WebRequest("GET", url, headers, timeout, postData, result, resHeaders);
   if(status != 200) {
      PrintFormat("[GVF EA] /api/intraday-discord failed: %d", status);
      return;
   }

   string json = CharArrayToString(result);
   ParseJsonDoubleArray(json, "\"levels\"", g_intradayKeys);
   PrintFormat("[GVF EA] Loaded %d Intraday Discord keys", ArraySize(g_intradayKeys));
}

//--- Minimal JSON double array parser: finds key, reads [n1, n2, ...] after it
void ParseJsonDoubleArray(const string &json, const string &key, double &out[])
{
   ArrayResize(out, 0);
   int kPos = StringFind(json, key);
   if(kPos < 0) return;
   int arrStart = StringFind(json, "[", kPos);
   int arrEnd   = StringFind(json, "]", arrStart);
   if(arrStart < 0 || arrEnd < 0) return;
   string inner = StringSubstr(json, arrStart + 1, arrEnd - arrStart - 1);
   string parts[];
   int n = StringSplit(inner, ',', parts);
   for(int i = 0; i < n; i++) {
      StringTrimLeft(parts[i]);
      StringTrimRight(parts[i]);
      double v = StringToDouble(parts[i]);
      if(v > 0) {
         int sz = ArraySize(out);
         ArrayResize(out, sz + 1);
         out[sz] = v;
      }
   }
}
