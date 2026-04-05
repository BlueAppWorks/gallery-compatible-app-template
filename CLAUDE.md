# Gallery Compatible App Template — AI Agent Instructions

You are building a Snowflake Native App that is **Gallery Compatible**.
This template provides the exact structure required for compatibility with Blue App Gallery.

**CRITICAL: Follow this template strictly. Deviations will cause deployment failures or Gallery incompatibility.**

---

## File Priority (Read These First)

| Priority | File | Purpose |
|----------|------|---------|
| 1 | `CLAUDE.md` (this file) | Agent instructions |
| 2 | `docs/gallery-compatible-spec.md` | Full specification |
| 3 | `deploy/scripts/setup.sql` | Core schema and procedures |
| 4 | `deploy/manifest.yml` | App manifest |
| 5 | `deploy/streamlit/setup_ui.py` | Admin UI |

---

## MUST NOT CHANGE (Gallery Compatible Requirements)

These elements are **mandatory** for Gallery compatibility. Do not modify, rename, or remove:

### 1. APPLICATION ROLE `app_admin`
```sql
-- deploy/scripts/setup.sql
CREATE APPLICATION ROLE IF NOT EXISTS app_admin;
```
Gallery Operator grants this role to control the app. Name must be exactly `app_admin`.

### 2. `resume_service()` Procedure Signature
```sql
-- deploy/scripts/setup.sql
CREATE OR REPLACE PROCEDURE app_setup.resume_service()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
```
- Must exist in `app_setup` schema
- Must take no arguments
- Must return VARCHAR
- Must be granted to `app_admin`

### 3. `service_status()` and `service_url()` Procedures
Same requirements as `resume_service()`. Gallery uses these for health checks.

### 4. Schema Structure
```
app_public   -- Public objects (Streamlit UI)
app_setup    -- Setup procedures (Gallery-facing)
app_config   -- Configuration tables and secrets
app_services -- Container services
```
Do not rename these schemas.

### 5. Manifest Privileges
```yaml
# deploy/manifest.yml
privileges:
  - CREATE COMPUTE POOL:
      description: "..."
  - BIND SERVICE ENDPOINT:
      description: "..."
```
These two privileges are required for SPCS apps.

---

## EXTENSION POINTS (Add App-Specific Features Here)

### A. Additional Secrets (e.g., OpenAI API Key)

**Where to add:**

1. **`deploy/config.sql`** — Add a new procedure:
```sql
CREATE OR REPLACE PROCEDURE app_setup.configure_api_key(p_api_key VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
BEGIN
    CREATE OR REPLACE SECRET app_config.openai_secret
        TYPE = GENERIC_STRING
        SECRET_STRING = :p_api_key;
    RETURN 'API key configured';
END;
$$;

GRANT USAGE ON PROCEDURE app_setup.configure_api_key(VARCHAR)
    TO APPLICATION ROLE app_admin;
```

2. **`deploy/service_spec.yml`** — Add secret mount:
```yaml
secrets:
  # Existing database secret
  - snowflakeSecret: app_config.db_secret
    secretKeyRef: username
    envVarName: DB_USER
  # NEW: API key secret
  - snowflakeSecret: app_config.openai_secret
    envVarName: OPENAI_API_KEY
```

3. **`deploy/streamlit/setup_ui.py`** — Add UI in Step 2 section:
```python
# After database configuration, add:
st.subheader("API Keys")
with st.form("api_key_form"):
    api_key = st.text_input("OpenAI API Key", type="password")
    if st.form_submit_button("Save API Key"):
        result = call_procedure("configure_api_key", api_key)
        st.success(result) if not result.startswith("ERROR") else st.error(result)
```

### B. Additional External Access (Multiple EAIs)

**Where to add:**

1. **`deploy/manifest.yml`** — Add to references:
```yaml
references:
  - db_eai:
      label: "Database Access"
      # ... existing
  - openai_eai:           # NEW
      label: "OpenAI API Access"
      description: "External access for OpenAI API calls"
      privileges:
        - USAGE
      object_type: EXTERNAL ACCESS INTEGRATION
      required_at_setup: false
      register_callback: app_setup.register_reference
```

2. **`deploy/streamlit/setup_ui.py`** — The existing EAI UI will automatically show both references.

### C. Additional Configuration Steps in Setup UI

**Pattern:** Insert new steps between existing steps. Use the `step_state()` helper.

```python
# In setup_ui.py, after Step 2 (Database):

# ----------------------------------------------------------
# Step 2.5: API Configuration (YOUR CUSTOM STEP)
# ----------------------------------------------------------
s2_5 = step_state(2.5, api_configured)
st.markdown(f"{s2_5} **Step 2.5: API Configuration**")
# Your custom UI here
```

### D. Additional Procedures

**Where to add:** `deploy/config.sql` or `deploy/services.sql`

**Pattern:**
```sql
CREATE OR REPLACE PROCEDURE app_setup.your_procedure(...)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
BEGIN
    -- Your logic
    RETURN 'Success';
EXCEPTION
    WHEN OTHER THEN
        RETURN 'ERROR: ' || SQLERRM;
END;
$$;

-- Grant to app_admin if needed from Gallery/external
GRANT USAGE ON PROCEDURE app_setup.your_procedure(...)
    TO APPLICATION ROLE app_admin;
```

---

## MUST REPLACE (Placeholders)

Search and replace ALL placeholders before deployment:

| Placeholder | Location | Example Value |
|-------------|----------|---------------|
| `<APP_NAME>` | manifest.yml | `My Analytics App` |
| `<APP_DESCRIPTION>` | manifest.yml | `Real-time analytics dashboard` |
| `<IMAGE_PATH>` | manifest.yml, service_spec.yml | `/my_db/my_schema/my_repo/app:v1` |
| `<CONTAINER_NAME>` | service_spec.yml | `app` |
| `<ENDPOINT_PORT>` | service_spec.yml | `8501` (Streamlit) or `8080` |
| `<SERVICE_NAME>` | services.sql, config.sql | `analytics_service` |
| `<SECRET_NAME>` | service_spec.yml, config.sql | `db_secret` |
| `<EAI_REF_NAME>` | manifest.yml, config.sql | `db_eai` |
| `<EAI_LABEL>` | manifest.yml | `PostgreSQL Access` |

**Validation:** Run `grep -r "<" deploy/` to find remaining placeholders.

---

## COMMON MISTAKES (Avoid These)

### 1. Renaming `app_admin` Role
**Wrong:** `CREATE APPLICATION ROLE admin;`
**Right:** `CREATE APPLICATION ROLE IF NOT EXISTS app_admin;`

Gallery Operator looks for exactly `app_admin`.

### 2. Adding Arguments to `resume_service()`
**Wrong:** `PROCEDURE app_setup.resume_service(p_timeout INT)`
**Right:** `PROCEDURE app_setup.resume_service()`

Gallery calls it with no arguments.

### 3. Forgetting GRANT to `app_admin`
**Wrong:** Creating procedure without GRANT
**Right:**
```sql
GRANT USAGE ON PROCEDURE app_setup.resume_service()
    TO APPLICATION ROLE app_admin;
```

### 4. Using Wrong Schema for Setup Procedures
**Wrong:** `CREATE PROCEDURE app_public.resume_service()`
**Right:** `CREATE PROCEDURE app_setup.resume_service()`

Gallery expects procedures in `app_setup` schema.

### 5. Hardcoding Compute Pool Name
**Wrong:** `ALTER COMPUTE POOL my_pool RESUME;`
**Right:**
```sql
LET pool_name := (SELECT value FROM app_config.settings WHERE key = 'compute_pool');
EXECUTE IMMEDIATE 'ALTER COMPUTE POOL ' || pool_name || ' RESUME';
```

Compute pool name is set by the consumer during setup.

### 6. Modifying setup_ui.py Structure Drastically
**Wrong:** Rewriting the entire file
**Right:** Add your custom steps between existing steps, keep the step numbering pattern

### 7. Removing Database Configuration When Not Needed
**Wrong:** Deleting the entire Step 2 section
**Right:** Keep the structure, add a comment that it's not used:
```python
# Step 2: Database Configuration (Not used in this app)
# Kept for template consistency
```

---

## QUICK START CHECKLIST

1. [ ] Replace ALL `<PLACEHOLDER>` values
2. [ ] Keep `app_admin` role name unchanged
3. [ ] Keep `resume_service()`, `service_status()`, `service_url()` signatures unchanged
4. [ ] Add custom secrets/configs as EXTENSION (don't modify core structure)
5. [ ] Test with `snow app run` before publishing
6. [ ] Verify Gallery compatibility: `CALL app_setup.resume_service()` works

---

## DIRECTORY STRUCTURE

```
deploy/
├── manifest.yml          # App manifest (privileges, references)
├── service_spec.yml      # Container spec (secrets, env vars, resources)
├── config.sql            # Configuration procedures (DB, secrets)
├── services.sql          # Service lifecycle procedures
├── scripts/
│   └── setup.sql         # Schema, roles, Streamlit, core procedures
├── streamlit/
│   └── setup_ui.py       # Admin UI (setup wizard)
└── deploy.sh             # Deployment script

docs/
└── gallery-compatible-spec.md  # Full specification (read for details)
```

---

## WHEN IN DOUBT

1. Read `docs/gallery-compatible-spec.md` for the full specification
2. Keep the existing structure, add to it rather than replacing
3. Test `resume_service()` manually before deploying to Gallery
4. Check that all GRANTs to `app_admin` are in place
