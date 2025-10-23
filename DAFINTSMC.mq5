//+------------------------------------------------------------------+
//|                        DAFINTSMC.mq5                             |
//|   Enhanced SMC Indicator with MTF Trend Buffers + Visuals       |
//|   Version 2.0 - Order Blocks + Graphical Zones + MTF Analysis   |
//+------------------------------------------------------------------+
#property indicator_chart_window
#property indicator_buffers 8
#property indicator_plots   6

//--- Inputs
input int      LookbackBars          = 5;           // Lookback pour BOS/Sweep
input ENUM_TIMEFRAMES MTF1           = PERIOD_H4;   // Multi-Timeframe 1
input ENUM_TIMEFRAMES MTF2           = PERIOD_W1;   // Multi-Timeframe 2
input bool     DrawOrderBlocks       = true;        // Dessiner Order Blocks
input bool     DrawFVG               = true;        // Dessiner Fair Value Gaps
input bool     DrawSweptLiquidity    = true;        // Dessiner Liquidity Sweeps
input int      MaxZonesToDraw        = 50;          // Max zones affichées
input double   MinOrderBlockSize     = 1.5;         // OB min = 1.5x avg candle
input int      AvgCandlePeriod       = 20;          // Période moyenne bougie

// Paramètres de compatibilité (non utilisés mais requis par EA)
input int      EMA1_Period           = 20;
input int      EMA2_Period           = 50;
input int      EMA_Gap_Threshold     = 10;

//--- Buffers
double bufferBuy[];        // Buffer 0: Signal BUY
double bufferSell[];       // Buffer 1: Signal SELL
double bufferH4Trend[];    // Buffer 2: Tendance H4 (1.0=bull, -1.0=bear, 0=neutral)
double bufferW1Trend[];    // Buffer 3: Tendance W1 (1.0=bull, -1.0=bear, 0=neutral)
double bufferOBBuy[];      // Buffer 4: Zone Order Block Buy
double bufferOBSell[];     // Buffer 5: Zone Order Block Sell
double bufferFVGBuy[];     // Buffer 6: Fair Value Gap Buy
double bufferFVGSell[];    // Buffer 7: Fair Value Gap Sell

//--- Variables globales
static datetime lastBuyTime = 0;
static datetime lastSellTime = 0;
static int drawnZones = 0;

// Handles pour MTF
int ema20HandleH4 = INVALID_HANDLE;
int ema50HandleH4 = INVALID_HANDLE;
int ema20HandleW1 = INVALID_HANDLE;
int ema50HandleW1 = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| Custom indicator initialization                                  |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Buffers de signaux
   SetIndexBuffer(0, bufferBuy, INDICATOR_DATA);
   SetIndexBuffer(1, bufferSell, INDICATOR_DATA);
   SetIndexBuffer(2, bufferH4Trend, INDICATOR_DATA);
   SetIndexBuffer(3, bufferW1Trend, INDICATOR_DATA);
   SetIndexBuffer(4, bufferOBBuy, INDICATOR_DATA);
   SetIndexBuffer(5, bufferOBSell, INDICATOR_DATA);
   SetIndexBuffer(6, bufferFVGBuy, INDICATOR_DATA);
   SetIndexBuffer(7, bufferFVGSell, INDICATOR_DATA);

   //--- Configure plots pour les signaux
   PlotIndexSetString(0, PLOT_LABEL, "SMC Buy");
   PlotIndexSetInteger(0, PLOT_DRAW_TYPE, DRAW_ARROW);
   PlotIndexSetInteger(0, PLOT_ARROW, 233); // Up arrow
   PlotIndexSetInteger(0, PLOT_LINE_COLOR, 0, clrLime);
   PlotIndexSetInteger(0, PLOT_LINE_WIDTH, 3);

   PlotIndexSetString(1, PLOT_LABEL, "SMC Sell");
   PlotIndexSetInteger(1, PLOT_DRAW_TYPE, DRAW_ARROW);
   PlotIndexSetInteger(1, PLOT_ARROW, 234); // Down arrow
   PlotIndexSetInteger(1, PLOT_LINE_COLOR, 0, clrRed);
   PlotIndexSetInteger(1, PLOT_LINE_WIDTH, 3);

   //--- Configure plots pour MTF Trends (histogrammes discrets)
   PlotIndexSetString(2, PLOT_LABEL, "H4 Trend");
   PlotIndexSetInteger(2, PLOT_DRAW_TYPE, DRAW_NONE);

   PlotIndexSetString(3, PLOT_LABEL, "W1 Trend");
   PlotIndexSetInteger(3, PLOT_DRAW_TYPE, DRAW_NONE);

   //--- Configure plots pour Order Blocks (rectangles via ligne)
   PlotIndexSetString(4, PLOT_LABEL, "OB Buy Zone");
   PlotIndexSetInteger(4, PLOT_DRAW_TYPE, DRAW_NONE);

   PlotIndexSetString(5, PLOT_LABEL, "OB Sell Zone");
   PlotIndexSetInteger(5, PLOT_DRAW_TYPE, DRAW_NONE);

   //--- Configure plots pour FVG
   PlotIndexSetString(6, PLOT_LABEL, "FVG Buy");
   PlotIndexSetInteger(6, PLOT_DRAW_TYPE, DRAW_NONE);

   PlotIndexSetString(7, PLOT_LABEL, "FVG Sell");
   PlotIndexSetInteger(7, PLOT_DRAW_TYPE, DRAW_NONE);

   //--- Empty values
   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(2, PLOT_EMPTY_VALUE, 0);
   PlotIndexSetDouble(3, PLOT_EMPTY_VALUE, 0);
   PlotIndexSetDouble(4, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(5, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(6, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(7, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   //--- Initialiser handles MTF
   ema20HandleH4 = iMA(_Symbol, MTF1, 20, 0, MODE_EMA, PRICE_CLOSE);
   ema50HandleH4 = iMA(_Symbol, MTF1, 50, 0, MODE_EMA, PRICE_CLOSE);
   ema20HandleW1 = iMA(_Symbol, MTF2, 20, 0, MODE_EMA, PRICE_CLOSE);
   ema50HandleW1 = iMA(_Symbol, MTF2, 50, 0, MODE_EMA, PRICE_CLOSE);

   if(ema20HandleH4 == INVALID_HANDLE || ema50HandleH4 == INVALID_HANDLE ||
      ema20HandleW1 == INVALID_HANDLE || ema50HandleW1 == INVALID_HANDLE)
   {
      Print("❌ Erreur chargement EMA pour MTF");
      return INIT_FAILED;
   }

   Print("✅ DAFINTSMC v2.0 initialisé");
   Print("   MTF Analysis: ", EnumToString(MTF1), " + ", EnumToString(MTF2));
   Print("   Visualisations: OB=", DrawOrderBlocks, " FVG=", DrawFVG, " Sweep=", DrawSweptLiquidity);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Custom indicator deinitialization                                |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   //--- Release handles
   if(ema20HandleH4 != INVALID_HANDLE) IndicatorRelease(ema20HandleH4);
   if(ema50HandleH4 != INVALID_HANDLE) IndicatorRelease(ema50HandleH4);
   if(ema20HandleW1 != INVALID_HANDLE) IndicatorRelease(ema20HandleW1);
   if(ema50HandleW1 != INVALID_HANDLE) IndicatorRelease(ema50HandleW1);

   //--- Supprimer objets graphiques
   DeleteAllSMCObjects();

   Print("DAFINTSMC v2.0 déchargé");
}

//+------------------------------------------------------------------+
//| Custom indicator iteration                                       |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
   if(rates_total <= LookbackBars + 2)
      return 0;

   //--- Optimisation: traiter seulement nouvelles barres
   int start = prev_calculated > 0 ? rates_total - 2 : LookbackBars + 2;
   if(start < LookbackBars + 2)
      start = LookbackBars + 2;

   //--- Calculer tendances MTF une seule fois par cycle
   double h4Trend = CalculateMTFTrend(MTF1);
   double w1Trend = CalculateMTFTrend(MTF2);

   for(int i = start; i < rates_total; i++)
   {
      //--- Initialiser buffers
      bufferBuy[i] = EMPTY_VALUE;
      bufferSell[i] = EMPTY_VALUE;
      bufferH4Trend[i] = h4Trend;
      bufferW1Trend[i] = w1Trend;
      bufferOBBuy[i] = EMPTY_VALUE;
      bufferOBSell[i] = EMPTY_VALUE;
      bufferFVGBuy[i] = EMPTY_VALUE;
      bufferFVGSell[i] = EMPTY_VALUE;

      if(i < LookbackBars + 1) continue;
      if(i == rates_total - 1) continue; // Ignorer bougie en cours

      //--- Variables pour stocker les détails SMC
      SMCDetails buyDetails, sellDetails;

      //--- Détecter signaux SMC
      bool smcBuySignal = DetectSMCBuySignal(i, high, low, close, open, time, buyDetails);
      bool smcSellSignal = DetectSMCSellSignal(i, high, low, close, open, time, sellDetails);

      //--- Anti-spam: un signal par bougie
      if(smcBuySignal && time[i] != lastBuyTime)
      {
         bufferBuy[i] = low[i] - (10 * _Point); // Positionner flèche sous la bougie
         lastBuyTime = time[i];

         //--- Dessiner zones SMC
         if(drawnZones < MaxZonesToDraw)
         {
            DrawSMCZones(time[i], buyDetails, true);
            drawnZones++;
         }
      }

      if(smcSellSignal && time[i] != lastSellTime)
      {
         bufferSell[i] = high[i] + (10 * _Point); // Positionner flèche au-dessus
         lastSellTime = time[i];

         //--- Dessiner zones SMC
         if(drawnZones < MaxZonesToDraw)
         {
            DrawSMCZones(time[i], sellDetails, false);
            drawnZones++;
         }
      }
   }

   //--- Afficher info MTF sur le chart
   DisplayMTFInfo(h4Trend, w1Trend);

   return rates_total;
}

//+------------------------------------------------------------------+
//| Structure pour stocker les détails SMC                          |
//+------------------------------------------------------------------+
struct SMCDetails
{
   bool bosDetected;
   bool orderBlockFound;
   bool fvgDetected;
   bool liquiditySweep;
   bool strongMomentum;

   // Zones à dessiner
   datetime obTime;
   double obHigh;
   double obLow;

   datetime fvgTime;
   double fvgTop;
   double fvgBottom;

   datetime sweepTime;
   double sweepLevel;
};

//+------------------------------------------------------------------+
//| ✅ AMÉLIORATION: Détection Order Blocks renforcée               |
//+------------------------------------------------------------------+
bool DetectSMCBuySignal(int currentBar, const double &high[], const double &low[],
                        const double &close[], const double &open[],
                        const datetime &time[], SMCDetails &details)
{
   if(currentBar < LookbackBars + 1) return false;

   ZeroMemory(details);

   //--- 1️⃣ BREAK OF STRUCTURE (BOS) - Bullish
   double recentHigh = high[currentBar - 1];
   for(int j = 1; j <= LookbackBars; j++)
   {
      if(currentBar - j >= 0 && high[currentBar - j] > recentHigh)
         recentHigh = high[currentBar - j];
   }

   if(close[currentBar] > recentHigh)
      details.bosDetected = true;

   //--- 2️⃣ ✅ ORDER BLOCK AMÉLIORÉ avec critères stricts
   double avgCandleSize = CalculateAvgCandleSize(currentBar, AvgCandlePeriod, close, open);

   for(int k = 1; k <= 5; k++) // Chercher plus loin (5 au lieu de 3)
   {
      if(currentBar - k >= 0)
      {
         // Bougie baissière (rouge)
         bool bearishCandle = close[currentBar - k] < open[currentBar - k];
         double candleSize = MathAbs(close[currentBar - k] - open[currentBar - k]);

         // ✅ CRITÈRE 1: Bougie doit être significative (> 1.5x moyenne)
         bool significantCandle = (candleSize > avgCandleSize * MinOrderBlockSize);

         // ✅ CRITÈRE 2: Mouvement haussier fort qui casse le high
         bool bullishBreak = close[currentBar] > high[currentBar - k];

         // ✅ CRITÈRE 3: Volume élevé (si disponible)
         bool highVolume = true; // Peut être amélioré avec tick_volume

         if(bearishCandle && significantCandle && bullishBreak && highVolume)
         {
            details.orderBlockFound = true;
            details.obTime = time[currentBar - k];
            details.obHigh = high[currentBar - k];
            details.obLow = low[currentBar - k];
            break;
         }
      }
   }

   //--- 3️⃣ FAIR VALUE GAP (FVG)
   if(currentBar >= 2)
   {
      double gap = low[currentBar] - high[currentBar - 2];
      if(gap > 0)
      {
         details.fvgDetected = true;
         details.fvgTime = time[currentBar - 1];
         details.fvgBottom = high[currentBar - 2];
         details.fvgTop = low[currentBar];
      }
   }

   //--- 4️⃣ LIQUIDITY SWEEP + REVERSAL
   double recentLow = low[currentBar - 1];
   int sweepBarIndex = currentBar - 1;

   for(int m = 1; m <= LookbackBars; m++)
   {
      if(currentBar - m >= 0 && low[currentBar - m] < recentLow)
      {
         recentLow = low[currentBar - m];
         sweepBarIndex = currentBar - m;
      }
   }

   if(low[currentBar - 1] <= recentLow && close[currentBar] > open[currentBar])
   {
      details.liquiditySweep = true;
      details.sweepTime = time[sweepBarIndex];
      details.sweepLevel = recentLow;
   }

   //--- 5️⃣ MOMENTUM BULLISH
   double candleBody = close[currentBar] - open[currentBar];
   double candleRange = high[currentBar] - low[currentBar];

   if(candleBody > 0 && candleRange > 0 && (candleBody / candleRange) > 0.6)
      details.strongMomentum = true;

   //--- SCORING: Au moins 2/5 conditions
   int smcScore = 0;
   if(details.bosDetected) smcScore++;
   if(details.orderBlockFound) smcScore++;
   if(details.fvgDetected) smcScore++;
   if(details.liquiditySweep) smcScore++;
   if(details.strongMomentum) smcScore++;

   return (smcScore >= 2);
}

//+------------------------------------------------------------------+
//| ✅ AMÉLIORATION: Détection SELL avec Order Blocks renforcés     |
//+------------------------------------------------------------------+
bool DetectSMCSellSignal(int currentBar, const double &high[], const double &low[],
                         const double &close[], const double &open[],
                         const datetime &time[], SMCDetails &details)
{
   if(currentBar < LookbackBars + 1) return false;

   ZeroMemory(details);

   //--- 1️⃣ BREAK OF STRUCTURE (BOS) - Bearish
   double recentLow = low[currentBar - 1];
   for(int j = 1; j <= LookbackBars; j++)
   {
      if(currentBar - j >= 0 && low[currentBar - j] < recentLow)
         recentLow = low[currentBar - j];
   }

   if(close[currentBar] < recentLow)
      details.bosDetected = true;

   //--- 2️⃣ ✅ ORDER BLOCK AMÉLIORÉ
   double avgCandleSize = CalculateAvgCandleSize(currentBar, AvgCandlePeriod, close, open);

   for(int k = 1; k <= 5; k++)
   {
      if(currentBar - k >= 0)
      {
         // Bougie haussière (verte)
         bool bullishCandle = close[currentBar - k] > open[currentBar - k];
         double candleSize = MathAbs(close[currentBar - k] - open[currentBar - k]);

         // ✅ Bougie significative
         bool significantCandle = (candleSize > avgCandleSize * MinOrderBlockSize);

         // ✅ Mouvement baissier fort qui casse le low
         bool bearishBreak = close[currentBar] < low[currentBar - k];

         if(bullishCandle && significantCandle && bearishBreak)
         {
            details.orderBlockFound = true;
            details.obTime = time[currentBar - k];
            details.obHigh = high[currentBar - k];
            details.obLow = low[currentBar - k];
            break;
         }
      }
   }

   //--- 3️⃣ FAIR VALUE GAP (FVG)
   if(currentBar >= 2)
   {
      double gap = low[currentBar - 2] - high[currentBar];
      if(gap > 0)
      {
         details.fvgDetected = true;
         details.fvgTime = time[currentBar - 1];
         details.fvgTop = low[currentBar - 2];
         details.fvgBottom = high[currentBar];
      }
   }

   //--- 4️⃣ LIQUIDITY SWEEP + REVERSAL
   double recentHigh = high[currentBar - 1];
   int sweepBarIndex = currentBar - 1;

   for(int m = 1; m <= LookbackBars; m++)
   {
      if(currentBar - m >= 0 && high[currentBar - m] > recentHigh)
      {
         recentHigh = high[currentBar - m];
         sweepBarIndex = currentBar - m;
      }
   }

   if(high[currentBar - 1] >= recentHigh && close[currentBar] < open[currentBar])
   {
      details.liquiditySweep = true;
      details.sweepTime = time[sweepBarIndex];
      details.sweepLevel = recentHigh;
   }

   //--- 5️⃣ MOMENTUM BEARISH
   double candleBody = open[currentBar] - close[currentBar];
   double candleRange = high[currentBar] - low[currentBar];

   if(candleBody > 0 && candleRange > 0 && (candleBody / candleRange) > 0.6)
      details.strongMomentum = true;

   //--- SCORING
   int smcScore = 0;
   if(details.bosDetected) smcScore++;
   if(details.orderBlockFound) smcScore++;
   if(details.fvgDetected) smcScore++;
   if(details.liquiditySweep) smcScore++;
   if(details.strongMomentum) smcScore++;

   return (smcScore >= 2);
}

//+------------------------------------------------------------------+
//| ✅ NOUVEAU: Calculer moyenne taille bougie                      |
//+------------------------------------------------------------------+
double CalculateAvgCandleSize(int currentBar, int period, const double &close[], const double &open[])
{
   double sum = 0.0;
   int count = 0;

   for(int i = 1; i <= period; i++)
   {
      if(currentBar - i >= 0)
      {
         sum += MathAbs(close[currentBar - i] - open[currentBar - i]);
         count++;
      }
   }

   return count > 0 ? sum / count : 0.0;
}

//+------------------------------------------------------------------+
//| ✅ NOUVEAU: Calculer tendance MTF (H4/W1)                       |
//+------------------------------------------------------------------+
double CalculateMTFTrend(ENUM_TIMEFRAMES tf)
{
   int ema20Handle = (tf == MTF1) ? ema20HandleH4 : ema20HandleW1;
   int ema50Handle = (tf == MTF1) ? ema50HandleH4 : ema50HandleW1;

   double ema20[], ema50[];
   ArraySetAsSeries(ema20, true);
   ArraySetAsSeries(ema50, true);

   if(CopyBuffer(ema20Handle, 0, 0, 1, ema20) <= 0 ||
      CopyBuffer(ema50Handle, 0, 0, 1, ema50) <= 0)
   {
      return 0.0; // Neutral si erreur
   }

   // Retourner 1.0 (bullish) ou -1.0 (bearish)
   return (ema20[0] > ema50[0]) ? 1.0 : -1.0;
}

//+------------------------------------------------------------------+
//| ✅ NOUVEAU: Dessiner zones SMC sur le graphique                 |
//+------------------------------------------------------------------+
void DrawSMCZones(datetime signalTime, SMCDetails &details, bool isBuy)
{
   string prefix = isBuy ? "SMC_BUY_" : "SMC_SELL_";
   string timeStr = TimeToString(signalTime, TIME_DATE|TIME_MINUTES);

   //--- Dessiner Order Block
   if(details.orderBlockFound && DrawOrderBlocks)
   {
      string obName = prefix + "OB_" + timeStr;

      datetime endTime = signalTime + PeriodSeconds(_Period) * 20; // Prolonger 20 bougies

      if(ObjectCreate(0, obName, OBJ_RECTANGLE, 0, details.obTime, details.obHigh, endTime, details.obLow))
      {
         ObjectSetInteger(0, obName, OBJPROP_COLOR, isBuy ? clrDodgerBlue : clrCrimson);
         ObjectSetInteger(0, obName, OBJPROP_STYLE, STYLE_SOLID);
         ObjectSetInteger(0, obName, OBJPROP_WIDTH, 1);
         ObjectSetInteger(0, obName, OBJPROP_FILL, true);
         ObjectSetInteger(0, obName, OBJPROP_BACK, true);
         ObjectSetString(0, obName, OBJPROP_TOOLTIP, "Order Block " + (isBuy ? "BUY" : "SELL"));
      }
   }

   //--- Dessiner Fair Value Gap
   if(details.fvgDetected && DrawFVG)
   {
      string fvgName = prefix + "FVG_" + timeStr;

      datetime endTime = signalTime + PeriodSeconds(_Period) * 15;

      if(ObjectCreate(0, fvgName, OBJ_RECTANGLE, 0, details.fvgTime, details.fvgTop, endTime, details.fvgBottom))
      {
         ObjectSetInteger(0, fvgName, OBJPROP_COLOR, isBuy ? clrAqua : clrOrange);
         ObjectSetInteger(0, fvgName, OBJPROP_STYLE, STYLE_DOT);
         ObjectSetInteger(0, fvgName, OBJPROP_WIDTH, 1);
         ObjectSetInteger(0, fvgName, OBJPROP_FILL, true);
         ObjectSetInteger(0, fvgName, OBJPROP_BACK, true);
         ObjectSetString(0, fvgName, OBJPROP_TOOLTIP, "Fair Value Gap");
      }
   }

   //--- Dessiner Liquidity Sweep
   if(details.liquiditySweep && DrawSweptLiquidity)
   {
      string sweepName = prefix + "SWEEP_" + timeStr;

      datetime endTime = signalTime + PeriodSeconds(_Period) * 10;

      if(ObjectCreate(0, sweepName, OBJ_TREND, 0, details.sweepTime, details.sweepLevel, endTime, details.sweepLevel))
      {
         ObjectSetInteger(0, sweepName, OBJPROP_COLOR, isBuy ? clrLimeGreen : clrRed);
         ObjectSetInteger(0, sweepName, OBJPROP_STYLE, STYLE_DASHDOT);
         ObjectSetInteger(0, sweepName, OBJPROP_WIDTH, 2);
         ObjectSetInteger(0, sweepName, OBJPROP_RAY_RIGHT, false);
         ObjectSetString(0, sweepName, OBJPROP_TOOLTIP, "Liquidity Sweep");
      }
   }
}

//+------------------------------------------------------------------+
//| ✅ NOUVEAU: Afficher info MTF sur le chart                      |
//+------------------------------------------------------------------+
void DisplayMTFInfo(double h4Trend, double w1Trend)
{
   string mtfText = "MTF ANALYSIS\n";
   mtfText += EnumToString(MTF1) + ": " + (h4Trend > 0 ? "BULLISH 📈" : "BEARISH 📉") + "\n";
   mtfText += EnumToString(MTF2) + ": " + (w1Trend > 0 ? "BULLISH 📈" : "BEARISH 📉") + "\n";

   // Concordance
   if((h4Trend > 0 && w1Trend > 0) || (h4Trend < 0 && w1Trend < 0))
      mtfText += "Status: ✅ ALIGNED";
   else
      mtfText += "Status: ⚠️ DIVERGENT";

   string labelName = "DAFINTSMC_MTF_INFO";

   if(ObjectFind(0, labelName) < 0)
   {
      ObjectCreate(0, labelName, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, labelName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, labelName, OBJPROP_XDISTANCE, 10);
      ObjectSetInteger(0, labelName, OBJPROP_YDISTANCE, 50);
      ObjectSetInteger(0, labelName, OBJPROP_COLOR, clrWhite);
      ObjectSetInteger(0, labelName, OBJPROP_FONTSIZE, 9);
      ObjectSetString(0, labelName, OBJPROP_FONT, "Consolas");
   }

   ObjectSetString(0, labelName, OBJPROP_TEXT, mtfText);
}

//+------------------------------------------------------------------+
//| Supprimer objets SMC anciens                                     |
//+------------------------------------------------------------------+
void DeleteAllSMCObjects()
{
   int total = ObjectsTotal(0, 0, -1);

   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i, 0, -1);

      if(StringFind(name, "SMC_BUY_") >= 0 ||
         StringFind(name, "SMC_SELL_") >= 0 ||
         StringFind(name, "DAFINTSMC_") >= 0)
      {
         ObjectDelete(0, name);
      }
   }
}
