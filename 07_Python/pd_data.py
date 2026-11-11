"""
Profit Diagnostic — data access and core calculations.

Two ways to load the same order-line table:
  * "sqlserver": reads dbo.vw_pd_sales_line from your restored AdventureWorksDW2022
                 (run 06_SQL/00_setup_views.sql first).
  * "csv":       rebuilds the same table from the Microsoft CSV install package
                 (AdventureWorksDW-data-warehouse-install-script.zip), for machines
                 without SQL Server.

Both paths return identical columns, so every notebook works with either.
"""
from __future__ import annotations

import os
import re
from pathlib import Path

import numpy as np
import pandas as pd

P0_START, P1_START, P1_END = "2011-12-01", "2012-12-01", "2013-12-01"


# ----------------------------------------------------------------------------- loading
def load_sales_lines(source: str | None = None,
                     server: str | None = None,
                     database: str = "AdventureWorksDW2022",
                     csv_folder: str | None = None) -> pd.DataFrame:
    """Return one row per order line with money columns, attributes and period label."""
    source = (source or os.getenv("PD_SOURCE", "sqlserver")).lower()
    if source == "sqlserver":
        df = _load_from_sqlserver(server or os.getenv("PD_SERVER", "localhost"), database)
    elif source == "csv":
        df = _load_from_csv(Path(csv_folder or os.getenv("PD_CSV_FOLDER", "../03_Raw_Data")))
    else:
        raise ValueError("source must be 'sqlserver' or 'csv'")
    _validate(df)
    return df


def _load_from_sqlserver(server: str, database: str) -> pd.DataFrame:
    import pyodbc  # pip install pyodbc  (needs "ODBC Driver 17/18 for SQL Server")
    drivers = [d for d in pyodbc.drivers() if "SQL Server" in d]
    if not drivers:
        raise RuntimeError("No SQL Server ODBC driver found. Install 'ODBC Driver 18 for SQL Server'.")
    conn_str = (f"DRIVER={{{sorted(drivers)[-1]}}};SERVER={server};DATABASE={database};"
                "Trusted_Connection=yes;TrustServerCertificate=yes;")
    with pyodbc.connect(conn_str) as conn:
        df = pd.read_sql("SELECT * FROM dbo.vw_pd_sales_line", conn)
    df["order_date"] = pd.to_datetime(df["order_date"])
    money = ["list_price", "dealer_price", "unit_price", "unit_cost", "discount_pct", "list_value",
             "dealer_value", "invoice_gross", "line_discount", "net_sales", "cogs", "gross_profit", "freight"]
    df[money] = df[money].astype(float)
    return df


def _read_pipe_table(folder: Path, table: str, ddl: str) -> pd.DataFrame:
    """Read one pipe-delimited table from the install package, columns taken from its DDL."""
    block = re.search(r"CREATE TABLE \[dbo\]\.\[%s\]\((.*?)\n\)" % table, ddl, re.S).group(1)
    cols = re.findall(r"^\s*\[(\w+)\]\s+\[\w+\]", block, re.M)
    raw = (folder / f"{table}.csv").read_bytes()
    for enc in ("utf-8-sig", "utf-16", "latin-1"):
        try:
            text = raw.decode(enc)
            if "|" in text[:2000]:
                break
        except UnicodeDecodeError:
            continue
    rows = [r.split("|") for r in text.split("\n") if r.strip()]
    rows = [r for r in rows if len(r) == len(cols)]
    return pd.DataFrame(rows, columns=cols).replace({"": None})


def _load_from_csv(folder: Path) -> pd.DataFrame:
    ddl = (folder / "instawdbdw.sql").read_text(encoding="utf-8", errors="replace")
    t = {name: _read_pipe_table(folder, name, ddl) for name in [
        "FactResellerSales", "DimProduct", "DimProductSubcategory", "DimProductCategory",
        "DimReseller", "DimEmployee", "DimSalesTerritory", "DimPromotion"]}

    f = t["FactResellerSales"]
    num = ["OrderQuantity", "UnitPrice", "ExtendedAmount", "UnitPriceDiscountPct", "DiscountAmount",
           "ProductStandardCost", "TotalProductCost", "SalesAmount", "Freight"]
    f[num] = f[num].astype(float)
    p = t["DimProduct"][["ProductKey", "ProductAlternateKey", "EnglishProductName", "ModelName",
                         "ProductSubcategoryKey", "ListPrice", "DealerPrice"]].copy()
    p[["ListPrice", "DealerPrice"]] = p[["ListPrice", "DealerPrice"]].astype(float)
    sc = t["DimProductSubcategory"][["ProductSubcategoryKey", "EnglishProductSubcategoryName", "ProductCategoryKey"]]
    c = t["DimProductCategory"][["ProductCategoryKey", "EnglishProductCategoryName"]]
    r = t["DimReseller"][["ResellerKey", "ResellerName", "BusinessType"]]
    e = t["DimEmployee"][["EmployeeKey", "FirstName", "LastName"]]
    st = t["DimSalesTerritory"][["SalesTerritoryKey", "SalesTerritoryRegion", "SalesTerritoryCountry"]]
    pr = t["DimPromotion"][["PromotionKey", "EnglishPromotionName"]]

    d = (f.merge(p, on="ProductKey").merge(sc, on="ProductSubcategoryKey", how="left")
          .merge(c, on="ProductCategoryKey", how="left").merge(r, on="ResellerKey")
          .merge(e, on="EmployeeKey").merge(st, on="SalesTerritoryKey").merge(pr, on="PromotionKey"))
    d["order_date"] = pd.to_datetime(d["OrderDate"]).dt.normalize()
    out = pd.DataFrame({
        "order_number": d["SalesOrderNumber"], "order_line": d["SalesOrderLineNumber"].astype(int),
        "order_date": d["order_date"], "period": label_period(d["order_date"]),
        "product_key": d["ProductKey"].astype(int), "sku": d["ProductAlternateKey"],
        "product_name": d["EnglishProductName"], "model": d["ModelName"],
        "subcategory": d["EnglishProductSubcategoryName"], "category": d["EnglishProductCategoryName"],
        "reseller_key": d["ResellerKey"].astype(int), "reseller_name": d["ResellerName"],
        "reseller_type": d["BusinessType"], "employee_key": d["EmployeeKey"].astype(int),
        "sales_rep": d["FirstName"] + " " + d["LastName"], "territory": d["SalesTerritoryRegion"],
        "country": d["SalesTerritoryCountry"], "promotion_key": d["PromotionKey"].astype(int),
        "promotion": d["EnglishPromotionName"], "qty": d["OrderQuantity"].astype(int),
        "list_price": d["ListPrice"], "dealer_price": d["DealerPrice"], "unit_price": d["UnitPrice"],
        "unit_cost": d["ProductStandardCost"], "discount_pct": d["UnitPriceDiscountPct"],
        "list_value": d["ListPrice"] * d["OrderQuantity"], "dealer_value": d["DealerPrice"] * d["OrderQuantity"],
        "invoice_gross": d["ExtendedAmount"], "line_discount": d["DiscountAmount"],
        "net_sales": d["SalesAmount"], "cogs": d["TotalProductCost"],
        "gross_profit": d["SalesAmount"] - d["TotalProductCost"], "freight": d["Freight"],
    })
    out["is_priced_below_cost"] = (out["dealer_price"] < out["unit_cost"]).astype(int)
    return out


def label_period(dates: pd.Series) -> pd.Series:
    """P0 = Dec 2011–Nov 2012, P1 = Dec 2012–Nov 2013, else None."""
    return pd.Series(np.select([(dates >= P0_START) & (dates < P1_START),
                                (dates >= P1_START) & (dates < P1_END)], ["P0", "P1"], default=None),
                     index=dates.index)


def _validate(df: pd.DataFrame) -> None:
    """Fail fast if the table is not what every analysis assumes."""
    assert df[["order_number", "order_line"]].duplicated().sum() == 0, "grain is not one row per order line"
    assert (df["qty"] > 0).all(), "non-positive quantities"
    assert np.isclose(df["invoice_gross"] - df["line_discount"], df["net_sales"], atol=0.01).all(), \
        "net sales != invoice − discount"


# ----------------------------------------------------------------------------- helpers
def margin(gp: float, sales: float) -> float:
    """Gross margin from totals (never an average of line percentages)."""
    return gp / sales if sales else np.nan


def summarise(df: pd.DataFrame, by: list[str] | str) -> pd.DataFrame:
    g = df.groupby(by, dropna=False).agg(lines=("qty", "size"), units=("qty", "sum"),
                                         net_sales=("net_sales", "sum"), cogs=("cogs", "sum"),
                                         gross_profit=("gross_profit", "sum"))
    g["gross_margin_pct"] = g["gross_profit"] / g["net_sales"] * 100
    return g


def pvm_bridge(df: pd.DataFrame, key: str = "sku") -> pd.DataFrame:
    """Price-volume-mix bridges (net sales and gross profit) from P0 to P1, at `key` level.

    Same formulas as 06_SQL/03_q2_pvm_bridge.sql. Raises if the effects do not reconcile.
    """
    piv = df[df["period"].isin(["P0", "P1"])].pivot_table(
        index=key, columns="period", values=["qty", "net_sales", "cogs"], aggfunc="sum")
    q0, q1 = piv[("qty", "P0")], piv[("qty", "P1")]
    r0, r1 = piv[("net_sales", "P0")], piv[("net_sales", "P1")]
    c0, c1 = piv[("cogs", "P0")], piv[("cogs", "P1")]
    cont = (q0 > 0) & (q1 > 0)
    new = q0.isna() & (q1 > 0)
    gone = (q0 > 0) & q1.isna()
    ratio = q1[cont].sum() / q0[cont].sum()
    g0 = r0 - c0

    eff = {
        "Price": (r1 - q1 * r0 / q0)[cont].sum(),
        "Cost": (-(c1 - q1 * c0 / q0))[cont].sum(),
        "Volume_rev": (r0 * (ratio - 1))[cont].sum(),
        "Mix_rev": (q1 * r0 / q0 - r0 * ratio)[cont].sum(),
        "Volume_gp": (g0 * (ratio - 1))[cont].sum(),
        "Mix_gp": (q1 * g0 / q0 - g0 * ratio)[cont].sum(),
    }
    rows = [
        ("Start (P0)", r0.sum(), g0.sum()),
        ("Price", eff["Price"], eff["Price"]),
        ("Cost", 0.0, eff["Cost"]),
        ("Volume", eff["Volume_rev"], eff["Volume_gp"]),
        ("Mix", eff["Mix_rev"], eff["Mix_gp"]),
        ("New products", r1[new].sum(), (r1 - c1)[new].sum()),
        ("Discontinued products", -r0[gone].sum(), -g0[gone].sum()),
        ("End (P1)", r1.sum(), (r1 - c1).sum()),
    ]
    out = pd.DataFrame(rows, columns=["item", "net_sales", "gross_profit"]).set_index("item")
    for col in out:
        steps = out[col].iloc[1:-1].sum()
        gap = out[col].iloc[0] + steps - out[col].iloc[-1]
        assert abs(gap) < 0.05, f"{col} bridge does not reconcile (gap {gap:,.2f})"
    return out
