/*
  Odoo 19 import dataset generator
  Source tables:
    - parts
    - bom_entries
    - suppliers

  This script creates staging tables that match Odoo CSV import expectations,
  then fills them from your source tables.

  Notes:
  - "External ID" values are generated as deterministic keys:
      part_<part_id>, supplier_<supplier_id>, bom_<bom_id>, bomline_<bom_entry_id>
  - BOM headers are grouped by (project_id, rev_id, part_id).
  - If your schema uses different table names or joins (e.g., part-vendor mapping),
    adjust the joins in sections 2 and 4.
*/

SET NOCOUNT ON;

/* ============================================================
   1) Product import table (product.template)
   Columns are named to match Odoo import headers.
   ============================================================ */
IF OBJECT_ID('dbo.odoo_import_products', 'U') IS NOT NULL
    DROP TABLE dbo.odoo_import_products;

CREATE TABLE dbo.odoo_import_products (
    [id] NVARCHAR(64) NOT NULL,                    -- External ID
    [Name] NVARCHAR(255) NOT NULL,
    [Internal Reference] NVARCHAR(128) NULL,       -- default_code
    [Barcode] NVARCHAR(128) NULL,
    [Sales Price] DECIMAL(18, 4) NULL,             -- list_price
    [Cost] DECIMAL(18, 4) NULL,                    -- standard_price
    [Can be Sold] NVARCHAR(5) NOT NULL,
    [Can be Purchased] NVARCHAR(5) NOT NULL,
    [Product Type] NVARCHAR(32) NOT NULL,          -- storable/consu/service
    [Product Category] NVARCHAR(255) NULL,
    [Description] NVARCHAR(MAX) NULL,
    [Qty On Hand] DECIMAL(18, 4) NULL,
    [Purchase Currency] NVARCHAR(3) NULL,
    [Sales Currency] NVARCHAR(3) NULL
);

INSERT INTO dbo.odoo_import_products (
    [id], [Name], [Internal Reference], [Barcode], [Sales Price], [Cost],
    [Can be Sold], [Can be Purchased], [Product Type], [Product Category],
    [Description], [Qty On Hand], [Purchase Currency], [Sales Currency]
)
SELECT
    CONCAT('part_', p.id) AS [id],
    COALESCE(NULLIF(p.[description], ''), p.[ipn], p.[mpn], CONCAT('Part ', p.[id])) AS [Name],
    p.[ipn] AS [Internal Reference],
    p.[mpn] AS [Barcode],
    p.[selling_price_value] AS [Sales Price],
    p.[unit_cost_value] AS [Cost],
    CASE WHEN ISNULL(p.[for_sale], 0) = 1 THEN 'TRUE' ELSE 'FALSE' END AS [Can be Sold],
    'TRUE' AS [Can be Purchased],
    'storable' AS [Product Type],
    p.[category] AS [Product Category],
    CONCAT(
        ISNULL(p.[description], ''),
        CASE WHEN p.[manufacturer] IS NOT NULL AND p.[manufacturer] <> ''
             THEN CONCAT(' | MFR: ', p.[manufacturer]) ELSE '' END,
        CASE WHEN p.[mpn] IS NOT NULL AND p.[mpn] <> ''
             THEN CONCAT(' | MPN: ', p.[mpn]) ELSE '' END
    ) AS [Description],
    TRY_CONVERT(DECIMAL(18,4), p.[stock]) AS [Qty On Hand],
    p.[unit_cost_currency] AS [Purchase Currency],
    p.[selling_price_currency] AS [Sales Currency]
FROM dbo.[parts] p;

/* ============================================================
   2) Supplier import table (res.partner for vendors)
   ============================================================ */
IF OBJECT_ID('dbo.odoo_import_vendors', 'U') IS NOT NULL
    DROP TABLE dbo.odoo_import_vendors;

CREATE TABLE dbo.odoo_import_vendors (
    [id] NVARCHAR(64) NOT NULL,                    -- External ID
    [Name] NVARCHAR(255) NOT NULL,
    [Is a Company] NVARCHAR(5) NOT NULL,
    [Is Vendor] NVARCHAR(5) NOT NULL,
    [Email] NVARCHAR(255) NULL,
    [Phone] NVARCHAR(64) NULL,
    [Website] NVARCHAR(255) NULL,
    [Street] NVARCHAR(255) NULL,
    [Country Code] NVARCHAR(2) NULL,
    [Notes] NVARCHAR(MAX) NULL
);

INSERT INTO dbo.odoo_import_vendors (
    [id], [Name], [Is a Company], [Is Vendor], [Email], [Phone], [Website], [Street], [Country Code], [Notes]
)
SELECT
    CONCAT('supplier_', s.id) AS [id],
    s.[name] AS [Name],
    'TRUE' AS [Is a Company],
    'TRUE' AS [Is Vendor],
    s.[email] AS [Email],
    s.[phone] AS [Phone],
    s.[website] AS [Website],
    s.[address] AS [Street],
    s.[country_code] AS [Country Code],
    s.[notes] AS [Notes]
FROM dbo.[suppliers] s;

/* ============================================================
   3) Vendor price list import table (product.supplierinfo)
   If there is no explicit part-supplier relation table, this creates one line
   per (part, supplier) combination as a starting point.
   Replace CROSS JOIN with your real mapping table if available.
   ============================================================ */
IF OBJECT_ID('dbo.odoo_import_vendor_pricelist', 'U') IS NOT NULL
    DROP TABLE dbo.odoo_import_vendor_pricelist;

CREATE TABLE dbo.odoo_import_vendor_pricelist (
    [id] NVARCHAR(128) NOT NULL,                   -- External ID
    [Vendor/id] NVARCHAR(64) NOT NULL,
    [Product/id] NVARCHAR(64) NOT NULL,
    [Vendor Product Code] NVARCHAR(128) NULL,
    [Vendor Product Name] NVARCHAR(255) NULL,
    [Price] DECIMAL(18,4) NULL,
    [Currency] NVARCHAR(3) NULL,
    [Min Quantity] DECIMAL(18,4) NULL,
    [Delivery Lead Time] INT NULL
);

INSERT INTO dbo.odoo_import_vendor_pricelist (
    [id], [Vendor/id], [Product/id], [Vendor Product Code], [Vendor Product Name],
    [Price], [Currency], [Min Quantity], [Delivery Lead Time]
)
SELECT
    CONCAT('vprice_', s.id, '_', p.id) AS [id],
    CONCAT('supplier_', s.id) AS [Vendor/id],
    CONCAT('part_', p.id) AS [Product/id],
    p.[mpn] AS [Vendor Product Code],
    COALESCE(NULLIF(p.[description], ''), p.[ipn]) AS [Vendor Product Name],
    p.[unit_cost_value] AS [Price],
    p.[unit_cost_currency] AS [Currency],
    1 AS [Min Quantity],
    1 AS [Delivery Lead Time]
FROM dbo.[parts] p
CROSS JOIN dbo.[suppliers] s;

/* ============================================================
   4) BOM header import table (mrp.bom)
   One BOM per unique (project_id, rev_id, part_id).
   "Product/id" references the manufactured product.
   ============================================================ */
IF OBJECT_ID('dbo.odoo_import_bom_headers', 'U') IS NOT NULL
    DROP TABLE dbo.odoo_import_bom_headers;

CREATE TABLE dbo.odoo_import_bom_headers (
    [id] NVARCHAR(128) NOT NULL,                   -- External ID
    [Reference] NVARCHAR(255) NOT NULL,
    [Product/id] NVARCHAR(64) NOT NULL,
    [Quantity] DECIMAL(18,4) NOT NULL,
    [BOM Type] NVARCHAR(32) NOT NULL,
    [Company] NVARCHAR(255) NULL
);

WITH bom_group AS (
    SELECT
        b.project_id,
        b.rev_id,
        b.part_id,
        MIN(b.id) AS seed_bom_id
    FROM dbo.[bom_entries] b
    GROUP BY b.project_id, b.rev_id, b.part_id
)
INSERT INTO dbo.odoo_import_bom_headers (
    [id], [Reference], [Product/id], [Quantity], [BOM Type], [Company]
)
SELECT
    CONCAT('bom_', bg.seed_bom_id) AS [id],
    CONCAT('PRJ-', bg.project_id, '-REV-', bg.rev_id, '-PART-', bg.part_id) AS [Reference],
    CONCAT('part_', bg.part_id) AS [Product/id],
    1 AS [Quantity],
    'Manufacture this product' AS [BOM Type],
    NULL AS [Company]
FROM bom_group bg;

/* ============================================================
   5) BOM line import table (mrp.bom.line)
   "BoM/id" links to odoo_import_bom_headers.id
   "Component/id" links to product external ID.
   ============================================================ */
IF OBJECT_ID('dbo.odoo_import_bom_lines', 'U') IS NOT NULL
    DROP TABLE dbo.odoo_import_bom_lines;

CREATE TABLE dbo.odoo_import_bom_lines (
    [id] NVARCHAR(128) NOT NULL,                   -- External ID
    [BoM/id] NVARCHAR(128) NOT NULL,
    [Component/id] NVARCHAR(64) NOT NULL,
    [Quantity] DECIMAL(18,4) NOT NULL,
    [Unit of Measure] NVARCHAR(64) NULL,
    [Line Notes] NVARCHAR(MAX) NULL
);

WITH bom_group AS (
    SELECT
        b.project_id,
        b.rev_id,
        b.part_id,
        MIN(b.id) AS seed_bom_id
    FROM dbo.[bom_entries] b
    GROUP BY b.project_id, b.rev_id, b.part_id
)
INSERT INTO dbo.odoo_import_bom_lines (
    [id], [BoM/id], [Component/id], [Quantity], [Unit of Measure], [Line Notes]
)
SELECT
    CONCAT('bomline_', b.id) AS [id],
    CONCAT('bom_', bg.seed_bom_id) AS [BoM/id],
    CONCAT('part_', b.part_id) AS [Component/id],
    TRY_CONVERT(DECIMAL(18,4), b.qty) AS [Quantity],
    'Units' AS [Unit of Measure],
    b.comment AS [Line Notes]
FROM dbo.[bom_entries] b
INNER JOIN bom_group bg
    ON bg.project_id = b.project_id
   AND bg.rev_id = b.rev_id
   AND bg.part_id = b.part_id;

/* ============================================================
   6) CSV export examples

   Option A (inside SQL tools): run each SELECT and save results as CSV.

   Option B (command-line, SQL Server bcp):
     bcp "SELECT * FROM dbo.odoo_import_products" queryout odoo_products.csv -c -t, -T -S <server>
     bcp "SELECT * FROM dbo.odoo_import_vendors" queryout odoo_vendors.csv -c -t, -T -S <server>
     bcp "SELECT * FROM dbo.odoo_import_vendor_pricelist" queryout odoo_vendor_pricelist.csv -c -t, -T -S <server>
     bcp "SELECT * FROM dbo.odoo_import_bom_headers" queryout odoo_bom_headers.csv -c -t, -T -S <server>
     bcp "SELECT * FROM dbo.odoo_import_bom_lines" queryout odoo_bom_lines.csv -c -t, -T -S <server>

   Option C (sqlcmd):
     sqlcmd -S <server> -d <database> -E -Q "SET NOCOUNT ON; SELECT * FROM dbo.odoo_import_products" -s"," -W -o odoo_products.csv
     ...repeat for each staging table...
   ============================================================ */

SELECT 'odoo_import_products' AS generated_table, COUNT(*) AS row_count FROM dbo.odoo_import_products
UNION ALL
SELECT 'odoo_import_vendors', COUNT(*) FROM dbo.odoo_import_vendors
UNION ALL
SELECT 'odoo_import_vendor_pricelist', COUNT(*) FROM dbo.odoo_import_vendor_pricelist
UNION ALL
SELECT 'odoo_import_bom_headers', COUNT(*) FROM dbo.odoo_import_bom_headers
UNION ALL
SELECT 'odoo_import_bom_lines', COUNT(*) FROM dbo.odoo_import_bom_lines;
