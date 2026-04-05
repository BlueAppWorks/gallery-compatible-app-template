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
-- Note: setup_ui is admin-only (not granted to app_user)

-- ============================================================
-- Gallery Compatible: resume_service() is required
-- Gallery Operator will call this procedure to start the SERVICE.
-- The GRANT to Gallery Operator is done by the consumer after
-- adding this app in the Operator dashboard.
-- ============================================================
