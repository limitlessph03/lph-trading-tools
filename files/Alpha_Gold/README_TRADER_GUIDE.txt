# LPH Extension Probability Map — Trader Guide (v1.10)

Tool: LPH_ExtensionProbabilityMap_EA (MT5: .ex5 / MT4: .mq4 / .ex4)
Platform: MetaTrader 4 & MetaTrader 5
Asset: XAUUSD (Gold) — D1 statistics on any timeframe

1. Setup:
- MT5: Place LPH_ExtensionProbabilityMap_EA.ex5 into MQL5\Experts\Alpha Gold\ and attach to XAUUSD.
- MT4: Place LPH_ExtensionProbabilityMap_EA.ex4 into MQL4\Experts\ and attach to XAUUSD.

2. Quick Verdict Rules:
- GREEN (Follow Up - Strong): P(+1.0A/3d) >= 65%. Follow momentum.
- YELLOW (Follow Up - Moderate): P(+1.0A/3d) 45-65%. Smaller size, tighter TP.
- RED (Weak / Expect Fade): P(+1.0A/3d) < 45%. Do not chase, expect pullback.
- ORANGE (EXTENDED): Move already ran >= 1.5 ATR. High risk of exhaustion. No new entries!