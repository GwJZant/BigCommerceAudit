-- Prevent output from including "Rows Affected" lines
SET NOCOUNT ON;

-- This query returns a csv-ready list of Styles in Celerant that are in BigCommerce
SELECT DISTINCT CONCAT('''',tb.STYLE,''',')
FROM VW_TICKETS AS vw
INNER JOIN TB_STYLES AS tb
ON tb.STYLE_ID = vw.STYLE_ID
WHERE vw.STORE_ID = 1
AND tb.STATUS_FINISH = 'N'
AND vw.LOOKUP IN ($(Products));