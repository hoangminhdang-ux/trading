//+------------------------------------------------------------------+
//| DataPusher.mq5                                                    |
//| Single EA instance pushes H1, H4, D1, W1 from any chart.        |
//| Attach once to any XAUUSD chart.                                  |
//|                                                                   |
//| SETUP: Tools → Options → Expert Advisors → Allow WebRequest      |
//|        Add https://trading.boredstudio.ai to the allowlist.     |
//+------------------------------------------------------------------+
#property strict

input string  ApiUrl    = "https://trading.boredstudio.ai/api/market-candles";
input string  EaSecret  = "";
input int     Ma1Per    = 5;    // EMA period (EMA5)
input int     Ma2Per    = 21;   // SMA period (SMA21)
input int     Ma3Per    = 50;   // SMA period (SMA50)
input int     Ma4Per    = 100;  // SMA period (SMA100)
input int     Ma5Per    = 200;  // SMA period (SMA200)
input int     RsiPeriod = 14;

#define TF_COUNT 4

ENUM_TIMEFRAMES PUSH_TFS[TF_COUNT] = {PERIOD_H1, PERIOD_H4, PERIOD_D1, PERIOD_W1};

struct TfState
{
   int      h1, h2, h3, h4, h5, hRsi;
   datetime prevBar;
   datetime lastPush;
   bool     initDone;
};

TfState g[TF_COUNT];

//+------------------------------------------------------------------+
int OnInit()
{
   for (int i = 0; i < TF_COUNT; i++)
   {
      ENUM_TIMEFRAMES tf = PUSH_TFS[i];
      g[i].h1   = iMA(_Symbol, tf, Ma1Per, 0, MODE_EMA, PRICE_CLOSE);
      g[i].h2   = iMA(_Symbol, tf, Ma2Per, 0, MODE_SMA, PRICE_CLOSE);
      g[i].h3   = iMA(_Symbol, tf, Ma3Per, 0, MODE_SMA, PRICE_CLOSE);
      g[i].h4   = iMA(_Symbol, tf, Ma4Per, 0, MODE_SMA, PRICE_CLOSE);
      g[i].h5   = iMA(_Symbol, tf, Ma5Per, 0, MODE_SMA, PRICE_CLOSE);
      g[i].hRsi = iRSI(_Symbol, tf, RsiPeriod, PRICE_CLOSE);

      if (g[i].h1   == INVALID_HANDLE || g[i].h2 == INVALID_HANDLE ||
          g[i].h3   == INVALID_HANDLE || g[i].h4 == INVALID_HANDLE ||
          g[i].h5   == INVALID_HANDLE || g[i].hRsi == INVALID_HANDLE)
      {
         Print("DataPusher: handle fail — ", EnumToString(tf));
         return INIT_FAILED;
      }
      g[i].prevBar  = 0;
      g[i].lastPush = 0;
      g[i].initDone = false;
   }

   EventSetTimer(1);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   for (int i = 0; i < TF_COUNT; i++)
   {
      IndicatorRelease(g[i].h1);
      IndicatorRelease(g[i].h2);
      IndicatorRelease(g[i].h3);
      IndicatorRelease(g[i].h4);
      IndicatorRelease(g[i].h5);
      IndicatorRelease(g[i].hRsi);
   }
   EventKillTimer();
}

//+------------------------------------------------------------------+
double ReadBuf(int handle, int shift)
{
   double buf[1];
   if (CopyBuffer(handle, 0, shift, 1, buf) > 0) return buf[0];
   return 0.0;
}

//+------------------------------------------------------------------+
void OnTimer()
{
   datetime now = TimeCurrent();

   for (int i = 0; i < TF_COUNT; i++)
   {
      datetime curBar  = iTime(_Symbol, PUSH_TFS[i], 0);
      bool     newBar  = (g[i].prevBar != 0 && curBar != g[i].prevBar);
      bool     periodic = (g[i].lastPush != 0 && now - g[i].lastPush >= 15 * 60);

      g[i].prevBar = curBar;

      if (!g[i].initDone)
      {
         if (PushCandle(i, 1)) { g[i].initDone = true; g[i].lastPush = now; }
         continue;
      }

      if (newBar)
      {
         if (PushCandle(i, 1)) g[i].lastPush = now;
      }
      else if (periodic)
      {
         if (PushCandle(i, 0)) g[i].lastPush = now;
      }
   }
}

//+------------------------------------------------------------------+
bool PushCandle(int tfIdx, int shift)
{
   ENUM_TIMEFRAMES tf = PUSH_TFS[tfIdx];

   MqlRates bars[];
   if (CopyRates(_Symbol, tf, shift, 1, bars) < 1)
   {
      Print("DataPusher: CopyRates failed — ", _Symbol, " ", EnumToString(tf), " shift=", shift);
      return false;
   }

   double ma1 = ReadBuf(g[tfIdx].h1,   shift);
   double ma2 = ReadBuf(g[tfIdx].h2,   shift);
   double ma3 = ReadBuf(g[tfIdx].h3,   shift);
   double ma4 = ReadBuf(g[tfIdx].h4,   shift);
   double ma5 = ReadBuf(g[tfIdx].h5,   shift);
   double rsi = ReadBuf(g[tfIdx].hRsi, shift);

   if (ma1 <= 0 || ma2 <= 0 || ma3 <= 0 || ma4 <= 0 || ma5 <= 0)
   {
      Print("DataPusher: buffer not ready — ", EnumToString(tf), " shift=", shift);
      return false;
   }

   // Weekly pivot for W1; daily pivot for H1/H4/D1
   ENUM_TIMEFRAMES pivotTf = (tf == PERIOD_W1) ? PERIOD_W1 : PERIOD_D1;
   MqlRates pivotBars[];
   double pivot = 0, r1 = 0, r2 = 0, r3 = 0, s1 = 0, s2 = 0, s3 = 0;
   if (CopyRates(_Symbol, pivotTf, 1, 1, pivotBars) >= 1)
   {
      double pH = pivotBars[0].high, pL = pivotBars[0].low, pC = pivotBars[0].close;
      pivot = (pH + pL + pC) / 3.0;
      r1 = 2*pivot - pL;     r2 = pivot + (pH - pL);     r3 = pH + 2*(pivot - pL);
      s1 = 2*pivot - pH;     s2 = pivot - (pH - pL);     s3 = pL - 2*(pH - pivot);
   }

   // Current day open (always D1 shift=0)
   double dayOpen = 0;
   MqlRates d1Now[];
   if (CopyRates(_Symbol, PERIOD_D1, 0, 1, d1Now) >= 1) dayOpen = d1Now[0].open;

   // Fib levels only for D1 and W1
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
   TimeToStruct(bars[0].time, dt);
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
      if (code == 200 || code == 201) break;
      Print("DataPusher: attempt ", attempt, " HTTP ", code,
            " — ", _Symbol, " ", EnumToString(tf), " ", openTime);
      if (code >= 400 && code < 500) break;
      if (attempt < 3) Sleep(2000);
   }
   return (code == 200 || code == 201);
}

void OnTick() {}
