# Gallery Compatible App Template

A starter template for building [Snowflake Native Apps](https://docs.snowflake.com/en/developer-guide/native-apps/native-apps-about) that integrate with **Blue App Gallery Operator**.

Gallery Operator manages compute pool lifecycle (start/stop) via time-based leases, so your app doesn't need its own auto-stop logic.

## Quick Start

1. Click **"Use this template"** on GitHub to create your own repository
2. Search and replace all `<PLACEHOLDER>` values with your app-specific names (see table below)
3. Add your application code under `app/`
4. Build your Docker image and push to Snowflake image repository
5. Deploy as a Snowflake Native App

## Placeholders to Replace

| Placeholder | Example | Where |
|---|---|---|
| `<APP_NAME>` | `MY_COOL_APP` | All SQL, manifest |
| `<APP_DESCRIPTION>` | `My app on SPCS` | manifest.yml |
| `<SERVICE_NAME>` | `my_cool_app_service` | services.sql, service_spec.yml |
| `<CONTAINER_NAME>` | `my-cool-app` | service_spec.yml, entrypoint.sh |
| `<IMAGE_PATH>` | `/MY_DB/MY_SCHEMA/MY_REPO/my-image:latest` | manifest.yml, service_spec.yml |
| `<EAI_REF_NAME>` | `my_eai` | manifest.yml, services.sql, config.sql |
| `<EAI_LABEL>` | `External API Access` | manifest.yml |
| `<SECRET_NAME>` | `db_secret` | config.sql, service_spec.yml |
| `<ENDPOINT_PORT>` | `8080` | service_spec.yml |

## Directory Structure

```
gallery-compatible-app-template/
├── README.md                    ← This file
├── docs/
│   └── gallery-compatible-spec.md  ← Full specification
├── deploy/
│   ├── manifest.yml             ← Native App manifest
│   ├── service_spec.yml         ← SPCS service specification template
│   ├── scripts/
│   │   └── setup.sql            ← Entry point (schemas, roles, module loading)
│   ├── config.sql               ← EAI callbacks, database connection config
│   ├── services.sql             ← Service lifecycle (resume_service, etc.)
│   └── streamlit/
│       └── setup_ui.py          ← Setup wizard with Gallery Integration
├── docker/
│   └── entrypoint.sh            ← Container entrypoint (secret loading)
└── app/                         ← Your application code goes here
    └── .gitkeep
```

## What's Included

### Gallery Compatible Interface (Required)

| Procedure | Purpose |
|---|---|
| `app_setup.resume_service()` | **Required.** Gallery Operator calls this to start your SERVICE |
| `app_setup.service_status()` | Recommended. Returns SERVICE status (RUNNING, SUSPENDED, etc.) |
| `app_setup.service_url()` | Recommended. Returns the public endpoint URL |

### External Database Connection (Optional)

If your app connects to an external database, the template includes:

| Component | Purpose |
|---|---|
| `configure_database()` | Stores consumer's connection details in settings + Snowflake SECRET |
| `get_eai_configuration()` | Dynamically generates EAI network rules from stored settings |
| `service_spec.yml` | Template variables + SECRET mount for container injection |
| `entrypoint.sh` | Reads SECRET files + validates connection at startup |

Remove the `references` section from `manifest.yml` and the EAI/database procedures from `config.sql` if your app doesn't need external access.

### Setup UI (Streamlit)

A 4-step wizard that guides consumers through:

1. **Compute Pool** — Privilege check + manual create button
2. **Database Connection** — Host, port, credentials (if applicable)
3. **EAI Approval** — External Access Integration for network access
4. **Service** — Create, status, endpoint URL

## Gallery Operator Integration

Gallery Operator **discovers** your app automatically via its Discovery feature.
The consumer adds your app in the Operator dashboard, and the Operator guides them
through the required GRANT statements. No special setup is needed in your app.

**Your app's responsibility:** Provide `app_setup.resume_service()` so the Operator
can start the SERVICE when the Compute Pool is resumed.

## For AI-Assisted Development

If you're using an AI coding assistant (Claude Code, Cursor, etc.) to deploy your app to Snowflake, add the following to your project's `CLAUDE.md`:

```markdown
# Snowflake Native App Deployment

This app is deployed as a **Gallery Compatible** Snowflake Native App.

## MUST READ FIRST

Before creating or modifying `deploy/` directory:
1. Read: https://github.com/BlueAppWorks/gallery-compatible-app-template/blob/main/CLAUDE.md
2. Read: https://github.com/BlueAppWorks/gallery-compatible-app-template/blob/main/docs/gallery-compatible-spec.md

## Rules

- Follow the template structure exactly
- Do not rename `app_admin` role or `resume_service()` signature
- Add app-specific config as EXTENSION POINTS (see template CLAUDE.md)
- Replace all `<PLACEHOLDER>` values
```

This ensures the AI follows the template structure correctly when creating deployment files.

## Guides

- [Browser Cache Mitigation](docs/browser-cache-guide.md) — Prevent stale pages after Compute Pool SUSPEND/RESUME
- [Image Versioning & Deploy](docs/image-versioning-guide.md) — Avoid stale container images and stage file issues
- [Deploy Script](deploy/deploy.sh) — Automated build, push, and deploy (`./deploy.sh v1`)

## Specification

See [docs/gallery-compatible-spec.md](docs/gallery-compatible-spec.md) for the full Gallery Compatible App Specification v3.

## Reference Implementation

[Postgres Learning Studio](https://github.com/KosukeKida/PostgresLearningStudio) is a production Gallery Compatible app built from this pattern.

## License

MIT
