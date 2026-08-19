//+------------------------------------------------------------------+
//| LPH_ExtensionProbabilityMap_EA.mq5                              |
//| Big 1-day candle run -> probability of further extension.       |
//| Multi-bar lookback (Yesterday D1 / Today D1) + Volume Engine.   |
//|                                                                  |
//| Two modes:                                                        |
//|  1) LIVE: attach to any chart of the symbol; shows a HUD panel   |
//|     with trader VERDICT, key probabilities, volume profile,      |
//|     volume-boosted continuation odds, and decay curve.           |
//|  2) RESEARCH: run in the Strategy Tester (D1, any model) and it  |
//|     writes a full Markdown report with volume breakdown tables   |
//|     and per-event log to MQL5\Files\Research.                    |
//|                                                                  |
//| Limitless PH Alpha Gold Quant Suite (v1.20)                     |
//+------------------------------------------------------------------+
#property copyright "Limitless PH Trading Academy"
#property link      "https://limitlessphtraining.com"
#property version   "1.20"
#property description "Big daily candle -> extension probability map (D1 statistics)."
#property description "Features multi-bar lookback context and historical volume expansion engine."

enum ENUM_EVAL_BAR
  {
   EVAL_TODAY_FORMING = 0, // Today's Forming D1 Bar (Shift 0)
   EVAL_PREVIOUS_D1   = 1, // Yesterday's Completed D1 Bar (Shift 1)
   EVAL_AUTO_SWITCH   = 2  // Auto: Prior D1 early session -> Today when active
  };

input group "=== 1. Statistics Engine ==="
input int           InpATRPeriod       = 14;     // D1 ATR period
input double        InpMinMoveATR      = 1.00;   // event: |close-close[prev]| >= this * ATR
input double        InpMinRangeATR     = 1.50;   // event: daily range >= this * ATR (big candle)
input int           InpMaxFwdDays      = 5;      // forward window (days) for extension stats
input int           InpMinEvents       = 20;     // minimum events per bucket for a valid % (else '--')

input int           InpVolMA_Period    = 20;     // D1 Volume MA Period
input double        InpHighVolRatio    = 1.25;   // High Volume Threshold (e.g. 1.25x of 20-day Avg)

input group "=== 2. Panel / Live Mode ==="
input bool          InpShowPanel       = true;   // show HUD panel on chart
input bool          InpSimpleMode      = true;   // trader view: big verdict + key numbers (false = full grid)
input ENUM_EVAL_BAR InpEvalBar         = EVAL_AUTO_SWITCH; // Evaluation Context (Today / Yesterday / Auto)
input ENUM_BASE_CORNER InpPanelCorner = CORNER_LEFT_UPPER;
input int           InpPanelX          = 15;
input int           InpPanelY          = 30;

input group "=== 3. Research / Report ==="
input bool          InpWriteReport     = true;   // write the Markdown report
input string        InpReportFolder    = "Research"; // subfolder under MQL5\Files
input bool          InpWriteEventLog   = true;   // include per-event log in the report

//+------------------------------------------------------------------+
//| Engine constants                                                 |
//+------------------------------------------------------------------+
#define MAXW   5                 // forward windows evaluated: 1,3,5 days -> 3 windows
#define MAXLVL 4                 // extension levels: 0.5,1.0,1.5,2.0 ATR
#define MAXSTEP 6                // decay steps: 0 .. 2.5 ATR in 0.5 steps
#define MAXBUCK 7                // buckets: [1,1.5),[1.5,2),[2,2.5),[2.5,3),[3,4),[4,Inf)
#define MAXTIER 2                // volume tiers: 0 = Normal/Low Vol (<1.25x), 1 = High Vol (>=1.25x)
#define MAXVOLIDX 28             // MAXBUCK * 2 * MAXTIER = 7 * 2 * 2 = 28
#define MAXEVT 12000             // event log capacity

double   g_winDays[MAXW]  = {1.0, 3.0, 5.0};
double   g_levels[MAXLVL] = {0.5, 1.0, 1.5, 2.0};
double   g_bEdges[MAXBUCK]={1.0,1.5,2.0,2.5,3.0,4.0,1e9};

// bucket statistics: [b][dir][win][lvl]
int      g_n[MAXBUCK][2];
int      g_hit[MAXBUCK][2][MAXW][MAXLVL];
int      g_clsUp[MAXBUCK][2][MAXW];
double   g_avgExt[MAXBUCK][2][MAXW];
double   g_maxExt[MAXBUCK][2][MAXW];
double   g_sumMoveATR[MAXBUCK][2];

// volume tier statistics
int      g_volN[MAXBUCK][2][MAXTIER];
int      g_volHit[MAXVOLIDX][MAXW][MAXLVL];
int      g_volClsUp[MAXVOLIDX][MAXW];
double   g_volAvgExt[MAXVOLIDX][MAXW];
double   g_sumVolRatio[MAXBUCK][2];

int VolIdx(const int b, const int d, const int t)
  {
   return (b * 4 + d * 2 + t);
  }

// decay: [dir][step] reached counts and next-step counts
int      g_reached[MAXBUCK][2][MAXSTEP];
int      g_nextStep[MAXBUCK][2][MAXSTEP];

// event log
struct SEvent
  {
   datetime t;
   int      dir;        // +1 up, -1 down
   double   moveATR;    // |close-close_prev|/ATR
   double   rangeATR;   // range/ATR
   double   volRatio;   // Volume / 20-day MA
   double   maxExt5;    // max extension within 5 days (ATR units, signless)
   double   clsUp5;     // 1 if close[+5] beyond event close in event direction
   double   fwd5Ret;    // % move 5 days later in event direction
  };
SEvent   g_ev[MAXEVT];
int      g_evN = 0;

datetime g_lastReportDay = 0;
bool     g_computed = false;
string   g_prefix = "LPH_EXT_";

// panel context (live mode): stored on new D1 bar, used per tick
double   g_prevCls   = 0.0;   // last completed D1 close (shift 1)
double   g_prevCls2  = 0.0;   // D1 close 2 days ago (shift 2)
double   g_curOpen   = 0.0;   // forming D1 bar open (shift 0)
double   g_curATR    = 0.0;   // D1 ATR of last completed bar
double   g_curVolMA  = 0.0;   // D1 Volume MA of last completed bar
int      g_nBars     = 0;

//+------------------------------------------------------------------+
//| ATR helper (D1)                                                  |
//+------------------------------------------------------------------+
void CalcATR_D1(const double &h[], const double &l[], const double &c[], const int n,
                const int period, double &atr[], const int start)
  {
   for(int i = 0; i < start; i++) atr[i] = 0.0;
   for(int i = start; i < n; i++)
     {
      double s = 0.0;
      for(int j = i - period + 1; j <= i; j++)
        {
         double tr = h[j] - l[j];
         double hc = MathAbs(h[j] - c[j - 1]);
         double lc = MathAbs(l[j] - c[j - 1]);
         if(hc > tr) tr = hc;
         if(lc > tr) tr = lc;
         s += tr;
        }
      atr[i] = s / (double)period;
     }
  }

//+------------------------------------------------------------------+
//| Volume MA helper (D1)                                            |
//+------------------------------------------------------------------+
void CalcVolMA_D1(const double &v[], const int n, const int period, double &vma[], const int start)
  {
   for(int i = 0; i < start; i++) vma[i] = 0.0;
   for(int i = start; i < n; i++)
     {
      double s = 0.0;
      for(int j = i - period; j < i; j++) s += v[j];
      vma[i] = s / (double)period;
     }
  }

//+------------------------------------------------------------------+
//| Main statistics over D1 arrays (index 0 = oldest)                |
//+------------------------------------------------------------------+
void ComputeStats(const datetime &dtime[], const double &dopen[], const double &dhigh[],
                  const double &dlow[], const double &dclose[], const double &dvol[], const int n)
  {
   // reset
   for(int b = 0; b < MAXBUCK; b++)
     {
      g_n[b][0] = g_n[b][1] = 0;
      g_sumMoveATR[b][0] = g_sumMoveATR[b][1] = 0.0;
      g_sumVolRatio[b][0] = g_sumVolRatio[b][1] = 0.0;
      for(int d = 0; d < 2; d++)
        {
         for(int t = 0; t < MAXTIER; t++)
           {
            g_volN[b][d][t] = 0;
            int vi = VolIdx(b, d, t);
            for(int w = 0; w < MAXW; w++)
              {
               g_volClsUp[vi][w] = 0;
               g_volAvgExt[vi][w] = 0.0;
               for(int l = 0; l < MAXLVL; l++) g_volHit[vi][w][l] = 0;
              }
           }
         for(int w = 0; w < MAXW; w++)
           {
            g_clsUp[b][d][w] = 0;
            g_avgExt[b][d][w] = 0.0;
            g_maxExt[b][d][w] = 0.0;
            for(int l = 0; l < MAXLVL; l++) g_hit[b][d][w][l] = 0;
           }
         for(int s = 0; s < MAXSTEP; s++) { g_reached[b][d][s] = 0; g_nextStep[b][d][s] = 0; }
        }
     }
   g_evN = 0;

   int period = MathMax(InpATRPeriod, 2);
   int volPeriod = MathMax(InpVolMA_Period, 5);
   int startIdx = MathMax(period, volPeriod);
   if(n < startIdx + InpMaxFwdDays + 5) return;

   double atr[], volMA[];
   ArrayResize(atr, n);
   ArrayResize(volMA, n);
   CalcATR_D1(dhigh, dlow, dclose, n, period, atr, period);
   CalcVolMA_D1(dvol, n, volPeriod, volMA, volPeriod);

   int maxFwd = MathMin(InpMaxFwdDays, 5);
   if(maxFwd < 1) maxFwd = 1;

   // windows actually evaluated
   int wd[MAXW] = {0,0,0};
   int wn = 0;
   for(int w = 0; w < MAXW; w++)
      if((int)g_winDays[w] <= maxFwd) wd[wn++] = (int)g_winDays[w];

   for(int i = startIdx; i < n - maxFwd - 1; i++)
     {
      if(atr[i] <= 0.0) continue;
      double move  = dclose[i] - dclose[i - 1];
      double range = dhigh[i] - dlow[i];
      double moveATR  = MathAbs(move) / atr[i];
      double rangeATR = range / atr[i];
      if(moveATR < InpMinMoveATR)  continue;
      if(rangeATR < InpMinRangeATR) continue;

      double vRatio = (volMA[i] > 0.0) ? (dvol[i] / volMA[i]) : 1.0;
      int vTier = (vRatio >= InpHighVolRatio) ? 1 : 0; // 1 = High Vol, 0 = Normal/Low Vol

      int dir = (move > 0) ? 0 : 1;                 // 0 = up, 1 = down
      double base = dclose[i];

      // bucket
      int b = 0;
      while(b < MAXBUCK - 1 && moveATR >= g_bEdges[b]) b++;

      g_n[b][dir]++;
      g_sumMoveATR[b][dir] += moveATR;
      g_sumVolRatio[b][dir] += vRatio;

      g_volN[b][dir][vTier]++;
      int vi = VolIdx(b, dir, vTier);

      // forward extension
      double maxExt5 = 0.0;
      for(int k = 1; k <= maxFwd; k++)
        {
         double ext = (dir == 0) ? (dhigh[i + k] - base) : (base - dlow[i + k]);
         if(ext > maxExt5) maxExt5 = ext;
        }
      double maxExt5ATR = maxExt5 / atr[i];
      if(maxExt5ATR > g_maxExt[b][dir][2]) g_maxExt[b][dir][2] = maxExt5ATR;

      for(int w = 0; w < wn; w++)
        {
         int k = wd[w];
         double ext = 0.0;
         for(int j = 1; j <= k; j++)
           {
            double e = (dir == 0) ? (dhigh[i + j] - base) : (base - dlow[i + j]);
            if(e > ext) ext = e;
           }
         double extATR = ext / atr[i];
         int wi = (k == 1) ? 0 : (k == 3 ? 1 : 2);
         g_avgExt[b][dir][wi] += extATR;
         g_volAvgExt[vi][wi] += extATR;

         if(extATR > g_maxExt[b][dir][wi]) g_maxExt[b][dir][wi] = extATR;
         for(int l = 0; l < MAXLVL; l++)
           {
            if(extATR >= g_levels[l])
              {
               g_hit[b][dir][wi][l]++;
               g_volHit[vi][wi][l]++;
              }
           }

         double fut = (dir == 0) ? (dclose[i + k] - base) : (base - dclose[i + k]);
         if(fut > 0)
           {
            g_clsUp[b][dir][wi]++;
            g_volClsUp[vi][wi]++;
           }
        }

      // decay steps (0 .. 2.5 ATR in 0.5 steps) over maxFwd window
      for(int s = 0; s < MAXSTEP; s++)
        {
         double L = 0.5 * (double)s;
         if(maxExt5ATR >= L)
           {
            g_reached[b][dir][s]++;
            if(maxExt5ATR >= L + 0.5) g_nextStep[b][dir][s]++;
           }
        }

      // event log
      if(g_evN < MAXEVT)
        {
         SEvent e;
         e.t        = dtime[i];
         e.dir      = (dir == 0) ? 1 : -1;
         e.moveATR  = moveATR;
         e.rangeATR = rangeATR;
         e.volRatio = vRatio;
         e.maxExt5  = maxExt5ATR;
         double fut5 = (dir == 0) ? (dclose[i + 5] - base) : (base - dclose[i + 5]);
         e.clsUp5   = (fut5 > 0) ? 1.0 : 0.0;
         e.fwd5Ret  = 100.0 * fut5 / base;
         g_ev[g_evN++] = e;
        }
     }

   // average extension
   for(int b = 0; b < MAXBUCK; b++)
     {
      for(int d = 0; d < 2; d++)
        {
         for(int w = 0; w < MAXW; w++)
           {
            if(g_n[b][d] > 0) g_avgExt[b][d][w] /= (double)g_n[b][d];
            for(int t = 0; t < MAXTIER; t++)
              {
               int vi = VolIdx(b, d, t);
               if(g_volN[b][d][t] > 0) g_volAvgExt[vi][w] /= (double)g_volN[b][d][t];
              }
           }
        }
     }

   g_computed = true;
  }

//+------------------------------------------------------------------+
//| Formatting helpers                                               |
//+------------------------------------------------------------------+
string Pct100(const int num, const int den)
  {
   if(den <= 0) return "--";
   return DoubleToString(100.0 * (double)num / (double)den, 1);
  }

string Pct100d(const double num, const double den)
  {
   if(den <= 0.0) return "--";
   return DoubleToString(100.0 * num / den, 1);
  }

int BucketOfMove(const double moveATR)
  {
   int b = 0;
   while(b < MAXBUCK - 1 && moveATR >= g_bEdges[b]) b++;
   return b;
  }

//+------------------------------------------------------------------+
//| Report generation                                                |
//+------------------------------------------------------------------+
void BuildReport(const string fname)
  {
   string r = "";
   StringAdd(r, "# LPH Extension & Volume Probability Map — " + Symbol() + "\n\n");
   StringAdd(r, "Generated: " + TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES) + "\n\n");
   StringAdd(r, "**Definition:** a *big 1-day run* = D1 |close-close(prev)| >= " +
                 DoubleToString(InpMinMoveATR, 2) + " x ATR(" + IntegerToString(InpATRPeriod) +
                 ") AND daily range >= " + DoubleToString(InpMinRangeATR, 2) + " x ATR. " +
                 "High Volume Threshold = " + DoubleToString(InpHighVolRatio, 2) + "x (" + IntegerToString(InpVolMA_Period) + "d MA). " +
                 "Forward window " + IntegerToString(InpMaxFwdDays) + " days.\n\n");

   int upN = 0, dnN = 0;
   for(int b = 0; b < MAXBUCK; b++) { upN += g_n[b][0]; dnN += g_n[b][1]; }
   StringAdd(r, "**Events:** UP " + IntegerToString(upN) + " | DOWN " + IntegerToString(dnN) +
                 " | total " + IntegerToString(upN + dnN) + "\n\n");

   // ---- headline table (UP) ----
   StringAdd(r, "## UP runs (bullish big candle): P(extension beyond close)\n\n");
   StringAdd(r, "| Bucket (move, ATR) | n | +0.5A (1d) | +1.0A (1d) | +1.0A (3d) | +1.5A (3d) | +2.0A (3d) | +1.0A (5d) | +2.0A (5d) | close> (1d) | close> (3d) | close> (5d) | avgExt(5d) |\n");
   StringAdd(r, "|---|---|---|---|---|---|---|---|---|---|---|---|---|\n");
   for(int b = 0; b < MAXBUCK; b++)
     {
      if(g_n[b][0] == 0) continue;
      string lab = (b >= MAXBUCK - 2) ? "4.0+" : DoubleToString(g_bEdges[b], 1) + "-" + DoubleToString(g_bEdges[b + 1], 1);
      StringAdd(r, "| " + lab + " | " + IntegerToString(g_n[b][0]) +
                " | " + Pct100(g_hit[b][0][0][0], g_n[b][0]) +
                " | " + Pct100(g_hit[b][0][0][1], g_n[b][0]) +
                " | " + Pct100(g_hit[b][0][1][1], g_n[b][0]) +
                " | " + Pct100(g_hit[b][0][1][2], g_n[b][0]) +
                " | " + Pct100(g_hit[b][0][1][3], g_n[b][0]) +
                " | " + Pct100(g_hit[b][0][2][1], g_n[b][0]) +
                " | " + Pct100(g_hit[b][0][2][3], g_n[b][0]) +
                " | " + Pct100(g_clsUp[b][0][0], g_n[b][0]) +
                " | " + Pct100(g_clsUp[b][0][1], g_n[b][0]) +
                " | " + Pct100(g_clsUp[b][0][2], g_n[b][0]) +
                " | " + DoubleToString(g_avgExt[b][0][2], 2) + " |\n");
     }
   StringAdd(r, "\n");

   // ---- volume breakdown table ----
   StringAdd(r, "## Volume Expansion Impact: High Volume (>= " + DoubleToString(InpHighVolRatio, 2) + "x) vs Normal/Low Volume\n\n");
   StringAdd(r, "| Direction & Bucket | High Vol n | P(+1.0A/3d) HighVol | Normal Vol n | P(+1.0A/3d) NormalVol | Volume Edge (Delta) |\n");
   StringAdd(r, "|---|---|---|---|---|---|\n");
   for(int d = 0; d < 2; d++)
     {
      string ds = (d == 0) ? "UP" : "DOWN";
      for(int b = 0; b < MAXBUCK; b++)
        {
         if(g_n[b][d] == 0) continue;
         int nHigh = g_volN[b][d][1];
         int nNorm = g_volN[b][d][0];
         int viHigh = VolIdx(b, d, 1);
         int viNorm = VolIdx(b, d, 0);
         string pHigh = Pct100(g_volHit[viHigh][1][1], nHigh);
         string pNorm = Pct100(g_volHit[viNorm][1][1], nNorm);
         double delta = 0.0;
         string dStr = "--";
         if(nHigh > 0 && nNorm > 0)
           {
            delta = (100.0 * g_volHit[viHigh][1][1] / nHigh) - (100.0 * g_volHit[viNorm][1][1] / nNorm);
            dStr = (delta >= 0 ? "+" : "") + DoubleToString(delta, 1) + "%";
           }
         string lab = (b >= MAXBUCK - 2) ? "4.0+" : DoubleToString(g_bEdges[b], 1) + "-" + DoubleToString(g_bEdges[b + 1], 1);
         StringAdd(r, "| " + ds + " " + lab + " ATR | " + IntegerToString(nHigh) + " | " + pHigh + "% | " +
                   IntegerToString(nNorm) + " | " + pNorm + "% | " + dStr + " |\n");
        }
     }
   StringAdd(r, "\n");

   // ---- headline table (DOWN) ----
   StringAdd(r, "## DOWN runs (bearish big candle): P(extension beyond close)\n\n");
   StringAdd(r, "| Bucket (move, ATR) | n | -0.5A (1d) | -1.0A (1d) | -1.0A (3d) | -1.5A (3d) | -2.0A (3d) | -1.0A (5d) | -2.0A (5d) | close< (1d) | close< (3d) | close< (5d) | avgExt(5d) |\n");
   StringAdd(r, "|---|---|---|---|---|---|---|---|---|---|---|---|---|\n");
   for(int b = 0; b < MAXBUCK; b++)
     {
      if(g_n[b][1] == 0) continue;
      string lab = (b >= MAXBUCK - 2) ? "4.0+" : DoubleToString(g_bEdges[b], 1) + "-" + DoubleToString(g_bEdges[b + 1], 1);
      StringAdd(r, "| " + lab + " | " + IntegerToString(g_n[b][1]) +
                " | " + Pct100(g_hit[b][1][0][0], g_n[b][1]) +
                " | " + Pct100(g_hit[b][1][0][1], g_n[b][1]) +
                " | " + Pct100(g_hit[b][1][1][1], g_n[b][1]) +
                " | " + Pct100(g_hit[b][1][1][2], g_n[b][1]) +
                " | " + Pct100(g_hit[b][1][1][3], g_n[b][1]) +
                " | " + Pct100(g_hit[b][1][2][1], g_n[b][1]) +
                " | " + Pct100(g_hit[b][1][2][3], g_n[b][1]) +
                " | " + Pct100(g_clsUp[b][1][0], g_n[b][1]) +
                " | " + Pct100(g_clsUp[b][1][1], g_n[b][1]) +
                " | " + Pct100(g_clsUp[b][1][2], g_n[b][1]) +
                " | " + DoubleToString(g_avgExt[b][1][2], 2) + " |\n");
     }
   StringAdd(r, "\n");

   // ---- decay curve ----
   StringAdd(r, "## Decay curve — P(extend another +0.5 ATR | already extended L ATR beyond close)\n\n");
   StringAdd(r, "**UP runs** (pooled move >= 2.0 ATR)\n\n");
   StringAdd(r, "| Level L (ATR) | n reached | P(extend to L+0.5) |\n|---|---|---|\n");
   for(int s = 0; s < MAXSTEP; s++)
      StringAdd(r, "| " + DoubleToString(0.5 * s, 1) + " | " + IntegerToString(g_reached[2][0][s]+g_reached[3][0][s]+g_reached[4][0][s]+g_reached[5][0][s]) +
                " | " + Pct100(g_nextStep[2][0][s]+g_nextStep[3][0][s]+g_nextStep[4][0][s]+g_nextStep[5][0][s], g_reached[2][0][s]+g_reached[3][0][s]+g_reached[4][0][s]+g_reached[5][0][s]) + " |\n");
   StringAdd(r, "\n**DOWN runs** (pooled move >= 2.0 ATR)\n\n");
   StringAdd(r, "| Level L (ATR) | n reached | P(extend to L+0.5) |\n|---|---|---|\n");
   for(int s = 0; s < MAXSTEP; s++)
      StringAdd(r, "| " + DoubleToString(0.5 * s, 1) + " | " + IntegerToString(g_reached[2][1][s]+g_reached[3][1][s]+g_reached[4][1][s]+g_reached[5][1][s]) +
                " | " + Pct100(g_nextStep[2][1][s]+g_nextStep[3][1][s]+g_nextStep[4][1][s]+g_nextStep[5][1][s], g_reached[2][1][s]+g_reached[3][1][s]+g_reached[4][1][s]+g_reached[5][1][s]) + " |\n");
   StringAdd(r, "\n");

   // ---- event log ----
   if(InpWriteEventLog && g_evN > 0)
     {
      StringAdd(r, "## Event log (all big-candle events, newest first)\n\n");
      StringAdd(r, "| Date | Dir | move(ATR) | range(ATR) | volRatio | maxExt5(ATR) | close>5d | fwd5d ret% |\n|---|---|---|---|---|---|---|---|\n");
      for(int e = g_evN - 1; e >= 0; e--)
        {
         SEvent ev = g_ev[e];
         string dirs = (ev.dir > 0) ? "UP" : "DN";
         StringAdd(r, "| " + TimeToString(ev.t, TIME_DATE) +
                      " | " + dirs +
                      " | " + DoubleToString(ev.moveATR, 2) +
                      " | " + DoubleToString(ev.rangeATR, 2) +
                      " | " + DoubleToString(ev.volRatio, 2) + "x" +
                      " | " + DoubleToString(ev.maxExt5, 2) +
                      " | " + (ev.clsUp5 > 0 ? "YES" : "no") +
                      " | " + DoubleToString(ev.fwd5Ret, 1) + " |\n");
        }
      StringAdd(r, "\n");
     }

   // write
   FolderCreate(InpReportFolder);
   int fh = FileOpen(fname, FILE_TXT | FILE_WRITE | FILE_ANSI);
   if(fh == INVALID_HANDLE)
     {
      Print("EXT_PROB: cannot write report ", fname, " err=", GetLastError());
      return;
     }
   FileWriteString(fh, r);
   FileClose(fh);
   Print("EXT_PROB: report written -> ", fname, " (", g_evN, " events)");
  }

string ReportFileName()
  {
   return InpReportFolder + "\\LPH_ExtensionProbability_" + Symbol() + ".md";
  }

//+------------------------------------------------------------------+
//| HUD panel graphics                                               |
//+------------------------------------------------------------------+
void ObjDelAll()
  {
   for(int i = ObjectsTotal(0, -1, -1) - 1; i >= 0; i--)
     {
      string nm = ObjectName(0, i);
      if(StringFind(nm, g_prefix) == 0) ObjectDelete(0, nm);
     }
  }

void HLabel(string name, int x, int y, string text, color clr, int fs, bool bold = false)
  {
   string id = g_prefix + name;
   if(ObjectFind(0, id) < 0) ObjectCreate(0, id, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, id, OBJPROP_CORNER, InpPanelCorner);
   ObjectSetInteger(0, id, OBJPROP_XDISTANCE, InpPanelX + x);
   ObjectSetInteger(0, id, OBJPROP_YDISTANCE, InpPanelY + y);
   ObjectSetInteger(0, id, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, id, OBJPROP_FONTSIZE, fs);
   ObjectSetString(0, id, OBJPROP_FONT, bold ? "Segoe UI Semibold" : "Segoe UI");
   ObjectSetString(0, id, OBJPROP_TEXT, text);
   ObjectSetInteger(0, id, OBJPROP_BACK, false);
   ObjectSetInteger(0, id, OBJPROP_SELECTABLE, false);
  }

void BgRect(string name, int x, int y, int w, int h, color bg, color border)
  {
   string id = g_prefix + name;
   if(ObjectFind(0, id) < 0) ObjectCreate(0, id, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, id, OBJPROP_CORNER, InpPanelCorner);
   ObjectSetInteger(0, id, OBJPROP_XDISTANCE, InpPanelX + x);
   ObjectSetInteger(0, id, OBJPROP_YDISTANCE, InpPanelY + y);
   ObjectSetInteger(0, id, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, id, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, id, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, id, OBJPROP_BORDER_COLOR, border);
   ObjectSetInteger(0, id, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, id, OBJPROP_BACK, true);
   ObjectSetInteger(0, id, OBJPROP_SELECTABLE, false);
  }

//+------------------------------------------------------------------+
//| Trader verdict (traffic light)                                   |
//+------------------------------------------------------------------+
void TraderVerdict(const int b, const int dir, const bool isBig, const int step,
                   const double volRatio, string &vText, color &vClr)
  {
   int nS = g_n[b][dir];
   vText = "NO SIGNAL"; vClr = C'120,130,150';
   if(!isBig) { vText = "NO BIG RUN - NORMAL DAY"; vClr = C'120,130,150'; return; }
   if(nS < InpMinEvents) { vText = "NO SIGNAL (n=" + IntegerToString(nS) + " < " + IntegerToString(InpMinEvents) + ")"; vClr = C'120,130,150'; return; }

   double p3  = 100.0 * (double)g_hit[b][dir][1][1] / (double)nS; // P(+-1.0A / 3d)
   bool strong = false, mod = false;
   if(dir == 0) { strong = (p3 >= 65.0); mod = (p3 >= 45.0); }
   else         { strong = (p3 >= 60.0); mod = (p3 >= 40.0); }

   if(strong)
     {
      if(volRatio >= InpHighVolRatio)
        { vText = (dir == 0 ? "FOLLOW UP - STRONG (HIGH VOL)" : "FOLLOW DN - STRONG (HIGH VOL)"); vClr = C'0,230,130'; }
      else
        { vText = (dir == 0 ? "FOLLOW UP - STRONG" : "FOLLOW DN - STRONG"); vClr = C'0,230,130'; }
     }
   else if(mod)
     { vText = (dir == 0 ? "FOLLOW UP - MODERATE" : "FOLLOW DN - MODERATE"); vClr = C'255,215,0'; }
   else
     {
      if(volRatio < 0.85)
        { vText = (dir == 0 ? "WEAK UP - LOW VOL FADE" : "DN FADES - LOW VOL RETRACE"); vClr = C'255,95,95'; }
      else
        { vText = (dir == 0 ? "WEAK UP - EXPECT FADE" : "DN FADES - EXPECT RETRACE"); vClr = C'255,95,95'; }
     }

   // already extended far beyond close -> probability of the NEXT step decays
   if(step >= 3)
     { vText += " | EXTENDED"; vClr = C'255,160,60'; }
  }

//+------------------------------------------------------------------+
//| Panel: simple trader view                                        |
//+------------------------------------------------------------------+
void DrawPanelSimple(const int b, const int dir, const bool isBig, const double moveATR,
                     const double rangeATR, const double curATR, const double curCls,
                     const double intradayAbs, const int step, const string ctxTag,
                     const double volRatio, const int activeEvalBar)
  {
   int W = 400, H = 295;
   BgRect("bg", 0, 0, W, H, C'14,18,26', C'45,60,85');

   HLabel("title", 12, 10, "LPH EXTENSION PROBABILITY MAP", C'240,245,255', 10, true);

   int upN = 0, dnN = 0;
   for(int bb = 0; bb < MAXBUCK; bb++) { upN += g_n[bb][0]; dnN += g_n[bb][1]; }
   HLabel("sub", 12, 27, Symbol() + " D1  |  " + ctxTag, C'140,160,190', 8);

   string dirmove = (dir == 0 ? "UP +" : "DN -") + DoubleToString(moveATR, 2) + " ATR";
   color dc = (dir == 0) ? C'0,230,130' : C'255,95,95';
   string evalLab = (activeEvalBar == 1) ? "Prior D1: " : "Today D1: ";
   HLabel("cur", 12, 45, evalLab + dirmove + (isBig ? "   [BIG RUN]" : ""), dc, 10, true);
   HLabel("rng", 12, 61, "Range " + DoubleToString(rangeATR, 2) + " ATR | intraday ext " +
          DoubleToString(intradayAbs, 2) + " ATR", C'170,185,210', 8);

   // ---- verdict ----
   string vText = "";
   color  vClr  = C'120,130,150';
   TraderVerdict(b, dir, isBig, step, volRatio, vText, vClr);
   string bLabel = (b >= MAXBUCK - 2) ? "4.0+" : DoubleToString(g_bEdges[b], 1) + "-" + DoubleToString(g_bEdges[b + 1], 1);
   HLabel("vbox", 12, 78, "VERDICT  " + vText + "   (" + bLabel + "A)", vClr, 12, true);

   // ---- volume analytics & prediction ----
   string volTag = (volRatio >= 1.5) ? "SURGE (High Edge)" : (volRatio >= InpHighVolRatio ? "EXPANSION (Bullish)" : (volRatio >= 0.8 ? "NORMAL" : "LOW (Fade Risk)"));
   color volClr = (volRatio >= InpHighVolRatio) ? C'0,230,130' : (volRatio >= 0.8 ? C'200,215,235' : C'255,140,140');
   HLabel("volh", 12, 98, "Volume Pace: " + DoubleToString(volRatio, 2) + "x 20d-Avg [" + volTag + "]", volClr, 8, true);

   int nHigh = g_volN[b][dir][1];
   int nNorm = g_volN[b][dir][0];
   int viHigh = VolIdx(b, dir, 1);
   int viNorm = VolIdx(b, dir, 0);
   string pHigh = (nHigh > 0) ? Pct100(g_volHit[viHigh][1][1], nHigh) + "%" : "--";
   string pNorm = (nNorm > 0) ? Pct100(g_volHit[viNorm][1][1], nNorm) + "%" : "--";
   HLabel("vole", 12, 114, "Vol Edge P(+1.0A/3d): HighVol=" + pHigh + " (n=" + IntegerToString(nHigh) + ") | NormVol=" + pNorm + " (n=" + IntegerToString(nNorm) + ")", C'170,200,240', 8);

   // ---- key probabilities ----
   if(isBig && g_n[b][dir] >= InpMinEvents)
     {
      HLabel("ph", 12, 134, "P(extend beyond candle close):", C'120,135,160', 8);
      HLabel("pv", 12, 149,
             "+0.5A/1d  " + Pct100(g_hit[b][dir][0][0], g_n[b][dir]) + "%     " +
             "+1.0A/3d  " + Pct100(g_hit[b][dir][1][1], g_n[b][dir]) + "%     " +
             "+1.5A/3d  " + Pct100(g_hit[b][dir][1][2], g_n[b][dir]) + "%",
             C'220,235,255', 9, true);
      HLabel("ch", 12, 167, "Close beyond candle: 1d " + Pct100(g_clsUp[b][dir][0], g_n[b][dir]) +
             "% | 3d " + Pct100(g_clsUp[b][dir][1], g_n[b][dir]) +
             "% | 5d " + Pct100(g_clsUp[b][dir][2], g_n[b][dir]) + "%", C'170,200,240', 8);
     }
   else
     {
      HLabel("ph", 12, 134, "No valid sample in bucket " + bLabel + " ATR (n=" +
             IntegerToString(g_n[b][dir]) + ")", C'140,150,170', 8);
      HLabel("pv", 12, 149, "", C'220,235,255', 9);
      HLabel("ch", 12, 167, "", C'170,200,240', 8);
     }

   // ---- decay ----
   string pNext = Pct100d(g_nextStep[b][dir][step], g_reached[b][dir][step]);
   if(step > 0)
      HLabel("decay", 12, 187, "DECAY: extended " + DoubleToString(intradayAbs, 2) +
             " ATR -> P(next +0.5 ATR) = " + pNext + "%", C'255,215,0', 8, true);
   else
      HLabel("decay", 12, 187, "DECAY: P(+0.5 ATR from close) = " + pNext + "%", C'255,215,0', 8, true);

   // ---- targets ----
   HLabel("th", 12, 207, "Extension targets from close (" + DoubleToString(curATR, 2) + " ATR):",
          C'120,135,160', 8);
   string t1, t2, t3, t4;
   if(dir == 0)
     {
      t1 = DoubleToString(curCls + 0.5 * curATR, _Digits);
      t2 = DoubleToString(curCls + 1.0 * curATR, _Digits);
      t3 = DoubleToString(curCls + 1.5 * curATR, _Digits);
      t4 = DoubleToString(curCls + 2.0 * curATR, _Digits);
     }
   else
     {
      t1 = DoubleToString(curCls - 0.5 * curATR, _Digits);
      t2 = DoubleToString(curCls - 1.0 * curATR, _Digits);
      t3 = DoubleToString(curCls - 1.5 * curATR, _Digits);
      t4 = DoubleToString(curCls - 2.0 * curATR, _Digits);
     }
   HLabel("tv", 12, 223, (dir == 0 ? "+0.5A " : "-0.5A ") + t1 + "  |  " +
          (dir == 0 ? "+1.0A " : "-1.0A ") + t2 + "  |  " +
          (dir == 0 ? "+1.5A " : "-1.5A ") + t3 + "  |  " +
          (dir == 0 ? "+2.0A " : "-2.0A ") + t4, C'255,235,170', 8);

   HLabel("foot", 12, 268, "Big run = |move|>= " + DoubleToString(InpMinMoveATR, 2) + "A & range>= " +
          DoubleToString(InpMinRangeATR, 2) + "A | n=" + IntegerToString(g_n[b][dir]), C'90,110,140', 7);
  }

//+------------------------------------------------------------------+
//| Panel: full statistical grid (no flicker)                        |
//+------------------------------------------------------------------+
void DrawPanelFull(const int b, const int dir, const bool isBig, const double moveATR,
                   const double rangeATR, const double curATR, const double curCls,
                   const double intradayAbs, const int step, const string ctxTag,
                   const double volRatio, const int activeEvalBar)
  {
   int W = 390, H = 285;
   BgRect("bg", 0, 0, W, H, C'14,18,26', C'45,60,85');

   HLabel("title", 12, 10, "LPH EXTENSION PROBABILITY MAP", C'240,245,255', 10, true);

   int upN = 0, dnN = 0;
   for(int bb = 0; bb < MAXBUCK; bb++) { upN += g_n[bb][0]; dnN += g_n[bb][1]; }
   HLabel("sub", 12, 27, Symbol() + " D1  |  " + ctxTag, C'140,160,190', 8);

   string dirmove = (dir == 0 ? "UP +" : "DN -") + DoubleToString(moveATR, 2) + " ATR";
   color dc = (dir == 0) ? C'0,230,130' : C'255,95,95';
   string evalLab = (activeEvalBar == 1) ? "Prior D1: " : "Today D1: ";
   HLabel("cur", 12, 45, evalLab + dirmove + (isBig ? "  [BIG RUN]" : ""), dc, 9, true);
   HLabel("rng", 12, 61, "Range " + DoubleToString(rangeATR, 2) + " ATR | intraday ext " +
          DoubleToString(intradayAbs, 2) + " ATR", C'170,185,210', 8);

   string volTag = (volRatio >= InpHighVolRatio) ? "HIGH VOL (" + DoubleToString(volRatio, 2) + "x)" : "NORM VOL (" + DoubleToString(volRatio, 2) + "x)";
   color volClr = (volRatio >= InpHighVolRatio) ? C'0,230,130' : C'140,160,190';
   HLabel("volh", 12, 78, "Volume Status: " + volTag, volClr, 8, true);

   if(g_n[b][dir] >= InpMinEvents)
     {
      string bLabel = (b >= MAXBUCK - 2) ? "4.0+" : DoubleToString(g_bEdges[b], 1) + "-" + DoubleToString(g_bEdges[b + 1], 1);
      HLabel("h1", 12, 96, "Bucket " + bLabel + " ATR (n=" + IntegerToString(g_n[b][dir]) + "):", C'255,205,0', 8, true);
      HLabel("h2", 12, 112, "P(+0.5A/1d)  P(+1.0A/1d)  P(+1.0A/3d)  P(+2.0A/3d)  P(+1.0A/5d)",
             C'120,135,160', 7);
      HLabel("h2v", 12, 126,
             "   " + Pct100(g_hit[b][dir][0][0], g_n[b][dir]) + "%         " +
             Pct100(g_hit[b][dir][0][1], g_n[b][dir]) + "%          " +
             Pct100(g_hit[b][dir][1][1], g_n[b][dir]) + "%           " +
             Pct100(g_hit[b][dir][1][3], g_n[b][dir]) + "%           " +
             Pct100(g_hit[b][dir][2][1], g_n[b][dir]) + "%",
             C'220,235,255', 8, true);
      HLabel("h3", 12, 144, "P(close beyond candle): 1d " + Pct100(g_clsUp[b][dir][0], g_n[b][dir]) +
             "% | 3d " + Pct100(g_clsUp[b][dir][1], g_n[b][dir]) +
             "% | 5d " + Pct100(g_clsUp[b][dir][2], g_n[b][dir]) + "%", C'170,200,240', 8);
     }
   else
     {
      HLabel("h1", 12, 96, "Bucket " + DoubleToString(g_bEdges[b], 1) + "+ ATR: n=" +
             IntegerToString(g_n[b][dir]) + " (below " + IntegerToString(InpMinEvents) + ")",
             C'140,150,170', 8);
     }

   string pNext = Pct100d(g_nextStep[b][dir][step], g_reached[b][dir][step]);
   if(step > 0)
      HLabel("decay", 12, 166, "DECAY: already extended " + DoubleToString(intradayAbs, 2) +
             " ATR -> P(next +0.5 ATR) = " + pNext + "%", C'255,215,0', 8, true);
   else
      HLabel("decay", 12, 166, "DECAY: P(+0.5 ATR from close) = " + pNext + "%", C'255,215,0', 8, true);

   HLabel("tgt", 12, 186, "Extension targets from close (" + DoubleToString(curATR, 2) + " ATR):",
          C'120,135,160', 8);
   string t1 = DoubleToString(curCls + 0.5 * curATR, _Digits) + "  ";
   string t2 = DoubleToString(curCls + 1.0 * curATR, _Digits) + "  ";
   string t3 = DoubleToString(curCls + 1.5 * curATR, _Digits) + "  ";
   string t4 = DoubleToString(curCls + 2.0 * curATR, _Digits);
   HLabel("tgtv", 12, 202, "+0.5A " + t1 + "| +1.0A " + t2 + "| +1.5A " + t3 + "| +2.0A " + t4,
          C'255,235,170', 8);

   HLabel("foot", 12, 245, "Big run = |move|>= " + DoubleToString(InpMinMoveATR, 2) + "A & range>= " +
          DoubleToString(InpMinRangeATR, 2) + "A | fwd " + IntegerToString(InpMaxFwdDays) + "d",
          C'90,110,140', 7);
  }

//+------------------------------------------------------------------+
//| Load D1 series oldest-first and compute statistics               |
//+------------------------------------------------------------------+
void LoadD1Data(const int n)
  {
   MqlRates rates[];
   ArraySetAsSeries(rates, false);
   int copied = CopyRates(Symbol(), PERIOD_D1, 0, n, rates);
   if(copied < InpATRPeriod + InpMaxFwdDays + 5) return;

   datetime dtime[];
   double   dopen[], dhigh[], dlow[], dclose[], dvol[];
   ArrayResize(dtime, copied);  ArrayResize(dopen, copied);
   ArrayResize(dhigh, copied);  ArrayResize(dlow, copied);
   ArrayResize(dclose, copied); ArrayResize(dvol, copied);

   for(int i = 0; i < copied; i++)
     {
      dtime[i]  = rates[i].time;
      dopen[i]  = rates[i].open;
      dhigh[i]  = rates[i].high;
      dlow[i]   = rates[i].low;
      dclose[i] = rates[i].close;
      dvol[i]   = (double)(rates[i].tick_volume > 0 ? rates[i].tick_volume : rates[i].real_volume);
     }
   ComputeStats(dtime, dopen, dhigh, dlow, dclose, dvol, copied);
  }

//+------------------------------------------------------------------+
//| Store per-tick panel context (called once per new D1 bar)        |
//+------------------------------------------------------------------+
void StorePanelContext(const int n)
  {
   g_nBars = n;
   if(n < 4) return;
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(Symbol(), PERIOD_D1, 0, MathMax(InpATRPeriod + 5, InpVolMA_Period + 5), rates);
   if(copied < 4) return;

   g_prevCls  = rates[1].close;
   g_prevCls2 = rates[2].close;
   g_curOpen  = rates[0].open;

   int period = MathMax(InpATRPeriod, 2);
   double s = 0.0;
   for(int j = 1; j <= period && j < copied - 1; j++)
     {
      double tr = rates[j].high - rates[j].low;
      double hc = MathAbs(rates[j].high - rates[j + 1].close);
      double lc = MathAbs(rates[j].low - rates[j + 1].close);
      if(hc > tr) tr = hc;
      if(lc > tr) tr = lc;
      s += tr;
     }
   g_curATR = s / (double)period;
   if(g_curATR <= 0.0) g_curATR = rates[1].high - rates[1].low;

   int volPeriod = MathMax(InpVolMA_Period, 5);
   double vs = 0.0;
   for(int k = 1; k <= volPeriod && k < copied; k++)
     {
      double v = (double)(rates[k].tick_volume > 0 ? rates[k].tick_volume : rates[k].real_volume);
      vs += v;
     }
   g_curVolMA = vs / (double)volPeriod;
   if(g_curVolMA <= 0.0) g_curVolMA = 1.0;
  }

//+------------------------------------------------------------------+
//| Update panel (called every tick; objects created on demand)      |
//+------------------------------------------------------------------+
void UpdatePanel()
  {
   if(!g_computed || g_nBars < 3) return;

   MqlRates rCurrent[];
   ArraySetAsSeries(rCurrent, true);
   if(CopyRates(Symbol(), PERIOD_D1, 0, 3, rCurrent) < 3) return;

   // 1. Determine active evaluation context (Today vs Yesterday)
   int activeEvalBar = 0;
   if(InpEvalBar == EVAL_PREVIOUS_D1)
      activeEvalBar = 1;
   else if(InpEvalBar == EVAL_AUTO_SWITCH)
     {
      double todayMoveATR = MathAbs(rCurrent[0].close - g_prevCls) / g_curATR;
      double yestMoveATR  = MathAbs(g_prevCls - g_prevCls2) / g_curATR;
      double yestRangeATR = (rCurrent[1].high - rCurrent[1].low) / g_curATR;
      bool yestIsBig = (yestMoveATR >= InpMinMoveATR && yestRangeATR >= InpMinRangeATR);
      if(todayMoveATR < 0.60 && yestIsBig)
         activeEvalBar = 1;
      else
         activeEvalBar = 0;
     }
   else
      activeEvalBar = 0;

   // 2. Extract metrics according to active bar
   double evalCls = 0.0, evalPrevCls = 0.0, evalHigh = 0.0, evalLow = 0.0, evalVol = 0.0;
   string ctxTag = "";

   if(activeEvalBar == 1)
     {
      evalCls     = rCurrent[1].close;
      evalPrevCls = g_prevCls2;
      evalHigh    = rCurrent[1].high;
      evalLow     = rCurrent[1].low;
      evalVol     = (double)(rCurrent[1].tick_volume > 0 ? rCurrent[1].tick_volume : rCurrent[1].real_volume);
      ctxTag      = "Prior D1 (Bar 1 Lookback)";
     }
   else
     {
      evalCls     = rCurrent[0].close;
      evalPrevCls = g_prevCls;
      evalHigh    = rCurrent[0].high;
      evalLow     = rCurrent[0].low;
      evalVol     = (double)(rCurrent[0].tick_volume > 0 ? rCurrent[0].tick_volume : rCurrent[0].real_volume);
      ctxTag      = "Today D1 (Bar 0 Forming)";
     }

   MqlTick lastTick;
   if(!SymbolInfoTick(Symbol(), lastTick)) return;
   double bid = lastTick.bid;

   double move = evalCls - evalPrevCls;
   double moveATR  = MathAbs(move) / g_curATR;
   double rangeATR = (evalHigh - evalLow) / g_curATR;
   int dir = (move > 0) ? 0 : 1;
   int b = BucketOfMove(moveATR);

   // Calculate volume ratio
   double volRatio = 1.0;
   if(activeEvalBar == 1)
     {
      volRatio = (g_curVolMA > 0.0) ? (evalVol / g_curVolMA) : 1.0;
     }
   else
     {
      datetime now = TimeCurrent();
      int secIntoDay = (int)(now % 86400);
      double dayFrac = MathMax((double)secIntoDay / 86400.0, 0.04);
      double projectedVol = evalVol / dayFrac;
      volRatio = (g_curVolMA > 0.0) ? (projectedVol / g_curVolMA) : 1.0;
     }

   // Intraday extension from active base
   double intradayExt = (bid - (activeEvalBar == 1 ? evalCls : g_curOpen)) / g_curATR;
   double intradayAbs = MathAbs(intradayExt);
   int step = (int)MathFloor(intradayAbs / 0.5);
   if(step > MAXSTEP - 1) step = MAXSTEP - 1;

   bool isBig = (moveATR >= InpMinMoveATR && rangeATR >= InpMinRangeATR);

   if(InpSimpleMode)
      DrawPanelSimple(b, dir, isBig, moveATR, rangeATR, g_curATR, evalCls, intradayAbs, step, ctxTag, volRatio, activeEvalBar);
   else
      DrawPanelFull(b, dir, isBig, moveATR, rangeATR, g_curATR, evalCls, intradayAbs, step, ctxTag, volRatio, activeEvalBar);

   ChartRedraw();
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   return (INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   ObjDelAll();
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   int n = iBars(Symbol(), PERIOD_D1);
   if(n < InpATRPeriod + InpMaxFwdDays + 5) return;

   if(MQLInfoInteger(MQL_TESTER))
     {
      // ---- research mode ----
      static datetime lastTickDay = 0;
      datetime curDay = iTime(Symbol(), PERIOD_D1, 0);
      if(!g_computed || curDay != lastTickDay)
        {
         LoadD1Data(n);
         lastTickDay = curDay;
        }
      if(InpWriteReport && (g_lastReportDay == 0 || curDay != g_lastReportDay))
        {
         BuildReport(ReportFileName());
         g_lastReportDay = curDay;
        }
      return;
     }

   // ---- live mode ----
   static datetime lastDay = 0;
   datetime curDay = iTime(Symbol(), PERIOD_D1, 0);
   if(!g_computed || curDay != lastDay)
     {
      LoadD1Data(n);
      StorePanelContext(n);
      lastDay = curDay;
      if(InpWriteReport && (g_lastReportDay == 0 || curDay != g_lastReportDay))
        {
         BuildReport(ReportFileName());
         g_lastReportDay = curDay;
        }
     }

   if(InpShowPanel) UpdatePanel();
  }
//+------------------------------------------------------------------+
