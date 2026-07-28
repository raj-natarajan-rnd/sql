/*==============================================================================
  CONNECTION-ERROR DIAGNOSTIC — 0x2746 / 10054 (reset) and 17828 (bad prelogin)
  Both are CONNECTION-LAYER failures (pre-login), so for most there is NO query
  to find — the goal is WHO is calling (client IP + app). An empty sql_text is
  itself the confirmation the failure happened before any batch ran.
  Read-only. Sections 1-3 are safe to run as-is.
==============================================================================*/
SET NOCOUNT ON;

/*------------------------------------------------------------------
  1. ERROR LOG — isolate these errors, extract client IP, count by who/when
------------------------------------------------------------------*/
PRINT '--- [1] Error log: connection failures ---';
IF OBJECT_ID('tempdb..#log') IS NOT NULL DROP TABLE #log;
CREATE TABLE #log (LogDate datetime, ProcessInfo nvarchar(100), [Text] nvarchar(max));
BEGIN TRY
    INSERT INTO #log EXEC sys.xp_readerrorlog 0, 1;          -- current log
    INSERT INTO #log EXEC sys.xp_readerrorlog 1, 1;          -- prev archive (in case it cycled); remove if it errors
END TRY
BEGIN CATCH PRINT '  note: ' + ERROR_MESSAGE(); END CATCH

IF OBJECT_ID('tempdb..#net') IS NOT NULL DROP TABLE #net;
SELECT l.LogDate, l.ProcessInfo, k.ErrorKind, ip.ClientIP, l.[Text]
INTO #net
FROM #log l
CROSS APPLY (SELECT CASE
        WHEN l.[Text] LIKE '%17828%' OR l.[Text] LIKE '%prelogin packet%' THEN '17828 - invalid prelogin'
        WHEN l.[Text] LIKE '%0x2746%' OR l.[Text] LIKE '%10054%'          THEN '0x2746 / 10054 - connection reset'
        WHEN l.[Text] LIKE '%input stream from the network%'              THEN 'network read error'
        ELSE 'other' END AS ErrorKind) k
CROSS APPLY (SELECT CASE WHEN CHARINDEX('CLIENT: ', l.[Text]) > 0
        THEN LEFT(x.tail, NULLIF(CHARINDEX(']', x.tail + ']'), 0) - 1) END AS ClientIP
        FROM (SELECT SUBSTRING(l.[Text], CHARINDEX('CLIENT: ', l.[Text]) + 8, 48) AS tail) x) ip
WHERE l.[Text] LIKE '%17828%' OR l.[Text] LIKE '%prelogin packet%'
   OR l.[Text] LIKE '%0x2746%' OR l.[Text] LIKE '%10054%'
   OR l.[Text] LIKE '%input stream from the network%';

PRINT '  [1a] WHO is calling + how often (start here):';
SELECT ClientIP, ErrorKind, COUNT(*) AS Occurrences,
       MIN(LogDate) AS FirstSeen, MAX(LogDate) AS LastSeen
FROM #net GROUP BY ClientIP, ErrorKind ORDER BY Occurrences DESC;

PRINT '  [1b] Per-minute cadence (confirms the "every minute" pattern):';
SELECT CONVERT(char(16), LogDate, 120) AS Minute, ErrorKind, COUNT(*) AS Hits
FROM #net GROUP BY CONVERT(char(16), LogDate, 120), ErrorKind ORDER BY Minute;

PRINT '  [1c] Every occurrence (detail):';
SELECT LogDate, ErrorKind, ClientIP, [Text] FROM #net ORDER BY LogDate;

/*------------------------------------------------------------------
  2. CONNECTIVITY RING BUFFER — connection stage, OS/SNI error, remote host.
     Spid = -1 or 0 means NO session was created = proof no query ran.
     (Memory-resident, ~1000 records; for the full overnight window use system_health.)
------------------------------------------------------------------*/
PRINT CHAR(13)+'--- [2] Connectivity ring buffer ---';
BEGIN TRY
    SELECT TOP 200
        DATEADD(SECOND, (rb.[timestamp] - inf.ms_ticks)/1000, GETDATE())              AS EventTime_Approx,
        c.rx.value('(Record/ConnectivityTraceRecord/RecordType)[1]','varchar(40)')    AS RecordType,
        c.rx.value('(Record/ConnectivityTraceRecord/RecordSource)[1]','varchar(40)')  AS Source,
        c.rx.value('(Record/ConnectivityTraceRecord/Spid)[1]','int')                  AS Spid,
        c.rx.value('(Record/ConnectivityTraceRecord/OSError)[1]','int')               AS OSError,     -- 10054 = 0x2746
        c.rx.value('(Record/ConnectivityTraceRecord/SniConsumerError)[1]','int')      AS SniError,
        c.rx.value('(Record/ConnectivityTraceRecord/RemoteHost)[1]','varchar(48)')    AS ClientIP,
        c.rx.value('(Record/ConnectivityTraceRecord/RemotePort)[1]','int')            AS ClientPort
    FROM sys.dm_os_ring_buffers rb
    CROSS JOIN (SELECT ms_ticks FROM sys.dm_os_sys_info) inf
    CROSS APPLY (SELECT TRY_CAST(rb.record AS xml) AS rx) c
    WHERE rb.ring_buffer_type = 'RING_BUFFER_CONNECTIVITY'
    ORDER BY EventTime_Approx DESC;
END TRY
BEGIN CATCH PRINT '  [2] SKIPPED: ' + ERROR_MESSAGE(); END CATCH

/*------------------------------------------------------------------
  3. LIVE CONNECTIONS — run this section a few times to catch the every-minute
     offender in the act. program_name often names the tool; most_recent_sql
     is usually NULL for these (pre-login failures never ran a batch).
------------------------------------------------------------------*/
PRINT CHAR(13)+'--- [3] Current connections snapshot (re-run to catch it live) ---';
BEGIN TRY
    SELECT
        c.session_id, c.client_net_address, c.client_tcp_port, c.connect_time,
        c.protocol_type, c.encrypt_option,
        s.login_name, s.host_name, s.program_name, s.status,
        t.text AS most_recent_sql
    FROM sys.dm_exec_connections c
    LEFT JOIN sys.dm_exec_sessions s ON c.session_id = s.session_id
    OUTER APPLY sys.dm_exec_sql_text(c.most_recent_sql_handle) t
    WHERE c.session_id <> @@SPID
    ORDER BY c.connect_time DESC;
END TRY
BEGIN CATCH PRINT '  [3] SKIPPED: ' + ERROR_MESSAGE(); END CATCH

PRINT CHAR(13)+'=== Read [1a] first: a single IP hammering every minute is your source. ===';

/*==============================================================================
  4. OPTIONAL — guaranteed live capture of the NEXT occurrence, with caller + any
     SQL text. Creates a server-side XE session, so it is COMMENTED OUT by design.
     Uncomment all four steps, run step A+B, wait ~2 min, then run C to read, D to clean up.
--------------------------------------------------------------------------------
-- A) CREATE:
CREATE EVENT SESSION [xe_conn_failures] ON SERVER
ADD EVENT sqlserver.error_reported (
    ACTION (sqlserver.client_hostname, sqlserver.client_app_name, sqlserver.session_id,
            sqlserver.server_principal_name, sqlserver.database_name,
            sqlserver.client_connection_id, sqlserver.sql_text)
    WHERE (severity >= 20 OR error_number IN (17828, 17830, 17832, 18056))),
ADD EVENT sqlserver.connectivity_ring_buffer_recorded ()
ADD TARGET package0.event_file (SET filename = N'xe_conn_failures', max_file_size = 50, max_rollover_files = 4)
WITH (MAX_MEMORY = 8MB, MAX_DISPATCH_LATENCY = 5 SECONDS, STARTUP_STATE = OFF);

-- B) START:
ALTER EVENT SESSION [xe_conn_failures] ON SERVER STATE = START;

-- C) READ (after waiting a couple of minutes):
SELECT
    DATEADD(MINUTE, DATEDIFF(MINUTE, GETUTCDATE(), SYSDATETIME()),
            x.value('(event/@timestamp)[1]','datetime2'))                     AS EventTime_Local,
    x.value('(event/@name)[1]','varchar(60)')                                 AS event_name,
    x.value('(event/data[@name="error_number"]/value)[1]','int')             AS error_number,
    x.value('(event/action[@name="client_app_name"]/value)[1]','varchar(128)') AS client_app,
    x.value('(event/action[@name="client_hostname"]/value)[1]','varchar(128)') AS client_host,
    x.value('(event/action[@name="server_principal_name"]/value)[1]','varchar(128)') AS login_name,
    x.value('(event/action[@name="sql_text"]/value)[1]','nvarchar(max)')      AS sql_text,   -- usually NULL for these
    x.query('.')                                                              AS event_xml
FROM (SELECT CAST(event_data AS xml) AS x
      FROM sys.fn_xe_file_target_read_file('xe_conn_failures*.xel', NULL, NULL, NULL)) e
ORDER BY EventTime_Local;

-- D) CLEAN UP:
ALTER EVENT SESSION [xe_conn_failures] ON SERVER STATE = STOP;
DROP EVENT SESSION [xe_conn_failures] ON SERVER;
==============================================================================*/
