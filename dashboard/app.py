"""
PayOps breakage dashboard — built on the `student_breakage_daily` mart.

Reads directly from the same Neon Postgres database the dbt project writes
to. No data pipeline lives in this app; it's a pure read/visualization layer.
"""

import pandas as pd
import plotly.graph_objects as go
import streamlit as st

MART = "sandbox.student_breakage_daily"

# Fixed identity colors — kept consistent across every chart in the app,
# per "color follows the entity, never its rank."
COLOR_PREDICTED = "#2a78d6"  # categorical slot 1 (blue)
COLOR_ACTUAL = "#008300"  # categorical slot 6 (green)
COLOR_BAR = "#2a78d6"
COLOR_GRIDLINE = "#e1e0d9"
COLOR_MUTED = "#898781"
COLOR_TEXT_SECONDARY = "#52514e"

st.set_page_config(page_title="Preply breakage dashboard", layout="wide")


@st.cache_resource
def get_connection():
    return st.connection("postgres", type="sql")


@st.cache_data(ttl=3600)
def get_as_of_date() -> pd.Timestamp:
    """The dataset's fixed point-in-time 'today' — not the real-world date."""
    conn = get_connection()
    df = conn.query(f"select max(date_day) as as_of_date from {MART}", ttl=3600)
    return pd.Timestamp(df["as_of_date"].iloc[0])


@st.cache_data(ttl=3600)
def get_filter_options() -> dict:
    conn = get_connection()
    df = conn.query(
        f"""
        select distinct
            country_code,
            persona,
            acquisition_channel,
            hours_purchased
        from {MART}
        """,
        ttl=3600,
    )
    return {
        "countries": sorted(df["country_code"].dropna().unique().tolist()),
        "personas": sorted(df["persona"].dropna().unique().tolist()),
        "channels": sorted(df["acquisition_channel"].dropna().unique().tolist()),
        "plan_sizes": sorted(df["hours_purchased"].dropna().unique().tolist()),
    }


def _filter_clause(countries, personas, channels, plan_sizes) -> tuple[str, dict]:
    """Build a shared WHERE clause + bind params from the sidebar filters."""
    clauses = []
    params = {}
    if countries:
        clauses.append("country_code = any(:countries)")
        params["countries"] = countries
    if personas:
        clauses.append("persona = any(:personas)")
        params["personas"] = personas
    if channels:
        clauses.append("acquisition_channel = any(:channels)")
        params["channels"] = channels
    if plan_sizes:
        clauses.append("hours_purchased = any(:plan_sizes)")
        params["plan_sizes"] = [float(p) for p in plan_sizes]
    where_sql = (" and " + " and ".join(clauses)) if clauses else ""
    return where_sql, params


@st.cache_data(ttl=3600)
def get_latest_snapshot(
    countries, personas, channels, plan_sizes, start_date, end_date
) -> pd.DataFrame:
    """One row per cycle — its most recent day (today's running estimate for
    an open cycle, the final tally for a closed one). Population is every
    cycle (open or closed) whose cycle_end_date falls within the selected
    month: for a fully-past month that's all-closed, so ~100% actual; for
    the current month it's a mix — already-closed cycles contribute actual,
    still-open cycles due to end later this month contribute an estimate."""
    conn = get_connection()
    where_sql, params = _filter_clause(countries, personas, channels, plan_sizes)
    params["start_date"] = start_date
    params["end_date"] = end_date
    sql = f"""
        select distinct on (student_id, payment_rk)
            student_id,
            payment_rk,
            date_day,
            is_cycle_closed,
            hours_purchased,
            price_per_hour_usd,
            country_code,
            persona,
            acquisition_channel,
            (payment_rk = 1) as is_new_student,
            predicted_breakage_usd,
            predicted_commission_usd,
            predicted_total_revenue_usd,
            actual_breakage_usd,
            actual_commission_usd,
            actual_total_revenue_usd,
            avg_actual_breakage_usd_last_1_cycle,
            avg_actual_breakage_usd_last_3_cycles,
            avg_actual_breakage_usd_last_6_cycles
        from {MART}
        where cycle_end_date >= :start_date
        and cycle_end_date <= :end_date
        {where_sql}
        order by student_id, payment_rk, date_day desc
    """
    return conn.query(sql, params=params, ttl=3600)


@st.cache_data(ttl=3600)
def get_available_months() -> pd.DataFrame:
    """Every calendar month that has at least one cycle ending in it —
    derived from cycle_end_date directly (not the mart's own month_start_date
    column, which is bounded by the day-spine and never extends into future
    months the way an open cycle's cycle_end_date can)."""
    conn = get_connection()
    return conn.query(
        f"""
        select distinct
            date_trunc('month', cycle_end_date)::date as month_start,
            (date_trunc('month', cycle_end_date) + interval '1 month - 1 day')::date as month_end
        from {MART}
        order by 1
        """,
        ttl=3600,
    )


@st.cache_data(ttl=3600)
def get_monthly_breakage_trend(
    countries, personas, channels, plan_sizes, as_of_month_end
) -> pd.DataFrame:
    """Total breakage by month (grouped by cycle_end_date's month), through
    the end of the current month — never future months, which barely have
    any closed cycles yet and would just show a noisy partial estimate.
    Past months are ~100% actual_breakage_usd (every cycle in them has
    closed); the current month blends actual (already-closed cycles) with
    predicted (still-open ones) — the same 'total expected breakage' as the
    KPI card above, trended over time instead of pinned to one month."""
    conn = get_connection()
    where_sql, params = _filter_clause(countries, personas, channels, plan_sizes)
    params["as_of_month_end"] = as_of_month_end
    sql = f"""
        with latest_per_cycle as (
            select distinct on (student_id, payment_rk)
                student_id,
                payment_rk,
                date_trunc('month', cycle_end_date)::date as breakage_month,
                actual_breakage_usd,
                predicted_breakage_usd
            from {MART}
            where cycle_end_date <= :as_of_month_end
            {where_sql}
            order by student_id, payment_rk, date_day desc
        )
        select
            breakage_month,
            sum(coalesce(actual_breakage_usd, predicted_breakage_usd)) as total_breakage_usd
        from latest_per_cycle
        group by 1
        order by 1
    """
    return conn.query(sql, params=params, ttl=3600)


@st.cache_data(ttl=3600)
def get_cohort_weeks() -> list[str]:
    """Weeks a cycle could have *started* in — date_trunc('week', ...) on
    cycle_start_date directly, not the mart's own week_start_date column
    (that's the week of each row's date_day, a different thing entirely —
    see get_cohort_evolution)."""
    conn = get_connection()
    df = conn.query(
        f"select distinct date_trunc('week', cycle_start_date)::date as week from {MART} order by 1",
        ttl=3600,
    )
    return [d.strftime("%Y-%m-%d") for d in df["week"]]


@st.cache_data(ttl=3600)
def get_cohort_evolution(
    cohort_week: str, countries, personas, channels, plan_sizes
) -> pd.DataFrame:
    """Average predicted_breakage_usd by days_elapsed_in_cycle, across every
    cycle whose cycle_start_date falls in the chosen cohort week — plus the
    average actual for whatever share of that cohort has already closed.
    Respects the sidebar's country/persona/channel/plan-size filters, but
    deliberately not its month filter — a cohort's cycle_end_date is always
    ~4 weeks after cycle_start_date, so combining "started this week" with
    "ends in this month" would usually just produce an empty result.

    Deliberately does NOT filter on the mart's week_start_date column: that's
    the week of each ROW's date_day, not of the cycle's start. Two different
    cohorts' day-1 and day-28 rows can land in the same calendar week, so
    filtering on week_start_date silently splices together ~28 unrelated
    cohorts instead of tracking one. date_trunc('week', cycle_start_date) is
    a fixed, per-cycle value, so this actually holds one cohort fixed across
    the whole day axis."""
    conn = get_connection()
    where_sql, params = _filter_clause(countries, personas, channels, plan_sizes)
    params["cohort_week"] = cohort_week
    sql = f"""
        select
            days_elapsed_in_cycle,
            avg(predicted_breakage_usd) as avg_predicted_breakage_usd,
            avg(actual_breakage_usd) as avg_actual_breakage_usd,
            count(distinct (student_id, payment_rk)) as n_cycles
        from {MART}
        where date_trunc('week', cycle_start_date)::date = :cohort_week
        {where_sql}
        group by 1
        order by 1
    """
    return conn.query(sql, params=params, ttl=3600)


SEGMENT_COLUMNS = {
    "Persona": "persona",
    "Country": "country_code",
    "Acquisition channel": "acquisition_channel",
    "Plan size (hours)": "hours_purchased",
    "New vs. renewing": "is_new_student",
}


def compute_segment_breakdown(snapshot: pd.DataFrame, dimension_col: str) -> pd.DataFrame:
    closed = snapshot[snapshot["is_cycle_closed"]]
    if closed.empty:
        return pd.DataFrame()
    grouped = (
        closed.groupby(dimension_col)
        .agg(
            avg_breakage_usd=("actual_breakage_usd", "mean"),
            avg_breakage_pct=(
                "actual_breakage_usd",
                lambda s: (
                    closed.loc[s.index, "actual_breakage_usd"].sum()
                    / (closed.loc[s.index, "hours_purchased"] * closed.loc[s.index, "price_per_hour_usd"]).sum()
                ),
            ),
            n_cycles=("student_id", "count"),
        )
        .reset_index()
        .sort_values("avg_breakage_usd", ascending=False)
    )
    if dimension_col == "is_new_student":
        grouped[dimension_col] = grouped[dimension_col].map({True: "New", False: "Renewing"})
    if dimension_col == "hours_purchased":
        grouped[dimension_col] = grouped[dimension_col].map(lambda h: f"{h:g} hrs")
    return grouped


def style_chart(fig: go.Figure) -> go.Figure:
    fig.update_layout(
        plot_bgcolor="#fcfcfb",
        paper_bgcolor="#fcfcfb",
        font=dict(color="#0b0b0b", family="system-ui, -apple-system, sans-serif"),
        margin=dict(l=10, r=10, t=50, b=60),
        legend=dict(orientation="h", yanchor="top", y=-0.2, xanchor="left", x=0),
    )
    fig.update_xaxes(gridcolor=COLOR_GRIDLINE, zeroline=False, linecolor=COLOR_MUTED)
    fig.update_yaxes(gridcolor=COLOR_GRIDLINE, zeroline=False, linecolor=COLOR_MUTED)
    return fig


# ---------------------------------------------------------------------------

st.title("Breakage & revenue — PayOps dashboard")
st.caption(
    "Built on `student_breakage_daily`. Actual figures for closed cycles, "
    "daily-updated estimates for cycles still inside their 28-day window."
)

as_of_date = get_as_of_date()
options = get_filter_options()

months = get_available_months()

with st.sidebar:
    st.header("Filters")
    st.caption(f"Data as of **{as_of_date.date()}**")

    month_labels = [d.strftime("%B %Y") for d in months["month_start"]]
    current_month_idx = next(
        (i for i, d in enumerate(months["month_start"]) if d.strftime("%Y-%m") == as_of_date.strftime("%Y-%m")),
        len(month_labels) - 1,
    )
    selected_month_label = st.selectbox(
        "Month",
        month_labels,
        index=current_month_idx,
        help="Includes every cycle whose 28-day window ends in this month — "
        "already closed or still open and due to end this month.",
    )
    month_row = months.iloc[month_labels.index(selected_month_label)]
    start_date, end_date = month_row["month_start"], month_row["month_end"]

    sel_countries = st.multiselect("Country", options["countries"])
    sel_personas = st.multiselect("Persona", options["personas"])
    sel_channels = st.multiselect("Acquisition channel", options["channels"])
    sel_plan_sizes = st.multiselect("Plan size (hours)", options["plan_sizes"])

snapshot = get_latest_snapshot(
    sel_countries, sel_personas, sel_channels, sel_plan_sizes, start_date, end_date
)

tab_overview, tab_cohort, tab_segments = st.tabs(
    ["Overview", "Cohort evolution", "Segments"]
)

# --- Overview ---------------------------------------------------------
with tab_overview:
    st.markdown(
        "The numbers below cover every payment cycle **whose 28-day window "
        "ends in the selected month**. Past months all reflect **actual** "
        "breakage, since they have already completed. For the **current** "
        "month, breakage is estimated for any open cycle using the "
        "historical average hours per day (i.e. hours booked / days "
        "elapsed) for the first 14 days, and the actual average hours per "
        "day in the active cycle for the remaining 14 days of the cycle, "
        "to get the expected number of booked hours in the cycle. This is "
        "then subtracted from total purchased hours in the cycle to get "
        "**estimated** breakage."
    )

    if snapshot.empty:
        st.info("No cycles match the current filters.")
    else:
        closed = snapshot[snapshot["is_cycle_closed"]]
        open_ = snapshot[~snapshot["is_cycle_closed"]]

        total_breakage = closed["actual_breakage_usd"].sum() + open_["predicted_breakage_usd"].sum()
        actual_breakage = closed["actual_breakage_usd"].sum()
        estimated_breakage = open_["predicted_breakage_usd"].sum()
        total_commission = closed["actual_commission_usd"].sum() + open_["predicted_commission_usd"].sum()
        total_revenue = closed["actual_total_revenue_usd"].sum() + open_["predicted_total_revenue_usd"].sum()

        c1, c2, c3, c4 = st.columns(4)
        c1.metric("Total expected breakage", f"${total_breakage:,.0f}")
        c2.metric("— actual (closed cycles)", f"${actual_breakage:,.0f}")
        c3.metric("— estimated (open cycles)", f"${estimated_breakage:,.0f}")
        c4.metric("Total expected revenue", f"${total_revenue:,.0f}")
        st.caption(f"Includes ${total_commission:,.0f} of commission across {len(snapshot):,} cycles.")

        st.divider()

        n1, n2 = st.columns(2)
        n1.metric("Closed cycles in view", f"{len(closed):,}")
        n2.metric("Open cycles in view", f"{len(open_):,}")

        st.divider()

        st.caption(
            "Recent-history benchmark: each cycle's own trailing average "
            "actual breakage over its preceding closed cycles, averaged "
            "across every cycle currently in view (only cycles with enough "
            "history contribute to each figure). Shown alongside the live "
            "estimate for this month's still-open cycles, so you can see "
            "how the current estimate is tracking against recent history."
        )
        is_current_month = (pd.Timestamp(start_date).year, pd.Timestamp(start_date).month) == (
            as_of_date.year,
            as_of_date.month,
        )
        b0, b1, b2, b3 = st.columns(4)
        b0.metric(
            "Estimated breakage / cycle (open, this month)",
            f"${open_['predicted_breakage_usd'].mean():,.2f}"
            if is_current_month and not open_.empty
            else "n/a",
            help="Only applies to the current month — this is the live, "
            "pace-based estimate per still-open cycle, not a historical figure.",
        )
        b1.metric(
            "Avg breakage — last 1 cycle",
            f"${snapshot['avg_actual_breakage_usd_last_1_cycle'].mean():,.2f}"
            if snapshot["avg_actual_breakage_usd_last_1_cycle"].notna().any()
            else "n/a",
        )
        b2.metric(
            "Avg breakage — last 3 cycles",
            f"${snapshot['avg_actual_breakage_usd_last_3_cycles'].mean():,.2f}"
            if snapshot["avg_actual_breakage_usd_last_3_cycles"].notna().any()
            else "n/a",
        )
        b3.metric(
            "Avg breakage — last 6 cycles",
            f"${snapshot['avg_actual_breakage_usd_last_6_cycles'].mean():,.2f}"
            if snapshot["avg_actual_breakage_usd_last_6_cycles"].notna().any()
            else "n/a",
        )

        st.divider()

        st.subheader("Total breakage by month")
        st.caption(
            "Past months are actual breakage, current month (marked by the "
            "open circle) is total expected breakage."
        )
        as_of_month_end = (as_of_date + pd.offsets.MonthEnd(0)).date()
        trend = get_monthly_breakage_trend(
            sel_countries, sel_personas, sel_channels, sel_plan_sizes, as_of_month_end
        )
        if trend.empty:
            st.info("No data available.")
        else:
            trend_fig = go.Figure()
            trend_fig.add_trace(
                go.Scatter(
                    x=trend["breakage_month"],
                    y=trend["total_breakage_usd"],
                    mode="lines+markers",
                    name="Total breakage",
                    line=dict(color=COLOR_ACTUAL, width=2),
                    marker=dict(size=6, color=COLOR_ACTUAL),
                )
            )
            is_current = trend["breakage_month"].apply(
                lambda d: (d.year, d.month) == (as_of_date.year, as_of_date.month)
            )
            if is_current.any():
                trend_fig.add_trace(
                    go.Scatter(
                        x=trend.loc[is_current, "breakage_month"],
                        y=trend.loc[is_current, "total_breakage_usd"],
                        mode="markers",
                        name="Current month (incl. estimate)",
                        marker=dict(size=12, color=COLOR_PREDICTED, symbol="circle-open", line=dict(width=3)),
                    )
                )
            trend_fig.update_layout(
                xaxis_title="Month", yaxis_title="Total breakage (USD)", height=400
            )
            st.plotly_chart(style_chart(trend_fig), use_container_width=True)

# --- Cohort evolution ---------------------------------------------------
with tab_cohort:
    st.subheader("Breakage estimate by day per payment cohort")
    st.caption(
        "Average predicted breakage across every cycle that started in the "
        "chosen week, day by day, against the average actual for whichever "
        "share of that cohort has already closed. Respects the sidebar's "
        "country/persona/channel/plan-size filters — but not the month "
        "filter, since a cohort's cycles end weeks after they start."
    )
    weeks = get_cohort_weeks()
    if not weeks:
        st.info("No data available.")
    else:
        default_idx = max(0, len(weeks) - 5)
        cohort_week = st.selectbox("Cohort (cycle start week)", weeks, index=default_idx)
        evolution = get_cohort_evolution(
            cohort_week, sel_countries, sel_personas, sel_channels, sel_plan_sizes
        )

        if evolution.empty:
            st.info("No cycles in this cohort.")
        else:
            n_cycles = int(evolution["n_cycles"].max())
            st.caption(f"{n_cycles} payment cycle(s) started the week of {cohort_week}.")

            fig = go.Figure()
            fig.add_trace(
                go.Scatter(
                    x=evolution["days_elapsed_in_cycle"],
                    y=evolution["avg_predicted_breakage_usd"],
                    mode="lines",
                    name="Predicted",
                    line=dict(color=COLOR_PREDICTED, width=2),
                )
            )
            actual_line = evolution["avg_actual_breakage_usd"].dropna()
            if not actual_line.empty:
                fig.add_trace(
                    go.Scatter(
                        x=evolution["days_elapsed_in_cycle"],
                        y=evolution["avg_actual_breakage_usd"],
                        mode="lines",
                        name="Actual (once closed)",
                        line=dict(color=COLOR_ACTUAL, width=2, dash="dash"),
                    )
                )
            fig.update_layout(
                title=f"Cohort of {cohort_week} — avg. predicted vs. actual breakage ($)",
                xaxis_title="Day of cycle",
                yaxis_title="Avg breakage (USD)",
                height=450,
            )
            st.plotly_chart(style_chart(fig), use_container_width=True)

# --- Segments -----------------------------------------------------------
with tab_segments:
    st.subheader("Breakage by segment")
    st.caption("Based on closed cycles only (known actuals), within the sidebar filters.")

    dimension_label = st.selectbox("Break down by", list(SEGMENT_COLUMNS.keys()))
    dimension_col = SEGMENT_COLUMNS[dimension_label]

    if snapshot.empty:
        st.info("No cycles match the current filters.")
    else:
        breakdown = compute_segment_breakdown(snapshot, dimension_col)
        if breakdown.empty:
            st.info("No closed cycles in the current filter selection.")
        else:
            fig = go.Figure(
                go.Bar(
                    x=breakdown["avg_breakage_usd"],
                    y=breakdown[dimension_col],
                    orientation="h",
                    marker_color=COLOR_BAR,
                    text=[f"${v:,.2f}" for v in breakdown["avg_breakage_usd"]],
                    textposition="outside",
                )
            )
            fig.update_layout(
                title=f"Average actual breakage by {dimension_label.lower()}",
                xaxis_title="Avg breakage per cycle (USD)",
                height=max(300, 40 * len(breakdown)),
            )
            fig.update_yaxes(autorange="reversed")
            st.plotly_chart(style_chart(fig), use_container_width=True)

            st.dataframe(
                breakdown.rename(
                    columns={
                        dimension_col: dimension_label,
                        "avg_breakage_usd": "Avg breakage (USD)",
                        "avg_breakage_pct": "Breakage % of plan value",
                        "n_cycles": "Closed cycles",
                    }
                ).style.format({"Avg breakage (USD)": "${:,.2f}", "Breakage % of plan value": "{:.1%}"}),
                use_container_width=True,
                hide_index=True,
            )
