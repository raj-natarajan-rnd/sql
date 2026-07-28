/*==============================================================================
  RECONSTRUCT A PAST LOG-GROWTH EVENT (no custom job required)
  Correlates the default trace (autogrow events) with the error log
  (long transactions / log-full / severe errors) over the same window.
  Set @start / @end to the growth timeframe. Read-only.
==============================================================================*/
SET NOCOUNT ON;
DECLARE @start datetime = '2026-07-27T23:00:00';
DECLARE @end   datetime = '2026-07-28T02:00:00';

/*--- 1. DEFAULT TRACE: the growth events themselves (with size + duration) ---*/
PRINT '--- [1] Log/data autogrow events from default trace ---';
BEGIN TRY
    DECLARE @path nvarchar(260) = (SELECT path FROM sys.traces WHERE is_default = 1);
    IF @path IS NULL
        PRINT '  Default trace disabled — no autogrow history available.';
    ELSE
        SELECT
            t.StartTime,
            te.name                                       AS EventClass,      -- Log/Data File Auto Grow
            t.DatabaseName,
            t.FileName                                    AS LogicalFile,
            t.ApplicationName,                            -- often shows Informatica
            t.LoginName,
            t.IntegerData * 8 / 1024.0                    AS GrowthMB,         -- 8KB pages -> MB
            CAST(t.Duration / 1000.0 AS decimal(18,1))    AS Duration_ms,      -- long = autogrow stall (IFI)
            t.SPID
        FROM sys.fn_trace_gettable(@path, DEFAULT) AS t
        JOIN sys.trace_events te ON t.EventClass = te.trace_event_id
        WHERE te.name LIKE '%Auto Grow%'
          AND t.StartTime BETWEEN @start AND @end
        ORDER BY t.StartTime;
END TRY
BEGIN CATCH PRINT '  [1] SKIPPED: ' + ERROR_MESSAGE(); END CATCH

/*--- 2. DEFAULT TRACE: growth summary per database (how bad, how many events) ---*/
PRINT CHAR(13)+'--- [2] Growth summary per database in window ---';
BEGIN TRY
    IF @path IS NOT NULL
        SELECT
            t.DatabaseName,
            te.name                                       AS EventClass,
            COUNT(*)                                      AS GrowthEvents,
            SUM(t.IntegerData * 8 / 1024.0)               AS TotalGrowthMB,
            MIN(t.StartTime)                              AS FirstGrowth,
            MAX(t.StartTime)                              AS LastGrowth,
            CAST(SUM(t.Duration) / 1000.0 AS decimal(18,1)) AS TotalStall_ms
        FROM sys.fn_trace_gettable(@path, DEFAULT) AS t
        JOIN sys.trace_events te ON t.EventClass = te.trace_event_id
        WHERE te.name LIKE '%Auto Grow%'
          AND t.StartTime BETWEEN @start AND @end
        GROUP BY t.DatabaseName, te.name
        ORDER BY TotalGrowthMB DESC;
END TRY
BEGIN CATCH PRINT '  [2] SKIPPED: ' + ERROR_MESSAGE(); END CATCH

/*--- 3. ERROR LOG: the "why" — log-full, long transactions, severe errors ---*/
PRINT CHAR(13)+'--- [3] Correlated error-log entries in window ---';
BEGIN TRY
    IF OBJECT_ID('tempdb..#el') IS NOT NULL DROP TABLE #el;
    CREATE TABLE #el (LogDate datetime, ProcessInfo nvarchar(100), [Text] nvarchar(max));
    INSERT INTO #el EXEC sys.xp_readerrorlog 0, 1, NULL, NULL, @start, @end, N'ASC';

    SELECT LogDate, ProcessInfo,
           CASE
               WHEN [Text] LIKE '%9002%' OR [Text] LIKE '%log for database%is full%' THEN '>> LOG FULL (9002)'
               WHEN [Text] LIKE '%1105%' OR [Text] LIKE '%1101%'                      THEN '>> OUT OF SPACE'
               WHEN [Text] LIKE '%autogrow%' OR [Text] LIKE '%auto grow%'            THEN '>> AUTOGROW note'
               WHEN [Text] LIKE '%long-running transaction%'
                 OR [Text] LIKE '%oldest active transaction%'                        THEN '>> LONG TRANSACTION'
               WHEN [Text] LIKE '%1205%'                                             THEN '>> DEADLOCK'
               ELSE '' END                                                           AS Flag,
           [Text]
    FROM #el
    ORDER BY LogDate;
END TRY
BEGIN CATCH PRINT '  [3] SKIPPED: ' + ERROR_MESSAGE(); END CATCH

/*--- 4. Current state — is a long transaction STILL holding the log now? ---*/
PRINT CHAR(13)+'--- [4] Present log-reuse state (ACTIVE_TRANSACTION = still happening) ---';
BEGIN TRY
    SELECT name, recovery_model_desc, log_reuse_wait_desc, state_desc
    FROM sys.databases
    WHERE database_id > 4
    ORDER BY CASE WHEN log_reuse_wait_desc = 'ACTIVE_TRANSACTION' THEN 0 ELSE 1 END, name;
END TRY
BEGIN CATCH PRINT '  [4] SKIPPED: ' + ERROR_MESSAGE(); END CATCH
