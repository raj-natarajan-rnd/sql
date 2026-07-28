/*==============================================================================
  OVERNIGHT LOAD FAILURE — CONSOLIDATED DIAGNOSTIC
  Window: 7/27/2026 11:00 PM  ->  7/28/2026 2:00 AM
  Read-only. Each section is fault-isolated; a failure in one prints and continues.
  Needs VIEW SERVER STATE, msdb access, and rights for xp_readerrorlog.
==============================================================================*/
SET NOCOUNT ON;

DECLARE @start   datetime  = '2026-07-27T23:00:00';
DECLARE @end     datetime  = '2026-07-28T02:00:00';
DECLARE @start2  datetime2 = '2026-07-27T23:00:00';
DECLARE @end2    datetime2 = '2026-07-28T02:00:00';
DECLARE @utcOff  int       = DATEDIFF(MINUTE, GETUTCDATE(), SYSDATETIME());  -- for UTC-stamped XE

PRINT '================ LOAD FAILURE DIAGNOSTIC ================';
PRINT 'Window: ' + CONVERT(varchar(30), @start, 120) + '  ->  ' + CONVERT(varchar(30), @end, 120);
PRINT '========================================================';

/*------------------------------------------------------------------
  1. TRIAGE — did the instance restart / fail over during the window?
     If StartupInWindow = YES, that alone killed the load and wiped the DMVs.
------------------------------------------------------------------*/
BEGIN TRY
    PRINT CHAR(13)+'--- [1] Instance start time (restart check) ---';
    SELECT
        sqlserver_start_time,
        CASE WHEN sqlserver_start_time BETWEEN @start AND @end
             THEN 'YES — service restarted mid-window; likely root cause'
             ELSE 'No restart inside window' END AS StartupInWindow
    FROM sys.dm_os_sys_info;
END TRY
BEGIN CATCH PRINT '  [1] SKIPPED: ' + ERROR_MESSAGE(); END CATCH

/*------------------------------------------------------------------
  2. SQL SERVER ERROR LOG for the window (current log only).
     Watch for 9002 (log full), 1105/1101 (out of space), 1205 (deadlock),
     severity 17+. If the instance restarted, also read archives 1 and 2.
------------------------------------------------------------------*/
BEGIN TRY
    PRINT CHAR(13)+'--- [2] SQL Server error log (current) ---';
    IF OBJECT_ID('tempdb..#err') IS NOT NULL DROP TABLE #err;
    CREATE TABLE #err (LogDate datetime, ProcessInfo nvarchar(100), [Text] nvarchar(max));
    INSERT INTO #err EXEC sys.xp_readerrorlog 0, 1, NULL, NULL, @start, @end, N'ASC';
    SELECT LogDate, ProcessInfo, [Text] FROM #err ORDER BY LogDate;
    PRINT '  (If instance restarted in-window, rerun xp_readerrorlog with 1st arg = 1 and 2 for archived logs.)';
END TRY
BEGIN CATCH PRINT '  [2] SKIPPED: ' + ERROR_MESSAGE(); END CATCH

/*------------------------------------------------------------------
  3. system_health Extended Events — deadlock graphs, severe errors,
     memory-pressure and long-IO signals. Persists to disk automatically.
------------------------------------------------------------------*/
BEGIN TRY
    PRINT CHAR(13)+'--- [3] system_health events in window ---';
    ;WITH xe AS (
        SELECT CAST(event_data AS xml) AS x
        FROM sys.fn_xe_file_target_read_file('system_health*.xel', NULL, NULL, NULL)
    )
    SELECT
        x.value('(event/@name)[1]','varchar(60)')                            AS event_name,
        DATEADD(MINUTE, @utcOff, x.value('(event/@timestamp)[1]','datetime2')) AS event_time_local,
        x.value('(event/data[@name="error_number"]/value)[1]','int')         AS error_number,
        x.value('(event/data[@name="severity"]/value)[1]','int')             AS severity,
        x.value('(event/data[@name="message"]/value)[1]','nvarchar(2000)')   AS message,
        x.query('.')                                                         AS event_xml
    FROM xe
    WHERE DATEADD(MINUTE, @utcOff, x.value('(event/@timestamp)[1]','datetime2')) BETWEEN @start2 AND @end2
    ORDER BY event_time_local;
    PRINT '  (Look for xml_deadlock_report and error_reported severity >= 20; full graph is in event_xml.)';
END TRY
BEGIN CATCH PRINT '  [3] SKIPPED: ' + ERROR_MESSAGE(); END CATCH

/*------------------------------------------------------------------
  4. DEFAULT TRACE — autogrow events (with duration), sort/hash warnings,
     errors. A burst of Log File Auto Grow ending abruptly = the F2/F3
     single-transaction log-fill fingerprint. Long Duration_ms = IFI stalls.
------------------------------------------------------------------*/
BEGIN TRY
    PRINT CHAR(13)+'--- [4] Default trace events in window ---';
    DECLARE @tracePath nvarchar(260) = (SELECT path FROM sys.traces WHERE is_default = 1);
    IF @tracePath IS NULL
        PRINT '  Default trace is disabled — no data.';
    ELSE
        SELECT
            t.StartTime,
            te.name                                   AS EventClass,
            t.DatabaseName, t.FileName,
            t.ApplicationName, t.LoginName,
            t.TextData,
            t.IntegerData                             AS Growth_8KB_Pages,
            CAST(t.Duration/1000.0 AS decimal(18,1))  AS Duration_ms
        FROM sys.fn_trace_gettable(@tracePath, DEFAULT) AS t
        JOIN sys.trace_events te ON t.EventClass = te.trace_event_id
        WHERE t.StartTime BETWEEN @start AND @end
        ORDER BY t.StartTime;
END TRY
BEGIN CATCH PRINT '  [4] SKIPPED: ' + ERROR_MESSAGE(); END CATCH

/*------------------------------------------------------------------
  5. SQL AGENT JOB HISTORY in window — catches a job-wrapped load or a
     maintenance job (backup / index rebuild) colliding with it.
     Blank = no Agent job ran (Informatica usually runs outside Agent).
------------------------------------------------------------------*/
BEGIN TRY
    PRINT CHAR(13)+'--- [5] SQL Agent job runs in window ---';
    SELECT
        j.name                                          AS JobName,
        h.step_id, h.step_name,
        msdb.dbo.agent_datetime(h.run_date, h.run_time) AS RunDateTime,
        CASE h.run_status WHEN 0 THEN 'FAILED' WHEN 1 THEN 'Succeeded'
                          WHEN 2 THEN 'Retry'  WHEN 3 THEN 'Canceled'
                          WHEN 4 THEN 'In progress' END AS RunStatus,
        h.message
    FROM msdb.dbo.sysjobhistory h
    JOIN msdb.dbo.sysjobs j ON h.job_id = j.job_id
    WHERE msdb.dbo.agent_datetime(h.run_date, h.run_time) BETWEEN @start AND @end
    ORDER BY RunDateTime;
END TRY
BEGIN CATCH PRINT '  [5] SKIPPED: ' + ERROR_MESSAGE(); END CATCH

/*------------------------------------------------------------------
  6. AFTERMATH — current log-reuse/truncation state, I/O-error pages,
     and any backup that overlapped the window.
     log_reuse_wait_desc = ACTIVE_TRANSACTION is the F2/F3 fingerprint.
------------------------------------------------------------------*/
BEGIN TRY
    PRINT CHAR(13)+'--- [6a] Log reuse / recovery state (now) ---';
    SELECT name, recovery_model_desc, log_reuse_wait_desc, state_desc
    FROM sys.databases WHERE database_id > 4 ORDER BY name;
END TRY
BEGIN CATCH PRINT '  [6a] SKIPPED: ' + ERROR_MESSAGE(); END CATCH

BEGIN TRY
    PRINT CHAR(13)+'--- [6b] Suspect (I/O-error) pages ---';
    IF EXISTS (SELECT 1 FROM msdb.dbo.suspect_pages)
        SELECT DB_NAME(database_id) AS DatabaseName, file_id, page_id, event_type, error_count, last_update_date
        FROM msdb.dbo.suspect_pages ORDER BY last_update_date DESC;
    ELSE PRINT '  None — clean.';
END TRY
BEGIN CATCH PRINT '  [6b] SKIPPED: ' + ERROR_MESSAGE(); END CATCH

BEGIN TRY
    PRINT CHAR(13)+'--- [6c] Backups overlapping the window ---';
    SELECT database_name,
           CASE type WHEN 'D' THEN 'Full' WHEN 'I' THEN 'Diff' WHEN 'L' THEN 'Log'
                     WHEN 'F' THEN 'FileGroup' ELSE type END AS BackupType,
           backup_start_date, backup_finish_date
    FROM msdb.dbo.backupset
    WHERE backup_start_date < @end AND backup_finish_date > @start
    ORDER BY backup_start_date;
END TRY
BEGIN CATCH PRINT '  [6c] SKIPPED: ' + ERROR_MESSAGE(); END CATCH

PRINT CHAR(13)+'================ END OF DIAGNOSTIC ================';
