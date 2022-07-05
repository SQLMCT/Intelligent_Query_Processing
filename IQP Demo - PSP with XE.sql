DBCC TRACEON (11091, 12619, -1);
GO

-- Setup environment
USE [master]
GO
ALTER DATABASE [PropertyMLS] SET COMPATIBILITY_LEVEL = 160;
GO
ALTER DATABASE [PropertyMLS] SET QUERY_STORE = ON
GO
ALTER DATABASE [PropertyMLS] SET QUERY_STORE (OPERATION_MODE = READ_WRITE, DATA_FLUSH_INTERVAL_SECONDS = 60, INTERVAL_LENGTH_MINUTES = 1, QUERY_CAPTURE_MODE = ALL)
GO

USE [PropertyMLS]
GO
ALTER DATABASE [PropertyMLS] SET QUERY_STORE CLEAR ALL
GO
ALTER DATABASE SCOPED CONFIGURATION CLEAR PROCEDURE_CACHE  
GO
--ALTER DATABASE SCOPED CONFIGURATION SET PARAMETER_SENSITIVE_PLAN_OPTIMIZATION = ON
--GO

EXEC sp_helptext PropertySearchByAgent
GO

-- See stats
SELECT sh.* 
FROM sys.stats AS s
CROSS APPLY sys.dm_db_stats_histogram(s.object_id, s.stats_id) AS sh
WHERE name = 'NCI_Property_AgentId' AND s.object_id = OBJECT_ID('dbo.Property')
GO

--Setup XE capture
IF EXISTS (SELECT * FROM sys.server_event_sessions WHERE name = 'PSP')
DROP EVENT SESSION [PSP] ON SERVER;
GO
CREATE EVENT SESSION [PSP] ON SERVER 
ADD EVENT sqlserver.parameter_sensitive_plan_optimization(
    ACTION(sqlserver.query_hash_signed,sqlserver.query_plan_hash_signed,sqlserver.sql_text)),
ADD EVENT sqlserver.parameter_sensitive_plan_testing(
    ACTION(sqlserver.query_hash_signed,sqlserver.query_plan_hash_signed,sqlserver.sql_text))
WITH (MAX_MEMORY=4096 KB,EVENT_RETENTION_MODE=NO_EVENT_LOSS,MAX_DISPATCH_LATENCY=1 SECONDS,MAX_EVENT_SIZE=0 KB,MEMORY_PARTITION_MODE=NONE,TRACK_CAUSALITY=OFF,STARTUP_STATE=OFF)
GO

-- Start XE
ALTER EVENT SESSION [PSP] ON SERVER
STATE = START;
GO

-- Kick this one off in a diff session as it takes ~100s
-- Agents with millions of properties
EXEC [dbo].[PropertySearchByAgent] 2;
GO

-- Agents with few properties
EXEC [dbo].[PropertySearchByAgent] 4;
GO 3
EXEC [dbo].[PropertySearchByAgent] 8;
GO 3

-- Stop XE
ALTER EVENT SESSION [PSP] ON SERVER
STATE = STOP;
GO

SELECT usecounts, plan_handle, text
FROM sys.dm_exec_cached_plans 
CROSS APPLY sys.dm_exec_sql_text (plan_handle)
WHERE text LIKE '%Bathrooms%'
	AND objtype = 'Prepared';
GO

SELECT cp.usecounts,  
    SUBSTRING(qt.text,qs.statement_start_offset/2 +1,   
                 (CASE WHEN qs.statement_end_offset = -1   
                       THEN LEN(CONVERT(nvarchar(max), qt.text)) * 2   
                       ELSE qs.statement_end_offset end -  
                            qs.statement_start_offset  
                 )/2  
             ) AS query_text,
    qs.query_hash,
	qs.query_plan_hash,
	cp.plan_handle,
	qs.sql_handle,
	qp.query_plan,
	qt.text
FROM sys.dm_exec_cached_plans AS cp
INNER JOIN sys.dm_exec_query_stats AS qs
	ON cp.plan_handle = qs.plan_handle
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS qt
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
WHERE qt.text like '%SELECT PropertyId%'   
ORDER BY qs.execution_count DESC; 
GO

SELECT qs.query_plan_hash,
	qs.query_hash,
	qs.execution_count,  
	qs.max_elapsed_time,
	qs.max_rows,
	qs.last_dop,
	qs.last_grant_kb,
	qs.last_worker_time,
	qp.query_plan
FROM sys.dm_exec_query_stats AS qs   
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS qt
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
WHERE qt.text like '%SELECT PropertyId%'  
ORDER BY qs.execution_count DESC; 
GO


-- Time permits, see data in QS UI

EXEC sp_query_store_flush_db;
GO
SELECT * FROM sys.query_store_query_variant
GO
SELECT DISTINCT qsq.* 
FROM sys.query_store_query AS qsq
INNER JOIN sys.dm_exec_query_stats AS qs ON qsq.query_hash = qs.query_hash
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS qt
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
WHERE qt.text like '%SELECT PropertyId%' 
GO