USE [YourDatabaseName];   -- run in the target warehouse database
GO

/* ---- 1. Total number of statistics in the database ---- */
SELECT COUNT(*) AS TotalStatistics
FROM sys.stats AS s
INNER JOIN sys.objects AS o ON s.object_id = o.object_id
WHERE o.is_ms_shipped = 0        -- user objects only (excludes system stats)
  AND o.type IN ('U','V');       -- user tables + indexed views

/* ---- 2. Summary by last-updated year ---- */
;WITH StatInfo AS (
    SELECT STATS_DATE(s.object_id, s.stats_id) AS LastUpdated
    FROM sys.stats AS s
    INNER JOIN sys.objects AS o ON s.object_id = o.object_id
    WHERE o.is_ms_shipped = 0
      AND o.type IN ('U','V')
)
SELECT
    YEAR(LastUpdated)                                                AS LastUpdatedYear,   -- NULL = never updated
    COUNT(*)                                                         AS StatisticsCount,
    CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS decimal(5,1))   AS PctOfTotal
FROM StatInfo
GROUP BY YEAR(LastUpdated)
ORDER BY
    CASE WHEN YEAR(LastUpdated) IS NULL THEN 1 ELSE 0 END,   -- push "never updated" to the bottom
    YEAR(LastUpdated);

************
