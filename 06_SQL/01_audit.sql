/* =============================================================================
   Profit Diagnostic · Script 01 · Data quality audit
   -----------------------------------------------------------------------------
   Every check below answers one question about the data and ends with an
   "Expected" comment: the value we got when we validated this script. If your
   result differs, stop and find out why before moving on.
   ============================================================================= */

USE AdventureWorksDW2022;
GO

/* A. Volume and grain -----------------------------------------------------------
   Is there exactly one row per order line?
   Expected: 60,855 rows = 60,855 distinct order lines; 3,796 orders;
             334 product keys; 250 SKUs; 635 resellers; 17 sales reps. */
SELECT
    COUNT(*)                                                     AS row_count,
    COUNT(DISTINCT CONCAT(SalesOrderNumber, '-', SalesOrderLineNumber)) AS distinct_order_lines,
    COUNT(DISTINCT SalesOrderNumber)                             AS orders,
    COUNT(DISTINCT f.ProductKey)                                 AS product_keys,
    COUNT(DISTINCT p.ProductAlternateKey)                        AS skus,
    COUNT(DISTINCT ResellerKey)                                  AS resellers,
    COUNT(DISTINCT EmployeeKey)                                  AS sales_reps
FROM dbo.FactResellerSales AS f
JOIN dbo.DimProduct AS p ON p.ProductKey = f.ProductKey;
GO

/* B. Date coverage --------------------------------------------------------------
   Which months have orders? Calendar years are only comparable if complete.
   Expected: 33 months from 2010-12 to 2013-11; no orders in 2011-02, 2011-04,
             2011-06; 2013 stops in November.
   Decision: compare P0 = Dec 2011–Nov 2012 with P1 = Dec 2012–Nov 2013. */
SELECT
    YEAR(OrderDate)                 AS order_year,
    MONTH(OrderDate)                AS order_month,
    COUNT(*)                        AS order_lines,
    CAST(SUM(SalesAmount) AS DECIMAL(19,2))                         AS net_sales,
    CAST(SUM(SalesAmount - TotalProductCost) AS DECIMAL(19,2))      AS gross_profit
FROM dbo.FactResellerSales
GROUP BY YEAR(OrderDate), MONTH(OrderDate)
ORDER BY order_year, order_month;
GO

/* C. Missing values in the columns the analysis uses
   Expected: 0 in every column. */
SELECT
    SUM(CASE WHEN OrderQuantity       IS NULL THEN 1 ELSE 0 END) AS null_qty,
    SUM(CASE WHEN UnitPrice           IS NULL THEN 1 ELSE 0 END) AS null_unit_price,
    SUM(CASE WHEN SalesAmount         IS NULL THEN 1 ELSE 0 END) AS null_sales,
    SUM(CASE WHEN TotalProductCost    IS NULL THEN 1 ELSE 0 END) AS null_cost,
    SUM(CASE WHEN UnitPriceDiscountPct IS NULL THEN 1 ELSE 0 END) AS null_discount_pct,
    SUM(CASE WHEN OrderDate           IS NULL THEN 1 ELSE 0 END) AS null_order_date
FROM dbo.FactResellerSales;
GO

/* D. Do the money columns add up? (unit price vs line total check)
   Expected: 0 mismatches in all four rules, so UnitPrice is a unit price and
             SalesAmount = ExtendedAmount − DiscountAmount. */
SELECT
    SUM(CASE WHEN ABS(UnitPrice * OrderQuantity - ExtendedAmount) > 0.01 THEN 1 ELSE 0 END)          AS extended_mismatch,
    SUM(CASE WHEN ABS(ExtendedAmount * UnitPriceDiscountPct - DiscountAmount) > 0.01 THEN 1 ELSE 0 END) AS discount_mismatch,
    SUM(CASE WHEN ABS(ExtendedAmount - DiscountAmount - SalesAmount) > 0.01 THEN 1 ELSE 0 END)         AS net_sales_mismatch,
    SUM(CASE WHEN ABS(ProductStandardCost * OrderQuantity - TotalProductCost) > 0.01 THEN 1 ELSE 0 END) AS cost_mismatch
FROM dbo.FactResellerSales;
GO

/* E. Impossible values
   Expected: 0 non-positive quantities, 0 negative sales; but 21,829 lines
             (36%) are sold below standard cost. That is not a data error: it is
             the main business finding, investigated in scripts 02–04. */
SELECT
    SUM(CASE WHEN OrderQuantity <= 0 THEN 1 ELSE 0 END)             AS non_positive_qty,
    SUM(CASE WHEN SalesAmount < 0 THEN 1 ELSE 0 END)                AS negative_sales,
    SUM(CASE WHEN SalesAmount < TotalProductCost THEN 1 ELSE 0 END) AS lines_below_cost,
    COUNT(*)                                                        AS all_lines
FROM dbo.FactResellerSales;
GO

/* F. Currency
   Five CurrencyKeys appear. If amounts were in local currency, the same product
   would show very different prices by currency.
   Expected: the most-sold product averages ~37 in every currency, so all amounts
             are stored in USD and can be summed. */
WITH top_product AS (
    SELECT TOP (1) ProductKey
    FROM dbo.FactResellerSales
    GROUP BY ProductKey
    ORDER BY COUNT(*) DESC
)
SELECT
    c.CurrencyAlternateKey                          AS currency,
    COUNT(*)                                        AS lines,
    CAST(AVG(f.UnitPrice) AS DECIMAL(19,2))         AS avg_unit_price
FROM dbo.FactResellerSales AS f
JOIN dbo.DimCurrency       AS c ON c.CurrencyKey = f.CurrencyKey
WHERE f.ProductKey IN (SELECT ProductKey FROM top_product)
GROUP BY c.CurrencyAlternateKey
ORDER BY lines DESC;
GO

/* G. Distinct values before grouping: promotions and discount rates
   Expected: 12 promotions in use; 9 discount rates (0% to 40%);
             57,573 lines (95%) carry no discount. */
SELECT
    f.PromotionKey,
    pr.EnglishPromotionName                         AS promotion,
    CAST(f.UnitPriceDiscountPct AS DECIMAL(9,4))    AS discount_pct,
    COUNT(*)                                        AS lines,
    CAST(SUM(f.DiscountAmount) AS DECIMAL(19,2))    AS discount_amount
FROM dbo.FactResellerSales AS f
JOIN dbo.DimPromotion      AS pr ON pr.PromotionKey = f.PromotionKey
GROUP BY f.PromotionKey, pr.EnglishPromotionName, f.UnitPriceDiscountPct
ORDER BY f.PromotionKey;
GO

/* H. Orphan keys: fact rows whose key has no dimension row
   Expected: 0 everywhere. */
SELECT
    SUM(CASE WHEN p.ProductKey        IS NULL THEN 1 ELSE 0 END) AS orphan_product,
    SUM(CASE WHEN r.ResellerKey       IS NULL THEN 1 ELSE 0 END) AS orphan_reseller,
    SUM(CASE WHEN e.EmployeeKey       IS NULL THEN 1 ELSE 0 END) AS orphan_employee,
    SUM(CASE WHEN t.SalesTerritoryKey IS NULL THEN 1 ELSE 0 END) AS orphan_territory,
    SUM(CASE WHEN pr.PromotionKey     IS NULL THEN 1 ELSE 0 END) AS orphan_promotion
FROM dbo.FactResellerSales          AS f
LEFT JOIN dbo.DimProduct            AS p  ON p.ProductKey         = f.ProductKey
LEFT JOIN dbo.DimReseller           AS r  ON r.ResellerKey        = f.ResellerKey
LEFT JOIN dbo.DimEmployee           AS e  ON e.EmployeeKey        = f.EmployeeKey
LEFT JOIN dbo.DimSalesTerritory     AS t  ON t.SalesTerritoryKey  = f.SalesTerritoryKey
LEFT JOIN dbo.DimPromotion          AS pr ON pr.PromotionKey      = f.PromotionKey;
GO

/* I. How is the invoice price built? (unit price vs list and dealer price)
   Expected: on undiscounted lines UnitPrice = 60% of ListPrice = DealerPrice.
   On promoted lines UnitPrice is ALREADY below DealerPrice (e.g. 58% of list on
   2% lines), and the line discount is then applied again on top.
   => The promotion reduces the price twice. Flag to the client as a question. */
SELECT
    CAST(f.UnitPriceDiscountPct AS DECIMAL(9,4))                 AS discount_pct,
    CAST(f.UnitPrice / p.ListPrice   AS DECIMAL(9,3))            AS unit_price_to_list,
    CAST(f.UnitPrice / p.DealerPrice AS DECIMAL(9,3))            AS unit_price_to_dealer,
    COUNT(*)                                                     AS lines
FROM dbo.FactResellerSales AS f
JOIN dbo.DimProduct        AS p ON p.ProductKey = f.ProductKey
GROUP BY f.UnitPriceDiscountPct,
         CAST(f.UnitPrice / p.ListPrice   AS DECIMAL(9,3)),
         CAST(f.UnitPrice / p.DealerPrice AS DECIMAL(9,3))
ORDER BY discount_pct;
GO

/* J. Anomaly: November 2011 lost money on a scale no other month did
   Expected: bikes −620,041 in 2011-11. This month is outside P0/P1, so it does
   not affect the comparison, but it is logged in the data quality assessment. */
SELECT
    category,
    CAST(SUM(net_sales)    AS DECIMAL(19,2)) AS net_sales,
    CAST(SUM(gross_profit) AS DECIMAL(19,2)) AS gross_profit
FROM dbo.vw_pd_sales_line
WHERE order_date >= '20111101' AND order_date < '20111201'
GROUP BY category
ORDER BY gross_profit;
GO

/* K. Period totals: the numbers the whole report is built on
   Expected:
     P0: 21,670 lines | net sales 27,921,670.52 | gross profit  1,153,444.77
     P1: 30,726 lines | net sales 36,240,484.70 | gross profit   -673,727.11
     (NULL = months outside both periods: 8,459 lines)
   Sum of the three rows must equal the totals in script 00. */
SELECT
    period,
    COUNT(*)                                         AS order_lines,
    SUM(qty)                                         AS units,
    CAST(SUM(net_sales)    AS DECIMAL(19,2))         AS net_sales,
    CAST(SUM(cogs)         AS DECIMAL(19,2))         AS cogs,
    CAST(SUM(gross_profit) AS DECIMAL(19,2))         AS gross_profit,
    CAST(SUM(gross_profit) / NULLIF(SUM(net_sales), 0) * 100 AS DECIMAL(9,2)) AS gross_margin_pct
FROM dbo.vw_pd_sales_line
GROUP BY period
ORDER BY period;
GO
