#!/usr/bin/env python3
"""Sample-size calculation for the Stage 5 pre-registration.

    python experiments/scripts/power_analysis.py

Reads the per-trial gate margins that make_figures.py writes
(docs/figures/measured/stage2_gate_margins.csv), so the inputs are the
measured Stage 2 results and nothing typed in by hand.

Test assumed (as pre-registered): one-sample one-sided t-test on per-trial
relative margins, alpha 0.025. Power from the noncentral t distribution.

Why size on an UPPER bound of the SD rather than the estimate: three trials
give an SD with two degrees of freedom, whose 95% interval spans more than a
factor of four. Sizing on the point estimate would plan an experiment that is
underpowered in most plausible worlds.
"""
import csv
import math
import os
import statistics as st

from scipy import stats

HERE = os.path.dirname(os.path.abspath(__file__))
CSV = os.path.join(HERE, "..", "..", "docs", "figures", "measured",
                   "stage2_gate_margins.csv")
ALPHA = 0.025
POWER = 0.90


def power(n, mu, sigma, alpha=ALPHA):
    df = n - 1
    tc = stats.t.ppf(1 - alpha, df)
    return 1 - stats.nct.cdf(tc, df, mu / (sigma / math.sqrt(n)))


def n_for(mu, sigma, target=POWER, alpha=ALPHA):
    for n in range(3, 1000):
        if power(n, mu, sigma, alpha) >= target:
            return n
    return None


def main():
    rows = list(csv.DictReader(open(CSV, encoding="utf-8")))
    m = [float(r["margin_pct"]) for r in rows
         if r["policy"] == "energy_consolidate" and r["trial"].startswith("stage2het")]
    s, n0 = st.stdev(m), len(m)
    print("Measured: energy_consolidate vs slo_packing, %d trials" % n0)
    print("  margins %s  mean %+.3f%%  sd %.3f" % (
        ", ".join("%+.3f" % x for x in m), st.mean(m), s))
    print("\nUpper confidence bounds on the SD (chi-square, df=%d):" % (n0 - 1))
    bounds = {}
    for conf in (0.80, 0.90, 0.95):
        bounds[conf] = s * math.sqrt((n0 - 1) / stats.chi2.ppf(1 - conf, n0 - 1))
        print("  %.0f%%: %.3f" % (conf * 100, bounds[conf]))

    mus = (0.5, 0.75, 1.0, 1.4)
    sigmas = (round(s, 2), 0.80, 1.00, round(bounds[0.80], 2), 1.50,
              round(bounds[0.90], 2))
    print("\nTrials needed for power %.2f, one-sided alpha %.3f:" % (POWER, ALPHA))
    print("  %-7s" % "sd" + "".join("%11s" % ("mu=%.2f%%" % u) for u in mus))
    for sg in sigmas:
        print("  %-7.2f" % sg + "".join("%11s" % n_for(u, sg) for u in mus))

    mu_d, sg_d = 1.0, bounds[0.80]
    n_d = n_for(mu_d, sg_d)
    print("\nDESIGN: true margin %.1f%%, SD at its 80%% upper bound %.2f -> n = %d"
          % (mu_d, sg_d, n_d))
    print("Power of that design if the SD is instead:")
    for sg in (s, 0.8, 1.0, sg_d, 1.5, bounds[0.90]):
        print("  sd %.2f -> power %.2f" % (sg, power(n_d, mu_d, sg)))
    print("\nH2 (exact binomial, one-sided vs 0.5): smallest n where all-n "
          "reversals reach p <= %.3f:" % ALPHA)
    for n in range(3, 10):
        p = 0.5 ** n
        print("  n=%d  p(all reversed)=%.4f%s" % (n, p, "   <- minimum" if p <= ALPHA and 0.5 ** (n - 1) > ALPHA else ""))


if __name__ == "__main__":
    main()
