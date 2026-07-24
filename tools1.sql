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
SET NOCOUNT ON;
IF OBJECT_ID('tempdb..#FileSpace') IS NOT NULL DROP TABLE #FileSpace;
CREATE TABLE #FileSpace(
    DatabaseName sysname, FileType nvarchar(60), LogicalName sysname,
    PhysicalPath nvarchar(260), Drive nvarchar(260) NULL,
    AllocatedMB decimal(18,1), UsedMB decimal(18,1),
    FreeInFileMB decimal(18,1), FreeInFilePct decimal(5,1),
    MaxSize varchar(24), AutoGrowth varchar(24),
    DriveTotalGB decimal(18,1) NULL, DriveFreeGB decimal(18,1) NULL
);

DECLARE @db sysname, @sql nvarchar(max);
DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases
    WHERE state_desc = 'ONLINE'        -- only online databases
      AND HAS_DBACCESS(name) = 1;      -- AND only ones this login can actually enter

OPEN db_cur;
FETCH NEXT FROM db_cur INTO @db;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @sql = N'USE ' + QUOTENAME(@db) + N';
        INSERT INTO #FileSpace (DatabaseName, FileType, LogicalName, PhysicalPath, Drive,
            AllocatedMB, UsedMB, FreeInFileMB, FreeInFilePct, MaxSize, AutoGrowth, DriveTotalGB, DriveFreeGB)
        SELECT
            DB_NAME(), df.type_desc, df.name, df.physical_name, vs.volume_mount_point,
            CAST(df.size/128.0 AS decimal(18,1)),
            CAST(FILEPROPERTY(df.name,''SpaceUsed'')/128.0 AS decimal(18,1)),
            CAST((df.size - FILEPROPERTY(df.name,''SpaceUsed''))/128.0 AS decimal(18,1)),
            CAST(100.0*(df.size - FILEPROPERTY(df.name,''SpaceUsed''))/NULLIF(df.size,0) AS decimal(5,1)),
            CASE df.max_size WHEN -1 THEN ''Unlimited'' WHEN 0 THEN ''No growth''
                 WHEN 268435456 THEN ''Unlimited''
                 ELSE CAST(CAST(df.max_size/128.0 AS decimal(18,1)) AS varchar(20))+'' MB'' END,
            CASE WHEN df.is_percent_growth=1 THEN CAST(df.growth AS varchar(10))+'' %''
                 ELSE CAST(CAST(df.growth/128.0 AS decimal(18,1)) AS varchar(20))+'' MB'' END,
            CAST(vs.total_bytes/1073741824.0 AS decimal(18,1)),
            CAST(vs.available_bytes/1073741824.0 AS decimal(18,1))
        FROM sys.database_files AS df
        OUTER APPLY sys.dm_os_volume_stats(DB_ID(), df.file_id) AS vs;';
        EXEC sys.sp_executesql @sql;
    END TRY
    BEGIN CATCH
        PRINT 'Skipped ' + QUOTENAME(@db) + ': ' + ERROR_MESSAGE();   -- one bad DB no longer kills the run
    END CATCH
    FETCH NEXT FROM db_cur INTO @db;
END
CLOSE db_cur; DEALLOCATE db_cur;

SELECT COUNT(*) AS RowsCollected FROM #FileSpace;   -- sanity check — should be > 0

SELECT DatabaseName, FileType, LogicalName, PhysicalPath, Drive,
       AllocatedMB, UsedMB, FreeInFileMB, FreeInFilePct, MaxSize, AutoGrowth, DriveFreeGB
FROM #FileSpace
ORDER BY DatabaseName, FileType, LogicalName;
