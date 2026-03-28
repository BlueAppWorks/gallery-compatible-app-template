# Image Versioning & Deploy Best Practices for SPCS

## Problem

When updating a Native App that runs on SPCS, you may encounter situations where the service continues running an old container image even after pushing a new one. This is caused by two independent caching/staleness issues.

## Issue 1: `:latest` Tag Caching

SPCS caches container images by tag. If you push a new image with the same tag (e.g., `:latest`), SPCS may not re-pull it when the service is restarted.

**Solution:** Always use explicit version tags.

```
# Bad: SPCS may serve cached image
docker push registry.snowflakecomputing.com/.../my-app:latest

# Good: new tag forces a fresh pull
docker push registry.snowflakecomputing.com/.../my-app:v3
```

Update both `manifest.yml` and `service_spec.yml` to reference the new tag:

```yaml
# manifest.yml
artifacts:
  container_services:
    images:
      - /MY_DB/MY_SCHEMA/MY_REPO/my-app:v3   # ← match the pushed tag

# service_spec.yml
spec:
  containers:
  - name: my-app
    image: /MY_DB/MY_SCHEMA/MY_REPO/my-app:v3  # ← match the pushed tag
```

## Issue 2: Stage Files Not Reflected After VERSION Registration

Once a VERSION is registered with `ALTER APPLICATION PACKAGE ... REGISTER VERSION`, the stage files are snapshotted. Uploading new files to the stage (via PUT) does **not** update an already-registered VERSION.

**Solution:** Always deregister the old version and register a new one after uploading updated files.

## Recommended Deploy Procedure

```bash
# 1. Build and push with a new version tag
docker build -t registry.snowflakecomputing.com/.../my-app:v3 .
docker push registry.snowflakecomputing.com/.../my-app:v3

# 2. Update manifest.yml and service_spec.yml to reference :v3

# 3. Upload ALL deploy files to stage (every file, not just the ones you changed)
#    Missing even one file can cause subtle issues (e.g., old service_spec used)
snow sql -q "PUT 'file://deploy/manifest.yml'      @MY_PKG.APP_SRC.STAGE/          OVERWRITE=TRUE AUTO_COMPRESS=FALSE"
snow sql -q "PUT 'file://deploy/service_spec.yml'   @MY_PKG.APP_SRC.STAGE/          OVERWRITE=TRUE AUTO_COMPRESS=FALSE"
snow sql -q "PUT 'file://deploy/scripts/setup.sql'  @MY_PKG.APP_SRC.STAGE/scripts/  OVERWRITE=TRUE AUTO_COMPRESS=FALSE"
snow sql -q "PUT 'file://deploy/config.sql'          @MY_PKG.APP_SRC.STAGE/          OVERWRITE=TRUE AUTO_COMPRESS=FALSE"
snow sql -q "PUT 'file://deploy/services.sql'        @MY_PKG.APP_SRC.STAGE/          OVERWRITE=TRUE AUTO_COMPRESS=FALSE"
snow sql -q "PUT 'file://deploy/streamlit/setup_ui.py' @MY_PKG.APP_SRC.STAGE/streamlit/ OVERWRITE=TRUE AUTO_COMPRESS=FALSE"
snow sql -q "PUT 'file://deploy/streamlit/environment.yml' @MY_PKG.APP_SRC.STAGE/streamlit/ OVERWRITE=TRUE AUTO_COMPRESS=FALSE"

# 4. Deregister old version, register new
snow sql -q "ALTER APPLICATION PACKAGE MY_PKG DEREGISTER VERSION V2"
snow sql -q "ALTER APPLICATION PACKAGE MY_PKG REGISTER VERSION V3 USING '@MY_PKG.APP_SRC.STAGE'"

# 5. Recreate application (or upgrade if versioned schema supports it)
#    Note: CREATE APPLICATION requires an active warehouse in the session
snow sql -q "CREATE WAREHOUSE IF NOT EXISTS SETUP_WH WAREHOUSE_SIZE='XSMALL' AUTO_SUSPEND=60 AUTO_RESUME=TRUE"
snow sql -q "USE WAREHOUSE SETUP_WH"
snow sql -q "DROP APPLICATION IF EXISTS MY_APP CASCADE"
snow sql -q "CREATE APPLICATION MY_APP FROM APPLICATION PACKAGE MY_PKG USING VERSION V3"
```

## Upgrade Without Recreating (Preserves Settings)

Recreating the application (`DROP` + `CREATE`) resets all consumer settings (DB connections, EAI bindings, compute pool, etc.). To avoid this, use `ALTER APPLICATION ... UPGRADE` when possible:

```sql
-- Set the default release directive to the new version
-- For packages WITHOUT release channels:
ALTER APPLICATION PACKAGE MY_PKG SET DEFAULT RELEASE DIRECTIVE VERSION = V3 PATCH = 0;

-- For packages WITH release channels (e.g., Marketplace listings):
ALTER APPLICATION PACKAGE MY_PKG
  MODIFY RELEASE CHANNEL DEFAULT
  SET DEFAULT RELEASE DIRECTIVE VERSION = V3 PATCH = 0;

-- Upgrade the installed application
ALTER APPLICATION MY_APP UPGRADE;
```

> **Note:** `UPGRADE` requires that the new version's `setup.sql` uses `CREATE OR ALTER VERSIONED SCHEMA` for internal procedure schemas. Non-versioned schemas may cause upgrade failures.
>
> **Note:** Marketplace-listed packages have release channels enabled automatically. Using the legacy `SET DEFAULT RELEASE DIRECTIVE` syntax will fail. See [Snowflake docs](https://docs.snowflake.com/en/sql-reference/sql/alter-application-package-release-directive).

## Verification

After deploy, verify the running image version:

```sql
SELECT SYSTEM$GET_SERVICE_STATUS('MY_APP.app_services.my_service');
```

Check the `"image"` field in the JSON output to confirm the expected version tag.

## Quick Reference

| Step | Action |
|---|---|
| Tag | Always use `:vN`, never `:latest` |
| Files | `manifest.yml` and `service_spec.yml` must match the tag |
| Stage | PUT all files **before** REGISTER VERSION |
| Version | DEREGISTER old → REGISTER new (stage is snapshotted at registration) |
| Verify | `SYSTEM$GET_SERVICE_STATUS` to confirm running image |
