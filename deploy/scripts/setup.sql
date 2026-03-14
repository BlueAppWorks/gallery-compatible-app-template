-- ============================================================
-- Gallery Compatible App - Setup Script (Entry Point)
-- Gallery Compatible v3 — lifecycle managed by Gallery Operator
-- ============================================================

-- Application Roles
CREATE APPLICATION ROLE IF NOT EXISTS app_admin;
CREATE APPLICATION ROLE IF NOT EXISTS app_user;
GRANT APPLICATION ROLE app_user TO APPLICATION ROLE app_admin;

-- ============================================================
-- Schemas
-- ============================================================

-- Public schema: Streamlit UI and user-facing objects
CREATE SCHEMA IF NOT EXISTS app_public;
GRANT USAGE ON SCHEMA app_public TO APPLICATION ROLE app_admin;
GRANT USAGE ON SCHEMA app_public TO APPLICATION ROLE app_user;

-- Setup schema: Internal procedures (versioned for upgrade safety)
CREATE OR ALTER VERSIONED SCHEMA app_setup;
GRANT USAGE ON SCHEMA app_setup TO APPLICATION ROLE app_admin;

-- Services schema: SPCS services
CREATE SCHEMA IF NOT EXISTS app_services;
GRANT USAGE ON SCHEMA app_services TO APPLICATION ROLE app_admin;
GRANT USAGE ON SCHEMA app_services TO APPLICATION ROLE app_user;

-- Config schema: Secrets, network rules, settings
CREATE SCHEMA IF NOT EXISTS app_config;
GRANT USAGE ON SCHEMA app_config TO APPLICATION ROLE app_admin;

-- ============================================================
-- Settings table (key-value store for consumer configuration)
-- ============================================================
CREATE TABLE IF NOT EXISTS app_config.settings (
    key VARCHAR NOT NULL,
    value VARCHAR,
    updated_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    PRIMARY KEY (key)
);

GRANT SELECT ON TABLE app_config.settings TO APPLICATION ROLE app_user;

-- ============================================================
-- Load module SQL files
-- ============================================================
EXECUTE IMMEDIATE FROM './config.sql';
EXECUTE IMMEDIATE FROM './services.sql';
-- Add your app-specific SQL modules here:
-- EXECUTE IMMEDIATE FROM './my_module.sql';

-- ============================================================
-- Streamlit UI
-- ============================================================
CREATE OR REPLACE STREAMLIT app_public.setup_ui
    FROM '/streamlit'
    MAIN_FILE = '/setup_ui.py';

GRANT USAGE ON STREAMLIT app_public.setup_ui TO APPLICATION ROLE app_admin;
GRANT USAGE ON STREAMLIT app_public.setup_ui TO APPLICATION ROLE app_user;

-- ============================================================
-- Gallery Operator Detection & Auto-Grant
-- At install time, registry access may not yet be granted.
-- This is a best-effort attempt; the Setup UI handles the fallback.
-- ============================================================
DECLARE
    v_gallery_available BOOLEAN DEFAULT FALSE;
BEGIN
    BEGIN
        SELECT TRUE INTO :v_gallery_available
        FROM BLUE_APP_GALLERY_REGISTRY.PUBLIC.OPERATOR
        WHERE app_name = 'BLUE_APP_GALLERY'
        LIMIT 1;
    EXCEPTION WHEN OTHER THEN
        v_gallery_available := FALSE;
    END;

    IF (:v_gallery_available) THEN
        BEGIN
            GRANT APPLICATION ROLE app_admin TO APPLICATION BLUE_APP_GALLERY;
        EXCEPTION WHEN OTHER THEN
            NULL; -- already granted or not yet accessible
        END;
    END IF;
END;
