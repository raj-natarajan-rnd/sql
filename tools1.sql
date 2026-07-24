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
;WITH StatInfo AS (
    SELECT
        sch.name AS SchemaName,
        o.name   AS TableName,
        STATS_DATE(s.object_id, s.stats_id) AS LastUpdated
    FROM sys.stats AS s
    INNER JOIN sys.objects AS o   ON s.object_id = o.object_id
    INNER JOIN sys.schemas AS sch ON o.schema_id = sch.schema_id
    WHERE o.is_ms_shipped = 0 AND o.type IN ('U','V')
)
SELECT
    SchemaName + '.' + TableName                                       AS [Table],
    COUNT(*)                                                           AS StatisticsCount,
    MIN(LastUpdated)                                                   AS OldestStatUpdate,
    MAX(LastUpdated)                                                   AS NewestStatUpdate,
    SUM(CASE WHEN LastUpdated < DATEADD(YEAR,-1,GETDATE())
             OR LastUpdated IS NULL THEN 1 ELSE 0 END)                 AS StatsOlderThan1Year
FROM StatInfo
GROUP BY SchemaName, TableName
ORDER BY MIN(LastUpdated) ASC;   -- never-updated (NULL) and 2019 tables surface first
********
/* ---- All database files: path, drive, size, growth ---- */
SELECT
    DB_NAME(mf.database_id)                                          AS DatabaseName,
    mf.type_desc                                                     AS FileType,     -- ROWS = data, LOG, FILESTREAM
    mf.name                                                          AS LogicalName,
    mf.physical_name                                                 AS PhysicalPath,
    vs.volume_mount_point                                            AS Drive,        -- NULL if DB offline
    vs.logical_volume_name                                           AS VolumeLabel,
    CAST(mf.size / 128.0 AS decimal(18,1))                           AS FileSizeMB,   -- size is in 8 KB pages
    CASE mf.max_size
         WHEN -1 THEN 'Unlimited'
         WHEN  0 THEN 'No growth'
         WHEN 268435456 THEN 'Unlimited (log)'
         ELSE CAST(CAST(mf.max_size / 128.0 AS decimal(18,1)) AS varchar(20)) + ' MB'
    END                                                             AS MaxSize,
    CASE WHEN mf.is_percent_growth = 1
         THEN CAST(mf.growth AS varchar(10)) + ' %'
         ELSE CAST(CAST(mf.growth / 128.0 AS decimal(18,1)) AS varchar(20)) + ' MB'
    END                                                             AS AutoGrowth,
    CAST(vs.available_bytes / 1073741824.0 AS decimal(18,1))        AS DriveFreeGB,
    CAST(vs.total_bytes     / 1073741824.0 AS decimal(18,1))        AS DriveTotalGB
FROM sys.master_files AS mf
OUTER APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) AS vs   -- OUTER so offline DBs still list
ORDER BY DatabaseName, mf.type_desc, mf.file_id;
