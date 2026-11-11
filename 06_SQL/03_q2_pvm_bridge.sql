/* =============================================================================
   Profit Diagnostic · Script 03 · Q2: Why did profit change? (Price-Volume-Mix)
   -----------------------------------------------------------------------------
   Business decision supported: is the problem price, cost, volume, mix or new
   products? Each has a different owner and a different fix.

   Product level = SKU (ProductAlternateKey). ProductKey is Type 2, so a price or
   cost change creates a new key; using it would wrongly treat a repriced SKU
   as a "new product".

   Formulas per continuing SKU i (sold in both periods), base P0, current P1:
     r = net sales, c = cost, g = r − c, q = units, ratio = Q1_total ÷ Q0_total
     Price  effect = (P1 − P0) × q1          = r1 − q1 × r0/q0
     Cost   effect = −(C1 − C0) × q1         = −(c1 − q1 × c0/q0)
     Volume effect = (Q1_total × s0 − q0) × unit value P0  = v0 × (ratio − 1)
     Mix    effect = (q1 − Q1_total × s0)  × unit value P0  = q1 × v0/q0 − v0 × ratio
   where v0 is r0 for the revenue bridge and g0 for the profit bridge.
   SKUs sold in only one period go to New products / Discontinued products.
   Check: the effects must add up to the total change (to the cent, allowing for
   decimal rounding of a few cents).
   ============================================================================= */

USE AdventureWorksDW2022;
GO

/* A. Revenue and gross-profit bridges, P0 → P1
   Expected (net sales):   P0 27,921,670.52 → P1 36,240,484.70 (+8,318,814.18)
     Price +1,548,051.53 | Volume +981,266.63 | Mix −2,840,144.97
     New products +20,921,237.46 | Discontinued −12,291,596.48
   Expected (gross profit): P0 1,153,444.77 → P1 −673,727.11 (−1,827,171.88)
     Price +1,548,051.53 | Cost −1,997,685.66 | Volume +61,086.73 | Mix −153,341.16
     New products −1,104,856.58 | Discontinued −180,426.74 */
WITH by_sku AS (
    SELECT
        sku,
        SUM(CASE WHEN period = 'P0' THEN qty       END) AS q0,
        SUM(CASE WHEN period = 'P1' THEN qty       END) AS q1,
        SUM(CASE WHEN period = 'P0' THEN net_sales END) AS r0,
        SUM(CASE WHEN period = 'P1' THEN net_sales END) AS r1,
        SUM(CASE WHEN period = 'P0' THEN cogs      END) AS c0,
        SUM(CASE WHEN period = 'P1' THEN cogs      END) AS c1
    FROM dbo.vw_pd_sales_line
    WHERE period IN ('P0', 'P1')
    GROUP BY sku
),
continuing AS (
    SELECT * FROM by_sku WHERE q0 > 0 AND q1 > 0
),
volume_ratio AS (
    -- How much total continuing volume grew: Q1_total ÷ Q0_total
    SELECT CAST(SUM(q1) AS DECIMAL(38,12)) / SUM(q0) AS ratio
    FROM continuing
),
effects AS (
    SELECT
        c.sku,
        c.r1 - c.q1 * c.r0 / c.q0                                  AS price_effect,
        -(c.c1 - c.q1 * c.c0 / c.q0)                               AS cost_effect,
        c.r0 * (v.ratio - 1)                                       AS volume_rev,
        c.q1 * c.r0 / c.q0 - c.r0 * v.ratio                        AS mix_rev,
        (c.r0 - c.c0) * (v.ratio - 1)                              AS volume_gp,
        c.q1 * (c.r0 - c.c0) / c.q0 - (c.r0 - c.c0) * v.ratio      AS mix_gp
    FROM continuing AS c
    CROSS JOIN volume_ratio AS v
),
bridge AS (
    SELECT 1 AS step, 'Start (P0)' AS item,
           (SELECT SUM(r0) FROM by_sku) AS net_sales_bridge,
           (SELECT SUM(r0 - c0) FROM by_sku WHERE q0 > 0) AS gross_profit_bridge
    UNION ALL SELECT 2, 'Price',   SUM(price_effect), SUM(price_effect) FROM effects
    UNION ALL SELECT 3, 'Cost',    0,                 SUM(cost_effect)  FROM effects
    UNION ALL SELECT 4, 'Volume',  SUM(volume_rev),   SUM(volume_gp)    FROM effects
    UNION ALL SELECT 5, 'Mix',     SUM(mix_rev),      SUM(mix_gp)       FROM effects
    UNION ALL SELECT 6, 'New products',
           SUM(r1), SUM(r1 - c1) FROM by_sku WHERE ISNULL(q0, 0) = 0 AND q1 > 0
    UNION ALL SELECT 7, 'Discontinued products',
           -SUM(r0), -SUM(r0 - c0) FROM by_sku WHERE q0 > 0 AND ISNULL(q1, 0) = 0
    UNION ALL SELECT 8, 'End (P1)',
           (SELECT SUM(r1) FROM by_sku),
           (SELECT SUM(r1 - c1) FROM by_sku WHERE q1 > 0)
)
SELECT
    step,
    item,
    CAST(net_sales_bridge    AS DECIMAL(19,2)) AS net_sales_bridge,
    CAST(gross_profit_bridge AS DECIMAL(19,2)) AS gross_profit_bridge
FROM bridge
ORDER BY step;
GO

/* B. Reconciliation check: Start + all effects − End must be ~0
   Expected: both differences 0.00 (or within a few cents). */
WITH by_sku AS (
    SELECT
        sku,
        SUM(CASE WHEN period = 'P0' THEN qty       END) AS q0,
        SUM(CASE WHEN period = 'P1' THEN qty       END) AS q1,
        SUM(CASE WHEN period = 'P0' THEN net_sales END) AS r0,
        SUM(CASE WHEN period = 'P1' THEN net_sales END) AS r1,
        SUM(CASE WHEN period = 'P0' THEN cogs      END) AS c0,
        SUM(CASE WHEN period = 'P1' THEN cogs      END) AS c1
    FROM dbo.vw_pd_sales_line
    WHERE period IN ('P0', 'P1')
    GROUP BY sku
),
continuing AS (SELECT * FROM by_sku WHERE q0 > 0 AND q1 > 0),
volume_ratio AS (SELECT CAST(SUM(q1) AS DECIMAL(38,12)) / SUM(q0) AS ratio FROM continuing),
effects AS (
    SELECT
        SUM(c.r1 - c.q1 * c.r0 / c.q0)                                         AS price_effect,
        SUM(-(c.c1 - c.q1 * c.c0 / c.q0))                                      AS cost_effect,
        SUM(c.r0 * (v.ratio - 1) + c.q1 * c.r0 / c.q0 - c.r0 * v.ratio)        AS volume_mix_rev,
        SUM((c.r0 - c.c0) * (v.ratio - 1)
            + c.q1 * (c.r0 - c.c0) / c.q0 - (c.r0 - c.c0) * v.ratio)           AS volume_mix_gp
    FROM continuing AS c CROSS JOIN volume_ratio AS v
)
SELECT
    CAST((SELECT SUM(r0) FROM by_sku) + e.price_effect + e.volume_mix_rev
         + (SELECT ISNULL(SUM(r1), 0) FROM by_sku WHERE ISNULL(q0, 0) = 0)
         - (SELECT ISNULL(SUM(r0), 0) FROM by_sku WHERE ISNULL(q1, 0) = 0)
         - (SELECT SUM(r1) FROM by_sku)                       AS DECIMAL(19,2)) AS revenue_difference,
    CAST((SELECT SUM(r0 - c0) FROM by_sku WHERE q0 > 0) + e.price_effect + e.cost_effect + e.volume_mix_gp
         + (SELECT ISNULL(SUM(r1 - c1), 0) FROM by_sku WHERE ISNULL(q0, 0) = 0)
         - (SELECT ISNULL(SUM(r0 - c0), 0) FROM by_sku WHERE ISNULL(q1, 0) = 0)
         - (SELECT SUM(r1 - c1) FROM by_sku WHERE q1 > 0)    AS DECIMAL(19,2)) AS profit_difference
FROM effects AS e;
GO

/* C. Portfolio churn: how many SKUs are new, discontinued or continuing?
   Expected: 49 continuing | 118 new (20.9M sales, −1.10M profit) | 58 discontinued.
   Only 49 of 167 SKUs sold in P1 were also sold in P0: the range was largely
   replaced, so "New products" dominates the bridge. */
WITH by_sku AS (
    SELECT
        sku,
        SUM(CASE WHEN period = 'P0' THEN qty END) AS q0,
        SUM(CASE WHEN period = 'P1' THEN qty END) AS q1,
        SUM(CASE WHEN period = 'P0' THEN net_sales END) AS r0,
        SUM(CASE WHEN period = 'P1' THEN net_sales END) AS r1,
        SUM(CASE WHEN period = 'P0' THEN gross_profit END) AS g0,
        SUM(CASE WHEN period = 'P1' THEN gross_profit END) AS g1
    FROM dbo.vw_pd_sales_line
    WHERE period IN ('P0', 'P1')
    GROUP BY sku
)
SELECT
    CASE
        WHEN q0 > 0 AND q1 > 0 THEN 'Continuing'
        WHEN q1 > 0            THEN 'New in P1'
        ELSE                        'Discontinued after P0'
    END                                         AS sku_status,
    COUNT(*)                                    AS skus,
    CAST(SUM(ISNULL(r0, 0)) AS DECIMAL(19,2))   AS net_sales_p0,
    CAST(SUM(ISNULL(r1, 0)) AS DECIMAL(19,2))   AS net_sales_p1,
    CAST(SUM(ISNULL(g0, 0)) AS DECIMAL(19,2))   AS gross_profit_p0,
    CAST(SUM(ISNULL(g1, 0)) AS DECIMAL(19,2))   AS gross_profit_p1
FROM by_sku
GROUP BY
    CASE
        WHEN q0 > 0 AND q1 > 0 THEN 'Continuing'
        WHEN q1 > 0            THEN 'New in P1'
        ELSE                        'Discontinued after P0'
    END
ORDER BY sku_status;
GO

/* D. New products: which launches lost money?
   Expected worst: Touring-1000 −829,643 | Touring-3000 −338,700 | Road-350-W −285,229 */
WITH sku_first AS (
    SELECT sku
    FROM dbo.vw_pd_sales_line
    WHERE period IN ('P0', 'P1')
    GROUP BY sku
    HAVING SUM(CASE WHEN period = 'P0' THEN qty ELSE 0 END) = 0
)
SELECT
    s.model,
    COUNT(DISTINCT s.sku)                                           AS skus,
    CAST(SUM(s.net_sales)    AS DECIMAL(19,2))                      AS net_sales,
    CAST(SUM(s.gross_profit) AS DECIMAL(19,2))                      AS gross_profit,
    CAST(SUM(s.gross_profit) / NULLIF(SUM(s.net_sales), 0) * 100 AS DECIMAL(9,2)) AS gross_margin_pct
FROM dbo.vw_pd_sales_line AS s
JOIN sku_first            AS n ON n.sku = s.sku
WHERE s.period = 'P1'
GROUP BY s.model
ORDER BY gross_profit;
GO

/* E. Continuing products: did cost rise faster than price?
   Expected: price effect +1,548,051.53 vs cost effect −1,997,685.66 overall
   (net −449,634). Largest squeeze: Road-250 −166,203 (price +347,538, cost
   −513,741) and Road-550-W −95,586. Mountain-200 nearly offsets (−19,309). */
WITH by_sku AS (
    SELECT
        sku,
        MAX(model)                                           AS model,
        SUM(CASE WHEN period = 'P0' THEN qty       END)      AS q0,
        SUM(CASE WHEN period = 'P1' THEN qty       END)      AS q1,
        SUM(CASE WHEN period = 'P0' THEN net_sales END)      AS r0,
        SUM(CASE WHEN period = 'P1' THEN net_sales END)      AS r1,
        SUM(CASE WHEN period = 'P0' THEN cogs      END)      AS c0,
        SUM(CASE WHEN period = 'P1' THEN cogs      END)      AS c1
    FROM dbo.vw_pd_sales_line
    WHERE period IN ('P0', 'P1')
    GROUP BY sku
)
SELECT
    model,
    CAST(SUM(r1 - q1 * r0 / q0)    AS DECIMAL(19,2))       AS price_effect,
    CAST(SUM(-(c1 - q1 * c0 / q0)) AS DECIMAL(19,2))       AS cost_effect,
    CAST(SUM(r1 - q1 * r0 / q0) + SUM(-(c1 - q1 * c0 / q0)) AS DECIMAL(19,2)) AS net_rate_effect
FROM by_sku
WHERE q0 > 0 AND q1 > 0
GROUP BY model
ORDER BY net_rate_effect;
GO
