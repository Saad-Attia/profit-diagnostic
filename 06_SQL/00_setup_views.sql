/* =============================================================================
   Profit Diagnostic — AdventureWorks reseller channel
   Script 00 · Analysis view
   -----------------------------------------------------------------------------
   Purpose : One clean row per sales order line, with every money column computed
             the same way, product/customer/rep attributes attached, and the two
             comparison periods labelled.
   Database: AdventureWorksDW2022 (Microsoft public sample). Change the USE line
             if your restored database has a different name.
   Author  : Saad Attia
   ============================================================================= */

USE AdventureWorksDW2022;
GO

/* -----------------------------------------------------------------------------
   Why these two periods?
   The data runs from 29 Dec 2010 to 29 Nov 2013. Calendar 2013 has only 11
   months and 2011 has gaps (no orders in Feb, Apr, Jun), so calendar years are
   not comparable. We compare two complete 12-month windows instead:
     P0 = Dec 2011 – Nov 2012   (prior 12 months)
     P1 = Dec 2012 – Nov 2013   (latest 12 months)
   ----------------------------------------------------------------------------- */
CREATE OR ALTER VIEW dbo.vw_pd_sales_line AS
SELECT
    -- Grain: one row per order line
    f.SalesOrderNumber                                       AS order_number,
    f.SalesOrderLineNumber                                   AS order_line,
    CAST(f.OrderDate AS DATE)                                AS order_date,
    CASE
        WHEN f.OrderDate >= '20111201' AND f.OrderDate < '20121201' THEN 'P0'
        WHEN f.OrderDate >= '20121201' AND f.OrderDate < '20131201' THEN 'P1'
    END                                                      AS period,

    -- Product: ProductKey is Type 2 (one SKU can have several versions),
    -- so SKU (ProductAlternateKey) is the stable product identifier.
    f.ProductKey                                             AS product_key,
    p.ProductAlternateKey                                    AS sku,
    p.EnglishProductName                                     AS product_name,
    p.ModelName                                              AS model,
    sc.EnglishProductSubcategoryName                         AS subcategory,
    c.EnglishProductCategoryName                             AS category,

    -- Customer, sales rep, territory, promotion
    f.ResellerKey                                            AS reseller_key,
    r.ResellerName                                           AS reseller_name,
    r.BusinessType                                           AS reseller_type,
    f.EmployeeKey                                            AS employee_key,
    CONCAT(e.FirstName, ' ', e.LastName)                     AS sales_rep,
    t.SalesTerritoryRegion                                   AS territory,
    t.SalesTerritoryCountry                                  AS country,
    f.PromotionKey                                           AS promotion_key,
    pr.EnglishPromotionName                                  AS promotion,

    -- Quantities and unit prices (DECIMAL for money, never FLOAT)
    CAST(f.OrderQuantity AS INT)                             AS qty,
    CAST(p.ListPrice           AS DECIMAL(19,4))             AS list_price,
    CAST(p.DealerPrice         AS DECIMAL(19,4))             AS dealer_price,
    CAST(f.UnitPrice           AS DECIMAL(19,4))             AS unit_price,
    CAST(f.ProductStandardCost AS DECIMAL(19,4))             AS unit_cost,
    CAST(f.UnitPriceDiscountPct AS DECIMAL(9,4))             AS discount_pct,

    -- Price waterfall columns (line totals)
    CAST(p.ListPrice   * f.OrderQuantity AS DECIMAL(19,4))   AS list_value,      -- catalogue price
    CAST(p.DealerPrice * f.OrderQuantity AS DECIMAL(19,4))   AS dealer_value,    -- standard reseller price
    CAST(f.ExtendedAmount AS DECIMAL(19,4))                  AS invoice_gross,   -- invoiced before line discount
    CAST(f.DiscountAmount AS DECIMAL(19,4))                  AS line_discount,   -- stored as FLOAT in source
    CAST(f.SalesAmount    AS DECIMAL(19,4))                  AS net_sales,
    CAST(f.TotalProductCost AS DECIMAL(19,4))                AS cogs,
    CAST(f.SalesAmount - f.TotalProductCost AS DECIMAL(19,4)) AS gross_profit,
    CAST(f.Freight AS DECIMAL(19,4))                         AS freight,

    -- Flag: dealer price set below standard cost (loses money before any discount)
    CASE WHEN p.DealerPrice < f.ProductStandardCost THEN 1 ELSE 0 END
                                                             AS is_priced_below_cost
FROM dbo.FactResellerSales           AS f
JOIN dbo.DimProduct                  AS p  ON p.ProductKey            = f.ProductKey
LEFT JOIN dbo.DimProductSubcategory  AS sc ON sc.ProductSubcategoryKey = p.ProductSubcategoryKey
LEFT JOIN dbo.DimProductCategory     AS c  ON c.ProductCategoryKey     = sc.ProductCategoryKey
JOIN dbo.DimReseller                 AS r  ON r.ResellerKey           = f.ResellerKey
JOIN dbo.DimEmployee                 AS e  ON e.EmployeeKey           = f.EmployeeKey
JOIN dbo.DimSalesTerritory           AS t  ON t.SalesTerritoryKey     = f.SalesTerritoryKey
JOIN dbo.DimPromotion                AS pr ON pr.PromotionKey         = f.PromotionKey;
GO

/* Reconciliation: the view must return every fact row and the same net sales.
   Expected: 60,855 rows in both; net sales 80,450,596.98 in both. */
SELECT 'FactResellerSales' AS source, COUNT(*) AS row_count,
       CAST(SUM(SalesAmount) AS DECIMAL(19,2)) AS net_sales
FROM dbo.FactResellerSales
UNION ALL
SELECT 'vw_pd_sales_line', COUNT(*), CAST(SUM(net_sales) AS DECIMAL(19,2))
FROM dbo.vw_pd_sales_line;
GO
