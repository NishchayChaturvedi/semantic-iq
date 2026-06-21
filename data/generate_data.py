#!/usr/bin/env python3
"""
generate_data.py — SemanticIQ / Meridian synthetic data generator.
Jan 2022 – Dec 2024 | 150 accounts | ~40 active API keys at any time
Outputs 9 raw CSV files to the data/ directory.

Deliberate messiness (per design.md §3):
  - NULL parent_account_id on accounts {25, 33, 47, 62} that logically should have a parent
  - SCD2 v2 rows for accounts {5, 12, 23} have _loaded_at = valid_from + 2 days (backdated)
  - First 7 API keys are reassigned between accounts mid-period
  - 3 FX rate gaps: (GBP, 2022-08-29), (EUR, 2023-03-14), (GBP, 2024-01-02) — no spot rate
  - Ragged hierarchy depth 0–4 (uneven by design, not by accident)
"""

import random
from datetime import date, timedelta
from pathlib import Path

import numpy as np
import pandas as pd
from faker import Faker

Faker.seed(42)
random.seed(42)
np.random.seed(42)
fake = Faker()

# ── constants ─────────────────────────────────────────────────────────────────
START      = date(2022, 1, 1)
END        = date(2024, 12, 31)
OUT        = Path(__file__).parent
N_ACCOUNTS = 150
CURRENCIES = ["USD", "GBP", "EUR"]
SEGMENTS   = ["SMB", "Mid-Market", "Enterprise"]
INDUSTRIES = [
    "Technology", "Financial Services", "Healthcare",
    "Retail", "Manufacturing", "Media", "Education",
]
REGIONS = ["North America", "EMEA", "APAC", "LATAM"]

PRODUCTS_META = {
    "PROD-001": {"name": "SemanticIQ Core",     "type": "CORE",        "base_mrr": 500},
    "PROD-002": {"name": "Advanced Analytics",  "type": "ADD_ON",      "base_mrr": 200},
    "PROD-003": {"name": "Data Export API",     "type": "ADD_ON",      "base_mrr": 150},
    "PROD-004": {"name": "Professional Tier",   "type": "CORE",        "base_mrr": 1_200},
    "PROD-005": {"name": "Enterprise Suite",    "type": "CORE",        "base_mrr": 3_500},
    "PROD-006": {"name": "Custom Integrations", "type": "ADD_ON",      "base_mrr": 800},
    "PROD-007": {"name": "Marketplace Access",  "type": "MARKETPLACE", "base_mrr": 0},
}

# Messiness constants — named and documented
NULL_PARENT_IDS    = {25, 33, 47, 62}
BACKDATED_ACC_NUMS = {5, 12, 23}
N_REASSIGNED_KEYS  = 7
FX_GAPS            = {
    ("GBP", date(2022, 8, 29)),
    ("EUR", date(2023, 3, 14)),
    ("GBP", date(2024, 1,  2)),
}

# ── shared account metadata (used across all builders) ───────────────────────
ACCOUNT_IDS = [f"ACC-{i:04d}" for i in range(1, N_ACCOUNTS + 1)]

L0 = ACCOUNT_IDS[:20]        # root — no parent
L1 = ACCOUNT_IDS[20:80]      # 60 accounts
L2 = ACCOUNT_IDS[80:120]     # 40 accounts
L3 = ACCOUNT_IDS[120:140]    # 20 accounts
L4 = ACCOUNT_IDS[140:150]    # 10 accounts
_LEVEL_SETS = [set(L0), set(L1), set(L2), set(L3), set(L4)]

def _lvl(a: str) -> int:
    for n, s in enumerate(_LEVEL_SETS):
        if a in s:
            return n
    return 0

# Ragged hierarchy — deliberately uneven depth
_parent: dict[str, str | None] = {}
for a in L0:
    _parent[a] = None
for a in L1:
    num = int(a.split("-")[1])
    _parent[a] = None if num in NULL_PARENT_IDS else random.choice(L0)
for a in L2:
    _parent[a] = random.choice(L1)
for a in L3:
    _parent[a] = random.choice(L2)
for a in L4:
    _parent[a] = random.choice(L3)

# Currency assignment (60% USD, 25% GBP, 15% EUR; top-level skew to international)
def _pick_ccy(a: str) -> str:
    if _lvl(a) <= 1:
        return random.choices(CURRENCIES, weights=[0.50, 0.30, 0.20])[0]
    return random.choices(CURRENCIES, weights=[0.60, 0.25, 0.15])[0]

_ccy: dict[str, str] = {a: _pick_ccy(a) for a in ACCOUNT_IDS}

def _region(ccy: str) -> str:
    if ccy == "GBP":
        return "EMEA"
    if ccy == "EUR":
        return random.choice(["EMEA", "APAC"])
    return random.choice(["North America", "APAC", "LATAM"])

_region_map: dict[str, str] = {a: _region(_ccy[a]) for a in ACCOUNT_IDS}

# Account lifecycle (start_date, end_date or None if still active)
def _lifecycle(a: str) -> tuple[date, date | None]:
    r = random.random()
    if r < 0.80:
        return (START, None)
    if r < 0.90:
        return (START + timedelta(random.randint(30, 365)), None)
    offset = random.randint(365, (END - START).days - 90)
    return (START, START + timedelta(offset))

_life: dict[str, tuple[date, date | None]] = {a: _lifecycle(a) for a in ACCOUNT_IDS}

# Initial segment (heavier enterprise at root, heavier SMB at leaves)
def _init_seg(a: str) -> str:
    w = {0: [.10, .30, .60], 1: [.20, .50, .30],
         2: [.40, .40, .20], 3: [.60, .30, .10], 4: [.70, .20, .10]}
    return random.choices(SEGMENTS, weights=w[_lvl(a)])[0]

_seg0: dict[str, str] = {a: _init_seg(a) for a in ACCOUNT_IDS}

# Accounts that upgrade segment over time
_changers_v2 = set(random.sample(ACCOUNT_IDS, 30))
_changers_v3 = set(random.sample(list(_changers_v2), 10))

def _next_seg(s: str) -> str:
    return SEGMENTS[min(SEGMENTS.index(s) + 1, 2)]

# Pre-computed date sequences
def _all_months() -> list[date]:
    out, y, m = [], START.year, START.month
    while date(y, m, 1) <= END:
        out.append(date(y, m, 1))
        m += 1
        if m > 12:
            m, y = 1, y + 1
    return out

MONTHS    = _all_months()
ALL_DATES = [START + timedelta(i) for i in range((END - START).days + 1)]

# Company names (stable mapping so SCD2 versions share the same name)
_acc_names: dict[str, str] = {a: fake.company() for a in ACCOUNT_IDS}


# ── builders ──────────────────────────────────────────────────────────────────

def build_products() -> pd.DataFrame:
    rows = []
    for pid, meta in PRODUCTS_META.items():
        rows.append({
            "product_id":   pid,
            "product_name": meta["name"],
            "product_type": meta["type"],
            "base_mrr_usd": meta["base_mrr"],
            "is_active":    True,
            "created_at":   date(2021, 12, 1),
        })
    return pd.DataFrame(rows)


def build_accounts() -> pd.DataFrame:
    rows = []
    sk = 1

    def _row(sk, a, seg, valid_from, valid_to, backdated=False):
        offset = timedelta(2) if backdated else timedelta(0)
        return {
            "account_key":        sk,
            "account_id":         a,
            "account_name":       _acc_names[a],
            "segment":            seg,
            "industry":           random.choice(INDUSTRIES),
            "parent_account_id":  _parent[a],
            "contract_currency":  _ccy[a],
            "valid_from":         valid_from,
            "valid_to":           valid_to,
            "is_current":         valid_to is None,
            "_source_updated_at": valid_from,
            "_loaded_at":         valid_from + offset,
        }

    for a in ACCOUNT_IDS:
        acc_start, acc_end = _life[a]
        s0 = _seg0[a]
        acc_num = int(a.split("-")[1])
        bd = acc_num in BACKDATED_ACC_NUMS
        eff_end = acc_end or END

        if a in _changers_v3:
            s1, s2 = _next_seg(s0), _next_seg(_next_seg(s0))
            dur = (eff_end - acc_start).days
            if dur > 400:
                t1 = acc_start + timedelta(random.randint(150, max(151, dur // 3)))
                t2 = t1 + timedelta(random.randint(150, max(151, (eff_end - t1).days - 60)))
                if t2 >= eff_end:
                    t2 = eff_end - timedelta(30)
                rows.append(_row(sk, a, s0, acc_start, t1 - timedelta(1)));    sk += 1  # v1: no backdate
                rows.append(_row(sk, a, s1, t1, t2 - timedelta(1), bd));       sk += 1  # v2: backdate if flagged
                rows.append(_row(sk, a, s2, t2, acc_end));                     sk += 1  # v3: no backdate
            else:
                rows.append(_row(sk, a, s0, acc_start, acc_end, bd)); sk += 1

        elif a in _changers_v2:
            s1 = _next_seg(s0)
            dur = (eff_end - acc_start).days
            if dur > 180:
                t1 = acc_start + timedelta(random.randint(90, dur - 60))
                rows.append(_row(sk, a, s0, acc_start, t1 - timedelta(1)));    sk += 1  # v1: no backdate
                rows.append(_row(sk, a, s1, t1, acc_end, bd));                 sk += 1  # v2: backdate if flagged
            else:
                rows.append(_row(sk, a, s0, acc_start, acc_end, bd)); sk += 1

        else:
            rows.append(_row(sk, a, s0, acc_start, acc_end, bd)); sk += 1

    return pd.DataFrame(rows)


def build_account_ownership() -> pd.DataFrame:
    """SCD2 owner assignments per account — the RLS source of truth."""
    # 5 reps per region = 20 reps total
    rep_pool: list[tuple[str, str]] = [
        (fake.name(), r) for r in REGIONS for _ in range(5)
    ]

    rows = []
    oid = 1

    for a in ACCOUNT_IDS:
        acc_start, acc_end = _life[a]
        region = _region_map[a]
        region_reps = [(n, r) for n, r in rep_pool if r == region]
        rep_name = random.choice(region_reps)[0]

        if random.random() < 0.20:
            eff_end = acc_end or END
            dur = (eff_end - acc_start).days
            if dur > 200:
                mid = acc_start + timedelta(random.randint(90, dur - 90))
                rows.append({
                    "ownership_id": f"OWN-{oid:05d}", "account_id": a,
                    "owner_name": rep_name, "owner_type": "REP", "region": region,
                    "valid_from": acc_start, "valid_to": mid - timedelta(1),
                    "is_current": False,
                })
                oid += 1
                alt_reps = [n for n, r in region_reps if n != rep_name]
                new_rep = random.choice(alt_reps) if alt_reps else rep_name
                rows.append({
                    "ownership_id": f"OWN-{oid:05d}", "account_id": a,
                    "owner_name": new_rep, "owner_type": "REP", "region": region,
                    "valid_from": mid, "valid_to": acc_end,
                    "is_current": acc_end is None,
                })
                oid += 1
                continue

        rows.append({
            "ownership_id": f"OWN-{oid:05d}", "account_id": a,
            "owner_name": rep_name, "owner_type": "REP", "region": region,
            "valid_from": acc_start, "valid_to": acc_end,
            "is_current": acc_end is None,
        })
        oid += 1

    return pd.DataFrame(rows)


def build_api_keys() -> tuple[pd.DataFrame, dict]:
    """
    65 keys total (~40 active at any time).
    First N_REASSIGNED_KEYS keys are deliberately reassigned to a different account
    mid-period — stresses the conformance join in fact_usage_daily.
    Returns (df, assignment_map) where assignment_map is used by build_usage_daily.
    """
    eligible = [
        a for a in ACCOUNT_IDS
        if _life[a][0] <= END and (_life[a][1] is None or _life[a][1] > START)
    ]

    n_keys = 65
    key_ids   = [f"KEY-{i:05d}" for i in range(1, n_keys + 1)]
    key_hashes = [f"sha256_{fake.sha256()[:16]}" for _ in key_ids]

    rows = []
    assignment_map: dict[str, list] = {}

    for idx, (kid, khash) in enumerate(zip(key_ids, key_hashes)):
        acc = random.choice(eligible)
        acc_start, acc_end = _life[acc]
        key_start = max(acc_start, START + timedelta(random.randint(0, 180)))
        eff_end = acc_end or END

        if idx < N_REASSIGNED_KEYS:
            reassign_at = key_start + timedelta(random.randint(200, 600))
            if reassign_at < eff_end - timedelta(60):
                new_acc = random.choice([a for a in eligible if a != acc] or eligible)
                rows.append({
                    "api_key_id": kid, "api_key_hash": khash,
                    "account_id": acc, "assigned_at": key_start,
                    "revoked_at": reassign_at - timedelta(1),
                    "is_active": False, "_reassigned": True,
                })
                rows.append({
                    "api_key_id": kid, "api_key_hash": khash,
                    "account_id": new_acc, "assigned_at": reassign_at,
                    "revoked_at": None,
                    "is_active": True, "_reassigned": True,
                })
                assignment_map[kid] = [
                    (acc,     key_start,   reassign_at - timedelta(1)),
                    (new_acc, reassign_at, None),
                ]
                continue

        # Normal key — 30% chance of revocation before END
        max_offset = (eff_end - key_start).days - 30
        if random.random() < 0.30 and max_offset > 60:
            revoke = key_start + timedelta(random.randint(60, max_offset))
            rows.append({
                "api_key_id": kid, "api_key_hash": khash,
                "account_id": acc, "assigned_at": key_start,
                "revoked_at": revoke, "is_active": False, "_reassigned": False,
            })
            assignment_map[kid] = [(acc, key_start, revoke)]
        else:
            rows.append({
                "api_key_id": kid, "api_key_hash": khash,
                "account_id": acc, "assigned_at": key_start,
                "revoked_at": None, "is_active": True, "_reassigned": False,
            })
            assignment_map[kid] = [(acc, key_start, None)]

    return pd.DataFrame(rows), assignment_map


def build_account_products() -> pd.DataFrame:
    """Many-to-many bridge: which accounts subscribe to which products."""
    rows = []
    bid = 1

    for a in ACCOUNT_IDS:
        acc_start, acc_end = _life[a]
        seg = _seg0[a]

        if seg == "Enterprise":
            core = random.choices(["PROD-004", "PROD-005"], weights=[0.30, 0.70])[0]
        elif seg == "Mid-Market":
            core = random.choices(["PROD-001", "PROD-004"], weights=[0.40, 0.60])[0]
        else:
            core = "PROD-001"

        prods = [core]

        # Add-on probability by segment
        addon_probs = {
            "Enterprise":  {"PROD-002": 0.80, "PROD-003": 0.60, "PROD-006": 0.70, "PROD-007": 0.35},
            "Mid-Market":  {"PROD-002": 0.50, "PROD-003": 0.30, "PROD-006": 0.20, "PROD-007": 0.10},
            "SMB":         {"PROD-002": 0.25, "PROD-003": 0.15},
        }
        for pid, prob in addon_probs.get(seg, {}).items():
            if random.random() < prob:
                prods.append(pid)

        is_bundled = len(prods) > 2
        for pid in prods:
            discount = random.choice([0.00, 0.00, 0.00, 0.05, 0.10, 0.15, 0.20])
            rows.append({
                "bridge_id":    f"BRG-{bid:05d}",
                "account_id":   a,
                "product_id":   pid,
                "start_date":   acc_start,
                "end_date":     acc_end,
                "discount_pct": round(discount, 2),
                "is_bundled":   is_bundled and pid != core,
                "created_at":   acc_start,
            })
            bid += 1

    return pd.DataFrame(rows)


def build_fx_rates() -> pd.DataFrame:
    """
    Daily spot rates + quarterly contract rates for GBP→USD and EUR→USD.
    Three spot-rate gaps are deliberately omitted (FX_GAPS) to force fallback logic.
    """
    rows = []
    rid = 1

    gbp = 1.355
    eur = 1.130

    # Spot rates — daily random walk
    for d in ALL_DATES:
        gbp = float(np.clip(gbp + np.random.normal(0, 0.003), 1.15, 1.45))
        eur = float(np.clip(eur + np.random.normal(0, 0.002), 1.00, 1.25))
        for ccy, rate in [("GBP", gbp), ("EUR", eur)]:
            if (ccy, d) in FX_GAPS:
                continue  # deliberate gap
            rows.append({
                "rate_id":       f"FX-{rid:06d}",
                "rate_date":     d,
                "from_currency": ccy,
                "to_currency":   "USD",
                "rate_type":     "SPOT",
                "rate":          round(rate, 6),
                "created_at":    d,
            })
            rid += 1

    # Contract rates — fixed per quarter, slightly different from spot
    for yr in [2022, 2023, 2024]:
        for q_month in [1, 4, 7, 10]:
            q_start = date(yr, q_month, 1)
            next_q_month = q_month + 3
            next_q_year  = yr + (1 if next_q_month > 12 else 0)
            if next_q_month > 12:
                next_q_month -= 12
            q_end = min(date(next_q_year, next_q_month, 1) - timedelta(1), END)

            gbp_contract = round(random.uniform(1.20, 1.40), 4)
            eur_contract = round(random.uniform(1.05, 1.20), 4)

            for d in ALL_DATES:
                if not (q_start <= d <= q_end):
                    continue
                for ccy, rate in [("GBP", gbp_contract), ("EUR", eur_contract)]:
                    rows.append({
                        "rate_id":       f"FX-{rid:06d}",
                        "rate_date":     d,
                        "from_currency": ccy,
                        "to_currency":   "USD",
                        "rate_type":     "CONTRACT",
                        "rate":          rate,
                        "created_at":    q_start,
                    })
                    rid += 1

    return pd.DataFrame(rows)


def build_subscriptions(bridge_df: pd.DataFrame) -> pd.DataFrame:
    """
    One row per account × product × billing month.
    MRR stored in the account's contract_currency.
    MARKETPLACE product (PROD-007) is billed via usage, not here.
    """
    # Rough USD→local conversion factors (contract-rate approximation for generation)
    _ccr = {"USD": 1.00, "GBP": 0.79, "EUR": 0.92}

    rows = []
    sid = 1

    for _, brg in bridge_df.iterrows():
        a   = brg["account_id"]
        pid = brg["product_id"]
        if PRODUCTS_META[pid]["type"] == "MARKETPLACE":
            continue  # billed via usage

        ccy      = _ccy[a]
        base_usd = PRODUCTS_META[pid]["base_mrr"]
        discount = float(brg["discount_pct"])
        price_usd   = base_usd * (1 - discount) * random.uniform(0.85, 1.15)
        price_local = round(price_usd / _ccr[ccy], 2)

        sub_start = brg["start_date"] if pd.notna(brg["start_date"]) else START
        sub_end   = brg["end_date"]   if pd.notna(brg["end_date"])   else None
        billing_type = "ANNUAL" if _lvl(a) <= 1 and random.random() < 0.40 else "MONTHLY"

        for i, month in enumerate(MONTHS):
            if month < sub_start:
                continue
            if sub_end is not None and month > sub_end:
                break
            # Small growth drift over the 3-year period
            drift = 1 + (i / len(MONTHS)) * random.uniform(-0.05, 0.15)
            rows.append({
                "subscription_id": f"SUB-{sid:06d}",
                "account_id":      a,
                "product_id":      pid,
                "billing_month":   month,
                "mrr_amount":      round(price_local * drift, 2),
                "currency":        ccy,
                "billing_type":    billing_type,
                "status":          "ACTIVE",
                "created_at":      sub_start,
            })
            sid += 1

    return pd.DataFrame(rows)


def build_usage_daily(assignment_map: dict) -> pd.DataFrame:
    """
    Daily API consumption per key assignment period.
    Reassigned-key usage is correctly attributed to whichever account held
    the key on each date — the dbt conformance join stress-test.
    """
    rows = []
    uid = 1

    for kid, assignments in assignment_map.items():
        for acc, a_start, a_end in assignments:
            period_end = a_end if a_end is not None else END
            for d in ALL_DATES:
                if not (a_start <= d <= period_end):
                    continue
                if random.random() > 0.85:
                    continue  # ~15% idle days

                units    = round(float(np.random.lognormal(mean=3.5, sigma=1.2)), 2)
                unit_rate = round(random.uniform(0.001, 0.005), 5)
                rows.append({
                    "usage_id":       f"USG-{uid:07d}",
                    "api_key_id":     kid,
                    "account_id":     acc,
                    "usage_date":     d,
                    "units_consumed": units,
                    "unit_rate":      unit_rate,
                    "currency":       _ccy[acc],
                    "created_at":     d,
                })
                uid += 1

    return pd.DataFrame(rows)


def build_services_milestones() -> pd.DataFrame:
    """
    Irregular milestone-based professional services revenue.
    Only Enterprise and Mid-Market accounts; ~40% of eligible accounts have services.
    """
    milestone_names = [
        "Discovery & Requirements",
        "Architecture Design",
        "Implementation Phase 1",
        "Implementation Phase 2",
        "UAT & Validation",
        "Go-Live",
        "Post-Launch Optimization",
    ]
    project_names = [
        "Analytics Platform Migration",
        "Data Warehouse Consolidation",
        "Semantic Layer Implementation",
        "Executive Dashboard Suite",
        "Regulatory Reporting Automation",
        "Self-Service BI Rollout",
    ]

    rows = []
    mid_counter = 1
    eligible = [
        a for a in ACCOUNT_IDS
        if _seg0[a] in ("Enterprise", "Mid-Market")
        and (_life[a][1] is None or _life[a][1] > START + timedelta(180))
    ]

    for a in eligible:
        if random.random() > 0.40:
            continue

        acc_start, acc_end = _life[a]
        eff_end = acc_end or END
        proj_name = random.choice(project_names)
        proj_start = acc_start + timedelta(random.randint(30, 180))
        proj_dur   = random.randint(90, 540)
        n_ms       = random.randint(2, 5)
        milestones = random.sample(milestone_names, n_ms)

        for i, ms_name in enumerate(milestones):
            ms_date = proj_start + timedelta(int(proj_dur * (i + 1) / (n_ms + 1)))
            if ms_date > eff_end:
                break
            rows.append({
                "milestone_id":   f"MS-{mid_counter:05d}",
                "account_id":     a,
                "project_name":   proj_name,
                "milestone_name": ms_name,
                "completed_date": ms_date,
                "revenue_amount": round(random.uniform(5_000, 75_000), 2),
                "currency":       _ccy[a],
                "created_at":     ms_date,
            })
            mid_counter += 1

    return pd.DataFrame(rows)


# ── main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    print("Generating SemanticIQ / Meridian synthetic data …")
    print(f"  Period: {START} → {END}  |  {N_ACCOUNTS} accounts\n")

    products_df   = build_products()
    accounts_df   = build_accounts()
    ownership_df  = build_account_ownership()
    key_df, amap  = build_api_keys()
    bridge_df     = build_account_products()
    fx_df         = build_fx_rates()
    subs_df       = build_subscriptions(bridge_df)
    usage_df      = build_usage_daily(amap)
    milestone_df  = build_services_milestones()

    datasets = {
        "raw_products":            products_df,
        "raw_accounts":            accounts_df,
        "raw_account_ownership":   ownership_df,
        "raw_api_keys":            key_df,
        "raw_account_products":    bridge_df,
        "raw_fx_rates":            fx_df,
        "raw_subscriptions":       subs_df,
        "raw_usage_daily":         usage_df,
        "raw_services_milestones": milestone_df,
    }

    for name, df in datasets.items():
        path = OUT / f"{name}.csv"
        df.to_csv(path, index=False)
        print(f"  {name:<28}  {len(df):>7,} rows  →  {path.name}")

    print("\nDone. Validate output, then run load_to_snowflake.py.")


if __name__ == "__main__":
    main()
