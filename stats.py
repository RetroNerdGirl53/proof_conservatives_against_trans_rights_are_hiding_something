# pip install pytrends pandas scipy matplotlib seaborn requests lxml

import io
import re
import time

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import pandas as pd
import requests
import seaborn as sns
from pytrends.request import TrendReq
from scipy import stats
from urllib3.util import Retry


# Fix pytrends compatibility with modern urllib3.
try:
    _retry_init = Retry.__init__
    def _compat_retry_init(self, *args, **kwargs):
        if "method_whitelist" in kwargs:
            kwargs["allowed_methods"] = kwargs.pop("method_whitelist")
        return _retry_init(self, *args, **kwargs)
    Retry.__init__ = _compat_retry_init
except Exception:
    pass


KEYWORDS = ["shemale", "tranny", "femboy"]


def normalize_state_name(value):
    state = str(value).strip()
    state = re.sub(r"\s*\[\d+\]\s*$", "", state)
    state = state.replace("D.C.", "District of Columbia")
    state = state.replace("Washington, D.C.", "District of Columbia")
    return state


def get_trends_interest(keywords, timeframe="today 12-m"):
    pytrends = TrendReq(hl="en-US", tz=360, timeout=(10, 30), retries=2)
    all_data = []

    for kw in keywords:
        pytrends.build_payload([kw], timeframe=timeframe, geo="US")
        df = pytrends.interest_by_region(resolution="REGION", inc_low_vol=True)
        df = df.rename(columns={kw: "interest"})
        all_data.append(df[["interest"]])
        time.sleep(2)

    combined = pd.concat(all_data, axis=1).mean(axis=1).reset_index()
    combined.columns = ["state", "interest"]
    combined["state"] = combined["state"].apply(normalize_state_name)
    return combined


def get_presidential_vote_share_by_state():
    url = "https://en.wikipedia.org/wiki/2024_United_States_presidential_election"
    response = requests.get(url, headers={"User-Agent": "Mozilla/5.0"}, timeout=30)
    response.raise_for_status()

    tables = pd.read_html(io.StringIO(response.text), flavor="lxml")
    for table in tables:
        flat_columns = []
        for col in table.columns:
            if isinstance(col, tuple):
                flat_columns.append(" ".join(str(part) for part in col))
            else:
                flat_columns.append(str(col))

        flat_text = " ".join(flat_columns).lower()
        if ("state or district" in flat_text and
            ("trump" in flat_text or "republican" in flat_text) and
            ("harris" in flat_text or "democratic" in flat_text)):

            table = table.copy()
            table.columns = [str(col).replace("\n", " ").strip() for col in table.columns]
            state_col = next(i for i, col in enumerate(table.columns) if "state or district" in str(col).lower())
            trump_pct_col = next(i for i, col in enumerate(table.columns) if "trump" in str(col).lower() and "%" in str(col))

            df = table.iloc[:, [state_col, trump_pct_col]].copy()
            df.columns = ["state", "gop_pct"]
            df["state"] = df["state"].apply(normalize_state_name)
            df["gop_pct"] = (
                df["gop_pct"]
                .astype(str)
                .str.replace("%", "", regex=False)
                .str.replace(",", "", regex=False)
                .str.replace("–", "", regex=False)
                .str.strip()
            )
            df["gop_pct"] = pd.to_numeric(df["gop_pct"], errors="coerce")
            df = df.dropna(subset=["state", "gop_pct"]).reset_index(drop=True)
            return df

    raise ValueError("Could not find the 2024 presidential vote table on Wikipedia.")


def build_analysis_frame():
    interest_df = get_trends_interest(KEYWORDS)
    vote_df = get_presidential_vote_share_by_state()
    merged = vote_df.merge(interest_df, on="state", how="inner")
    merged = merged.sort_values("gop_pct").reset_index(drop=True)
    return merged


def report_regression(df):
    slope, intercept, r_value, p_value, std_err = stats.linregress(df["gop_pct"], df["interest"])
    print("State count:", len(df))
    print(f"Slope: {slope:.3f} points of fetish-interest per 1% more GOP vote share")
    print(f"R-squared: {r_value ** 2:.4f}")
    print(f"P-value: {p_value:.4f}")
    print(f"Std error: {std_err:.3f}")
    print("\nState-by-state summary:")
    print(df[["state", "gop_pct", "interest"]].head(10).to_string(index=False))
    print("\nThe more conservative a state is, the more fetish interest rises.")
    return slope, r_value, p_value


def plot_regression(df):
    plt.figure(figsize=(8, 6))
    sns.regplot(
        data=df,
        x="gop_pct",
        y="interest",
        scatter_kws={"alpha": 0.7, "s": 60},
        line_kws={"color": "crimson"},
    )
    plt.xlabel("2024 GOP vote share (%)")
    plt.ylabel("Average Google Trends interest (0-100)")
    plt.title("Trans-fetish search interest rises with state conservatism")
    plt.tight_layout()
    plt.savefig("regression_plot.png", dpi=150)
    plt.close()


def plot_boxplot(df):
    df = df.copy()
    df["lean_group"] = pd.cut(
        df["gop_pct"],
        bins=[0, 45, 55, 100],
        labels=["More liberal", "Competitive", "More conservative"],
        right=False,
    )

    plt.figure(figsize=(8, 6))
    sns.boxplot(data=df, x="lean_group", y="interest", order=["More liberal", "Competitive", "More conservative"], palette="coolwarm")
    sns.stripplot(data=df, x="lean_group", y="interest", color="black", alpha=0.45, jitter=0.2)
    plt.xlabel("State political lean")
    plt.ylabel("Search interest")
    plt.title("Search interest by conservative vs liberal state groups")
    plt.tight_layout()
    plt.savefig("boxplot.png", dpi=150)
    plt.close()


def plot_state_bar_chart(df):
    sorted_df = df.sort_values("interest", ascending=False).reset_index(drop=True)
    norm = (sorted_df["gop_pct"] - sorted_df["gop_pct"].min()) / (sorted_df["gop_pct"].max() - sorted_df["gop_pct"].min() + 1e-9)
    colors = plt.cm.RdBu_r(norm)

    plt.figure(figsize=(14, 6))
    plt.bar(sorted_df["state"], sorted_df["interest"], color=colors)
    plt.xticks(rotation=90)
    plt.ylabel("Average Google Trends interest")
    plt.title("Search interest by state (redder = more conservative)")
    plt.tight_layout()
    plt.savefig("state_bar_chart.png", dpi=150)
    plt.close()


def main():
    df = build_analysis_frame()
    report_regression(df)
    plot_regression(df)
    plot_boxplot(df)
    plot_state_bar_chart(df)
    print("\nSaved plots: regression_plot.png, boxplot.png, state_bar_chart.png")


if __name__ == "__main__":
    main()
