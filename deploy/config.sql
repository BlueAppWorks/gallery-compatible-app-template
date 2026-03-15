-- ============================================================
-- Gallery Compatible App - Configuration Module
-- Manages EAI references, database connection, and diagnostics.
--
-- If your app has no external database connection:
--   Remove configure_database() and get_config_status().
--   Keep register_reference() and get_eai_configuration() only if
--   your app uses an EAI for other purposes (e.g., external API).
-- ============================================================

-- ============================================================
-- EAI Reference Callbacks
-- Called by the platform when consumer binds/unbinds an EAI.
-- ============================================================

CREATE OR REPLACE PROCEDURE app_setup.register_reference(
    ref_name VARCHAR,
    operation VARCHAR,
    ref_or_alias VARCHAR
)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
BEGIN
    CASE (operation)
        WHEN 'ADD' THEN
            SELECT SYSTEM$SET_REFERENCE(:ref_name, :ref_or_alias);
        WHEN 'REMOVE' THEN
            SELECT SYSTEM$REMOVE_REFERENCE(:ref_name, :ref_or_alias);
        WHEN 'CLEAR' THEN
            SELECT SYSTEM$REMOVE_ALL_REFERENCES(:ref_name);
        ELSE
            RETURN 'Unknown operation: ' || operation;
    END CASE;
    RETURN 'OK';
END;
$$;

GRANT USAGE ON PROCEDURE app_setup.register_reference(VARCHAR, VARCHAR, VARCHAR)
    TO APPLICATION ROLE app_admin;

-- Called by platform to get EAI configuration (host_ports, allowed_secrets).
-- Reads from app_config.settings to dynamically generate network rules.
CREATE OR REPLACE PROCEDURE app_setup.get_eai_configuration(ref_name VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    db_host VARCHAR;
    db_port VARCHAR;
    config_json VARCHAR;
BEGIN
    SELECT value INTO :db_host FROM app_config.settings WHERE key = 'db_host';
    SELECT value INTO :db_port FROM app_config.settings WHERE key = 'db_port';

    IF (:db_host IS NULL OR :db_host = '') THEN
        -- Return placeholder before consumer configures the connection.
        -- The platform requires a valid response even if not yet configured.
        RETURN '{"type": "CONFIGURATION", "payload": {"host_ports": ["example.com:5432"], "allowed_secrets": "ALL"}}';
    END IF;

    db_port := COALESCE(:db_port, '5432');
    db_host := REPLACE(:db_host, '"', '');
    db_port := REPLACE(:db_port, '"', '');

    config_json := '{'
        || '"type": "CONFIGURATION",'
        || '"payload": {'
        ||     '"host_ports": ["' || :db_host || ':' || :db_port || '"],'
        ||     '"allowed_secrets": "ALL"'
        || '}'
        || '}';

    RETURN config_json;
END;
$$;

GRANT USAGE ON PROCEDURE app_setup.get_eai_configuration(VARCHAR)
    TO APPLICATION ROLE app_admin;

-- ============================================================
-- Database Connection Configuration
-- Consumer calls this from Setup UI to store connection details.
-- Credentials go to Snowflake SECRET (never in plaintext tables).
-- ============================================================

CREATE OR REPLACE PROCEDURE app_setup.configure_database(
    p_host VARCHAR,
    p_port VARCHAR DEFAULT '5432',
    p_user VARCHAR DEFAULT 'admin',
    p_pass VARCHAR DEFAULT ''
)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    safe_user VARCHAR;
    safe_pass VARCHAR;
BEGIN
    IF (:p_host IS NULL OR :p_host = '') THEN
        RETURN 'ERROR: Database host is required';
    END IF;
    IF (:p_pass IS NULL OR :p_pass = '') THEN
        RETURN 'ERROR: Database password is required';
    END IF;

    -- SQL injection prevention: escape single quotes
    safe_user := REPLACE(:p_user, '''', '''''');
    safe_pass := REPLACE(:p_pass, '''', '''''');

    -- Store credentials in Snowflake SECRET (container reads from mounted path)
    EXECUTE IMMEDIATE
        'CREATE OR REPLACE SECRET app_config.<SECRET_NAME> '
        || 'TYPE = PASSWORD '
        || 'USERNAME = ''' || :safe_user || ''' '
        || 'PASSWORD = ''' || :safe_pass || '''';

    -- Store non-sensitive config in settings table
    MERGE INTO app_config.settings AS t
    USING (
        SELECT column1 AS key, column2 AS value FROM VALUES
            ('db_host', :p_host),
            ('db_port', :p_port),
            ('db_user', :p_user),
            ('db_configured', 'true')
    ) AS s
    ON t.key = s.key
    WHEN MATCHED THEN UPDATE SET value = s.value, updated_at = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT (key, value) VALUES (s.key, s.value);

    RETURN 'Database configured: ' || :p_host || ':' || :p_port
        || '. Please approve the External Access Integration in the app settings.';
END;
$$;

GRANT USAGE ON PROCEDURE app_setup.configure_database(VARCHAR, VARCHAR, VARCHAR, VARCHAR)
    TO APPLICATION ROLE app_admin;

-- ============================================================
-- Status & Diagnostics
-- ============================================================

CREATE OR REPLACE PROCEDURE app_setup.get_config_status()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    configured VARCHAR DEFAULT 'false';
    db_host VARCHAR DEFAULT '';
    db_port VARCHAR DEFAULT '';
    db_user VARCHAR DEFAULT '';
    pool_name VARCHAR DEFAULT '';
    result VARCHAR;
BEGIN
    BEGIN SELECT value INTO :configured FROM app_config.settings WHERE key = 'db_configured';
    EXCEPTION WHEN OTHER THEN configured := 'false'; END;
    BEGIN SELECT value INTO :db_host FROM app_config.settings WHERE key = 'db_host';
    EXCEPTION WHEN OTHER THEN NULL; END;
    BEGIN SELECT value INTO :db_port FROM app_config.settings WHERE key = 'db_port';
    EXCEPTION WHEN OTHER THEN NULL; END;
    BEGIN SELECT value INTO :db_user FROM app_config.settings WHERE key = 'db_user';
    EXCEPTION WHEN OTHER THEN NULL; END;
    BEGIN SELECT value INTO :pool_name FROM app_config.settings WHERE key = 'compute_pool';
    EXCEPTION WHEN OTHER THEN NULL; END;

    result := '{'
        || '"configured": "' || COALESCE(:configured, 'false') || '",'
        || '"db_host": "' || COALESCE(:db_host, '') || '",'
        || '"db_port": "' || COALESCE(:db_port, '') || '",'
        || '"db_user": "' || COALESCE(:db_user, '') || '",'
        || '"compute_pool": "' || COALESCE(:pool_name, '') || '"'
        || '}';

    RETURN result;
END;
$$;

GRANT USAGE ON PROCEDURE app_setup.get_config_status()
    TO APPLICATION ROLE app_admin;
GRANT USAGE ON PROCEDURE app_setup.get_config_status()
    TO APPLICATION ROLE app_user;

-- ============================================================
-- Reset Configuration
-- ============================================================

CREATE OR REPLACE PROCEDURE app_setup.reset_config()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
BEGIN
    BEGIN
        ALTER SERVICE IF EXISTS app_services.<SERVICE_NAME> SUSPEND;
    EXCEPTION WHEN OTHER THEN NULL; END;

    BEGIN
        DROP SECRET IF EXISTS app_config.<SECRET_NAME>;
    EXCEPTION WHEN OTHER THEN NULL; END;

    DELETE FROM app_config.settings
    WHERE key IN ('db_host', 'db_port', 'db_user', 'db_configured');

    RETURN 'Configuration reset. You can reconfigure the database connection.';
END;
$$;

GRANT USAGE ON PROCEDURE app_setup.reset_config()
    TO APPLICATION ROLE app_admin;
