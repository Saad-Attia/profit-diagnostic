/* =============================================================================
   Profit Diagnostic · Script 04 · Q3: Where does the money leak?
   -----------------------------------------------------------------------------
   Business decision supported: which pricing and discount practices to stop,
   cap or fix.
   Price waterfall for the reseller channel:
     List price → standard dealer discount → promotion built into unit price
     → line discount → net sales → standard cost → gross profit
   ============================================================================= */

USE AdventureWorksDW2022;
GO

/* A. Price waterfall, latest 12 months (P1), in $ and per $100 of list price
   Expected:
     List value          62,253,591.49   100.00
     Dealer discount    −24,901,436.60   −40.00
     Promo in unit price   −782,985.57    −1.26
     Line discount         −328,684.65    −0.53
     Net sales           36,240,484.70    58.21
     Standard cost      −36,914,211.81   −59.30
     Gross profit          −673,727.11    −1.08
   Reading: before any promotion, the dealer price already returns less than
   the product costs on the models in query D. */
WITH totals AS (
    SELECT
        SUM(list_value)    AS list_value,
        SUM(dealer_value)  AS dealer_value,
        SUM(invoice_gross) AS invoice_gross,
        SUM(line_discount) AS line_discount,
        SUM(net_sales)     AS net_sales,
        SUM(cogs)          AS cogs,
        SUM(gross_profit)  AS gross_profit
    FROM dbo.vw_pd_sales_line
    WHERE period = 'P1'
),
steps AS (
    SELECT 1 AS step, 'List value'                     AS item, list_value                    AS amount, list_value AS base FROM totals
    UNION ALL SELECT 2, 'Standard dealer discount',     -(list_value - dealer_value),          list_value FROM totals
    UNION ALL SELECT 3, 'Promotion built into unit price', -(dealer_value - invoice_gross),    list_value FROM totals
    UNION ALL SELECT 4, 'Line discount',                -line_discount,                         list_value FROM totals
    UNION ALL SELECT 5, 'Net sales',                    net_sales,                              list_value FROM totals
    UNION ALL SELECT 6, 'Standard cost',                -cogs,                                  list_value FROM totals
    UNION ALL SELECT 7, 'Gross profit',                 gross_profit,                           list_value FROM totals
)
SELECT
    step,
    item,
    CAST(amount AS DECIMAL(19,2))                    AS amount,
    CAST(amount / base * 100 AS DECIMAL(9,2))        AS per_100_of_list
FROM steps
ORDER BY step;
GO

/* B. Discount bands vs margin, P1
   Bands are computed per line: discount ÷ invoice value. NULL guard first, so
   zero-value lines cannot fall into the worst band by accident.
   Expected:
     0%      28,388 lines | 32,645,904.78 sales | +393,166.59 profit (1.20%)
     0–10%    1,349 lines |  2,533,906.42 sales | −150,304.04 (−5.93%)
     10–20%     820 lines |  1,034,774.35 sales | −824,749.57 (−79.70%)
     30%+       169 lines |     25,899.14 sales |  −91,840.10 (−354.61%)
   Reading: the 2,338 promoted lines (7.6% of P1 lines) lose 1,066,893.71;
   all undiscounted lines together earn only 393,166.59. */
WITH lines AS (
    SELECT
        *,
        CASE WHEN invoice_gross > 0 THEN line_discount / invoice_gross END AS line_discount_rate
    FROM dbo.vw_pd_sales_line
    WHERE period = 'P1'
),
banded AS (
    SELECT
        *,
        CASE
            WHEN line_discount_rate IS NULL  THEN '9. Unknown'
            WHEN line_discount_rate = 0      THEN '1. 0%'
            WHEN line_discount_rate <= 0.10  THEN '2. 0-10%'
            WHEN line_discount_rate <= 0.20  THEN '3. 10-20%'
            WHEN line_discount_rate <= 0.30  THEN '4. 20-30%'
            ELSE                                  '5. 30%+'
        END AS discount_band
    FROM lines
)
SELECT
    discount_band,
    COUNT(*)                                                          AS order_lines,
    CAST(SUM(net_sales)    AS DECIMAL(19,2))                          AS net_sales,
    CAST(SUM(gross_profit) AS DECIMAL(19,2))                          AS gross_profit,
    CAST(SUM(gross_profit) / NULLIF(SUM(net_sales), 0) * 100 AS DECIMAL(9,2)) AS gross_margin_pct
FROM banded
GROUP BY discount_band
ORDER BY discount_band;
GO

/* C. Promotions, P1: which ones destroy the most profit?
   Expected worst: Touring-1000 Promotion −547,905.05 | Touring-3000 Promotion
   −277,071.13 | Mountain-500 Silver Clearance −91,840.10. Both Touring
   promotions discount products that already sell below cost. */
SELECT
    promotion,
    CAST(MAX(discount_pct) * 100 AS DECIMAL(9,2))                     AS discount_pct,
    COUNT(*)                                                          AS order_lines,
    CAST(SUM(net_sales)    AS DECIMAL(19,2))                          AS net_sales,
    CAST(SUM(gross_profit) AS DECIMAL(19,2))                          AS gross_profit,
    CAST(SUM(gross_profit) / NULLIF(SUM(net_sales), 0) * 100 AS DECIMAL(9,2)) AS gross_margin_pct
FROM dbo.vw_pd_sales_line
WHERE period = 'P1'
GROUP BY promotion
ORDER BY gross_profit;
GO

/* D. The root cause: dealer price set below standard cost
   Expected: P0  6,942 lines | 13,377,538.93 sales (47.9%) | −499,278.05
             P1 12,154 lines | 21,930,915.52 sales (60.5%) | −2,042,236.65
   All other lines earned 1,368,509.53 in P1.
   Every unit of these products loses money before any discount is given. */
SELECT
    period,
    SUM(is_priced_below_cost)                                                     AS lines_priced_below_cost,
    CAST(SUM(CASE WHEN is_priced_below_cost = 1 THEN net_sales END) AS DECIMAL(19,2)) AS net_sales_below_cost,
    CAST(SUM(CASE WHEN is_priced_below_cost = 1 THEN net_sales END)
         / SUM(net_sales) * 100 AS DECIMAL(9,2))                                  AS share_of_sales_pct,
    CAST(SUM(CASE WHEN is_priced_below_cost = 1 THEN gross_profit END) AS DECIMAL(19,2)) AS gross_profit_below_cost,
    CAST(SUM(CASE WHEN is_priced_below_cost = 0 THEN gross_profit END) AS DECIMAL(19,2)) AS gross_profit_rest
FROM dbo.vw_pd_sales_line
WHERE period IN ('P0', 'P1')
GROUP BY period
ORDER BY period;
GO

/* E. Which models are priced below cost? (P1, per unit)
   Expected: 13 models. Road-250/350-W/550-W/750 (dealer price 6.07% below
   cost); Touring-1000/2000/3000 (3.60% below); two jerseys and the cycling cap
   (28.33% below); three road frames (1.13% below). */
SELECT
    category,
    model,
    CAST(AVG(dealer_price) AS DECIMAL(19,2))                                   AS avg_dealer_price,
    CAST(AVG(unit_cost)    AS DECIMAL(19,2))                                   AS avg_standard_cost,
    CAST((SUM(dealer_value) - SUM(qty * unit_cost)) / SUM(dealer_value) * 100 AS DECIMAL(9,2)) AS margin_at_dealer_price_pct,
    SUM(qty)                                                                   AS units,
    CAST(SUM(gross_profit) AS DECIMAL(19,2))                                   AS gross_profit
FROM dbo.vw_pd_sales_line
WHERE period = 'P1'
  AND is_priced_below_cost = 1
GROUP BY category, model
ORDER BY gross_profit;
GO
