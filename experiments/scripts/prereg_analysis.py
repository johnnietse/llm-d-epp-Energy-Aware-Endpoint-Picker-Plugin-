#!/usr/bin/env python3
"""Confirmatory analysis for the Stage 5 pre-registration.

    python experiments/scripts/prereg_analysis.py \
        --het <trial_dir> [<trial_dir> ...] --homog <trial_dir> [<trial_dir> ...]

This file IS the pre-registered analysis (docs/plan/PREREGISTRATION-STAGE5.md).
Once the pre-registration is frozen by tag, changing anything here that can
alter a verdict is a protocol deviation and must be reported as one.

It reuses stage2_analyse.py's own functions (load, best_feasible) so the
operating-point definition cannot drift from the gate that motivated Stage 5.

Hypotheses (numbers match the pre-registration):
  H1  primary   mixed fleet: energy_consolidate beats slo_packing on SLO-goodput
                per joule at each policy's best feasible point. One-sample
                one-sided t-test on per-trial relative margins, alpha 0.025.
  H2  secondary homogeneous fleet: energy_consolidate does NOT beat round_robin.
                Per trial a "reversal" is consolidate infeasible, or its best
                feasible SLO-goodput per joule below round_robin's. One-sided
                exact binomial test against 0.5.
  H3  secondary mixed fleet: the activation term helps - energy_consolidate
                beats energy_greedy. One-sided t-test on per-trial margins.
  H2 and H3 form one family, Holm-corrected at alpha 0.025.
  H4 (Amendment 1)  mixed fleet: energy_consolidate beats llmd_latency_least,
                llm-d's own SLO packing. Tested like H3; joins the Holm family
                when that arm is present in the data.

Pre-registered decision rules implemented here:
  * A cell is invalid if it is client-limited, has more than 2% ungrounded
    router picks, or lacks an energy measurement. A trial with an invalid cell
    in any policy the hypothesis compares is excluded from that hypothesis.
  * If the baseline has no feasible point in a trial, the comparison is
    undefined and the trial is excluded (it cannot count for or against).
  * If the tested policy has no feasible point while the baseline does, its
    margin is recorded as -100%: it delivered no feasible SLO-goodput. This is
    the conservative choice against H1 and H3.
"""
import argparse
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import stage2_analyse as gate  # noqa: E402

ALPHA = 0.025                 # one-sided; equivalent to two-sided 0.05
UNGROUNDED_MAX = 0.02         # same tolerance as stage2_analyse.py
INFEASIBLE_MARGIN = -100.0


def cell_invalid(r):
    if r.get("client_limited"):
        return "client-limited"
    if (r.get("router_ungrounded_frac") or 0.0) > UNGROUNDED_MAX:
        return "ungrounded %.1f%%" % (100 * r["router_ungrounded_frac"])
    if r.get("goodput_per_joule") is None:
        return "no energy"
    return None


def trial_margin(run_dir, test, base):
    """Relative margin of `test` over `base` (percent), or (None, reason)."""
    rows = gate.load(run_dir)
    if not rows:
        return None, "no records"
    for r in rows:
        if r["policy"] in (test, base):
            why = cell_invalid(r)
            if why:
                return None, "invalid cell %s@%s: %s" % (
                    r["policy"], r["offered_rate_rps"], why)
    best = gate.best_feasible(rows)
    if base not in best or not best[base].get("goodput_per_joule"):
        return None, "baseline %s has no feasible point" % base
    b = best[base]["goodput_per_joule"]
    if test not in best:
        return INFEASIBLE_MARGIN, "%s infeasible" % test
    return (best[test]["goodput_per_joule"] - b) / b * 100.0, ""


def one_sided_t(xs):
    """Mean, sd, t, one-sided p (H1: mean > 0), and two-sided 95% CI."""
    from scipy import stats
    n = len(xs)
    m = sum(xs) / n
    sd = math.sqrt(sum((x - m) ** 2 for x in xs) / (n - 1))
    se = sd / math.sqrt(n)
    t = m / se if se > 0 else math.inf
    p = 1 - stats.t.cdf(t, n - 1)
    half = stats.t.ppf(0.975, n - 1) * se
    return m, sd, t, p, (m - half, m + half)


def binom_one_sided(k, n):
    from scipy import stats
    return 1 - stats.binom.cdf(k - 1, n, 0.5)


def holm(ps, alpha):
    """Holm step-down. ps: dict name -> p. Returns dict name -> rejected."""
    order = sorted(ps, key=ps.get)
    out, m = {}, len(order)
    still = True
    for i, name in enumerate(order):
        still = still and ps[name] <= alpha / (m - i)
        out[name] = still
    return out


def run_margins(dirs, test, base, label):
    vals = []
    print("\n%s: %s vs %s" % (label, test, base))
    for d in dirs:
        v, why = trial_margin(d, test, base)
        tag = os.path.basename(d.rstrip("/\\"))
        if v is None:
            print("  %-26s EXCLUDED  %s" % (tag, why))
        else:
            vals.append(v)
            print("  %-26s %+8.3f%%  %s" % (tag, v, why))
    return vals


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--het", nargs="*", default=[], help="mixed-fleet trial dirs")
    ap.add_argument("--homog", nargs="*", default=[], help="homogeneous trial dirs")
    ap.add_argument("--pilot", action="store_true",
                    help="label output as a pilot run on pre-registration data")
    a = ap.parse_args()

    if a.pilot:
        print("=" * 72)
        print("PILOT RUN ON STAGE 2 DATA. Not confirmatory: these trials informed")
        print("the hypotheses and the sample size, so they cannot also test them.")
        print("=" * 72)

    verdicts = {}

    # ------------------------------------------------------------- H1 primary
    h1 = run_margins(a.het, "energy_consolidate", "slo_packing", "H1 (primary)")
    if len(h1) >= 2:
        m, sd, t, p, ci = one_sided_t(h1)
        ok = p <= ALPHA
        verdicts["H1"] = ok
        print("  n=%d  mean %+.3f%%  sd %.3f  95%% CI [%+.3f, %+.3f]  t=%.2f  "
              "one-sided p=%.4g  ->  %s" % (len(h1), m, sd, ci[0], ci[1], t, p,
                                             "SUPPORTED" if ok else "NOT SUPPORTED"))
    else:
        print("  fewer than 2 valid trials: H1 cannot be tested")

    # ---------------------------------------------------- H2, H3 secondary
    ps = {}
    h3 = run_margins(a.het, "energy_consolidate", "energy_greedy", "H3 (secondary)")
    if len(h3) >= 2:
        m, sd, t, p, ci = one_sided_t(h3)
        ps["H3"] = p
        print("  n=%d  mean %+.3f%%  sd %.3f  95%% CI [%+.3f, %+.3f]  t=%.2f  "
              "one-sided p=%.4g" % (len(h3), m, sd, ci[0], ci[1], t, p))

    # H4 (Amendment 1, A3/A4): against llm-d's own SLO packing. It joins the
    # family exactly when the arm exists in the data; the amendment drops the
    # arm before trial 1 if it cannot run, so presence is decided in advance,
    # not by looking at results.
    if any(r["policy"] == "llmd_latency_least"
           for d in a.het for r in gate.load(d)):
        h4 = run_margins(a.het, "energy_consolidate", "llmd_latency_least",
                         "H4 (secondary)")
        if len(h4) >= 2:
            m, sd, t, p, ci = one_sided_t(h4)
            ps["H4"] = p
            print("  n=%d  mean %+.3f%%  sd %.3f  95%% CI [%+.3f, %+.3f]  t=%.2f  "
                  "one-sided p=%.4g" % (len(h4), m, sd, ci[0], ci[1], t, p))

    print("\nH2 (secondary): reversal on the homogeneous fleet")
    k = n = 0
    for d in a.homog:
        tag = os.path.basename(d.rstrip("/\\"))
        rows = gate.load(d)
        bad = [cell_invalid(r) for r in rows
               if r["policy"] in ("energy_consolidate", "round_robin")]
        if not rows or any(bad):
            print("  %-26s EXCLUDED  %s" % (tag, next((b for b in bad if b), "no records")))
            continue
        best = gate.best_feasible(rows)
        if "round_robin" not in best:
            print("  %-26s EXCLUDED  round_robin has no feasible point" % tag)
            continue
        rr = best["round_robin"]["goodput_per_joule"]
        if "energy_consolidate" not in best:
            rev, note = True, "consolidate infeasible"
        else:
            c = best["energy_consolidate"]["goodput_per_joule"]
            rev, note = c < rr, "consolidate %.4f vs round_robin %.4f" % (c, rr)
        n += 1
        k += rev
        print("  %-26s %s  %s" % (tag, "reversal" if rev else "NO reversal", note))
    if n:
        ps["H2"] = binom_one_sided(k, n)
        print("  %d of %d trials reversed  one-sided binomial p=%.4g" % (k, n, ps["H2"]))

    if ps:
        rej = holm(ps, ALPHA)
        print("\nSecondary family, Holm at alpha %.3f:" % ALPHA)
        for name in sorted(ps):
            verdicts[name] = rej[name]
            print("  %s  p=%.4g  ->  %s" % (name, ps[name],
                                           "SUPPORTED" if rej[name] else "NOT SUPPORTED"))

    print("\nVERDICTS: " + ", ".join("%s=%s" % (k2, "supported" if v else "not supported")
                                    for k2, v in sorted(verdicts.items())))
    return 0


if __name__ == "__main__":
    sys.exit(main())
