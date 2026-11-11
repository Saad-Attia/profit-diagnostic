/* =============================================================================
   Profit Diagnostic · Script 05 · Q4: What should the client do?
   -----------------------------------------------------------------------------
   Scenarios re-price the latest 12 months (P1) line by line. Unless stated,
   volume is held constant, so the result is an UPPER bound. Scenario 2 is the
   matching LOWER bound: it assumes every order that contains a below-cost line
   is lost completely.
   All figures are gross profit (net sales − standard cost). Fixed costs,
   freight and overheads are out of scope.
   ============================================================================= */

USE AdventureWorksDW2022;
GO

/* A. Scenario summary, P1
   Expected:
     Actual gross profit                                   −673,727.11
     S1 Price floor at standard cost (volume held)       1,021,905.54  (+1,695,632.66)
     S2 Price floor, lose every affected order (worst)     491,988.38  (+1,165,715.50)
     S3 Promotions applied once (unit price = dealer)      −31,848.26    (+641,878.85)
     S4 Cap line discounts at 15%                         −626,602.58     (+47,124.54)
   Reading: the price floor is worth 1.17M–1.70M; capping discounts barely moves
   the result, because discounts are not where the money goes. */
WITH lines AS (
    SELECT * FROM dbo.vw_pd_sales_line WHERE period = 'P1'
),
orders_with_below_cost AS (
    SELECT DISTINCT order_number FROM lines WHERE is_priced_below_cost = 1
),
scenarios AS (
    SELECT
        -- Actual
        SUM(gross_profit)                                                    AS actual_gp,

        -- S1: no unit price below standard cost; the same discount rate applies
        SUM(
            CASE WHEN unit_price < unit_cost THEN unit_cost ELSE unit_price END
            * qty * (1 - discount_pct) - cogs
        )                                                                    AS s1_price_floor_gp,

        -- S3: promotion applied once: unit price back to dealer price, line
        -- discount kept (recomputed on the higher invoice value)
        SUM(
            CASE WHEN discount_pct > 0
                 THEN dealer_value * (1 - discount_pct) - cogs
                 ELSE gross_profit
            END
        )                                                                    AS s3_single_promo_gp,

        -- S4: no line discount above 15%
        SUM(
            CASE WHEN discount_pct > 0.15
                 THEN invoice_gross * (1 - 0.15) - cogs
                 ELSE gross_profit
            END
        )                                                                    AS s4_cap15_gp
    FROM lines
),
worst_case AS (
    -- S2: every order containing a below-cost line is lost (all its lines)
    SELECT SUM(l.gross_profit) AS s2_lose_orders_gp
    FROM lines AS l
    WHERE l.order_number NOT IN (SELECT order_number FROM orders_with_below_cost)
)
SELECT 1 AS id, 'Actual gross profit' AS scenario,
       CAST(actual_gp AS DECIMAL(19,2)) AS gross_profit, CAST(0 AS DECIMAL(19,2)) AS change_vs_actual
FROM scenarios
UNION ALL
SELECT 2, 'S1 Price floor at standard cost (volume held)',
       CAST(s1_price_floor_gp AS DECIMAL(19,2)), CAST(s1_price_floor_gp - actual_gp AS DECIMAL(19,2))
FROM scenarios
UNION ALL
SELECT 3, 'S2 Price floor, every affected order lost (worst case)',
       CAST(w.s2_lose_orders_gp AS DECIMAL(19,2)), CAST(w.s2_lose_orders_gp - s.actual_gp AS DECIMAL(19,2))
FROM scenarios AS s CROSS JOIN worst_case AS w
UNION ALL
SELECT 4, 'S3 Promotions applied once',
       CAST(s3_single_promo_gp AS DECIMAL(19,2)), CAST(s3_single_promo_gp - actual_gp AS DECIMAL(19,2))
FROM scenarios
UNION ALL
SELECT 5, 'S4 Cap line discounts at 15%',
       CAST(s4_cap15_gp AS DECIMAL(19,2)), CAST(s4_cap15_gp - actual_gp AS DECIMAL(19,2))
FROM scenarios
ORDER BY id;
GO

/* B. Why the worst case still gains: order-level view (lesson: market basket)
   Do loss-making bikes pull profitable items into the same order?
   Expected (P1): 1,292 orders contain a below-cost line. In those orders the
   below-cost lines lose 2,042,236.65 while the other lines earn 876,521.15.
   Net: −1,165,715.50, so even losing these orders entirely would raise profit.
   510 orders without below-cost lines earn 491,988.38. */
WITH order_split AS (
    SELECT
        order_number,
        MAX(is_priced_below_cost)                                           AS has_below_cost_line,
        SUM(CASE WHEN is_priced_below_cost = 1 THEN gross_profit ELSE 0 END) AS gp_below_cost_lines,
        SUM(CASE WHEN is_priced_below_cost = 0 THEN gross_profit ELSE 0 END) AS gp_other_lines,
        COUNT(*)                                                            AS order_lines
    FROM dbo.vw_pd_sales_line
    WHERE period = 'P1'
    GROUP BY order_number
)
SELECT
    has_below_cost_line,
    COUNT(*)                                                AS orders,
    CAST(SUM(gp_below_cost_lines) AS DECIMAL(19,2))         AS gp_below_cost_lines,
    CAST(SUM(gp_other_lines)      AS DECIMAL(19,2))         AS gp_other_lines,
    CAST(SUM(gp_below_cost_lines + gp_other_lines) AS DECIMAL(19,2)) AS gp_whole_orders,
    CAST(AVG(CAST(order_lines AS DECIMAL(9,2))) AS DECIMAL(9,1))     AS avg_lines_per_order
FROM order_split
GROUP BY has_below_cost_line
ORDER BY has_below_cost_line;
GO

/* C. Price floor by model: where the S1 gain comes from
   Expected top: Touring-1000 +580,366.41 | Road-350-W +260,861.89 |
   Touring-3000 +229,152.91 | Road-250 +195,548.03 */
SELECT
    model,
    SUM(qty)                                                                AS units,
    CAST(SUM(gross_profit) AS DECIMAL(19,2))                                AS actual_gp,
    CAST(SUM(CASE WHEN unit_price < unit_cost THEN unit_cost ELSE unit_price END
             * qty * (1 - discount_pct) - cogs) AS DECIMAL(19,2))           AS gp_with_price_floor,
    CAST(SUM(CASE WHEN unit_price < unit_cost THEN unit_cost ELSE unit_price END
             * qty * (1 - discount_pct) - cogs) - SUM(gross_profit) AS DECIMAL(19,2)) AS gain
FROM dbo.vw_pd_sales_line
WHERE period = 'P1'
GROUP BY model
HAVING SUM(CASE WHEN unit_price < unit_cost THEN 1 ELSE 0 END) > 0
ORDER BY gain DESC;
GO

/* D. Break-even price increase needed per below-cost model (lesson 2)
   Minimum dealer price increase so that dealer price = standard cost.
   Expected: jerseys and cap +28.33% | Road models +6.07% | Touring models +3.60%
             | road frames +1.13%. Small increases on bikes; clothing needs a
             real reprice or a cheaper supplier. */
SELECT
    model,
    CAST(AVG(dealer_price) AS DECIMAL(19,2))                                   AS avg_dealer_price,
    CAST(AVG(unit_cost)    AS DECIMAL(19,2))                                   AS avg_standard_cost,
    CAST((SUM(qty * unit_cost) / SUM(dealer_value) - 1) * 100 AS DECIMAL(9,2)) AS increase_to_break_even_pct
FROM dbo.vw_pd_sales_line
WHERE period = 'P1'
  AND is_priced_below_cost = 1
GROUP BY model
ORDER BY increase_to_break_even_pct DESC;
GO
