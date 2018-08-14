/* Cleanup existing versions */
IF EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[dbo].[sp_sizeoptimiser]'))
	BEGIN
		DROP PROCEDURE [dbo].[sp_sizeoptimiser];
	END

IF  EXISTS (SELECT * FROM sys.types st JOIN sys.schemas ss ON st.schema_id = ss.schema_id WHERE st.name = N'SizeOptimiserTableType' AND ss.name = N'dbo')
	BEGIN
		DROP TYPE [dbo].[SizeOptimiserTableType]
	END
GO

/**************************************************************/
/* Create user defined table type for database list parameter */
/**************************************************************/
IF NOT EXISTS (SELECT * FROM sys.types st JOIN sys.schemas ss ON st.schema_id = ss.schema_id WHERE st.name = N'SizeOptimiserTableType' AND ss.name = N'dbo')
	CREATE TYPE [dbo].[SizeOptimiserTableType] AS TABLE(
		[database_name] [sysname] NOT NULL,
		PRIMARY KEY CLUSTERED ([database_name] ASC)WITH (IGNORE_DUP_KEY = OFF))
GO

/***************************/
/* Create stored procedure */
/***************************/
IF NOT EXISTS(SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[dbo].[sp_sizeoptimiser]'))
	BEGIN
		EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [dbo].[sp_sizeoptimiser] AS';
	END;
GO

ALTER PROCEDURE [dbo].[sp_sizeoptimiser] 
				@IndexNumThreshold INT = 10,
				@IncludeDatabases [dbo].[SizeOptimiserTableType] READONLY,
				@ExcludeDatabases [dbo].[SizeOptimiserTableType] READONLY,
				@IncludeSysDatabases BIT = 0,
				@IncludeSSRSDatabases BIT = 0,
				@IsExpress BIT = NULL

WITH RECOMPILE
AS
	SET NOCOUNT ON;
	SET ANSI_NULLS ON;
	SET QUOTED_IDENTIFIER ON; 
	
	BEGIN TRY

		DECLARE @HasSparse BIT = 0,
				@Debug BIT = 0,
				@HasTempStat BIT = 0;
		DECLARE @MajorVersion TINYINT,
				@CheckNumber TINYINT = 0;
		DECLARE @MinorVersion INT;
		DECLARE @LastUpdated NVARCHAR(20) = '2018-07-16';
		DECLARE @Version NVARCHAR(50) = CAST(SERVERPROPERTY('PRODUCTVERSION') AS NVARCHAR)
		DECLARE @CheckSQL NVARCHAR(MAX) = N'',
				@Msg NVARCHAR(MAX) = N'';
		
		/* Validate @IndexNumThreshold */
		IF (@IndexNumThreshold < 1 OR @IndexNumThreshold > 999)
			BEGIN
				SET @msg = '@IndexNumThreshold must be between 1 and 999.';
				RAISERROR(@msg, 16, 1);
			END
			
		/* Validate database list */
		IF (SELECT COUNT(*) FROM @IncludeDatabases) >= 1 AND (SELECT COUNT(*) FROM @ExcludeDatabases) >= 1
			BEGIN
				SET @msg = 'Both @IncludeDatabases and @ExcludeDatabases cannot be specified.';
				RAISERROR(@msg, 16, 1);
			END
		
		CREATE TABLE #Databases (
			[database_name] SYSNAME NOT NULL);
	
		/*Build database list if no parameters set*/
		IF (SELECT COUNT(*) FROM @IncludeDatabases) = 0 AND (SELECT COUNT(*) FROM @ExcludeDatabases) = 0
			BEGIN
				INSERT INTO #Databases
				SELECT [d].[name]
				FROM [sys].[databases] AS [d]
				WHERE ([d].[database_id] > 4 OR @IncludeSysDatabases = 1)
					AND ([d].[name] NOT IN ('ReportServer', 'ReportServerTempDB') OR @IncludeSSRSDatabases = 1)
					AND DATABASEPROPERTYEX([d].[name], 'UPDATEABILITY') = N'READ_WRITE'
					AND DATABASEPROPERTYEX([d].[name], 'USERACCESS') = N'MULTI_USER'
					AND DATABASEPROPERTYEX([d].[name], 'STATUS') = N'ONLINE';
			END;
		/*Build database list from @IncludeDatabases */
		ELSE IF (SELECT COUNT(*) FROM @IncludeDatabases) >= 1
			BEGIN
				INSERT INTO #Databases
				SELECT [database_name]
				FROM @IncludeDatabases AS [d]
					INNER JOIN [sys].[databases] AS [sd] ON [sd].[name] = REPLACE(REPLACE([d].[database_name], '[', ''), ']', '')
				WHERE DATABASEPROPERTYEX([sd].[name], 'UPDATEABILITY') = N'READ_WRITE'
					AND DATABASEPROPERTYEX([sd].[name], 'USERACCESS') = N'MULTI_USER'
					AND DATABASEPROPERTYEX([sd].[name], 'STATUS') = N'ONLINE';
					
				IF (SELECT COUNT(*) FROM @IncludeDatabases) > (SELECT COUNT(*) FROM #Databases)
					BEGIN
						DECLARE @ErrorDatabaseList NVARCHAR(MAX);

						WITH ErrorDatabase AS(
							SELECT [database_name]
							FROM @IncludeDatabases
							EXCEPT
							SELECT [database_name]
							FROM #Databases)

						SELECT @ErrorDatabaseList = ISNULL(@ErrorDatabaseList + N', ' + [database_name], [database_name])
						FROM ErrorDatabase;

						SET @msg = 'Supplied databases do not exist or are not accessible: ' + @ErrorDatabaseList + '.';
						RAISERROR(@msg, 16, 1);
					END;
			END;
		/*Build database list from @ExcludeDatabases */
		ELSE IF (SELECT COUNT(*) FROM @ExcludeDatabases) >= 1
			BEGIN
				INSERT INTO #Databases
				SELECT [sd].[name]
				FROM [sys].[databases] AS [sd] 
				WHERE NOT EXISTS (SELECT [d].[database_name] FROM @IncludeDatabases AS [d] WHERE [sd].[name] = REPLACE(REPLACE([d].[database_name], '[', ''), ']', ''))
					AND DATABASEPROPERTYEX([sd].[name], 'UPDATEABILITY') = N'READ_WRITE'
					AND DATABASEPROPERTYEX([sd].[name], 'USERACCESS') = N'MULTI_USER'
					AND DATABASEPROPERTYEX([sd].[name], 'STATUS') = N'ONLINE';
			END

		/* Find edition */
		IF(@IsExpress IS NULL AND CAST(SERVERPROPERTY('Edition') AS VARCHAR(50)) LIKE '%express%')
			BEGIN
				SET @isExpress = 1;
			END;

		/* Find Version */
		DECLARE @tempVersion NVARCHAR(100);
		
		SET @MajorVersion = (SELECT CAST(LEFT(@version, CHARINDEX('.', @version, 0)-1) AS INT));
		SET @tempVersion = (SELECT RIGHT(@version, LEN(@version) - CHARINDEX('.', @version, 0)));
		SET @tempVersion = (SELECT RIGHT(@tempVersion, LEN(@tempVersion) - CHARINDEX('.', @tempVersion, 0)));
		SET @minorVersion = (SELECT LEFT(@tempVersion,CHARINDEX('.', @tempVersion, 0) -1));

		/* Check for Sparse Columns feature */
		IF 1 = (SELECT COUNT(*) FROM sys.all_columns AS ac WHERE ac.name = 'is_sparse' AND OBJECT_NAME(ac.object_id) = 'all_columns')
			 BEGIN
				 SET @hasSparse = 1;
			 END;

		/*Check for is_temp value on statistics*/
		IF 1 = (SELECT COUNT(*) FROM sys.all_columns AS ac WHERE ac.name = 'is_temporary' AND OBJECT_NAME(ac.object_id) = 'all_columns')
			 BEGIN
				 SET @hasTempStat = 1;
			 END;

		/* Print info */
		SET @msg = 'sp_OptiMiser';
		RAISERROR(@msg, 10, 1) WITH NOWAIT;
		SET @msg = '------------';
		RAISERROR(@msg, 10, 1) WITH NOWAIT;
		SET @msg = '';
		RAISERROR(@msg, 10, 1) WITH NOWAIT;
		SET @msg = 'Time:				' + CAST(GETDATE() AS NVARCHAR(50))
		RAISERROR(@msg, 10, 1) WITH NOWAIT;
		SET @msg = 'Express Edition:	' + CAST(@isExpress AS CHAR(1))
		RAISERROR(@msg, 10, 1) WITH NOWAIT;
		SET @msg = 'SQL Major Version:	' + CAST(@MajorVersion AS VARCHAR(5));
		RAISERROR(@msg, 10, 1) WITH NOWAIT;
		SET @msg = 'SQL Minor Version:	' + CAST(@minorVersion AS VARCHAR(20));
		RAISERROR(@msg, 10, 1) WITH NOWAIT;
		SET @msg = 'Sparse Columns Feature:		' + CAST(@hasSparse AS CHAR(1));
		RAISERROR(@msg, 10, 1) WITH NOWAIT;
		SET @msg = '';
		RAISERROR(@msg, 10, 1) WITH NOWAIT;
		SET @msg = 'Building results table...';
		RAISERROR(@msg, 10, 1) WITH NOWAIT;

		/*Build results table */
		IF OBJECT_ID(N'tempdb..#results') IS NOT NULL
			BEGIN
				DROP TABLE #results;
			END;

		CREATE TABLE #results
				([check_num]	INT NOT NULL,
				[check_type]	NVARCHAR(50) NOT NULL,
				[db_name]		SYSNAME NOT NULL,
				[obj_type]		SYSNAME NOT NULL,
				[obj_name]		SYSNAME NOT NULL,
				[col_name]		SYSNAME NULL,
				[message]		NVARCHAR(500) NULL,
				[ref_link]		NVARCHAR(500) NULL);

		/* Header row */
		INSERT INTO #results ([check_num], [check_type], [obj_type], [db_name], [obj_name], [col_name], [message], [ref_link])
		SELECT	@CheckNumber ,
				N'Let''s do this',
				N'Vroom, vroom',
				N'beep boop',
				N'Off to the races!',
				N'Ready, set, go!',
				N'Last Updated '+ @lastUpdated,
				N'http://lowlydba.com/ExpressSQL/';

		RAISERROR('Running size checks...', 10, 1) WITH NOWAIT;
		RAISERROR('', 10, 1) WITH NOWAIT;

		/* Date & Time Data Type Usage */
		SET @CheckNumber = @CheckNumber + 1;
		SET @msg = N'Check ' + CAST(@CheckNumber AS NVARCHAR(3)) + ' - Date and Time Data Types';
		RAISERROR(@msg, 10, 1) WITH NOWAIT;
		BEGIN
			SET @checkSQL = N'';
			SELECT @checkSQL = @checkSQL + N'USE ' + [database_name] + N'; 
								INSERT INTO #results ([check_num], [check_type], [obj_type], [db_name], [obj_name], [col_name], [message], [ref_link])
								SELECT @CheckNumber, 
								N''Data Types'', 
								N''USER_TABLE'', 
								QUOTENAME(DB_NAME()),
								QUOTENAME(SCHEMA_NAME(t.schema_id)) + ''.'' + QUOTENAME(t.name), 
								QUOTENAME(c.name), 
								N''Columns storing date or time should use a temporal specific data type, but this column is using '' + ty.name + ''.'', 
								N''http://lowlydba.com/ExpressSQL/#time-based-formats''
								FROM sys.columns as c
									inner join sys.tables as t on t.object_id = c.object_id
									inner join sys.types as ty on ty.user_type_id = c.user_type_id
								WHERE c.is_identity = 0 --exclude identity cols
									AND t.is_ms_shipped = 0 --exclude sys table
									AND (c.name LIKE ''%date%'' OR c.name LIKE ''%time%'') 
									AND [c].[name] NOT LIKE ''%days%''
									AND ty.name NOT IN (''datetime'', ''datetime2'', ''datetimeoffset'', ''date'', ''smalldatetime'', ''time'');'
			FROM #Databases;
			EXEC sp_executesql @checkSQL, N'@CheckNumber TINYINT', @CheckNumber = @CheckNumber;
		 END; --Date and Time Data Type Check

		/* Archaic varchar Lengths (255/256) */
		SET @CheckNumber = @CheckNumber + 1;
		SET @msg = N'Check ' + CAST(@CheckNumber AS NVARCHAR(3)) + ' - Archaic varchar Lengths';
		RAISERROR(@msg, 10, 1) WITH NOWAIT;
			BEGIN
				SET @checkSQL = N'';
				SELECT @checkSQL = @checkSQL + N'USE ' + [database_name]  + N'; WITH archaic AS (
									SELECT	QUOTENAME(SCHEMA_NAME(t.schema_id)) + ''.'' + QUOTENAME(t.name) AS [obj_name],
											QUOTENAME(c.name) AS [col_name],
											N''Possible arbitrary variable length column in use. Is the '' + ty.name + N'' length of '' + CAST (c.max_length / 2 AS varchar(MAX)) + N'' based on requirements'' AS [message],
											N''http://lowlydba.com/ExpressSQL/#arbitrary-varchar-length'' AS [ref_link]
									FROM sys.columns c
										inner join sys.tables as t on t.object_id = c.object_id
										inner join sys.types as ty on ty.user_type_id = c.user_type_id
									WHERE c.is_identity = 0 --exclude identity cols
										AND t.is_ms_shipped = 0 --exclude sys table
										AND ty.name = ''NVARCHAR''
										AND c.max_length IN (510, 512)
									UNION
									SELECT	QUOTENAME(SCHEMA_NAME(t.schema_id)) + ''.'' + QUOTENAME(t.name), 
											QUOTENAME(c.name), 
											N''Possible arbitrary variable length column in use. Is the '' + ty.name + N'' length of '' + CAST (c.max_length AS varchar(MAX)) + N'' based on requirements'', 
											N''http://lowlydba.com/ExpressSQL/#arbitrary-varchar-length''
									FROM sys.columns as c
										inner join sys.tables as t on t.object_id = c.object_id
										inner join sys.types as ty on ty.user_type_id = c.user_type_id
									WHERE c.is_identity = 0 --exclude identity cols
										AND t.is_ms_shipped = 0 --exclude sys table
										AND ty.name = ''VARCHAR''
										AND c.max_length IN (255, 256))

								INSERT INTO #results ([check_num], [check_type], [obj_type], [db_name], [obj_name], [col_name], [message], [ref_link])
								SELECT	@CheckNumber, 
										N''Data Types'',
										N''USER_TABLE'',
										QUOTENAME(DB_NAME()),
										[obj_name],
										[col_name],
										[message],
										[ref_link]
								FROM [archaic];'
				FROM #Databases;
				EXEC sp_executesql @checkSQL, N'@CheckNumber TINYINT', @CheckNumber = @CheckNumber;
			END; --Archaic varchar Lengths

		/* Unspecified VARCHAR Length */
		SET @CheckNumber = @CheckNumber + 1;
		SET @msg = N'Check ' + CAST(@CheckNumber AS NVARCHAR(3)) + ' - Unspecified VARCHAR Length';
		RAISERROR(@msg, 10, 1) WITH NOWAIT;
		BEGIN
			SET @checkSQL = N'';
			SELECT @checkSQL = @checkSQL + 'USE ' + [database_name] + ';
								WITH UnspecifiedVarChar AS (
									SELECT	QUOTENAME(SCHEMA_NAME(t.schema_id)) + ''.'' + QUOTENAME(t.name) AS [obj_name],
											QUOTENAME(c.name) AS [col_name],
											N''VARCHAR column without specified length, it should not have a length of '' + CAST (c.max_length AS varchar(10)) + '''' AS [message],
											N''http://lowlydba.com/ExpressSQL/#unspecified-varchar-length'' AS [ref_link]
									FROM sys.columns as c
										inner join sys.tables as t on t.object_id = c.object_id
										inner join sys.types as ty on ty.user_type_id = c.user_type_id
									WHERE c.is_identity = 0 	--exclude identity cols
										AND t.is_ms_shipped = 0 --exclude sys table
										AND ty.name IN (''VARCHAR'', ''NVARCHAR'')
										AND c.max_length = 1)

								INSERT INTO #results ([check_num], [check_type], [obj_type], [db_name], [obj_name], [col_name], [message], [ref_link])
								SELECT	@CheckNumber, 
										N''Data Types'',
										N''USER_TABLE'',
										QUOTENAME(DB_NAME()),
										[obj_name],
										[col_name],
										[message],
										[ref_link]
								FROM [UnspecifiedVarChar];'
			FROM #Databases;
			EXEC sp_executesql @checkSQL, N'@CheckNumber TINYINT', @CheckNumber = @CheckNumber;
		END; --Unspecified VARCHAR Length

		/* Mad MAX - Varchar(MAX) */
		SET @CheckNumber = @CheckNumber + 1;
		SET @msg = N'Check ' + CAST(@CheckNumber AS NVARCHAR(3)) + ' - Mad MAX VARCHAR';
		RAISERROR(@msg, 10, 1) WITH NOWAIT;
			BEGIN
				SET @checkSQL = N'';
				SELECT @checkSQL = @checkSQL + N'USE ' + [database_name] + N';
								INSERT INTO #results ([check_num], [check_type], [obj_type], [db_name], [obj_name], [col_name], [message], [ref_link])
								SELECT @CheckNumber,
										N''Data Types'', 
										N''USER_TABLE'',
										QUOTENAME(DB_NAME()),
										QUOTENAME(SCHEMA_NAME(t.schema_id)) + ''.'' + QUOTENAME(t.name),
										QUOTENAME(c.name), 
										N''Column is NVARCHAR(MAX) which allows very large row sizes. Consider a character limit.'',
										N''http://lowlydba.com/ExpressSQL/#mad-varchar-max''
								FROM sys.columns as c
									 inner join sys.tables as t on t.object_id = c.object_id
									 inner join sys.types as ty on ty.user_type_id = c.user_type_id
								WHERE t.is_ms_shipped = 0 --exclude sys table
									 AND ty.[name] = ''nvarchar''
									 AND c.max_length = -1;'
				FROM #Databases;
				EXEC sp_executesql @checkSQL, N'@CheckNumber TINYINT', @CheckNumber = @CheckNumber;
			END; --NVARCHAR MAX Check
			
		/* NVARCHAR data type in Express*/
		SET @CheckNumber = @CheckNumber + 1;
		SET @msg = N'Check ' + CAST(@CheckNumber AS NVARCHAR(3)) + ' - Use of NVARCHAR (EXPRESS).';
		RAISERROR(@msg, 10, 1) WITH NOWAIT;
		IF(@isExpress = 1)
			BEGIN
				SET @checkSQL = N'';
				SELECT @checkSQL = @checkSQL + N'USE ' + [database_name] + N';
												INSERT INTO #results ([check_num], [check_type], [obj_type], [db_name], [obj_name], [col_name], [message], [ref_link])
												SELECT @CheckNumber
														,N''Data Types''
														,N''USER_TABLE''
														,DB_NAME()
														,QUOTENAME(SCHEMA_NAME([o].schema_id)) + ''.'' + QUOTENAME(OBJECT_NAME([o].object_id))
														,QUOTENAME([ac].[name])
														,N''nvarchar columns take 2x the space per char of varchar. Only use if you need Unicode characters.''
														,N''http://lowlydba.com/ExpressSQL/#nvarchar-in-express''
												FROM   [sys].[all_columns] AS [ac]
														INNER JOIN [sys].[types] AS [t] ON [t].[user_type_id] = [ac].[user_type_id]
														INNER JOIN [sys].[objects] AS [o] ON [o].object_id = [ac].object_id
												WHERE  [t].[name] = ''NVARCHAR''
														AND [o].[is_ms_shipped] = 0'
				FROM #Databases
				EXEC sp_executesql @checkSQL, N'@CheckNumber TINYINT', @CheckNumber = @CheckNumber;
			 END;
		ELSE
			BEGIN
				RAISERROR('	Skipping check, not express...', 10, 1) WITH NOWAIT;
			END; --NVARCHAR Use Check
			
		/* FLOAT and REAL data types */
		SET @CheckNumber = @CheckNumber + 1;
		SET @msg = N'Check ' + CAST(@CheckNumber AS NVARCHAR(3)) + ' - Use of FLOAT/REAL data types';
		RAISERROR(@msg, 10, 1) WITH NOWAIT;
			BEGIN
				SET @checkSQL = N'';
				SELECT @checkSQL = @checkSQL + N'USE ' + [database_name] + N';
									INSERT INTO #results ([check_num], [check_type], [obj_type], [db_name], [obj_name], [col_name], [message], [ref_link])
									SELECT @CheckNumber,
										N''Data Types'',
										[o].[type_desc],
										QUOTENAME(DB_NAME()),
										QUOTENAME(SCHEMA_NAME(o.schema_id)) + ''.'' + QUOTENAME(o.name),
										QUOTENAME(ac.name),
										N''Best practice is to use DECIMAL/NUMERIC instead of '' + st.name + '' for non floating point math.'',
										N''http://lowlydba.com/ExpressSQL/#float-and-real-data-types''
									FROM sys.all_columns AS ac
											INNER JOIN sys.objects AS o ON o.object_id = ac.object_id
											INNER JOIN sys.systypes AS st ON st.xtype = ac.system_type_id
									WHERE st.name IN(''FLOAT'', ''REAL'')
											AND o.type_desc = ''USER_TABLE'';'
				FROM #Databases
				EXEC sp_executesql @checkSQL, N'@CheckNumber TINYINT', @CheckNumber = @CheckNumber;
			END; -- FLOAT/REAL Check

		/* Deprecated data types (NTEXT, TEXT, IMAGE) */
		SET @CheckNumber = @CheckNumber + 1;
		SET @msg = N'Check ' + CAST(@CheckNumber AS NVARCHAR(3)) + ' - Deprecated data types';
		RAISERROR(@msg, 10, 1) WITH NOWAIT;
			BEGIN
				SET @checkSQL = N'';
				SELECT @checkSQL = @checkSQL + N'USE ' + [database_name] + N';
									INSERT INTO #results ([check_num], [check_type], [obj_type], [db_name], [obj_name], [col_name], [message], [ref_link])
									SELECT @CheckNumber
											,N''Data Types''
											,QUOTENAME(DB_NAME())
											,[o].[type_desc]
											,QUOTENAME(SCHEMA_NAME(o.schema_id)) + ''.'' + QUOTENAME(o.name)
											,QUOTENAME(ac.name)
											,N''Deprecated data type in use: '' + st.name + ''.''
											,N''http://lowlydba.com/ExpressSQL/#deprecated-data-types''
									FROM sys.all_columns AS ac
											INNER JOIN sys.objects AS o ON o.object_id = ac.object_id
											INNER JOIN sys.systypes AS st ON st.xtype = ac.system_type_id
									WHERE st.name IN(''NEXT'', ''TEXT'', ''IMAGE'')
											AND o.type_desc = ''USER_TABLE'';'
				FROM #Databases
				EXEC sp_executesql @checkSQL, N'@CheckNumber TINYINT', @CheckNumber = @CheckNumber;
			END; --Don't use deprecated data types check
			
		/* BIGINT for identity values in Express*/
		SET @CheckNumber = @CheckNumber + 1;
		SET @msg = N'Check ' + CAST(@CheckNumber AS NVARCHAR(3)) + ' - BIGINT used for identity columns (EXPRESS)';
		RAISERROR(@msg, 10, 1) WITH NOWAIT;
		IF(@isExpress = 1)
			BEGIN
				SET @checkSQL = N'';
				SELECT @checkSQL = @checkSQL + N'USE ' + [database_name] + N';
									INSERT INTO #results ([check_num], [check_type], [obj_type], [db_name], [obj_name], [col_name], [message], [ref_link])
									SELECT  @CheckNumber
											,N''Data Types''
											,N''USER_TABLE''
											,QUOTENAME(DB_NAME())
											,QUOTENAME(SCHEMA_NAME(t.schema_id)) + ''.'' + QUOTENAME(t.name)
											,QUOTENAME(c.name)
											,N''BIGINT used on IDENTITY column in SQL Express. If values will never exceed 2,147,483,647 use INT instead.''
											,N''http://lowlydba.com/ExpressSQL/#bigint-as-identity''
										FROM sys.columns as c
											INNER JOIN sys.tables as t on t.object_id = c.object_id
											INNER JOIN sys.types as ty on ty.user_type_id = c.user_type_id
										WHERE t.is_ms_shipped = 0 --exclude sys table
											AND ty.name = ''BIGINT''
											AND c.is_identity = 1;'
				FROM #Databases
				EXEC sp_executesql @checkSQL, N'@CheckNumber TINYINT', @CheckNumber = @CheckNumber;
			END; -- BIGINT for identity Check
		ELSE --Skip check 
			BEGIN
				RAISERROR('	Skipping check, not Express...', 10, 1) WITH NOWAIT;
			END;
			
		/* Numeric or decimal with 0 scale */
		SET @CheckNumber = @CheckNumber + 1;
		SET @msg = N'Check ' + CAST(@CheckNumber AS NVARCHAR(3)) + ' - NUMERIC or DECIMAL with scale of 0';
		RAISERROR(@msg, 10, 1) WITH NOWAIT;
		BEGIN
			SET @checkSQL = N'';
			SELECT @checkSQL = @checkSQL + N'USE ' + [database_name] + N';
								INSERT INTO #results ([check_num], [check_type], [obj_type], [db_name], [obj_name], [col_name], [message], [ref_link])
								SELECT @CheckNumber
										,N''Data Types''
										,QUOTENAME(DB_NAME())
										,[o].[type_desc]
										,QUOTENAME(SCHEMA_NAME(o.schema_id)) + ''.'' + QUOTENAME(o.name)
										,QUOTENAME(ac.name)
										,N''Column is '' + UPPER(st.name) + ''('' + CAST(ac.precision AS VARCHAR) + '','' + CAST(ac.scale AS VARCHAR) + '')''
											+ '' . Consider using an INT variety for space reduction since the scale is 0.''
										,N''http://lowlydba.com/ExpressSQL/#numeric-or-decimal-0-scale)''
								FROM sys.objects AS o
										INNER JOIN sys.all_columns AS ac ON ac.object_id = o.object_id
										INNER JOIN sys.systypes AS st ON st.xtype = ac.system_type_id
								WHERE ac.scale = 0
										AND ac.precision < 19
										AND st.name IN(''DECIMAL'', ''NUMERIC'');'
			FROM #Databases
			EXEC sp_executesql @checkSQL, N'@CheckNumber TINYINT', @CheckNumber = @CheckNumber;
		 END; -- Numeric or decimal with 0 scale check

		/* User DB or model db  Growth set past 10GB - ONLY IF EXPRESS*/
		SET @CheckNumber = @CheckNumber + 1;
		SET @msg = N'Check ' + CAST(@CheckNumber AS NVARCHAR(3)) + ' - Data file growth set past 10GB (EXPRESS).';
		RAISERROR(@msg, 10, 1) WITH NOWAIT;
		IF(@isExpress = 1)
			BEGIN
				SET @checkSQL = N'';
				SELECT @checkSQL = @checkSQL + N'USE ' + [database_name] + N';
								INSERT INTO #results ([check_num], [check_type], [obj_type], [db_name], [obj_name], [col_name], [message], [ref_link])
								SELECT @CheckNumber,
									N''File Growth'',
									N''DATABASE'',
									QUOTENAME(DB_NAME()),
									QUOTENAME(DB_NAME(database_id)),
									NULL,
									N''Database file '' + name + '' has a maximum growth set to '' + CASE 
																										WHEN max_size = -1
																											THEN ''Unlimited''
																										WHEN max_size > 0
																											THEN CAST((max_size / 1024) * 8 AS VARCHAR(MAX))
																									END + '', which is over the user database maximum file size of 10GB.'',
									N''http://lowlydba.com/ExpressSQL/#database-growth-past-10GB''
								 FROM sys.master_files mf
								 WHERE (max_size > 1280000 OR max_size = -1) -- greater than 10GB or unlimited
									 AND [mf].[database_id] > 5
									 AND [mf].[data_space_id] > 0 -- limit doesn''t apply to log files;'
				FROM #Databases
				EXEC sp_executesql @checkSQL, N'@CheckNumber TINYINT', @CheckNumber = @CheckNumber;
			END; -- User DB or model db  Growth check
		ELSE
			BEGIN
				RAISERROR('	Skipping check, not express...', 10, 1) WITH NOWAIT;
			END;

		/* User DB or model db growth set to % */
		SET @CheckNumber = @CheckNumber + 1;
		SET @msg = N'Check ' + CAST(@CheckNumber AS NVARCHAR(3)) + ' - Data file growth set to percentage.';
		RAISERROR(@msg, 10, 1) WITH NOWAIT;
		BEGIN
			INSERT INTO #results ([check_num], [check_type], [obj_type], [db_name], [obj_name], [col_name], [message], [ref_link])
			SELECT @CheckNumber,
					N'File Growth',
					N'DATABASE',
					QUOTENAME(DB_NAME([sd].[database_id])),
					[mf].[name],
					NULL,
					N'Database file '+[mf].[name]+' has growth set to % instead of a fixed amount. This may grow quickly.',
					N'http://lowlydba.com/ExpressSQL/#database-growth-type'
			FROM [sys].[master_files] AS [mf]
				INNER JOIN [sys].[databases] AS [sd] ON [sd].[database_id] = [mf].[database_id]
				INNER JOIN #Databases AS [d] ON [d].[database_name] = [sd].[name]
			WHERE [mf].[is_percent_growth] = 1
					AND [mf].[data_space_id] = 1 ; --ignore log files
		 END; -- User DB or model db growth set to % Check

		/* Default fill factor (EXPRESS ONLY)*/
		SET @CheckNumber = @CheckNumber + 1;
		SET @msg = N'Check ' + CAST(@CheckNumber AS NVARCHAR(3)) + ' - Non-default fill factor (EXPRESS)';
		RAISERROR(@msg, 10, 1) WITH NOWAIT;
		IF(@isExpress = 1)
			BEGIN
				SET @checkSQL = N'';
				SELECT @checkSQL = @checkSQL + N'USE ' + [database_name] + N';
									INSERT INTO #results ([check_num], [check_type], [obj_type], [db_name], [obj_name], [col_name], [message], [ref_link])
									SELECT @CheckNumber,
											N''Architecture'',
											QUOTENAME(DB_NAME()),
											N''INDEX'',
											QUOTENAME(SCHEMA_NAME([o].[schema_id])) + ''.'' + QUOTENAME([o].[name]) + ''.'' + QUOTENAME([i].[name]),
											NULL,
											N''Non-default fill factor on this index. Not inherently bad, but will increase table size more quickly.'',
											N''http://lowlydba.com/ExpressSQL/#default-fill-factor''
									FROM [sys].[indexes] AS [i]
											INNER JOIN [sys].[objects] AS [o] ON [o].[object_id] = [i].[object_id]
									WHERE [i].[fill_factor] NOT IN(0, 100);'
				FROM #Databases;
				EXEC sp_executesql @checkSQL, N'@CheckNumber TINYINT', @CheckNumber = @CheckNumber;
			END; -- Non-default fill factor check
		ELSE --Skip check
			BEGIN
				RAISERROR('	Skipping check, not express...', 10, 1) WITH NOWAIT;
			END;

		/* Number of indexes */
		SET @CheckNumber = @CheckNumber + 1;
		SET @msg = N'Check ' + CAST(@CheckNumber AS NVARCHAR(3)) + ' - Questionable number of indexes';
		RAISERROR(@msg, 10, 1) WITH NOWAIT;
		BEGIN
			SET @checkSQL = N'';
			SELECT @checkSQL = @checkSQL + N'USE ' + [database_name] + N';
									INSERT INTO #results ([check_num], [check_type], [obj_type], [db_name], [obj_name], [col_name], [message], [ref_link])
									SELECT @CheckNumber,
											N''Architecture'',
											N''INDEX'',
											QUOTENAME(DB_NAME()),
											QUOTENAME(SCHEMA_NAME(t.schema_id)) + ''.'' + QUOTENAME(t.name),
											NULL,
											''There are '' + CAST(COUNT(DISTINCT(i.index_id)) AS VARCHAR) + '' indexes on this table taking up '' + CAST(CAST(SUM(s.[used_page_count]) * 8 / 1024.00 AS DECIMAL(10, 2)) AS VARCHAR) + '' MB of space.'',
											''http://lowlydba.com/ExpressSQL/#number-of-indexes''
									FROM sys.indexes AS i
											INNER JOIN sys.tables AS t ON i.object_id = t.object_id
											INNER JOIN sys.dm_db_partition_stats AS s ON s.object_id = i.object_id
																			AND s.index_id = i.index_id
									WHERE t.is_ms_shipped = 0 --exclude sys table
											AND i.type_desc = ''NONCLUSTERED'' --exclude clustered indexes from count
									GROUP BY t.name,
												t.schema_id
									HAVING COUNT(DISTINCT(i.index_id)) > @IndexNumThreshold;'
			FROM #Databases;
			EXEC sp_executesql @checkSQL, N'@IndexNumThreshold TINYINT, @CheckNumber TINYINT', @IndexNumThreshold = @IndexNumThreshold, @CheckNumber = @CheckNumber;
		 END; -- Questionable number of indexes check

		/* Sparse columns */
		SET @CheckNumber = @CheckNumber + 1;
		SET @msg = N'Check ' + CAST(@CheckNumber AS NVARCHAR(3)) + ' - Sparse column eligibility';
		RAISERROR(@msg, 10, 1) WITH NOWAIT;
			IF @hasSparse = 1
				BEGIN
					IF OBJECT_ID('tempdb..#SparseTypes') IS NOT NULL
						BEGIN;
							DROP TABLE [#SparseTypes];
						END;
					IF OBJECT_ID('tempdb..#Stats') IS NOT NULL
						BEGIN;
							DROP TABLE [#Stats];
						END;
					IF OBJECT_ID('tempdb..#StatsHeaderStaging') IS NOT NULL
						BEGIN;
							DROP TABLE [#StatsHeaderStaging];
						END;
					IF OBJECT_ID('tempdb..#StatHistogramStaging') IS NOT NULL
						BEGIN;
							DROP TABLE [#StatHistogramStaging];
						END;
	
					CREATE TABLE #SparseTypes (
							[ID] INT IDENTITY(1,1) NOT NULL,
							[name] VARCHAR(20),
							[user_type_ID] INT,
							[scale] TINYINT NULL,
							[precision] TINYINT NOT NULL,
							[threshold_null_perc] TINYINT NOT NULL);

					CREATE CLUSTERED INDEX cidx_#sparsetypes ON #SparseTypes([ID]);

					/*	Reference values for when it makes sense to use the sparse feature based on 40% minimum space savings
						including if those recommendations change based on scale / precision. Conservative estimates are used
						when a column is in between the high and low values in the table.
						https://docs.microsoft.com/en-us/sql/relational-databases/tables/use-sparse-columns?view=sql-server-2017#estimated-space-savings-by-data-type */ 	
					INSERT INTO #SparseTypes ([name], [user_type_ID], [scale], [precision], [threshold_null_perc])
					VALUES	('BIT',104, 0,0, 98),
							('TINYINT',48, 0,0, 86),
							('SMALLINT',52, 0,0, 76),
							('INT',56, 0,0, 64),
							('BIGINT',127, 0,0, 52),
							('REAL',59, 0,0, 64),
							('FLOAT',62, 0,0, 52),
							('SMALLMONEY',122, 0,0, 64),
							('MONEY',60, 0,0, 52),
							('SMALLDATETIME',58, 0,0, 64),
							('DATETIME',61, 0,0, 52),
							('UNIQUEIDENTIFIER',36, 0,0, 43),
							('DATE',40, 0,0, 69),
							('DATETIME2',42, 0,0, 57),
							('DATETIME2',42, 7,0, 52),
							('TIME',41, 0,0, 69),
							('TIME',41, 7,0, 60),
							('DATETIMEOFFSET',43, 0,0, 52),
							('DATETIMEOFFSET',43, 7,0, 49),
							('VARCHAR',167, 0,0, 60),
							('CHAR',175, 0,0, 60),
							('NVARCHAR',231, 0,0, 60),
							('NCHAR',239, 0,0, 60),
							('VARBINARY',165, 0,0, 60),
							('BINARY',173, 0,0, 60),
							('XML',241, 0,0, 60),
							('HIERARCHYID',128, 0,0, 60),
							('DECIMAL', 106, NULL, 1, 60), 
							('DECIMAL', 106, NULL, 38, 42), 
							('NUMERIC', 108, NULL, 1, 60), 
							('NUMERIC', 108, NULL, 38, 42);

					CREATE TABLE #StatsHeaderStaging (
						 [name] SYSNAME 
						,[updated] DATETIME2(0)
						,[rows] BIGINT
						,[rows_sampled] BIGINT
						,[steps] INT
						,[density] DECIMAL(6,3)
						,[average_key_length] DECIMAL(5,2)
						,[string_index] VARCHAR(10)
						,[filter_expression] nvarchar(max)
						,[unfiltered_rows] BIGINT);
						
					--2016 SP1 CU4 adds extra column
					IF (@MajorVersion = 13 AND @minorVersion >= 4446)
						BEGIN
							ALTER TABLE #StatsHeaderStaging
							ADD [persisted_sample_percent] INT;
						END
						
					CREATE TABLE #StatHistogramStaging (
						 [range_hi_key] NVARCHAR(MAX)
						,[range_rows] BIGINT
						,[eq_rows] DECIMAL(38,2)
						,[distinct_range_rows] BIGINT
						,[avg_range_rows] BIGINT);

					CREATE TABLE #Stats (
						 [stats_id] INT IDENTITY(1,1)
						,[db_name] SYSNAME
						,[stat_name] SYSNAME 
						,[stat_updated] DATETIME2(0)
						,[rows] BIGINT
						,[rows_sampled] BIGINT
						,[schema_name] SYSNAME
						,[table_name] SYSNAME NULL
						,[col_name] SYSNAME NULL
						,[eq_rows] BIGINT NULL
						,[null_perc] AS CAST([eq_rows] AS DECIMAL (38,2)) /[rows] * 100
						,[threshold_null_perc] SMALLINT);

					CREATE CLUSTERED INDEX cidx_#stats ON #Stats([stats_id]);

					DECLARE @db_name SYSNAME;
					DECLARE @tempStatSQL NVARCHAR(MAX) = N'';
					DECLARE @statSQL NVARCHAR(MAX) = 
						N'	USE ?;
							BEGIN
								DECLARE	@schemaName SYSNAME,
										@tableName SYSNAME, 
										@statName SYSNAME, 
										@colName SYSNAME, 
										@threshold_null_perc SMALLINT;

								DECLARE @DBCCSQL NVARCHAR(MAX) = N'''';
								DECLARE @DBCCStatSQL NVARCHAR(MAX) = N'''';
								DECLARE @DBCCHistSQL NVARCHAR(MAX) = N'''';

								DECLARE [DBCC_Cursor] CURSOR LOCAL FAST_FORWARD
								FOR SELECT DISTINCT	  sch.name	AS [schema_name]
													, t.name	AS [table_name]
													, s.name	AS [stat_name]
													, ac.name	AS [col_name]
													, threshold_null_perc 
									FROM [sys].[stats] AS [s] 
										INNER JOIN [sys].[stats_columns] AS [sc] on sc.stats_id = s.stats_id
										INNER JOIN [sys].[tables] AS [t] on t.object_id = s.object_id
										INNER JOIN [sys].[schemas] AS [sch] on sch.schema_id = t.schema_id
										INNER JOIN [sys].[all_columns] AS [ac] on ac.column_id = sc.column_id
																AND [ac].[object_id] = [t].[object_id]
																AND [ac].[object_id] = [sc].[object_id]
										INNER JOIN [sys].[types] AS [typ] ON [typ].[user_type_id] = [ac].[user_type_id]
										LEFT JOIN [sys].[indexes] AS [i] ON i.object_id = t.object_id
																AND i.name = s.name
										LEFT JOIN [sys].[index_columns] AS [ic] ON [ic].[object_id] = [i].[object_id]
																AND [ic].[column_id] = [ac].[column_id]
																AND ic.index_id = i.index_id
										INNER JOIN [#SparseTypes] AS [st] ON [st].[user_type_id] = [typ].[user_type_id]
																AND (typ.name NOT IN (''DECIMAL'', ''NUMERIC'', ''DATETIME2'', ''TIME'', ''DATETIMEOFFSET''))
																OR (typ.name IN (''DECIMAL'', ''NUMERIC'') AND st.precision = ac.precision AND st.precision = 1)
																OR (typ.name IN (''DECIMAL'', ''NUMERIC'') AND ac.precision > 1 AND st.precision = 38)
																OR (typ.name IN (''DATETIME2'', ''TIME'', ''DATETIMEOFFSET'') AND st.scale = ac.scale AND st.scale = 0)
																OR (typ.name IN (''DATETIME2'', ''TIME'', ''DATETIMEOFFSET'') AND ac.scale > 0 AND st.scale = 7)
									WHERE [sc].[stats_column_id] = 1
										AND [s].[has_filter] = 0
										AND [s].[no_recompute] = 0
										AND [ac].[is_nullable] = 1 ';

					IF @hasTempStat = 1 
						BEGIN
							SET @statSQL = @statSQL + N'AND [s].[is_temporary] = 0 ';
						END
									
					SET @statSQL = @statSQL + N'
										AND ([ic].[index_column_id] = 1 OR [ic].[index_column_id] IS NULL)
										AND ([i].[type_desc] =''NONCLUSTERED'' OR [i].[type_desc] IS NULL)
								
								OPEN [DBCC_Cursor];

								FETCH NEXT FROM [DBCC_Cursor]
								INTO @schemaName, @tableName, @statName, @colName, @threshold_null_perc;

								WHILE @@FETCH_STATUS = 0
									BEGIN;
										/* Build DBCC statistics queries */
										SET @DBCCSQL = N''DBCC SHOW_STATISTICS('''''' + @schemaName + ''.'' + @tableName + '''''', '''''' + @statName + '''''')'';
										SET @DBCCStatSQL = @DBCCSQL + '' WITH STAT_HEADER, NO_INFOMSGS;'';
										SET @DBCCHistSQL = @DBCCSQL + '' WITH HISTOGRAM, NO_INFOMSGS;'';

										/* Stat Header */
										INSERT INTO #StatsHeaderStaging 
										EXEC sp_executeSQL @DBCCStatSQL;

										/* Histogram */
										INSERT INTO #StatHistogramStaging 
										EXEC sp_executesql @DBCCHistSQL;
										
										INSERT INTO #Stats  
										SELECT	  QUOTENAME(DB_NAME())
												, [head].[name]
												, [head].[updated]
												, [head].[rows]
												, [head].[rows_Sampled]
												, @schemaName
												, @tableName
												, @colName
												, [hist].[eq_rows]
												, @threshold_null_perc
										FROM #StatsHeaderStaging head 
											CROSS APPLY #StatHistogramStaging hist
										WHERE hist.RANGE_HI_KEY IS NULL
											AND hist.eq_rows > 0
											AND head.Unfiltered_rows > 0
											AND head.rows > 1000;

										TRUNCATE TABLE #StatsHeaderStaging;
										TRUNCATE TABLE #StatHistogramStaging;

										FETCH NEXT FROM DBCC_Cursor
										INTO @schemaName, @tableName, @statName, @colName, @threshold_null_perc;
									END;
								CLOSE [DBCC_Cursor];
								DEALLOCATE [DBCC_Cursor];
							END;'

					DECLARE [DB_Cursor] CURSOR LOCAL FAST_FORWARD
					FOR SELECT QUOTENAME([database_name])
						FROM #Databases;

					OPEN [DB_Cursor];

					FETCH NEXT FROM [DB_Cursor]
					INTO @db_name

					/* Run stat query for each database */
					WHILE @@FETCH_STATUS = 0
						BEGIN
							SET @tempStatSQL = REPLACE(@statSQL, N'?', @db_name);

							EXEC sp_executeSQL @tempStatSQL;

							FETCH NEXT FROM [DB_Cursor]
							INTO @db_name;
						END;
					CLOSE [DB_Cursor];
					DEALLOCATE [DB_Cursor];
					
					INSERT INTO #results ([check_num], [check_type], [obj_type], [db_name], [obj_name], [col_name], [message], [ref_link])
					SELECT	@CheckNumber, 
							N'Architecture', 
							N'USER_TABLE', 
							[db_name], 
							QUOTENAME([schema_name]) + '.' + QUOTENAME([table_name]), 
							QUOTENAME([col_name]), 
							N'Candidate for converting to a space-saving sparse column based on NULL distribution of more than ' + CAST(threshold_null_perc AS VARCHAR(3))+ ' percent.', 
							N'http://lowlydba.com/ExpressSQL/#sparse-columns'
					FROM #stats
					WHERE [null_perc] >= [threshold_null_perc];
				END; -- Should sparse columns be used check
			ELSE 
				BEGIN;
					RAISERROR('	Skipping check, sparse columns not available in this version...', 10, 1) WITH NOWAIT;
				END;

		/* Wrap it up */
		SELECT *
		FROM #results
		ORDER BY check_num, db_name, obj_type, obj_name, col_name;

		RAISERROR('', 10, 1) WITH NOWAIT;
		RAISERROR('Done!', 10, 1) WITH NOWAIT;

	END TRY

	BEGIN CATCH;
		BEGIN
			DECLARE @ErrorNumber INT = ERROR_NUMBER();
			DECLARE @ErrorLine INT = ERROR_LINE();
			DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
			DECLARE @ErrorSeverity INT = ERROR_SEVERITY();
			DECLARE @ErrorState INT = ERROR_STATE();
			
			IF (@debug = 1)
				BEGIN
					PRINT 'Actual error number: ' + CAST(@ErrorNumber AS VARCHAR(10));
					PRINT 'Actual line number: ' + CAST(@ErrorLine AS VARCHAR(10));
				END
 
			RAISERROR(@ErrorMessage, @ErrorSeverity, @ErrorState);
		END
	END CATCH;
GO