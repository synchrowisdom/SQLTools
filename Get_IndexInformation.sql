-- Mandatory parameters
DECLARE @database_name          SYSNAME                     -- Target database
DECLARE @schema_name            SYSNAME                     -- Target schema
DECLARE @table_name             SYSNAME                     -- Target table

-- Options
DECLARE @use_quotename          BIT = 'True' --'False'      -- Encloses names with brackets []
DECLARE @show_primarykey        BIT = 'True' --'False'      -- Show primary key indexes or not
DECLARE @show_disabled_index    BIT = 'True' --'False'      -- Show disabled indexes or not

-- Constants
DECLARE @new_line               CHAR(2) = CHAR(10) + CHAR(13)

-- DEBUG parameter
DECLARE @DEBUG_keep_temptables          BIT = 'False'   -- For debugging purposes, will keep temp tables intact when set to 'True' ( SELECT CAST('True' AS BIT) )
DECLARE @DEBUG_indexInformation_exists  BIT = 
    CASE WHEN OBJECT_ID(N'tempdb..#indexInformation') IS NOT NULL 
        THEN 'True' 
        ELSE 'False' 
    END


------------------------------
-- User inputs
------------------------------
SET @database_name  = N'Test'
SET @schema_name    = N'dbo'
SET @table_name     = N'Test'
------------------------------
-- User inputs
------------------------------

-- Make sure the object information was provided
IF (@database_name IS NULL
    OR @schema_name IS NULL
    OR @table_name IS NULL) BEGIN

    PRINT 'Error: Missing database object information.'
    RETURN
END


------------------------------------------
-- Generate #indexInformation
------------------------------------------
IF @DEBUG_indexInformation_exists = 'True'
    IF (@DEBUG_keep_temptables = 'False') BEGIN
        DROP TABLE #indexInformation
        SET @DEBUG_indexInformation_exists = 'False'
    END

IF @DEBUG_indexInformation_exists = 'False' 
    DECLARE @sql        NVARCHAR(MAX)
    DECLARE @sqlParam   NVARCHAR(MAX)

    -- Create a temporairy table to contain our index information
    SELECT TOP 0
        IDENTITY(INT, 1, 1) AS IndexInformationId   -- Used to sort the index information in a specific way (ie: ''pretty print'' kind of way)
        , CAST(NULL AS VARCHAR(MAX)) AS [Source]    
        , CAST(NULL AS SYSNAME) AS [IndexName]
        , CAST(NULL AS NVARCHAR(60)) AS [IndexType]
        , CAST(NULL AS VARCHAR(8)) AS [IndexStatus]
        , CAST(NULL AS SYSNAME) AS [IndexColumn]
        , CAST(NULL AS BIT) AS [is_included_column]
        , CAST(NULL AS INT) AS [index_id]
        , CAST(NULL AS INT) AS [index_column_id]
    INTO 
        #indexInformation   
                                            
    -- Prepare our dynamic SQL - Query needs to be ran against a specific database
    SET @sqlParam = N'
        @use_quotename          BIT,
        @show_primarykey        BIT,
        @show_disabled_index    BIT'

    SET @sql = N'
    USE ' + @database_name + ' 
    
    INSERT #indexInformation
    SELECT
        NULL AS [Source]
    
        , CASE @use_quotename
            WHEN ''True'' THEN QUOTENAME(I.[name])
            ELSE I.[name]
            END AS IndexName        
    
        , I.[type_desc] AS IndexType
    
        , CASE [is_disabled]
            WHEN ''True'' THEN ''DISABLED''
            ELSE ''ENABLED''
            END AS IndexStatus

        , C.[name] AS IndexColumn
        , IC.[is_included_column]
        , IC.[index_id]
        , IC.index_column_id

    FROM 
        sys.tables AS T
    
        INNER JOIN sys.schemas AS S
            ON S.[schema_id] = T.[schema_id]
    
        INNER JOIN sys.indexes AS I 
            ON I.[object_id] = T.[object_id]
    
        INNER JOIN sys.index_columns AS IC
            ON IC.[object_id] = I.[object_id]
            AND IC.[index_id] = I.[index_id]

        INNER JOIN sys.columns AS C
            ON C.[object_id] = I.[object_id]
            AND C.[column_id] = IC.[column_id]      

    WHERE   
        -- Conditional display for CLUSTERED indexes
        (CASE @show_primarykey
            WHEN ''True'' THEN 1
            ELSE ~I.is_primary_key
        END) = 1
        
        AND 

        -- Conditional display for DISABLED indexes
        (CASE @show_disabled_index
            WHEN ''True'' THEN 1
            ELSE ~I.is_disabled
        END) = 1
                                            
    ORDER BY
            I.is_primary_key ASC
        , [Source] ASC  
        --, is_disabled ASC 
        , IC.is_included_column ASC
        , IC.index_column_id ASC
    ;'
EXECUTE sp_executesql   @sql, @sqlParam,
                        @use_quotename          = @use_quotename,
                        @show_primarykey        = @show_primarykey,
                        @show_disabled_index    = @show_disabled_index

-- Generate the column [Source]
UPDATE II
SET 
    [Source] = S.[Source]
FROM 
    #indexInformation AS II
    INNER JOIN (
            SELECT
                index_id,
                CASE WHEN @use_quotename = 'True'
                     THEN QUOTENAME(@database_name)
                     ELSE @database_name
                END
                + '.' +
                CASE WHEN @use_quotename = 'True' 
                     THEN QUOTENAME(@schema_name)
                     ELSE @schema_name
                END
                + '.' + 
                CASE WHEN @use_quotename = 'True'
                     THEN QUOTENAME(@table_name)
                     ELSE @table_name
                END AS [Source]
            FROM
                #indexInformation
            ) AS S /*Source*/
                ON S.index_id = II.index_id
------------------------------------------
-- Generate #indexInformation   
------------------------------------------


----------------------------------------------------
-- Display the collected index information
----------------------------------------------------
SELECT 
    *
FROM
    #indexInformation
ORDER BY
    IndexInformationId


-------------------------------------------------------
-- Generate the index creation script
-------------------------------------------------------
SELECT DISTINCT
    II.[Source],
    II.IndexStatus,
    'CREATE ' + [IndexType] +
    ' INDEX ' + [IndexName] COLLATE DATABASE_DEFAULT + @new_line + 
    ' ON ' + [Source] +
    ' (' + CL.[column_list] + ')' + 
    
    -- Included columns if needed
    CASE WHEN ICL.[included_column_list] IS NOT NULL
        THEN @new_line + ' INCLUDE (' + ICL.[included_column_list] + ');'
        ELSE ';'
    END AS IndexCreationScript

FROM 
    #indexInformation AS II
    INNER JOIN (SELECT 
                    index_id
                   ,STUFF((
                        SELECT ', ' + CAST(IndexColumn AS VARCHAR(MAX))
                        FROM #indexInformation AS I2
                        WHERE I2.index_id = I.index_id
                          AND is_included_column = 'False'
                        ORDER BY index_column_id ASC
                        FOR XML PATH('')
                        ), 1, 2, '') AS column_list
                FROM
                    #indexInformation AS I
                ) AS CL
                    ON CL.index_id = II.index_id
    
    LEFT OUTER JOIN (SELECT 
                        index_id
                       ,STUFF((
                            SELECT ', ' + CAST(IndexColumn AS VARCHAR(MAX))
                            FROM #indexInformation AS I2
                            WHERE I2.index_id = I.index_id
                              AND is_included_column = 'True'
                            ORDER BY index_column_id ASC
                            FOR XML PATH('')
                            ), 1, 2, '') AS included_column_list
                    FROM
                        #indexInformation AS I
               ) AS ICL
                    ON ICL.index_id = II.index_id
ORDER BY
     IndexCreationScript DESC
-------------------------------------------------------
-- Generate the index creation script
-------------------------------------------------------
