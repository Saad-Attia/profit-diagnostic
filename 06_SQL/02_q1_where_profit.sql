/* =============================================================================
   Profit Diagnostic · Script 02 · Q1: Where is profit made (and lost)?
   -----------------------------------------------------------------------------
   Business decision supported: which products and resellers to protect, fix,
   reprice or exit.
   Rule: every margin % is computed from totals (Σ gross profit ÷ Σ net sales),
   never as an average of line-level percentages.
   ============================================================================= */

USE AdventureWorksDW2022;
GO

/* A. Profit by category, both periods
   Expected (P1): Bikes −1,232,916 (−4.27%) | Components 354,645 (5.91%)
                  Clothing 59,987 (6.24%)   | Accessories 144,558 (35.25%)
   Reading: bikes are 80% of sales and the whole loss. */
SELECT
    category,
    period,
    CAST(SUM(net_sales)    AS DECIMAL(19,2))                         AS net_sales,
    CAST(SUM(gross_profit) AS DECIMAL(19,2))                         AS gross_profit,
    CAST(SUM(gross_profit) / NULLIF(SUM(net_sales), 0) * 100 AS DECIMAL(9,2)) AS gross_margin_pct
FROM dbo.vw_pd_sales_line
WHERE period IS NOT NULL
GROUP BY category, period
ORDER BY category, period;
GO

/* B. Profit by bike subcategory, both periods
   Expected: Touring Bikes appear only in P1: 10,451,490 sales, −1,237,595 profit.
             Road Bikes −495,964 (P0) → −658,840 (P1). */
SELECT
    subcategory,
    period,
    CAST(SUM(net_sales)    AS DECIMAL(19,2))                         AS net_sales,
    CAST(SUM(gross_profit) AS DECIMAL(19,2))                         AS gross_profit,
    CAST(SUM(gross_profit) / NULLIF(SUM(net_sales), 0) * 100 AS DECIMAL(9,2)) AS gross_margin_pct
FROM dbo.vw_pd_sales_line
WHERE period IS NOT NULL
  AND category = 'Bikes'
GROUP BY subcategory, period
ORDER BY subcategory, period;
GO

/* C. Product models in the latest 12 months, worst to best
   Expected worst: Touring-1000 −829,643 | Touring-3000 −338,700 | Road-350-W −285,229
   Expected best : Mountain-200 607,776 | HL Mountain Frame 119,057 */
SELECT
    category,
    model,
    SUM(qty)                                                         AS units,
    CAST(SUM(net_sales)    AS DECIMAL(19,2))                         AS net_sales,
    CAST(SUM(gross_profit) AS DECIMAL(19,2))                         AS gross_profit,
    CAST(SUM(gross_profit) / NULLIF(SUM(net_sales), 0) * 100 AS DECIMAL(9,2)) AS gross_margin_pct
FROM dbo.vw_pd_sales_line
WHERE period = 'P1'
GROUP BY category, model
ORDER BY gross_profit;
GO

/* D. ABC classification on gross profit (SKU level, P1)
   Cumulative share is computed on profitable SKUs only; loss-making SKUs form
   their own class, otherwise the cumulative share passes 100% and ABC breaks.
   Expected first row: BK-M68B-38 (Mountain-200 Black, 38), 136,026.32, class A. */
WITH sku_profit AS (
    SELECT
        sku,
        MAX(product_name)          AS product_name,
        MAX(category)              AS category,
        SUM(net_sales)             AS net_sales,
        SUM(gross_profit)          AS gross_profit
    FROM dbo.vw_pd_sales_line
    WHERE period = 'P1'
    GROUP BY sku
),
ranked AS (
    SELECT
        *,
        SUM(CASE WHEN gross_profit > 0 THEN gross_profit END)
            OVER (ORDER BY gross_profit DESC, sku ROWS UNBOUNDED PRECEDING)
        / SUM(CASE WHEN gross_profit > 0 THEN gross_profit END) OVER () AS cum_share_of_positive
    FROM sku_profit
)
SELECT
    sku,
    product_name,
    category,
    CAST(net_sales    AS DECIMAL(19,2))                    AS net_sales,
    CAST(gross_profit AS DECIMAL(19,2))                    AS gross_profit,
    CAST(cum_share_of_positive * 100 AS DECIMAL(9,2))      AS cum_share_pct,
    CASE
        WHEN gross_profit < 0              THEN 'Loss-making'
        WHEN cum_share_of_positive <= 0.80 THEN 'A'
        WHEN cum_share_of_positive <= 0.95 THEN 'B'
        ELSE 'C'
    END                                                    AS abc_class
FROM ranked
ORDER BY gross_profit DESC, sku;
GO

/* E. ABC summary
   Expected: A = 26 SKUs | B = 26 | C = 44 | Loss-making = 71 (167 SKUs sold in P1).
   26 SKUs (16%) make 80% of the profit that profitable SKUs earn.
   Loss-making SKUs: 23,745,342.87 of sales (65.5%) and −2,089,313.18 of profit. */
WITH sku_profit AS (
    SELECT sku, SUM(net_sales) AS net_sales, SUM(gross_profit) AS gross_profit
    FROM dbo.vw_pd_sales_line
    WHERE period = 'P1'
    GROUP BY sku
),
ranked AS (
    SELECT
        *,
        SUM(CASE WHEN gross_profit > 0 THEN gross_profit END)
            OVER (ORDER BY gross_profit DESC, sku ROWS UNBOUNDED PRECEDING)
        / SUM(CASE WHEN gross_profit > 0 THEN gross_profit END) OVER () AS cum_share
    FROM sku_profit
),
classed AS (
    SELECT
        *,
        CASE
            WHEN gross_profit < 0   THEN 'Loss-making'
            WHEN cum_share <= 0.80  THEN 'A'
            WHEN cum_share <= 0.95  THEN 'B'
            ELSE 'C'
        END AS abc_class
    FROM ranked
)
SELECT
    abc_class,
    COUNT(*)                                                         AS skus,
    CAST(SUM(net_sales)    AS DECIMAL(19,2))                         AS net_sales,
    CAST(SUM(net_sales) / SUM(SUM(net_sales)) OVER () * 100 AS DECIMAL(9,2)) AS share_of_sales_pct,
    CAST(SUM(gross_profit) AS DECIMAL(19,2))                         AS gross_profit
FROM classed
GROUP BY abc_class
ORDER BY CASE abc_class WHEN 'A' THEN 1 WHEN 'B' THEN 2 WHEN 'C' THEN 3 ELSE 4 END;
GO

/* F. Whale curve (SKU level, P1): how high does cumulative profit climb before
   loss-makers pull it down?
   Expected: peak 1,415,586.07 → final −673,727.11. Profitable SKUs earn 1.42M;
   loss-making SKUs give back 2.09M. */
WITH sku_profit AS (
    SELECT sku, SUM(gross_profit) AS gross_profit
    FROM dbo.vw_pd_sales_line
    WHERE period = 'P1'
    GROUP BY sku
),
curve AS (
    SELECT
        sku,
        SUM(gross_profit) OVER (ORDER BY gross_profit DESC, sku ROWS UNBOUNDED PRECEDING) AS cumulative_profit
    FROM sku_profit
)
SELECT
    CAST(MAX(cumulative_profit) AS DECIMAL(19,2))                    AS peak_cumulative_profit,
    CAST((SELECT SUM(gross_profit) FROM sku_profit) AS DECIMAL(19,2)) AS final_profit
FROM curve;
GO

/* G. Resellers (customers), P1
   Expected: 493 active resellers; 297 unprofitable, holding 66.8% of sales.
   Profitable resellers earn 1,090,231; unprofitable ones lose 1,763,959. */
WITH reseller_profit AS (
    SELECT reseller_key, SUM(net_sales) AS net_sales, SUM(gross_profit) AS gross_profit
    FROM dbo.vw_pd_sales_line
    WHERE period = 'P1'
    GROUP BY reseller_key
)
SELECT
    COUNT(*)                                                             AS resellers,
    SUM(CASE WHEN gross_profit < 0 THEN 1 ELSE 0 END)                    AS unprofitable_resellers,
    CAST(SUM(CASE WHEN gross_profit < 0 THEN net_sales END) / SUM(net_sales) * 100
         AS DECIMAL(9,2))                                                AS unprofitable_share_of_sales_pct,
    CAST(SUM(CASE WHEN gross_profit > 0 THEN gross_profit END) AS DECIMAL(19,2)) AS profit_from_profitable,
    CAST(SUM(CASE WHEN gross_profit < 0 THEN gross_profit END) AS DECIMAL(19,2)) AS loss_from_unprofitable
FROM reseller_profit;
GO

/* H. Sales rep × territory, P1: is this a sales-discipline problem?
   Expected: discount rates sit between 0.05% and 3.24% of invoice value for
   every rep, and 19 of 30 rep-territory pairs lose money. Every rep sells the
   same price list, so the loss follows the price list, not the people. */
SELECT
    sales_rep,
    territory,
    CAST(SUM(net_sales)    AS DECIMAL(19,2))                              AS net_sales,
    CAST(SUM(gross_profit) AS DECIMAL(19,2))                              AS gross_profit,
    CAST(SUM(gross_profit)  / NULLIF(SUM(net_sales), 0)     * 100 AS DECIMAL(9,2)) AS gross_margin_pct,
    CAST(SUM(line_discount) / NULLIF(SUM(invoice_gross), 0) * 100 AS DECIMAL(9,2)) AS discount_pct_of_invoice
FROM dbo.vw_pd_sales_line
WHERE period = 'P1'
GROUP BY sales_rep, territory
ORDER BY gross_profit;
GO
