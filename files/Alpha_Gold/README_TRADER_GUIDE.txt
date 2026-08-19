# LPH Extension Probability Map — Trader Guide (v1.20)

Tool: LPH_ExtensionProbabilityMap_EA (MT4: .ex4 / .mq4 | MT5: .ex5 / .mq5)
Platform: MetaTrader 4 & MetaTrader 5
Asset: XAUUSD (Gold) — Multi-Bar Lookback + Historical Volume Engine

1. New Multi-Bar Context Modes:
- EVAL_AUTO_SWITCH (Default): Evaluates yesterday's closed breakout candle early in session, then automatically transitions to today's forming candle once intraday move expands.
- EVAL_PREVIOUS_D1: Evaluates yesterday's completed D1 bar (Shift 1) to predict today's follow-through extension.
- EVAL_TODAY_FORMING: Evaluates today's active forming D1 bar (Shift 0).

2. Historical Volume Expansion Prediction:
- Volume Pace Ratio: Compares volume to the 20-day D1 moving average.
- High Volume Surge (>= 1.25x): Statistically boosts continuation probability (+10% to +20% higher P(+1.0A)).
- Low Volume Warning (< 0.85x): Identifies exhaustion / low-participation moves with higher fade & retrace risk.

3. Quick Verdicts:
- GREEN (Follow Up - Strong): P(+1.0A/3d) >= 65% + High Volume confirmed.
- YELLOW (Follow Up - Moderate): P(+1.0A/3d) 45-65%. Normal sizing.
- RED (Weak / Expect Fade): P(+1.0A/3d) < 45% or Low Volume divergence.
- ORANGE (EXTENDED): Intraday move already >= 1.5 ATR. Exhaustion risk — zero top/bottom FOMO entries.