//+------------------------------------------------------------------+
//|                        DAFINT_EA.mq5                             |
//|   Full Strategy: SMC + MTF Filter + Risk + 3TP + BE SL          |
//|   Version 2.0 - Utilise buffers MTF de l'indicateur SMC         |
//+------------------------------------------------------------------+
#property strict
#property script_show_inputs

#define MODE_EMA 1
#define PRICE_CLOSE 0
#define ORDER_TYPE_BUY  0
#define ORDER_TYPE_SELL 1

#include <Trade\Trade.mqh>
CTrade trade;

//----------------------------------------------------
// Inputs originaux
//----------------------------------------------------
input string   ExpertName           = "DAFINT_EA";
input long     Magic_Number         = 123456789;
input double   Risk_Percent         = 1.0;
input int      EMA1_Period          = 20;
input int      EMA2_Period          = 50;
input int      EMA_Gap_Threshold    = 10;
input int      ATR_Period           = 14;
input double   ATR_Mult_SL          = 1.5;
input double   TP1_RR               = 1.0;
input double   TP2_RR               = 1.5;
input double   TP3_RR               = 2.0;
input int      Partial_TP1_Percent  = 50;
input int      Partial_TP2_Percent  = 30;
input int      Partial_TP3_Percent  = 20;
input ENUM_TIMEFRAMES Higher_TF1    = PERIOD_H4;
input ENUM_TIMEFRAMES Higher_TF2    = PERIOD_W1;
input bool     Dashboard_Show       = true;
input bool     EnableAlerts         = true;

//----------------------------------------------------
// SMC Principal
//----------------------------------------------------
input group "=== SMC Principal ==="
input bool     UseSMC_Signals       = true;
input int      SMC_EMA1_Period      = 20;
input int      SMC_EMA2_Period      = 50;
input int      SMC_EMA_Gap_Threshold = 10;
input int      SMC_LookbackBars     = 5;
input ENUM_TIMEFRAMES SMC_HTF1      = PERIOD_H4;
input ENUM_TIMEFRAMES SMC_HTF2      = PERIOD_W1;
input bool     UseStrictMode        = false;

//----------------------------------------------------
// ADAPTIVE RISK MANAGEMENT
//----------------------------------------------------
input group "=== ADAPTIVE RISK MANAGEMENT ==="
input bool     Enable_Adaptive_Risk = true;
input double   Moderate_Risk_Percent = 0.5;
input double   Low_Volatility_Threshold = 0.8;
input double   High_Volatility_Threshold = 1.3;
input int      Max_Consecutive_Losses = 3;
input double   Max_Daily_Drawdown   = 2.0;
input int      Suspension_Bars      = 10;
input double   Min_Risk_Threshold   = 0.2;
input int      ATR_Average_Period   = 20;
input bool     Debug_Adaptive_Risk  = true;

//----------------------------------------------------
// RISK MANAGEMENT GLOBAL
//----------------------------------------------------
input group "=== RISK MANAGEMENT GLOBAL ==="
input double   Max_Total_Risk_Percent = 4.5;
input bool     Enable_Global_Risk_Control = true;

//----------------------------------------------------
// Variables globales de base
//----------------------------------------------------
double atr, ema1, ema2;
bool inBuy = false, inSell = false;
double entryPrice, stopLoss;
ulong ticketBuy = 0, ticketSell = 0;

// ✅ SMC avec buffers MTF
int smcHandle1;
double smc1_buy_buffer[], smc1_sell_buffer[];
double smc_h4_trend_buffer[], smc_w1_trend_buffer[]; // ✅ NOUVEAUX BUFFERS MTF
bool smcAvailable1 = false;

// EMA et ATR
int ema1Handle, ema2Handle, atrHandle;
double ema1Array[], ema2Array[], atrArray[];

// 3 TP + BE
bool tp1Hit = false, tp2Hit = false, tp3Hit = false;
bool slMovedToBE = false;
double originalSL = 0.0;

//----------------------------------------------------
// STRUCTURES ADAPTIVE RISK PAR SYMBOLE
//----------------------------------------------------
struct TradeResult {
   datetime time;
   bool isWin;
   double profit;
   string comment;
};

struct SymbolRiskData {
   string symbol;
   int consecutiveLosses;
   int consecutiveWins;
   TradeResult recentTrades[10];
   int tradeHistoryCount;
   datetime suspensionEndTime;
   bool isSuspended;
   double dailyStartBalance;
   datetime dailyStartTime;
};

SymbolRiskData symbolRiskArray[];
int symbolCount = 0;

double confidenceScore = 0.0;
double volatilityFactor = 1.0;
double performanceFactor = 1.0;
double finalAdaptiveRisk = 0.0;

//----------------------------------------------------
int OnInit()
{
   Print("=== DAFINT EA v2.0 ADAPTIVE RISK + MTF BUFFERS ===");

   trade.SetExpertMagicNumber(Magic_Number);
   Print("🔧 Magic Number configuré: ", Magic_Number);

   GetSymbolRiskIndex(_Symbol);

   // Indicateurs de base
   ema1Handle = iMA(_Symbol, _Period, EMA1_Period, 0, MODE_EMA, PRICE_CLOSE);
   ema2Handle = iMA(_Symbol, _Period, EMA2_Period, 0, MODE_EMA, PRICE_CLOSE);
   atrHandle = iATR(_Symbol, _Period, ATR_Period);

   if(ema1Handle == INVALID_HANDLE || ema2Handle == INVALID_HANDLE || atrHandle == INVALID_HANDLE) {
      Print("❌ Erreur chargement indicateurs EMA/ATR");
      return INIT_FAILED;
   }

   ArraySetAsSeries(ema1Array, true);
   ArraySetAsSeries(ema2Array, true);
   ArraySetAsSeries(atrArray, true);

   // ✅ SMC avec buffers MTF
   smcAvailable1 = false;
   if(UseSMC_Signals) {
      Print("Chargement SMC avec MTF Buffers [", _Symbol, "]...");
      smcHandle1 = iCustom(_Symbol, _Period, "DAFINTSMC",
                           SMC_LookbackBars, SMC_HTF1, SMC_HTF2,
                           true, true, true, 50, 1.5, 20,
                           SMC_EMA1_Period, SMC_EMA2_Period, SMC_EMA_Gap_Threshold);

      if(smcHandle1 == INVALID_HANDLE) {
         Print("⚠️ SMC indisponible sur ", _Symbol, " - Mode EMA uniquement");
      } else {
         ArraySetAsSeries(smc1_buy_buffer, true);
         ArraySetAsSeries(smc1_sell_buffer, true);
         ArraySetAsSeries(smc_h4_trend_buffer, true); // ✅ NOUVEAU
         ArraySetAsSeries(smc_w1_trend_buffer, true); // ✅ NOUVEAU
         smcAvailable1 = true;
         Print("✅ SMC v2.0 chargé avec MTF Analysis sur ", _Symbol);
      }
   }

   Print("=== CONFIGURATION ===");
   Print("- MTF via SMC Buffers: ", EnumToString(Higher_TF1), "/", EnumToString(Higher_TF2));
   Print("- Max Total Risk: ", Max_Total_Risk_Percent, "%");

   Print("✅ DAFINT EA v2.0 initialisé sur ", _Symbol);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
int GetSymbolRiskIndex(string symbol)
{
   for(int i = 0; i < symbolCount; i++) {
      if(symbolRiskArray[i].symbol == symbol) {
         return i;
      }
   }

   ArrayResize(symbolRiskArray, symbolCount + 1);
   int newIndex = symbolCount;

   symbolRiskArray[newIndex].symbol = symbol;
   symbolRiskArray[newIndex].consecutiveLosses = 0;
   symbolRiskArray[newIndex].consecutiveWins = 0;
   symbolRiskArray[newIndex].tradeHistoryCount = 0;
   symbolRiskArray[newIndex].isSuspended = false;
   symbolRiskArray[newIndex].suspensionEndTime = 0;
   symbolRiskArray[newIndex].dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   symbolRiskArray[newIndex].dailyStartTime = TimeCurrent();

   for(int j = 0; j < 10; j++) {
      symbolRiskArray[newIndex].recentTrades[j].time = 0;
      symbolRiskArray[newIndex].recentTrades[j].isWin = false;
      symbolRiskArray[newIndex].recentTrades[j].profit = 0.0;
      symbolRiskArray[newIndex].recentTrades[j].comment = "";
   }

   symbolCount++;

   if(Debug_Adaptive_Risk) {
      Print("🆕 Nouveau symbole ajouté au tracking: ", symbol, " (Index: ", newIndex, ")");
   }

   return newIndex;
}

//+------------------------------------------------------------------+
double GetCurrentTotalRisk()
{
   double totalRisk = 0.0;
   double accountBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   if(accountBalance <= 0) return 0.0;

   for(int i = 0; i < PositionsTotal(); i++) {
      if(PositionGetTicket(i) > 0) {
         string posSymbol = PositionGetString(POSITION_SYMBOL);
         double posVolume = PositionGetDouble(POSITION_VOLUME);
         double posOpenPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double posSL = PositionGetDouble(POSITION_SL);

         if(posSL > 0) {
            double slDistance = MathAbs(posOpenPrice - posSL);
            double tickValue = SymbolInfoDouble(posSymbol, SYMBOL_TRADE_TICK_VALUE);
            double tickSize = SymbolInfoDouble(posSymbol, SYMBOL_TRADE_TICK_SIZE);

            if(tickSize > 0 && tickValue > 0) {
               double positionRisk = (slDistance / tickSize * tickValue * posVolume);
               double riskPercent = (positionRisk / accountBalance) * 100.0;
               totalRisk += riskPercent;

               if(Debug_Adaptive_Risk && posSymbol == _Symbol) {
                  Print("📊 Position Risk [", posSymbol, "]: ", DoubleToString(riskPercent, 2), "%");
               }
            }
         }
      }
   }

   return totalRisk;
}

//+------------------------------------------------------------------+
bool CanAddRisk(double newRiskPercent)
{
   if(!Enable_Global_Risk_Control) return true;

   double currentRisk = GetCurrentTotalRisk();
   double futureRisk = currentRisk + newRiskPercent;

   bool canAdd = (futureRisk <= Max_Total_Risk_Percent);

   if(Debug_Adaptive_Risk) {
      Print("🛡️ GLOBAL RISK CONTROL CHECK:");
      Print("   Current Total Risk: ", DoubleToString(currentRisk, 2), "%");
      Print("   New Position Risk [", _Symbol, "]: ", DoubleToString(newRiskPercent, 2), "%");
      Print("   Future Total Risk: ", DoubleToString(futureRisk, 2), "%");
      Print("   Max Allowed: ", DoubleToString(Max_Total_Risk_Percent, 2), "%");
      Print("   Decision: ", canAdd ? "✅ ALLOWED" : "❌ BLOCKED");
   }

   return canAdd;
}

//+------------------------------------------------------------------+
bool CanTradeSymbol(string symbol)
{
   for(int i = 0; i < PositionsTotal(); i++) {
      if(PositionGetTicket(i) > 0) {
         if(PositionGetString(POSITION_SYMBOL) == symbol &&
            PositionGetInteger(POSITION_MAGIC) == Magic_Number) {
            return false;
         }
      }
   }
   return true;
}

//----------------------------------------------------
void OnDeinit(const int reason)
{
   if(ema1Handle != INVALID_HANDLE) IndicatorRelease(ema1Handle);
   if(ema2Handle != INVALID_HANDLE) IndicatorRelease(ema2Handle);
   if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
   if(smcHandle1 != INVALID_HANDLE) IndicatorRelease(smcHandle1);

   ObjectsDeleteAll(0, "DAFINT_");
   Comment("");
   Print("DAFINT EA arrêté sur ", _Symbol);
}

//----------------------------------------------------
void OnTick()
{
   if(!UpdateIndicators()) return;

   if(Enable_Adaptive_Risk) UpdatePerformanceTracking();

   ManageOpenPositions_3TP_BE();

   if(!IsNewBar()) {
      if(Dashboard_Show) ShowAdaptiveDashboard();
      return;
   }

   if(Enable_Adaptive_Risk && IsTradesSuspended()) {
      if(Debug_Adaptive_Risk) Print("🚫 Trading suspendu sur ", _Symbol);
      if(Dashboard_Show) ShowAdaptiveDashboard();
      return;
   }

   // Signaux de base
   bool emaBuySignal = GetEMABuySignal();
   bool emaSellSignal = GetEMASellSignal();
   bool smcBuySignal = false, smcSellSignal = false;

   if(UseSMC_Signals && smcAvailable1) {
      GetMainSMCSignals(smcBuySignal, smcSellSignal);
   }

   // Combiner signaux
   bool buySignal = false, sellSignal = false;

   if(UseSMC_Signals && smcAvailable1) {
      if(UseStrictMode) {
         buySignal = smcBuySignal && (emaBuySignal || ema1 > ema2);
         sellSignal = smcSellSignal && (emaSellSignal || ema1 < ema2);
      } else {
         buySignal = smcBuySignal || emaBuySignal;
         sellSignal = smcSellSignal || emaSellSignal;
      }
   } else {
      buySignal = emaBuySignal;
      sellSignal = emaSellSignal;
   }

   // Calcul Adaptive Risk
   double adaptiveRisk = 0.0;

   if(Enable_Adaptive_Risk) {
      adaptiveRisk = CalculateAdaptiveRisk(buySignal, sellSignal);
   } else {
      adaptiveRisk = CalculateRiskBasedOnMTF(buySignal, sellSignal, smcBuySignal, smcSellSignal);
   }

   if(adaptiveRisk == 0.0) {
      if(buySignal && Debug_Adaptive_Risk) Print("🚫 BUY bloqué par Adaptive Risk sur ", _Symbol);
      if(sellSignal && Debug_Adaptive_Risk) Print("🚫 SELL bloqué par Adaptive Risk sur ", _Symbol);
      buySignal = false;
      sellSignal = false;
   }

   // Exécution avec contrôle risque global
   if(buySignal && !inBuy && CanTradeSymbol(_Symbol) && adaptiveRisk > 0.0) {
      if(CanAddRisk(adaptiveRisk)) {
         ExecuteBuyOrder_3TP(adaptiveRisk);
      } else {
         if(Debug_Adaptive_Risk) {
            Print("🚫 BUY bloqué [", _Symbol, "] - Risque total dépasserait ", Max_Total_Risk_Percent, "%");
         }
      }
   }

   if(sellSignal && !inSell && CanTradeSymbol(_Symbol) && adaptiveRisk > 0.0) {
      if(CanAddRisk(adaptiveRisk)) {
         ExecuteSellOrder_3TP(adaptiveRisk);
      } else {
         if(Debug_Adaptive_Risk) {
            Print("🚫 SELL bloqué [", _Symbol, "] - Risque total dépasserait ", Max_Total_Risk_Percent, "%");
         }
      }
   }

   if(Dashboard_Show) ShowAdaptiveDashboard();
}

//+------------------------------------------------------------------+
//| CALCUL ADAPTIVE RISK COMPLET                                    |
//+------------------------------------------------------------------+
double CalculateAdaptiveRisk(bool buySignal, bool sellSignal)
{
   if(!buySignal && !sellSignal) return 0.0;

   if(CheckDailyDrawdown()) return 0.0;
   if(IsTradesSuspended()) return 0.0;

   bool isBuySignal = buySignal && !sellSignal;

   // ✅ NOUVEAU: Utiliser les buffers MTF de l'indicateur
   confidenceScore = CalculateConfidenceScore_MTFBuffers(isBuySignal);
   if(confidenceScore == 0.0) return 0.0;

   volatilityFactor = CalculateVolatilityFactor();
   performanceFactor = CalculatePerformanceFactor();

   finalAdaptiveRisk = Risk_Percent * confidenceScore * volatilityFactor * performanceFactor;

   if(Debug_Adaptive_Risk) {
      Print("🎯 === ADAPTIVE RISK [", _Symbol, "] ===");
      Print("Signal: ", isBuySignal ? "BUY" : "SELL");
      Print("Base Risk: ", DoubleToString(Risk_Percent, 2), "%");
      Print("MTF Confidence (via Buffers): ", DoubleToString(confidenceScore, 2));
      Print("Volatility Factor: ", DoubleToString(volatilityFactor, 2));
      Print("Performance Factor [", _Symbol, "]: ", DoubleToString(performanceFactor, 2));
      Print("FINAL RISK: ", DoubleToString(finalAdaptiveRisk, 2), "%");
      Print("===========================================");
   }

   if(finalAdaptiveRisk < Min_Risk_Threshold) {
      if(Debug_Adaptive_Risk) Print("🚫 Risque trop faible sur ", _Symbol, ": ", DoubleToString(finalAdaptiveRisk, 2), "% < ", Min_Risk_Threshold, "%");
      return 0.0;
   }

   return finalAdaptiveRisk;
}

//+------------------------------------------------------------------+
//| ✅ NOUVEAU: Score MTF depuis les buffers de l'indicateur       |
//+------------------------------------------------------------------+
double CalculateConfidenceScore_MTFBuffers(bool isBuySignal)
{
   if(!smcAvailable1 || smcHandle1 == INVALID_HANDLE) {
      // Fallback: mode classique si SMC non disponible
      return CalculateConfidenceScore_2MTF(isBuySignal);
   }

   // ✅ Lire les buffers MTF depuis l'indicateur SMC
   if(CopyBuffer(smcHandle1, 2, 0, 1, smc_h4_trend_buffer) <= 0 ||
      CopyBuffer(smcHandle1, 3, 0, 1, smc_w1_trend_buffer) <= 0)
   {
      if(Debug_Adaptive_Risk) Print("⚠️ Erreur lecture buffers MTF - Fallback mode classique");
      return CalculateConfidenceScore_2MTF(isBuySignal);
   }

   double h4Trend = smc_h4_trend_buffer[0]; // 1.0 = bullish, -1.0 = bearish
   double w1Trend = smc_w1_trend_buffer[0];

   // Compter les timeframes alignés
   int alignedCount = 0;

   if(isBuySignal) {
      if(h4Trend > 0) alignedCount++; // H4 bullish
      if(w1Trend > 0) alignedCount++; // W1 bullish
   } else {
      if(h4Trend < 0) alignedCount++; // H4 bearish
      if(w1Trend < 0) alignedCount++; // W1 bearish
   }

   double score = 0.0;
   switch(alignedCount) {
      case 2: score = 1.0; break;
      case 1: score = 0.5; break;
      case 0: score = 0.0; break;
   }

   if(Debug_Adaptive_Risk) {
      Print("📊 MTF Analysis [", _Symbol, "] (via SMC Buffers):");
      Print("   H4 Trend: ", h4Trend > 0 ? "BULL" : "BEAR", " (", DoubleToString(h4Trend, 1), ")");
      Print("   W1 Trend: ", w1Trend > 0 ? "BULL" : "BEAR", " (", DoubleToString(w1Trend, 1), ")");
      Print("   Aligned: ", alignedCount, "/2 → Score: ", DoubleToString(score, 2));
   }

   return score;
}

//+------------------------------------------------------------------+
//| ✅ Fallback: Mode classique MTF (si indicateur indisponible)   |
//+------------------------------------------------------------------+
double CalculateConfidenceScore_2MTF(bool isBuySignal)
{
   bool htf1Bullish = GetTrendDirection(Higher_TF1);
   bool htf2Bullish = GetTrendDirection(Higher_TF2);

   int alignedCount = 0;

   if(isBuySignal) {
      if(htf1Bullish) alignedCount++;
      if(htf2Bullish) alignedCount++;
   } else {
      if(!htf1Bullish) alignedCount++;
      if(!htf2Bullish) alignedCount++;
   }

   double score = 0.0;
   switch(alignedCount) {
      case 2: score = 1.0; break;
      case 1: score = 0.5; break;
      case 0: score = 0.0; break;
   }

   return score;
}

//+------------------------------------------------------------------+
double CalculateVolatilityFactor()
{
   double atrBuffer[];
   ArraySetAsSeries(atrBuffer, true);

   if(CopyBuffer(atrHandle, 0, 0, ATR_Average_Period, atrBuffer) <= 0) {
      return 1.0;
   }

   double atrSum = 0.0;
   for(int i = 0; i < ATR_Average_Period; i++) {
      atrSum += atrBuffer[i];
   }
   double avgATR = atrSum / ATR_Average_Period;

   if(avgATR <= 0) return 1.0;

   double volatilityRatio = atr / avgATR;

   double factor = 1.0;
   if(volatilityRatio < Low_Volatility_Threshold) {
      factor = 1.2;
   } else if(volatilityRatio > High_Volatility_Threshold) {
      factor = 0.7;
   } else {
      factor = 1.0;
   }

   if(Debug_Adaptive_Risk) {
      Print("📈 Volatility Analysis [", _Symbol, "]:");
      Print("   Current ATR: ", DoubleToString(atr, _Digits));
      Print("   Average ATR: ", DoubleToString(avgATR, _Digits));
      Print("   Ratio: ", DoubleToString(volatilityRatio, 2));
      Print("   Factor: ", DoubleToString(factor, 2));
   }

   return factor;
}

//+------------------------------------------------------------------+
double CalculatePerformanceFactor()
{
   int symbolIndex = GetSymbolRiskIndex(_Symbol);

   if(symbolRiskArray[symbolIndex].tradeHistoryCount < 2) return 1.0;

   double factor = 1.0;

   if(symbolRiskArray[symbolIndex].consecutiveWins >= 2) {
      factor = 1.2;
   } else if(symbolRiskArray[symbolIndex].consecutiveLosses >= 2) {
      factor = 0.5;
   } else {
      factor = 1.0;
   }

   if(Debug_Adaptive_Risk) {
      Print("🎭 Performance Analysis [", _Symbol, "]:");
      Print("   Consecutive Wins: ", symbolRiskArray[symbolIndex].consecutiveWins);
      Print("   Consecutive Losses: ", symbolRiskArray[symbolIndex].consecutiveLosses);
      Print("   Factor: ", DoubleToString(factor, 2));
   }

   return factor;
}

//+------------------------------------------------------------------+
bool CheckDailyDrawdown()
{
   int symbolIndex = GetSymbolRiskIndex(_Symbol);

   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double dailyDrawdown = ((symbolRiskArray[symbolIndex].dailyStartBalance - currentBalance) / symbolRiskArray[symbolIndex].dailyStartBalance) * 100.0;

   if(dailyDrawdown >= Max_Daily_Drawdown) {
      TriggerSuspension("Drawdown journalier ≥ " + DoubleToString(Max_Daily_Drawdown, 1) + "% sur " + _Symbol);
      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
void UpdatePerformanceTracking()
{
   int symbolIndex = GetSymbolRiskIndex(_Symbol);

   datetime currentTime = TimeCurrent();
   MqlDateTime dtCurrent, dtStart;
   TimeToStruct(currentTime, dtCurrent);
   TimeToStruct(symbolRiskArray[symbolIndex].dailyStartTime, dtStart);

   if(dtCurrent.day != dtStart.day) {
      symbolRiskArray[symbolIndex].dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      symbolRiskArray[symbolIndex].dailyStartTime = currentTime;
      if(Debug_Adaptive_Risk) Print("🌅 Nouveau jour - Reset balance référence pour ", _Symbol);
   }

   if(symbolRiskArray[symbolIndex].isSuspended && currentTime >= symbolRiskArray[symbolIndex].suspensionEndTime) {
      symbolRiskArray[symbolIndex].isSuspended = false;
      Print("✅ Fin de suspension sur ", _Symbol, " - Trading réactivé");
   }
}

void AddTradeResult(bool isWin, double profit, string comment)
{
   int symbolIndex = GetSymbolRiskIndex(_Symbol);

   int index = symbolRiskArray[symbolIndex].tradeHistoryCount % 10;
   symbolRiskArray[symbolIndex].recentTrades[index].time = TimeCurrent();
   symbolRiskArray[symbolIndex].recentTrades[index].isWin = isWin;
   symbolRiskArray[symbolIndex].recentTrades[index].profit = profit;
   symbolRiskArray[symbolIndex].recentTrades[index].comment = comment;

   symbolRiskArray[symbolIndex].tradeHistoryCount++;

   if(isWin) {
      symbolRiskArray[symbolIndex].consecutiveWins++;
      symbolRiskArray[symbolIndex].consecutiveLosses = 0;
   } else {
      symbolRiskArray[symbolIndex].consecutiveLosses++;
      symbolRiskArray[symbolIndex].consecutiveWins = 0;
   }

   if(Debug_Adaptive_Risk) {
      Print("📝 Trade Result [", _Symbol, "]: ", isWin ? "WIN" : "LOSS", " - Profit: ", DoubleToString(profit, 2));
      Print("   Consecutive: W:", symbolRiskArray[symbolIndex].consecutiveWins, " L:", symbolRiskArray[symbolIndex].consecutiveLosses);
   }

   if(symbolRiskArray[symbolIndex].consecutiveLosses >= Max_Consecutive_Losses) {
      TriggerSuspension("3 trades perdants consécutifs sur " + _Symbol);
   }
}

void TriggerSuspension(string reason)
{
   int symbolIndex = GetSymbolRiskIndex(_Symbol);

   symbolRiskArray[symbolIndex].isSuspended = true;
   symbolRiskArray[symbolIndex].suspensionEndTime = TimeCurrent() + (Suspension_Bars * PeriodSeconds(_Period));

   Print("🚫 SUSPENSION [", _Symbol, "]: ", reason);
   Print("   Durée: ", Suspension_Bars, " barres sur ", _Symbol, " uniquement");

   if(EnableAlerts) {
      Alert("DAFINT EA: Trading suspendu sur ", _Symbol, " - ", reason);
   }
}

bool IsTradesSuspended()
{
   int symbolIndex = GetSymbolRiskIndex(_Symbol);

   if(!symbolRiskArray[symbolIndex].isSuspended) return false;

   if(TimeCurrent() >= symbolRiskArray[symbolIndex].suspensionEndTime) {
      symbolRiskArray[symbolIndex].isSuspended = false;
      Print("✅ Fin de suspension sur ", _Symbol, " - Trading réactivé");
      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| DASHBOARD ADAPTATIF AVEC MTF BUFFERS                           |
//+------------------------------------------------------------------+
void ShowAdaptiveDashboard()
{
   int symbolIndex = GetSymbolRiskIndex(_Symbol);
   static datetime lastUpdate = 0;
   if(TimeCurrent() - lastUpdate < 3) return;
   lastUpdate = TimeCurrent();

   string dashboard = "\n=== DAFINT EA v2.0 - " + _Symbol + " ===\n";
   dashboard += "Magic Number: " + IntegerToString(Magic_Number) + "\n";

   // RISK MANAGEMENT GLOBAL
   if(Enable_Global_Risk_Control) {
      double currentTotalRisk = GetCurrentTotalRisk();

      dashboard += "=== RISK MANAGEMENT GLOBAL ===\n";
      dashboard += "Total Risk Used: " + DoubleToString(currentTotalRisk, 2) + "%\n";
      dashboard += "Max Allowed: " + DoubleToString(Max_Total_Risk_Percent, 2) + "%\n";
      dashboard += "Available: " + DoubleToString(Max_Total_Risk_Percent - currentTotalRisk, 2) + "%\n";

      if(currentTotalRisk >= Max_Total_Risk_Percent * 0.9) {
         dashboard += "Status: 🔴 ALMOST FULL\n";
      } else if(currentTotalRisk >= Max_Total_Risk_Percent * 0.7) {
         dashboard += "Status: 🟡 MODERATE\n";
      } else {
         dashboard += "Status: 🟢 SAFE\n";
      }

      dashboard += "Active Positions: " + IntegerToString(PositionsTotal()) + "\n";
   }

   // ADAPTIVE RISK
   if(Enable_Adaptive_Risk) {
      dashboard += "=== ADAPTIVE RISK [" + _Symbol + "] ===\n";
      dashboard += "Status: " + (symbolRiskArray[symbolIndex].isSuspended ? "🚫 SUSPENDU" : "✅ ACTIF") + "\n";

      if(symbolRiskArray[symbolIndex].isSuspended) {
         int barsRemaining = (int)((symbolRiskArray[symbolIndex].suspensionEndTime - TimeCurrent()) / PeriodSeconds(_Period));
         dashboard += "Suspension: " + IntegerToString(barsRemaining) + " barres [" + _Symbol + "]\n";
      }

      dashboard += "=== CALCULS ADAPTATIFS [" + _Symbol + "] ===\n";
      dashboard += "MTF Score: " + DoubleToString(confidenceScore, 2) + " (via SMC Buffers)\n";
      dashboard += "Volatility Factor: " + DoubleToString(volatilityFactor, 2) + "\n";
      dashboard += "Performance Factor: " + DoubleToString(performanceFactor, 2) + "\n";
      dashboard += "FINAL RISK: " + DoubleToString(finalAdaptiveRisk, 2) + "%\n";

      dashboard += "=== PERFORMANCE [" + _Symbol + "] ===\n";
      dashboard += "Consecutive Wins: " + IntegerToString(symbolRiskArray[symbolIndex].consecutiveWins) + "\n";
      dashboard += "Consecutive Losses: " + IntegerToString(symbolRiskArray[symbolIndex].consecutiveLosses) + "\n";
      dashboard += "Trade History Count: " + IntegerToString(symbolRiskArray[symbolIndex].tradeHistoryCount) + "\n";

      double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      double dailyDrawdown = ((symbolRiskArray[symbolIndex].dailyStartBalance - currentBalance) / symbolRiskArray[symbolIndex].dailyStartBalance) * 100.0;
      dashboard += "Daily Drawdown: " + DoubleToString(dailyDrawdown, 2) + "%\n";
   }

   // ✅ MTF Status depuis buffers SMC
   if(smcAvailable1) {
      double h4Trend = 0, w1Trend = 0;
      if(CopyBuffer(smcHandle1, 2, 0, 1, smc_h4_trend_buffer) > 0)
         h4Trend = smc_h4_trend_buffer[0];
      if(CopyBuffer(smcHandle1, 3, 0, 1, smc_w1_trend_buffer) > 0)
         w1Trend = smc_w1_trend_buffer[0];

      dashboard += "=== MTF STATUS (SMC Buffers) ===\n";
      dashboard += "H4: " + (h4Trend > 0 ? "BULL 📈" : "BEAR 📉") + "\n";
      dashboard += "W1: " + (w1Trend > 0 ? "BULL 📈" : "BEAR 📉") + "\n";
      dashboard += "Concordance: " + ((h4Trend > 0 && w1Trend > 0) || (h4Trend < 0 && w1Trend < 0) ? "✅ ALIGNED" : "⚠️ DIVERGENT") + "\n";
   }

   // Position active
   if(inBuy || inSell) {
      dashboard += "=== POSITION ACTIVE [" + _Symbol + "] ===\n";
      dashboard += "Type: " + (inBuy ? "BUY 🟢" : "SELL 🔴") + "\n";

      if(SelectMyPosition(_Symbol)) {
         double currentPrice = inBuy ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double rr = MathAbs(currentPrice - entryPrice) / MathAbs(entryPrice - originalSL);

         dashboard += "R/R: " + DoubleToString(rr, 2) + "\n";
         dashboard += "SL: " + (slMovedToBE ? "✅ BE" : "⚠️ INITIAL") + "\n";

         string tpStatus = "";
         if(tp3Hit) tpStatus = "TP: ✅✅✅ COMPLETE";
         else if(tp2Hit) tpStatus = "TP: ✅✅⏳ 2/3";
         else if(tp1Hit) tpStatus = "TP: ✅⏳⏳ 1/3";
         else tpStatus = "TP: ⏳⏳⏳ PENDING";

         dashboard += tpStatus + "\n";
      }
   } else {
      dashboard += "=== POSITION [" + _Symbol + "] ===\n";
      dashboard += "Status: AUCUNE POSITION ⚪\n";
   }

   dashboard += "==========================\n";
   dashboard += "Time: " + TimeToString(TimeCurrent(), TIME_MINUTES) + "\n";

   Comment(dashboard);
}

//+------------------------------------------------------------------+
//| FONCTIONS MTF CLASSIQUES (fallback)                            |
//+------------------------------------------------------------------+
double CalculateRiskBasedOnMTF(bool buySignal, bool sellSignal, bool smcBuy, bool smcSell)
{
   if(!buySignal && !sellSignal) return 0.0;

   bool htf1Bullish = GetTrendDirection(Higher_TF1);
   bool htf2Bullish = GetTrendDirection(Higher_TF2);
   bool signalBullish = buySignal && !sellSignal;

   int alignedHTF = 0;

   if(signalBullish) {
      if(htf1Bullish) alignedHTF++;
      if(htf2Bullish) alignedHTF++;
   } else if(sellSignal) {
      if(!htf1Bullish) alignedHTF++;
      if(!htf2Bullish) alignedHTF++;
   }

   switch(alignedHTF) {
      case 2: return Risk_Percent;
      case 1: return Moderate_Risk_Percent;
      case 0: return 0.0;
   }

   return 0.0;
}

//+------------------------------------------------------------------+
//| TRADING FUNCTIONS                                               |
//+------------------------------------------------------------------+
void ExecuteBuyOrder_3TP(double riskPercent)
{
   double lots = CalculateLotSizeWithRisk(riskPercent);
   double sl = CalculateBuySL();
   double tp1 = CalculateBuyTP(TP1_RR);

   if(Debug_Adaptive_Risk) {
      Print("🔍 DEBUG ExecuteBuyOrder_3TP [", _Symbol, "]:");
      Print("   Risk Percent: ", DoubleToString(riskPercent, 2), "%");
      Print("   Lots calculés: ", DoubleToString(lots, 2));
      Print("   SL: ", DoubleToString(sl, _Digits));
      Print("   TP1: ", DoubleToString(tp1, _Digits));
   }

   if(lots <= 0) {
      Print("❌ Lots invalides: ", lots, " - Ordre annulé");
      return;
   }

   if(trade.Buy(lots, _Symbol, 0, sl, tp1, "DAFINT_" + _Symbol)) {
      ticketBuy = trade.ResultOrder();
      inBuy = true;
      entryPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      stopLoss = sl;
      originalSL = sl;

      tp1Hit = tp2Hit = tp3Hit = slMovedToBE = false;

      if(EnableAlerts) Alert("DAFINT EA: BUY ", _Symbol, " - Adaptive Risk: ", riskPercent, "%");
      Print("🟢 BUY ouvert [", _Symbol, "] - Adaptive Risk: ", DoubleToString(riskPercent, 2), "%");
   } else {
      Print("❌ ÉCHEC BUY [", _Symbol, "] - Code erreur: ", trade.ResultRetcode());
      Print("   Description: ", trade.ResultRetcodeDescription());
   }
}

void ExecuteSellOrder_3TP(double riskPercent)
{
   double lots = CalculateLotSizeWithRisk(riskPercent);
   double sl = CalculateSellSL();
   double tp1 = CalculateSellTP(TP1_RR);

   if(Debug_Adaptive_Risk) {
      Print("🔍 DEBUG ExecuteSellOrder_3TP [", _Symbol, "]:");
      Print("   Risk Percent: ", DoubleToString(riskPercent, 2), "%");
      Print("   Lots calculés: ", DoubleToString(lots, 2));
      Print("   SL: ", DoubleToString(sl, _Digits));
      Print("   TP1: ", DoubleToString(tp1, _Digits));
   }

   if(lots <= 0) {
      Print("❌ Lots invalides: ", lots, " - Ordre annulé");
      return;
   }

   if(trade.Sell(lots, _Symbol, 0, sl, tp1, "DAFINT_" + _Symbol)) {
      ticketSell = trade.ResultOrder();
      inSell = true;
      entryPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      stopLoss = sl;
      originalSL = sl;

      tp1Hit = tp2Hit = tp3Hit = slMovedToBE = false;

      if(EnableAlerts) Alert("DAFINT EA: SELL ", _Symbol, " - Adaptive Risk: ", riskPercent, "%");
      Print("🔴 SELL ouvert [", _Symbol, "] - Adaptive Risk: ", DoubleToString(riskPercent, 2), "%");
   } else {
      Print("❌ ÉCHEC SELL [", _Symbol, "] - Code erreur: ", trade.ResultRetcode());
      Print("   Description: ", trade.ResultRetcodeDescription());
   }
}

void ManageOpenPositions_3TP_BE()
{
   if(!SelectMyPosition(_Symbol)) {
      if(inBuy || inSell) {
         if(Enable_Adaptive_Risk && (tp1Hit || tp2Hit || tp3Hit)) {
            AddTradeResult(true, (tp3Hit ? TP3_RR : (tp2Hit ? TP2_RR : TP1_RR)), "POSITION_CLOSED");
         } else if(Enable_Adaptive_Risk) {
            AddTradeResult(false, -1.0, "POSITION_CLOSED_LOSS");
         }

         inBuy = inSell = false;
         ticketBuy = ticketSell = 0;
         tp1Hit = tp2Hit = tp3Hit = slMovedToBE = false;
         entryPrice = stopLoss = originalSL = 0.0;
      }
      return;
   }

   ulong ticket = (ulong)PositionGetInteger(POSITION_TICKET);
   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl = PositionGetDouble(POSITION_SL);
   int posType = (int)PositionGetInteger(POSITION_TYPE);
   double currentPrice = (posType == POSITION_TYPE_BUY) ?
      SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(sl == 0) {
      Print("⚠️ Position sans SL détectée - Application SL initial");
      double newSL = (posType == POSITION_TYPE_BUY) ? CalculateBuySL() : CalculateSellSL();
      ModifySL_3TP(ticket, newSL, "SL_INITIAL");
      return;
   }

   double rr = MathAbs(currentPrice - openPrice) / MathAbs(openPrice - sl);

   if(rr >= TP1_RR && !tp1Hit) {
      Print("🎯 TP1 déclenché [", _Symbol, "] - RR: ", DoubleToString(rr, 2));

      PartialClose_3TP(ticket, Partial_TP1_Percent, "TP1");
      Sleep(100);

      if(CheckPositionByTicket(ticket)) {
         double bePrice = NormalizeDouble(openPrice, _Digits);
         ModifySL_3TP(ticket, bePrice, "BREAKEVEN_TP1");

         tp1Hit = true;
         slMovedToBE = true;

         if(Enable_Adaptive_Risk) AddTradeResult(true, rr, "TP1_HIT");

         Print("✅ TP1 COMPLET [", _Symbol, "] - Position maintenue en BE");
      } else {
         Print("⚠️ Position fermée complètement après TP1 - Vérifier paramètres");
      }
   }
   else if(rr >= TP2_RR && tp1Hit && !tp2Hit) {
      Print("🎯 TP2 déclenché [", _Symbol, "] - RR: ", DoubleToString(rr, 2));

      PartialClose_3TP(ticket, Partial_TP2_Percent, "TP2");
      tp2Hit = true;

      if(Enable_Adaptive_Risk) AddTradeResult(true, rr, "TP2_HIT");
      Print("✅ TP2 COMPLET [", _Symbol, "]");
   }
   else if(rr >= TP3_RR && tp2Hit && !tp3Hit) {
      Print("🎯 TP3 déclenché [", _Symbol, "] - RR: ", DoubleToString(rr, 2));

      if(CheckPositionByTicket(ticket)) {
         double remainingVolume = PositionGetDouble(POSITION_VOLUME);

         MqlTradeRequest request;
         MqlTradeResult result;
         ZeroMemory(request);

         request.action = TRADE_ACTION_DEAL;
         request.symbol = _Symbol;
         request.volume = remainingVolume;
         request.type = (posType == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
         request.price = currentPrice;
         request.deviation = 10;
         request.position = ticket;
         request.comment = _Symbol + "_TP3_FINAL";
         request.magic = Magic_Number;

         if(OrderSend(request, result) && result.retcode == TRADE_RETCODE_DONE) {
            tp3Hit = true;

            if(Enable_Adaptive_Risk) AddTradeResult(true, rr, "TP3_COMPLETE");
            Print("✅ TP3 FINAL [", _Symbol, "] - Position fermée complètement");
         }
      }
   }
}

void ModifySL_3TP(ulong ticket, double newSL, string reason)
{
   if(!CheckPositionByTicket(ticket)) {
      Print("❌ Position ", ticket, " non trouvée pour modification SL");
      return;
   }

   double currentSL = PositionGetDouble(POSITION_SL);

   if(MathAbs(currentSL - newSL) < _Point) {
      if(Debug_Adaptive_Risk) Print("⚠️ SL déjà au niveau demandé: ", DoubleToString(newSL, _Digits));
      return;
   }

   MqlTradeRequest request;
   MqlTradeResult result;
   ZeroMemory(request);

   request.action = TRADE_ACTION_SLTP;
   request.symbol = _Symbol;
   request.sl = newSL;
   request.tp = PositionGetDouble(POSITION_TP);
   request.position = ticket;
   request.magic = Magic_Number;
   request.deviation = 3;

   if(OrderSend(request, result)) {
      if(result.retcode == TRADE_RETCODE_DONE) {
         Print("✅ SL modifié [", _Symbol, "] ", reason, ": ", DoubleToString(newSL, _Digits));
         stopLoss = newSL;
      } else {
         Print("❌ Échec modification SL [", _Symbol, "] - Code: ", result.retcode, " - ", result.comment);
      }
   } else {
      Print("❌ Erreur envoi ordre modification SL [", _Symbol, "]");
   }
}

void PartialClose_3TP(ulong ticket, int percent, string tpLevel)
{
   if(!CheckPositionByTicket(ticket)) {
      Print("❌ Position ", ticket, " non trouvée pour fermeture partielle");
      return;
   }

   double currentLot = PositionGetDouble(POSITION_VOLUME);
   double closeLot = NormalizeDouble(currentLot * percent / 100.0, 2);

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   closeLot = NormalizeDouble(MathRound(closeLot / stepLot) * stepLot, 2);

   if(closeLot < minLot) {
      Print("❌ Volume fermeture trop petit: ", closeLot, " < ", minLot);
      return;
   }

   if(closeLot >= currentLot) {
      closeLot = currentLot - minLot;
      if(closeLot < minLot) {
         Print("❌ Impossible fermeture partielle - Volume insuffisant");
         return;
      }
   }

   MqlTradeRequest request;
   MqlTradeResult result;
   ZeroMemory(request);

   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = closeLot;
   request.type = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ?
      ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   request.price = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ?
      SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   request.deviation = 10;
   request.position = ticket;
   request.comment = _Symbol + "_" + tpLevel;
   request.magic = Magic_Number;

   if(OrderSend(request, result)) {
      if(result.retcode == TRADE_RETCODE_DONE) {
         Print("✅ Fermeture partielle [", _Symbol, "] ", tpLevel, ": ", DoubleToString(closeLot, 2), " lots");
      } else {
         Print("❌ Échec fermeture partielle [", _Symbol, "] - Code: ", result.retcode, " - ", result.comment);
      }
   } else {
      Print("❌ Erreur envoi ordre fermeture partielle [", _Symbol, "]");
   }
}

//+------------------------------------------------------------------+
bool SelectMyPosition(string symbol)
{
   for(int i = 0; i < PositionsTotal(); i++) {
      if(PositionGetTicket(i) > 0) {
         if(PositionGetString(POSITION_SYMBOL) == symbol &&
            PositionGetInteger(POSITION_MAGIC) == Magic_Number) {
            return PositionSelectByTicket(PositionGetTicket(i));
         }
      }
   }
   return false;
}

bool CheckPositionByTicket(ulong ticket)
{
   for(int i = 0; i < PositionsTotal(); i++) {
      if(PositionGetTicket(i) == ticket) {
         return PositionSelectByTicket(ticket);
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| FONCTIONS TECHNIQUES                                            |
//+------------------------------------------------------------------+
void GetMainSMCSignals(bool &buySignal, bool &sellSignal)
{
   buySignal = false;
   sellSignal = false;

   if(!smcAvailable1 || smcHandle1 == INVALID_HANDLE) return;

   if(CopyBuffer(smcHandle1, 0, 0, 2, smc1_buy_buffer) > 0 &&
      CopyBuffer(smcHandle1, 1, 0, 2, smc1_sell_buffer) > 0) {
      buySignal = (smc1_buy_buffer[0] != EMPTY_VALUE && smc1_buy_buffer[0] > 0);
      sellSignal = (smc1_sell_buffer[0] != EMPTY_VALUE && smc1_sell_buffer[0] < 0);
   }
}

bool UpdateIndicators()
{
   if(CopyBuffer(ema1Handle, 0, 0, 3, ema1Array) <= 0) return false;
   if(CopyBuffer(ema2Handle, 0, 0, 3, ema2Array) <= 0) return false;
   if(CopyBuffer(atrHandle, 0, 0, 2, atrArray) <= 0) return false;

   ema1 = ema1Array[0];
   ema2 = ema2Array[0];
   atr = atrArray[0];

   return true;
}

bool GetEMABuySignal()
{
   if(ArraySize(ema1Array) < 2 || ArraySize(ema2Array) < 2) return false;

   double ema1_prev = ema1Array[1];
   double ema2_prev = ema2Array[1];

   bool gapValid = MathAbs(ema1 - ema2) / _Point > EMA_Gap_Threshold;
   return (ema1_prev <= ema2_prev) && (ema1 > ema2) && gapValid;
}

bool GetEMASellSignal()
{
   if(ArraySize(ema1Array) < 2 || ArraySize(ema2Array) < 2) return false;

   double ema1_prev = ema1Array[1];
   double ema2_prev = ema2Array[1];

   bool gapValid = MathAbs(ema1 - ema2) / _Point > EMA_Gap_Threshold;
   return (ema1_prev >= ema2_prev) && (ema1 < ema2) && gapValid;
}

bool GetTrendDirection(ENUM_TIMEFRAMES tf)
{
   int emaFastHandle = iMA(_Symbol, tf, EMA1_Period, 0, MODE_EMA, PRICE_CLOSE);
   int emaSlowHandle = iMA(_Symbol, tf, EMA2_Period, 0, MODE_EMA, PRICE_CLOSE);

   double emaFast[], emaSlow[];
   ArraySetAsSeries(emaFast, true);
   ArraySetAsSeries(emaSlow, true);

   bool result = true;

   if(CopyBuffer(emaFastHandle, 0, 0, 1, emaFast) > 0 &&
      CopyBuffer(emaSlowHandle, 0, 0, 1, emaSlow) > 0) {
      result = (emaFast[0] > emaSlow[0]);
   }

   IndicatorRelease(emaFastHandle);
   IndicatorRelease(emaSlowHandle);

   return result;
}

bool IsNewBar()
{
   static datetime lastBarTime = 0;
   datetime currentBarTime = iTime(_Symbol, _Period, 0);

   if(currentBarTime != lastBarTime) {
      lastBarTime = currentBarTime;
      return true;
   }
   return false;
}

double CalculateLotSizeWithRisk(double riskPercent)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * riskPercent / 100.0;
   double slDistance = atr * ATR_Mult_SL;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(slDistance <= 0 || tickValue <= 0 || tickSize <= 0) return 0.01;

   double lots = riskAmount / (slDistance / tickSize * tickValue);

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   return MathMax(minLot, MathMin(maxLot, MathRound(lots / stepLot) * stepLot));
}

double CalculateBuySL()
{
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   return NormalizeDouble(currentPrice - (atr * ATR_Mult_SL), _Digits);
}

double CalculateSellSL()
{
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   return NormalizeDouble(currentPrice + (atr * ATR_Mult_SL), _Digits);
}

double CalculateBuyTP(double rr)
{
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double slDistance = atr * ATR_Mult_SL;
   return NormalizeDouble(currentPrice + (slDistance * rr), _Digits);
}

double CalculateSellTP(double rr)
{
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double slDistance = atr * ATR_Mult_SL;
   return NormalizeDouble(currentPrice - (slDistance * rr), _Digits);
}
