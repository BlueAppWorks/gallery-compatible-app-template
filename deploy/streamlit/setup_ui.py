"""
Gallery Compatible App - Setup UI
4-step wizard for consumer setup + Gallery Integration.

Replace <PLACEHOLDER> values with your app-specific names.
"""

import streamlit as st
from snowflake.snowpark.context import get_active_session

session = get_active_session()
APP_NAME = session.sql("SELECT CURRENT_DATABASE()").collect()[0][0]

st.set_page_config(page_title=f"{APP_NAME} Setup", layout="wide")

# ============================================================
# Sidebar Navigation
# ============================================================
pages = ["Overview", "Setup", "Advanced Settings"]
selected_page = st.sidebar.radio("Navigation", pages)


# ============================================================
# Helper Functions
# ============================================================
def get_setting(key: str, default: str = "") -> str:
    """Read a value from app_config.settings."""
    try:
        rows = session.sql(
            f"SELECT value FROM app_config.settings WHERE key = '{key}'"
        ).collect()
        return rows[0]["VALUE"] if rows else default
    except Exception:
        return default


def call_procedure(proc: str, *args) -> str:
    """Call a stored procedure and return the result string."""
    if args:
        arg_str = ", ".join(
            f"'{a}'" if isinstance(a, str) else str(a) for a in args
        )
        result = session.sql(f"CALL app_setup.{proc}({arg_str})").collect()
    else:
        result = session.sql(f"CALL app_setup.{proc}()").collect()
    return str(result[0][0]) if result else ""


# ============================================================
# Gallery Operator Detection
# ============================================================
gallery_operator_installed = False
gallery_operator_version = None
try:
    rows = session.sql(
        "SELECT version FROM BLUE_APP_GALLERY_REGISTRY.PUBLIC.OPERATOR "
        "WHERE app_name = 'BLUE_APP_GALLERY' LIMIT 1"
    ).collect()
    gallery_operator_installed = len(rows) > 0
    if gallery_operator_installed:
        gallery_operator_version = rows[0]["VERSION"]
except Exception:
    pass


# ============================================================
# Page: Overview
# ============================================================
if selected_page == "Overview":
    st.title(f"{APP_NAME}")

    if gallery_operator_installed:
        st.success(
            f"Gallery Operator detected (v{gallery_operator_version}). "
            "This app is managed by Gallery — start and stop from the Gallery UI."
        )
    else:
        st.info("Gallery Operator not detected. Use the Setup page to configure manually.")

    # Service status
    status = call_procedure("service_status")
    if status == "RUNNING":
        url = call_procedure("service_url")
        st.success(f"Service is **{status}**")
        if url:
            st.markdown(f"**Endpoint:** [https://{url}](https://{url})")
    elif status == "NOT_FOUND":
        st.warning("Service not yet created. Complete the Setup wizard first.")
    else:
        st.info(f"Service status: **{status}**")


# ============================================================
# Page: Setup (4-step wizard)
# ============================================================
elif selected_page == "Setup":
    st.title("Setup Wizard")

    # ----------------------------------------------------------
    # Step 1: Compute Pool
    # ----------------------------------------------------------
    st.header("Step 1: Compute Pool")

    pool_name = get_setting("compute_pool")
    if pool_name:
        st.success(f"Compute pool: **{pool_name}**")
    else:
        st.warning(
            "Compute pool not yet created. "
            "Grant the **CREATE COMPUTE POOL** privilege in the app's security settings."
        )
        st.info(
            "After granting, the pool is auto-created via the grant callback. "
            "Refresh this page to see the result."
        )

    # ----------------------------------------------------------
    # Step 2: Database Connection
    # Remove this section if your app has no external database.
    # ----------------------------------------------------------
    st.header("Step 2: Database Connection")

    configured = get_setting("db_configured", "false")
    if configured == "true":
        db_host = get_setting("db_host")
        db_port = get_setting("db_port", "<DB_PORT>")
        db_user = get_setting("db_user")
        st.success(f"Connected to: **{db_user}@{db_host}:{db_port}**")

        if st.button("Reset Connection"):
            call_procedure("reset_config")
            st.rerun()
    else:
        with st.form("db_config"):
            db_host = st.text_input("Host", placeholder="your-database.example.com")
            db_port = st.text_input("Port", value="<DB_PORT>")
            db_user = st.text_input("Username", value="admin")
            db_pass = st.text_input("Password", type="password")

            if st.form_submit_button("Save Configuration"):
                if not db_host or not db_pass:
                    st.error("Host and password are required.")
                else:
                    result = call_procedure(
                        "configure_database", db_host, db_port, db_user, db_pass
                    )
                    if result.startswith("ERROR"):
                        st.error(result)
                    else:
                        st.success(result)
                        st.info(
                            "**Next:** Approve the External Access Integration in "
                            "the app's security settings, then come back to start the service."
                        )
                        st.rerun()

    # ----------------------------------------------------------
    # Step 3: Service
    # ----------------------------------------------------------
    st.header("Step 3: Service")

    status = call_procedure("service_status")
    st.info(f"Current status: **{status}**")

    if status == "NOT_FOUND":
        can_start = pool_name and configured == "true"
        if can_start:
            if st.button("Start Service"):
                with st.spinner("Starting service..."):
                    result = call_procedure("start_service")
                st.success(result)
                st.rerun()
        else:
            st.warning("Complete Steps 1 and 2 before starting the service.")
    elif status == "RUNNING":
        url = call_procedure("service_url")
        if url:
            st.success(f"Endpoint: [https://{url}](https://{url})")
        else:
            st.info("Service is running but endpoint is not yet available. Please wait...")
    elif status == "SUSPENDED":
        st.info(
            "Service is suspended. "
            "If Gallery Operator is configured, start it from the Gallery UI."
        )

    # ----------------------------------------------------------
    # Step 4: Gallery Integration
    # ----------------------------------------------------------
    st.header("Step 4: Gallery Integration")

    if gallery_operator_installed:
        st.success(f"Gallery Operator: detected (v{gallery_operator_version})")

        with st.expander("Grant commands for Gallery Operator (if not already done)"):
            st.markdown(
                "Run the following as **ACCOUNTADMIN** to allow Gallery Operator "
                "to manage this app's compute pool and service:"
            )
            grant_sql = (
                f"-- Grant compute pool control\n"
                f"GRANT OPERATE ON COMPUTE POOL {pool_name} TO APPLICATION APP_GALLERY_OPERATOR;\n"
                f"GRANT MONITOR ON COMPUTE POOL {pool_name} TO APPLICATION APP_GALLERY_OPERATOR;\n"
                f"\n"
                f"-- Grant app role (for resume_service)\n"
                f"GRANT APPLICATION ROLE {APP_NAME}.app_admin TO APPLICATION APP_GALLERY_OPERATOR;"
            )
            st.code(grant_sql, language="sql")
    else:
        st.warning("**Gallery Operator not detected.**")
        st.markdown(
            "This can mean:\n"
            "- Gallery Operator is not installed\n"
            "- Installed but registry access is not granted to this app\n\n"
            "If Gallery Operator is installed, run the following as **ACCOUNTADMIN**:"
        )
        st.code(
            f"-- Grant registry access to this app\n"
            f"GRANT USAGE ON DATABASE BLUE_APP_GALLERY_REGISTRY\n"
            f"    TO APPLICATION {APP_NAME};\n"
            f"GRANT USAGE ON SCHEMA BLUE_APP_GALLERY_REGISTRY.PUBLIC\n"
            f"    TO APPLICATION {APP_NAME};\n"
            f"GRANT SELECT ON TABLE BLUE_APP_GALLERY_REGISTRY.PUBLIC.OPERATOR\n"
            f"    TO APPLICATION {APP_NAME};",
            language="sql",
        )


# ============================================================
# Page: Advanced Settings
# Add your app-specific settings here.
# ============================================================
elif selected_page == "Advanced Settings":
    st.title("Advanced Settings")
    st.info("Add your app-specific configuration here (resource sizing, feature flags, etc.)")

    # Example: Resource sizing
    st.subheader("Container Resources")

    with st.form("resource_config"):
        col1, col2 = st.columns(2)
        with col1:
            cpu_req = st.text_input("CPU Request", value=get_setting("cpu_request", "0.5"))
            mem_req = st.text_input("Memory Request", value=get_setting("memory_request", "1Gi"))
        with col2:
            cpu_lim = st.text_input("CPU Limit", value=get_setting("cpu_limit", "2"))
            mem_lim = st.text_input("Memory Limit", value=get_setting("memory_limit", "4Gi"))

        if st.form_submit_button("Save Resources"):
            for key, val in [
                ("cpu_request", cpu_req), ("cpu_limit", cpu_lim),
                ("memory_request", mem_req), ("memory_limit", mem_lim),
            ]:
                session.sql(
                    f"MERGE INTO app_config.settings AS t "
                    f"USING (SELECT '{key}' AS key, '{val}' AS value) AS s "
                    f"ON t.key = s.key "
                    f"WHEN MATCHED THEN UPDATE SET value = s.value, updated_at = CURRENT_TIMESTAMP() "
                    f"WHEN NOT MATCHED THEN INSERT (key, value) VALUES (s.key, s.value)"
                ).collect()
            st.success("Resource settings saved. Restart the service to apply.")

    # Service logs
    st.subheader("Service Logs")
    if st.button("Fetch Logs"):
        logs = call_procedure("service_logs", 50)
        st.code(logs)
