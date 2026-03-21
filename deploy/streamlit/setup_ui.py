"""
Gallery Compatible App - Setup UI
5-step guided wizard with progress tracking and auto-expand.

Replace <PLACEHOLDER> values with your app-specific names.
Completed steps collapse automatically; the current action step opens.
"""

import time

import streamlit as st
from snowflake.snowpark.context import get_active_session

session = get_active_session()
APP_NAME = session.sql("SELECT CURRENT_DATABASE()").collect()[0][0]

st.set_page_config(page_title=f"{APP_NAME} Setup", layout="wide")

# ============================================================
# App-specific configuration — edit these for your app
# ============================================================
# EAI logical reference name (must match manifest.yml references key)
EAI_REF_NAME = "<EAI_REF_NAME>"
EAI_DISPLAY_LABEL = "<EAI_LABEL>"

# Default port for the database connection form.
# Set DEFAULT_DB_PORT to "" if your app has no external database.
DEFAULT_DB_PORT = "5432"
DEFAULT_DB_USER = "admin"
DB_HOST_PLACEHOLDER = "your-postgres.snowflake.app"

# Resource type label shown in EAI guidance (e.g., "PostgreSQL", "External API")
RESOURCE_TYPE_LABEL = "PostgreSQL"


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


def upsert_setting(key: str, value: str):
    """Save a setting to app_config.settings."""
    safe_key = key.replace("'", "''")
    safe_value = value.replace("'", "''")
    session.sql(
        f"MERGE INTO app_config.settings AS t "
        f"USING (SELECT '{safe_key}' AS key, '{safe_value}' AS value) AS s ON t.key = s.key "
        f"WHEN MATCHED THEN UPDATE SET value = s.value, updated_at = CURRENT_TIMESTAMP() "
        f"WHEN NOT MATCHED THEN INSERT (key, value) VALUES (s.key, s.value)"
    ).collect()


def get_service_status() -> str:
    """Get the current service status string."""
    try:
        result = call_procedure("service_status")
        if result and "ERROR" not in str(result):
            return str(result).strip()
    except Exception:
        pass
    return "NOT_FOUND"


# ============================================================
# Step header with color-coded status badge
# ============================================================
def _step_header(step_num: int, title: str, state: str) -> str:
    """Return step header with status badge.

    state: 'done', 'current', 'future'
    """
    if state == "done":
        icon = "\u2705"
        color = "#0d6"
        label = "Done"
    elif state == "current":
        icon = "\u25b6\ufe0f"
        color = "#f55"
        label = "Action Required"
    else:
        icon = "\u23f3"
        color = "#888"
        label = "Pending"
    return (
        f"{icon}  **Step {step_num}: {title}**"
        f"  &nbsp; <span style='font-size:0.75rem;padding:2px 8px;border-radius:4px;"
        f"background:{color}22;color:{color};font-weight:600'>{label}</span>"
    )


def _done_badge(text: str) -> str:
    """Green summary badge for completed steps."""
    return (
        f'<div style="font-size:0.82rem;padding:6px 10px;border-radius:6px;'
        f'background:#0d662222;border:1px solid #0d663333">'
        f'<span style="color:#0d6;font-weight:600">{text}</span></div>'
    )


# ============================================================
# Sidebar Navigation
# ============================================================
pages = ["Overview", "Setup", "Advanced Settings"]
selected_page = st.sidebar.radio("Navigation", pages)


# ============================================================
# Shared State (read once, used across all pages/steps)
# ============================================================
pool_name = get_setting("compute_pool")
db_configured = get_setting("db_configured", "false")
svc_status = get_service_status()

# Step 1: Compute Pool created
step1_done = bool(pool_name)

# Step 2: Database configured
step2_done = db_configured == "true"

# Step 3: EAI approved — check via SYSTEM$GET_ALL_REFERENCES
step3_done = False
try:
    ref_result = session.sql(
        f"SELECT SYSTEM$GET_ALL_REFERENCES('{EAI_REF_NAME}')"
    ).collect()[0][0]
    if ref_result and ref_result.strip() not in ("", "[]"):
        step3_done = True
except Exception:
    pass

# Step 4: Service created (any state except NOT_FOUND)
step4_done = svc_status != "NOT_FOUND"
step4_running = svc_status in ("READY", "RUNNING")

# Step 5: Gallery Operator detected
step5_done = False
try:
    rows = session.sql(
        "SELECT app_name FROM BLUE_APP_GALLERY_REGISTRY.PUBLIC.OPERATOR "
        "WHERE app_name = 'BLUE_APP_GALLERY' LIMIT 1"
    ).collect()
    step5_done = len(rows) > 0
except Exception:
    pass

# Determine current step (first incomplete)
step_states = [step1_done, step2_done, step3_done, step4_done, step5_done]
done_count = sum(step_states)
all_done = done_count == 5

if not step1_done:
    current_step = 1
elif not step2_done:
    current_step = 2
elif not step3_done:
    current_step = 3
elif not step4_done:
    current_step = 4
elif not step5_done:
    current_step = 5
else:
    current_step = 0  # All done


def step_state(step_num: int, done: bool) -> str:
    if done:
        return "done"
    if step_num == current_step:
        return "current"
    return "future"


# ============================================================
# Page: Overview
# ============================================================
if selected_page == "Overview":
    st.title(f"{APP_NAME}")

    if step5_done:
        st.success(
            "Gallery Operator detected. "
            "This app is managed by Gallery — start and stop from the Gallery UI."
        )
    elif all_done:
        st.success("All setup steps are complete. Your app is ready to use.")
    else:
        st.info("Setup is not complete. Go to the **Setup** page to continue.")

    # Service status
    if step4_running:
        url = call_procedure("service_url")
        st.success(f"Service is **{svc_status}**")
        if url:
            st.markdown(
                f'<a href="https://{url}" target="_blank" '
                f'style="display:inline-block;margin-top:8px;padding:10px 20px;'
                f'background:#0d6efd;color:white;border-radius:8px;'
                f'text-decoration:none;font-weight:bold;">'
                f'Open {APP_NAME}</a>',
                unsafe_allow_html=True,
            )
            st.caption(f"URL: https://{url}")
    elif svc_status == "NOT_FOUND":
        st.warning("Service not yet created. Complete the Setup wizard first.")
    else:
        st.info(f"Service status: **{svc_status}**")


# ============================================================
# Page: Setup (5-step guided wizard)
# ============================================================
elif selected_page == "Setup":
    st.title("Setup Wizard")
    st.caption("Setup & Configuration")

    # Overall progress
    if all_done:
        st.success("All setup steps are complete. Your app is ready to use.")
    else:
        st.progress(done_count / 5)
        st.caption(f"Setup progress: **{done_count}/5** steps complete")

    # Quick status bar
    step_labels = ["Compute Pool", "Database", "EAI", "Service", "Gallery"]
    qs_cols = st.columns(5)
    for i, (label, done) in enumerate(zip(step_labels, step_states)):
        with qs_cols[i]:
            color = "#0d6" if done else "#f55" if (i + 1) == current_step else "#888"
            st.markdown(
                f'<div style="text-align:center;font-size:0.78rem">'
                f'<span style="display:inline-block;width:10px;height:10px;border-radius:50%;'
                f'background:{color};margin-right:4px"></span>{label}</div>',
                unsafe_allow_html=True,
            )

    st.divider()

    # ----------------------------------------------------------
    # Step 1: Compute Pool
    # ----------------------------------------------------------
    s1 = step_state(1, step1_done)
    st.markdown(_step_header(1, "Compute Pool", s1), unsafe_allow_html=True)

    with st.expander("Create compute pool for containers", expanded=(s1 == "current")):
        if step1_done:
            # Verify pool exists and show status
            pool_status = "UNKNOWN"
            try:
                rows = session.sql(
                    f"SHOW COMPUTE POOLS LIKE '{pool_name}'"
                ).collect()
                if rows:
                    pool_status = rows[0]["state"]
            except Exception:
                pass
            st.markdown(
                _done_badge(f"Compute Pool: {pool_name} ({pool_status})"),
                unsafe_allow_html=True,
            )
        else:
            # Check if CREATE COMPUTE POOL privilege is available
            has_privilege = False
            try:
                rows = session.sql(
                    f"SHOW GRANTS TO APPLICATION {APP_NAME}"
                ).collect()
                for row in rows:
                    if row["privilege"] == "CREATE COMPUTE POOL":
                        has_privilege = True
                        break
            except Exception:
                pass

            if has_privilege:
                st.info(
                    "**CREATE COMPUTE POOL** privilege is granted. "
                    "Click the button below to create the compute pool."
                )
                if st.button("Create Compute Pool", type="primary", key="create_pool"):
                    with st.spinner("Creating compute pool..."):
                        result = call_procedure("ensure_compute_pool")
                    st.success(f"Compute pool created: **{result}**")
                    time.sleep(1)
                    st.rerun()
            else:
                st.warning("**CREATE COMPUTE POOL** privilege is required.")
                st.markdown(
                    "**How to grant:**\n"
                    "1. Click the app name **in the top navigation bar** of this page\n"
                    "2. Click the **Security** tab (or the shield icon next to the app name)\n"
                    "3. Find **CREATE COMPUTE POOL** and click **Grant**\n"
                    "4. Come back to this Setup page and **refresh**"
                )

    st.divider()

    # ----------------------------------------------------------
    # Step 2: Database Connection
    # Remove this entire section if your app has no external database.
    # ----------------------------------------------------------
    s2 = step_state(2, step2_done)
    st.markdown(
        _step_header(2, f"{RESOURCE_TYPE_LABEL} Connection", s2),
        unsafe_allow_html=True,
    )

    with st.expander(
        f"Configure {RESOURCE_TYPE_LABEL} connection",
        expanded=(s2 == "current"),
    ):
        if not step1_done:
            st.caption("Complete Step 1 first.")
        elif step2_done:
            db_host = get_setting("db_host")
            db_port = get_setting("db_port", DEFAULT_DB_PORT)
            db_user = get_setting("db_user")
            st.markdown(
                _done_badge(f"{db_user}@{db_host}:{db_port}"),
                unsafe_allow_html=True,
            )
            st.caption("")
            if st.button("Reset Connection", type="secondary", key="reset_db"):
                call_procedure("reset_config")
                time.sleep(1)
                st.rerun()
        else:
            st.info(
                f"Configure the {RESOURCE_TYPE_LABEL} connection. "
                "Credentials are stored securely in a Snowflake SECRET."
            )
            with st.form("db_config"):
                db_host = st.text_input("Host", placeholder=DB_HOST_PLACEHOLDER)
                db_port = st.text_input("Port", value=DEFAULT_DB_PORT)
                db_user = st.text_input("Username", value=DEFAULT_DB_USER)
                db_pass = st.text_input("Password", type="password")
                db_name = st.text_input(
                    "Database", placeholder="my_database",
                    help="Optional: used by your app to select the target database",
                )

                if st.form_submit_button("Save Configuration", type="primary"):
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
                            time.sleep(1)
                            st.rerun()

    st.divider()

    # ----------------------------------------------------------
    # Step 3: External Access Integration (EAI)
    # Remove this section if your app has no external network access.
    # ----------------------------------------------------------
    s3 = step_state(3, step3_done)
    st.markdown(
        _step_header(3, "External Access Integration (EAI)", s3),
        unsafe_allow_html=True,
    )

    with st.expander(
        f"Approve EAI for {RESOURCE_TYPE_LABEL} connectivity",
        expanded=(s3 == "current"),
    ):
        if not step1_done or not step2_done:
            st.caption("Complete Steps 1 and 2 first.")
        elif step3_done:
            st.markdown(
                _done_badge(f"EAI Approved — {RESOURCE_TYPE_LABEL} access enabled"),
                unsafe_allow_html=True,
            )
        else:
            st.warning(
                f"**EAI approval is required** before the service can connect to "
                f"{RESOURCE_TYPE_LABEL}.\n\n"
                "The service will **fail to start** without this approval."
            )
            st.markdown(
                "**What is EAI?**\n\n"
                "External Access Integration (EAI) is a Snowflake security control that "
                "allows containers to make outbound network connections. "
                f"This app needs EAI to connect to your {RESOURCE_TYPE_LABEL} instance."
            )

            db_host_display = get_setting("db_host", "your-database-host")
            db_port_display = get_setting("db_port", DEFAULT_DB_PORT)

            st.markdown(
                "**How to approve:**\n\n"
                f"1. Click the app name **{APP_NAME}** in the top navigation bar of this page\n"
                "2. Click the **Security** tab (shield icon)\n"
                f"3. Find **\"{EAI_DISPLAY_LABEL}\"** under External Access\n"
                "4. Click **Review** to see the connection details:\n"
                f"   - Allowed host: `{db_host_display}:{db_port_display}`\n"
                "5. Click **Approve**\n"
                "6. Come back to this Setup page and click **Check EAI Status** below"
            )

            st.info(
                "**Tip:** The Security tab is in Snowsight's Native App detail page, "
                "not inside this Streamlit app. Look for the tab bar at the top that shows "
                "the app name."
            )

            if st.button("Check EAI Status", type="primary", key="check_eai"):
                st.rerun()

    st.divider()

    # ----------------------------------------------------------
    # Step 4: Service
    # ----------------------------------------------------------
    s4 = step_state(4, step4_done)
    st.markdown(_step_header(4, "Service", s4), unsafe_allow_html=True)

    with st.expander("Service status and Web UI", expanded=(s4 == "current")):
        if not step1_done or not step2_done or not step3_done:
            missing = []
            if not step1_done:
                missing.append("Step 1 (Compute Pool)")
            if not step2_done:
                missing.append("Step 2 (Database Connection)")
            if not step3_done:
                missing.append("Step 3 (EAI Approval)")
            st.caption(f"Complete {', '.join(missing)} first.")
        elif step4_running:
            st.markdown(
                _done_badge(f"Service: {svc_status}"),
                unsafe_allow_html=True,
            )
            url = call_procedure("service_url")
            if url and url.strip():
                st.markdown(
                    f'<a href="https://{url}" target="_blank" '
                    f'style="display:inline-block;margin-top:8px;padding:10px 20px;'
                    f'background:#0d6efd;color:white;border-radius:8px;'
                    f'text-decoration:none;font-weight:bold;">'
                    f'Open {APP_NAME}</a>',
                    unsafe_allow_html=True,
                )
                st.caption(f"URL: https://{url}")
            else:
                st.info("Endpoint URL is being provisioned. Refresh in a moment.")
        elif step4_done:
            # Service exists but not running
            st.markdown(
                _done_badge(f"Service created (status: {svc_status})"),
                unsafe_allow_html=True,
            )
            st.caption(
                "Start/stop is managed by Gallery Operator. "
                "Use the Gallery UI to start the app."
            )
        else:
            st.info(
                "**Create the service for the first time.**\n\n"
                "This is a one-time action. After creation, Gallery Operator "
                "will manage start/stop."
            )
            if st.button("Create Service", type="primary", key="create_svc"):
                with st.spinner("Starting service..."):
                    result = call_procedure("start_service")
                if "ERROR" in str(result):
                    st.error(result)
                else:
                    st.success(result)
                    time.sleep(2)
                    st.rerun()

        # Troubleshooting (available when service has been created)
        if step2_done and step4_done:
            st.markdown("---")
            st.caption(
                "If the service is stuck or unreachable, you can recreate it here."
            )
            t_cols = st.columns(2)
            with t_cols[0]:
                if st.button("Recreate Service", key="recreate_svc"):
                    call_procedure("drop_service")
                    result = call_procedure("start_service")
                    st.info(result)
                    time.sleep(2)
                    st.rerun()
            with t_cols[1]:
                if st.button("Fetch Logs", key="fetch_logs"):
                    logs = call_procedure("service_logs", 100)
                    if "ERROR" in str(logs):
                        st.error(logs)
                    else:
                        st.code(logs, language="text")

    st.divider()

    # ----------------------------------------------------------
    # Step 5: Gallery Operator Integration
    # ----------------------------------------------------------
    s5 = step_state(5, step5_done)
    st.markdown(
        _step_header(5, "Gallery Operator Integration", s5),
        unsafe_allow_html=True,
    )

    with st.expander("Connect to Gallery Operator", expanded=(s5 == "current")):
        if step5_done:
            st.markdown(
                _done_badge("Gallery Operator Connected"),
                unsafe_allow_html=True,
            )
        else:
            st.info(
                "Run the following GRANTs in a **Snowsight SQL Worksheet** as **ACCOUNTADMIN** "
                "to connect this app with Gallery Operator."
            )

        # Build GRANT SQL with actual or placeholder names
        pool_display = pool_name if pool_name else "<COMPUTE_POOL_NAME>"

        grant_sql = (
            f"-- Run in Snowsight Worksheet as ACCOUNTADMIN\n\n"
            f"-- 1. Registry access (Gallery Operator detection)\n"
            f"GRANT USAGE ON DATABASE BLUE_APP_GALLERY_REGISTRY\n"
            f"    TO APPLICATION {APP_NAME};\n"
            f"GRANT USAGE ON SCHEMA BLUE_APP_GALLERY_REGISTRY.PUBLIC\n"
            f"    TO APPLICATION {APP_NAME};\n"
            f"GRANT SELECT ON TABLE BLUE_APP_GALLERY_REGISTRY.PUBLIC.OPERATOR\n"
            f"    TO APPLICATION {APP_NAME};\n"
            f"\n"
            f"-- 2. App role (allows Gallery Operator to manage this app)\n"
            f"GRANT APPLICATION ROLE {APP_NAME}.app_admin\n"
            f"    TO APPLICATION BLUE_APP_GALLERY;\n"
            f"\n"
            f"-- 3. Compute Pool (start/stop control)\n"
            f"GRANT OPERATE ON COMPUTE POOL {pool_display}\n"
            f"    TO APPLICATION BLUE_APP_GALLERY;\n"
            f"GRANT MONITOR ON COMPUTE POOL {pool_display}\n"
            f"    TO APPLICATION BLUE_APP_GALLERY;\n"
        )

        st.code(grant_sql, language="sql")

        if not pool_name:
            st.caption(
                "`<COMPUTE_POOL_NAME>` will be replaced when the compute pool is created."
            )

        if not step5_done:
            if st.button("Check Gallery Operator", type="primary", key="check_gallery"):
                st.rerun()


# ============================================================
# Page: Advanced Settings
# Add your app-specific settings here.
# ============================================================
elif selected_page == "Advanced Settings":
    st.title("Advanced Settings")
    st.info("Add your app-specific configuration here (resource sizing, feature flags, etc.)")

    # Resource sizing
    with st.expander("Service Resource Limits", expanded=False):
        st.caption(
            "Default settings are sufficient for most use cases. "
            "Changes take effect on next service start."
        )
        with st.form("resource_config"):
            col1, col2 = st.columns(2)
            with col1:
                cpu_req = st.text_input(
                    "CPU Request", value=get_setting("cpu_request", "0.5")
                )
                mem_req = st.text_input(
                    "Memory Request", value=get_setting("memory_request", "1Gi")
                )
            with col2:
                cpu_lim = st.text_input(
                    "CPU Limit", value=get_setting("cpu_limit", "2")
                )
                mem_lim = st.text_input(
                    "Memory Limit", value=get_setting("memory_limit", "4Gi")
                )

            if st.form_submit_button("Save Resource Settings"):
                upsert_setting("cpu_request", cpu_req)
                upsert_setting("cpu_limit", cpu_lim)
                upsert_setting("memory_request", mem_req)
                upsert_setting("memory_limit", mem_lim)
                st.success("Resource settings saved. Restart the service to apply.")

    # Service logs
    with st.expander("Service Logs", expanded=False):
        if st.button("Fetch Logs", key="adv_fetch_logs"):
            logs = call_procedure("service_logs", 100)
            if "ERROR" in str(logs):
                st.error(logs)
            else:
                st.code(logs, language="text")
