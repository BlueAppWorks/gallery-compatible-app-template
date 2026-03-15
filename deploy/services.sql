-- ============================================================
-- Gallery Compatible App - Service Management Module
-- Gallery Compatible v3: lifecycle managed entirely by Gallery Operator.
-- No auto-stop tasks, no app-side start/stop scheduling.
-- ============================================================

-- ============================================================
-- Grant Callback (auto-create compute pool when privilege granted)
-- ============================================================

CREATE OR REPLACE PROCEDURE app_setup.grant_callback(privileges ARRAY)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    has_create_pool BOOLEAN DEFAULT FALSE;
    pool_name VARCHAR;
    db_name VARCHAR;
BEGIN
    LET i INTEGER := 0;
    WHILE (i < ARRAY_SIZE(:privileges)) DO
        IF (GET(:privileges, i)::VARCHAR = 'CREATE COMPUTE POOL') THEN
            has_create_pool := TRUE;
        END IF;
        i := i + 1;
    END WHILE;

    IF (:has_create_pool) THEN
        SELECT CURRENT_DATABASE() INTO :db_name;
        pool_name := :db_name || '_POOL';

        BEGIN
            EXECUTE IMMEDIATE 'CREATE COMPUTE POOL IF NOT EXISTS IDENTIFIER('''
                || :pool_name || ''') '
                || 'MIN_NODES = 1 MAX_NODES = 1 '
                || 'INSTANCE_FAMILY = CPU_X64_XS '
                || 'AUTO_RESUME = TRUE '
                || 'AUTO_SUSPEND_SECS = 300';

            MERGE INTO app_config.settings AS t
            USING (SELECT 'compute_pool' AS key, :pool_name AS value) AS s
            ON t.key = s.key
            WHEN MATCHED THEN UPDATE SET value = s.value, updated_at = CURRENT_TIMESTAMP()
            WHEN NOT MATCHED THEN INSERT (key, value) VALUES (s.key, s.value);

        EXCEPTION WHEN OTHER THEN
            RETURN 'Error creating compute pool: ' || SQLERRM;
        END;
    END IF;

    RETURN 'Grant callback completed.';
END;
$$;

GRANT USAGE ON PROCEDURE app_setup.grant_callback(ARRAY)
    TO APPLICATION ROLE app_admin;

-- ============================================================
-- Compute Pool Management
-- ============================================================

CREATE OR REPLACE PROCEDURE app_setup.ensure_compute_pool()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    pool_name VARCHAR;
    db_name VARCHAR;
BEGIN
    BEGIN
        SELECT value INTO :pool_name FROM app_config.settings WHERE key = 'compute_pool';
    EXCEPTION WHEN OTHER THEN pool_name := NULL; END;

    IF (:pool_name IS NULL OR :pool_name = '') THEN
        SELECT CURRENT_DATABASE() INTO :db_name;
        pool_name := :db_name || '_POOL';

        EXECUTE IMMEDIATE 'CREATE COMPUTE POOL IF NOT EXISTS IDENTIFIER('''
            || :pool_name || ''') '
            || 'MIN_NODES = 1 MAX_NODES = 1 '
            || 'INSTANCE_FAMILY = CPU_X64_XS '
            || 'AUTO_RESUME = TRUE '
            || 'AUTO_SUSPEND_SECS = 300';

        MERGE INTO app_config.settings AS t
        USING (SELECT 'compute_pool' AS key, :pool_name AS value) AS s
        ON t.key = s.key
        WHEN MATCHED THEN UPDATE SET value = s.value, updated_at = CURRENT_TIMESTAMP()
        WHEN NOT MATCHED THEN INSERT (key, value) VALUES (s.key, s.value);
    END IF;

    RETURN pool_name;
END;
$$;

CREATE OR REPLACE PROCEDURE app_setup.drop_compute_pool()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    pool_name VARCHAR;
BEGIN
    BEGIN
        SELECT value INTO :pool_name FROM app_config.settings WHERE key = 'compute_pool';
    EXCEPTION WHEN OTHER THEN pool_name := NULL; END;

    IF (:pool_name IS NULL OR :pool_name = '') THEN
        RETURN 'No compute pool configured.';
    END IF;

    DROP SERVICE IF EXISTS app_services.<SERVICE_NAME>;
    EXECUTE IMMEDIATE 'DROP COMPUTE POOL IF EXISTS IDENTIFIER(''' || :pool_name || ''')';

    DELETE FROM app_config.settings WHERE key = 'compute_pool';

    RETURN 'Compute pool ' || :pool_name || ' dropped.';
EXCEPTION WHEN OTHER THEN
    RETURN 'Error: ' || SQLERRM;
END;
$$;

GRANT USAGE ON PROCEDURE app_setup.drop_compute_pool()
    TO APPLICATION ROLE app_admin;

-- ============================================================
-- Service Lifecycle (Gallery Compatible v3)
-- ============================================================

-- Start the service (internal: called by resume_service on first run)
CREATE OR REPLACE PROCEDURE app_setup.start_service()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    pool_name VARCHAR;
    db_host VARCHAR;
    db_port VARCHAR;
    cpu_request VARCHAR DEFAULT '0.5';
    cpu_limit VARCHAR DEFAULT '2';
    memory_request VARCHAR DEFAULT '1Gi';
    memory_limit VARCHAR DEFAULT '4Gi';
    create_sql VARCHAR;
BEGIN
    CALL app_setup.ensure_compute_pool() INTO :pool_name;

    -- Read database connection from settings
    -- Remove this block if your app has no external database connection
    SELECT value INTO :db_host FROM app_config.settings WHERE key = 'db_host';
    IF (:db_host IS NULL OR :db_host = '') THEN
        RETURN 'ERROR: Database not configured. Run configure_database() first.';
    END IF;

    BEGIN SELECT value INTO :db_port FROM app_config.settings WHERE key = 'db_port';
    EXCEPTION WHEN OTHER THEN NULL; END;
    db_port := COALESCE(:db_port, '5432');

    -- Read resource settings (optional overrides from Setup UI)
    BEGIN SELECT value INTO :cpu_request FROM app_config.settings WHERE key = 'cpu_request';
    EXCEPTION WHEN OTHER THEN NULL; END;
    BEGIN SELECT value INTO :cpu_limit FROM app_config.settings WHERE key = 'cpu_limit';
    EXCEPTION WHEN OTHER THEN NULL; END;
    BEGIN SELECT value INTO :memory_request FROM app_config.settings WHERE key = 'memory_request';
    EXCEPTION WHEN OTHER THEN NULL; END;
    BEGIN SELECT value INTO :memory_limit FROM app_config.settings WHERE key = 'memory_limit';
    EXCEPTION WHEN OTHER THEN NULL; END;

    cpu_request := COALESCE(:cpu_request, '0.5');
    cpu_limit := COALESCE(:cpu_limit, '2');
    memory_request := COALESCE(:memory_request, '1Gi');
    memory_limit := COALESCE(:memory_limit, '4Gi');

    -- Resume compute pool if suspended
    BEGIN
        EXECUTE IMMEDIATE 'ALTER COMPUTE POOL IDENTIFIER(''' || :pool_name || ''') RESUME';
    EXCEPTION WHEN OTHER THEN NULL; END;

    -- Create service (CREATE IF NOT EXISTS for Gallery compatibility — never DROP)
    create_sql := 'CREATE SERVICE IF NOT EXISTS app_services.<SERVICE_NAME> '
        || 'IN COMPUTE POOL IDENTIFIER(''' || :pool_name || ''') '
        || 'MIN_INSTANCES = 1 MAX_INSTANCES = 1 '
        || 'EXTERNAL_ACCESS_INTEGRATIONS = (REFERENCE(''<EAI_REF_NAME>'')) '
        || 'FROM SPECIFICATION_TEMPLATE_FILE = ''/service_spec.yml'' '
        || 'USING ('
        || 'DB_HOST => ''"' || :db_host || '"'', '
        || 'DB_PORT => ''"' || :db_port || '"'', '
        || 'COMPUTE_POOL => ''"' || :pool_name || '"'', '
        || 'CPU_REQUEST => ''' || :cpu_request || ''', '
        || 'CPU_LIMIT => ''' || :cpu_limit || ''', '
        || 'MEMORY_REQUEST => ''' || :memory_request || ''', '
        || 'MEMORY_LIMIT => ''' || :memory_limit || ''''
        || ')';

    EXECUTE IMMEDIATE :create_sql;

    -- Resume service if it already existed but was suspended
    BEGIN
        ALTER SERVICE IF EXISTS app_services.<SERVICE_NAME> RESUME;
    EXCEPTION WHEN OTHER THEN NULL; END;

    GRANT USAGE ON SERVICE app_services.<SERVICE_NAME> TO APPLICATION ROLE app_user;
    GRANT MONITOR ON SERVICE app_services.<SERVICE_NAME> TO APPLICATION ROLE app_user;

    -- Grant service role for public endpoint access
    GRANT SERVICE ROLE app_services.<SERVICE_NAME>!all_endpoints_usage TO APPLICATION ROLE app_admin;
    GRANT SERVICE ROLE app_services.<SERVICE_NAME>!all_endpoints_usage TO APPLICATION ROLE app_user;

    RETURN 'Service started.';
END;
$$;

GRANT USAGE ON PROCEDURE app_setup.start_service()
    TO APPLICATION ROLE app_admin;

-- ============================================================
-- Gallery Compatible v3: resume_service()
-- This is the PRIMARY interface for Gallery Operator.
-- Gallery Operator calls: CALL <app>.app_setup.resume_service()
-- ============================================================

CREATE OR REPLACE PROCEDURE app_setup.resume_service()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    pool_name VARCHAR;
    v_err VARCHAR;
    v_result VARCHAR;
    v_status VARCHAR;
BEGIN
    -- 1. Resume compute pool
    BEGIN
        SELECT value INTO :pool_name FROM app_config.settings WHERE key = 'compute_pool';
        IF (:pool_name IS NOT NULL AND :pool_name != '') THEN
            EXECUTE IMMEDIATE 'ALTER COMPUTE POOL IDENTIFIER(''' || :pool_name || ''') RESUME';
        END IF;
    EXCEPTION WHEN OTHER THEN NULL; END;

    -- 2. Resume service
    BEGIN
        ALTER SERVICE IF EXISTS app_services.<SERVICE_NAME> RESUME;
    EXCEPTION WHEN OTHER THEN
        v_err := SQLERRM;
        IF (:v_err ILIKE '%already%started%' OR :v_err ILIKE '%already%running%') THEN
            NULL;
        ELSEIF (:v_err ILIKE '%does not exist%') THEN
            -- First run: service not yet created
            CALL app_setup.start_service() INTO :v_result;
            RETURN 'CREATED: ' || :v_result;
        ELSE
            RETURN 'ERROR: ' || :v_err;
        END IF;
    END;

    -- 3. Health check: detect stale image path (after version upgrade)
    BEGIN
        SELECT SYSTEM$GET_SERVICE_STATUS(
            'app_services.<SERVICE_NAME>'
        ) INTO :v_status;

        IF (:v_status ILIKE '%Failed to pull image%') THEN
            DROP SERVICE IF EXISTS app_services.<SERVICE_NAME>;
            CALL app_setup.start_service() INTO :v_result;
            RETURN 'RECREATED: stale image detected';
        END IF;
    EXCEPTION WHEN OTHER THEN
        NULL;
    END;

    RETURN 'RESUMED';
END;
$$;

GRANT USAGE ON PROCEDURE app_setup.resume_service()
    TO APPLICATION ROLE app_admin;

-- Emergency drop (not called by Gallery Operator)
CREATE OR REPLACE PROCEDURE app_setup.drop_service()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
BEGIN
    DROP SERVICE IF EXISTS app_services.<SERVICE_NAME>;
    RETURN 'Service dropped.';
EXCEPTION WHEN OTHER THEN
    RETURN 'Error: ' || SQLERRM;
END;
$$;

GRANT USAGE ON PROCEDURE app_setup.drop_service()
    TO APPLICATION ROLE app_admin;

-- ============================================================
-- Gallery Compatible v3: service_status()
-- ============================================================

CREATE OR REPLACE PROCEDURE app_setup.service_status()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
BEGIN
    SHOW SERVICES LIKE '<SERVICE_NAME>' IN SCHEMA app_services;
    LET rs RESULTSET := (SELECT "status" FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())));
    LET cur CURSOR FOR rs;
    FOR rec IN cur DO
        RETURN rec."status";
    END FOR;
    RETURN 'NOT_FOUND';
END;
$$;

GRANT USAGE ON PROCEDURE app_setup.service_status()
    TO APPLICATION ROLE app_admin;
GRANT USAGE ON PROCEDURE app_setup.service_status()
    TO APPLICATION ROLE app_user;

-- ============================================================
-- Gallery Compatible v3: service_url()
-- ============================================================

CREATE OR REPLACE PROCEDURE app_setup.service_url()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
BEGIN
    SHOW ENDPOINTS IN SERVICE app_services.<SERVICE_NAME>;
    LET rs RESULTSET := (SELECT "ingress_url" FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())));
    LET cur CURSOR FOR rs;
    FOR rec IN cur DO
        RETURN rec."ingress_url";
    END FOR;
    RETURN NULL;
END;
$$;

GRANT USAGE ON PROCEDURE app_setup.service_url()
    TO APPLICATION ROLE app_admin;
GRANT USAGE ON PROCEDURE app_setup.service_url()
    TO APPLICATION ROLE app_user;

-- ============================================================
-- Service Logs (for debugging)
-- ============================================================

CREATE OR REPLACE PROCEDURE app_setup.service_logs(num_lines INTEGER DEFAULT 100)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    log_result VARCHAR DEFAULT '';
BEGIN
    BEGIN
        SELECT SYSTEM$GET_SERVICE_LOGS(
            'app_services.<SERVICE_NAME>', 0,
            '<CONTAINER_NAME>', :num_lines
        ) INTO :log_result;
    EXCEPTION WHEN OTHER THEN
        log_result := 'Error fetching logs: ' || SQLERRM;
    END;

    RETURN log_result;
END;
$$;

GRANT USAGE ON PROCEDURE app_setup.service_logs(INTEGER)
    TO APPLICATION ROLE app_admin;
