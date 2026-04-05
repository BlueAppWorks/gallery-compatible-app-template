# Gallery Compatible App Specification v3.0

## AI向け指示文 — Snowflake Native App を Gallery Compatible にする手順

> **この文書の目的**: Snowflake Native App を新規作成する際に、
> Gallery Operator（Blue App Gallery SaaS）から安定的にリース管理（起動/停止）
> できる状態にするための仕様と手順を定義する。
> 生成AIに対する指示文として利用することを想定。

---

## 1. 概要

Gallery Operator は Snowflake の Compute Pool / Postgres Instance / Service を
「リース」単位で時間管理するコントロールプレーンである。

Gallery Compatible な Native App とは、以下を満たすアプリを指す:

1. **`app_setup.resume_service()` プロシージャを提供** — Gallery Operator が SERVICE を明示的に起動できる（**必須**）
2. **`app_admin` APPLICATION ROLE を定義** — Consumer が Operator に GRANT できる（**必須**）
3. **SERVICE を SUSPEND/RESUME で管理** — DROP しない設計（**必須**）

> **v3.1 変更**: Gallery Operator がアプリを **Discovery で自動検知** するようになったため、
> アプリ側で Operator の存在を検知するロジックは不要になった。
> アプリは Marketplace に出品する際に Operator への依存を記載する必要がない。

---

## 2. Operator API v1.0 アーキテクチャ

### 2.1 レスポンスエンベロープ

すべての `api.*` プロシージャは以下の統一エンベロープで応答する:

```json
{
  "api_version": "1.0",
  "status": "OK" | "ERROR",
  "data": { ... },       // status=OK の場合
  "error": {             // status=ERROR の場合
    "code": "ERROR_CODE",
    "message": "Human-readable message",
    "lease_id": "...",        // optional (LEASE_ALREADY_EXISTS 時)
    "resource_name": "...",   // optional
    "resource_type": "..."    // optional
  }
}
```

### 2.2 エラーコード一覧

| コード | 説明 | 追加フィールド |
|---|---|---|
| `APP_NOT_FOUND` | app_catalog に存在しないアプリ名 | — |
| `NO_START_NEEDED` | 全リソースが既に STARTED/ACTIVE | — |
| `LEASE_ALREADY_EXISTS` | 同一アプリに既存リースあり | `lease_id` |
| `LEASE_NOT_FOUND` | 指定 lease_id が存在しない | — |
| `PERMISSION_NOT_GRANTED` | リソースへの GRANT が不足 | `resource_name`, `resource_type` |
| `START_FAILED` | リソース起動に失敗 | `resource_name`, `resource_type` |
| `EXTEND_FAILED` | リース延長に失敗 | — |
| `STOP_FAILED` | リース停止に失敗 | — |

### 2.3 SaaS ↔ Operator 通信フロー

```
[SaaS Gallery UI] → [Snowflake SQL API (JWT)] → [Gallery Operator Native App]
                                                          │
                     CALL BLUE_APP_GALLERY.api.launch(app_name, duration, user)
                     CALL BLUE_APP_GALLERY.api.extend(lease_id, duration, user)
                     CALL BLUE_APP_GALLERY.api.stop(lease_id)
                     CALL BLUE_APP_GALLERY.api.get_status(app_name)
                     CALL BLUE_APP_GALLERY.api.heartbeat(lease_id, user)
                     CALL BLUE_APP_GALLERY.api.list_apps()
                     CALL BLUE_APP_GALLERY.api.get_endpoints(app_name)
                     CALL BLUE_APP_GALLERY.api.get_version()
```

> **重要**: SaaS はリソース配列を送信しない。Operator が `app_catalog` から
> 対象アプリのリソース（Compute Pool, Service, Postgres Instance）を自動導出する。

---

## 3. SPCS ライフサイクルの事実（テスト検証済み）

**アプリ開発者はこの挙動を正しく理解した上で設計すること。**

| 事実 | 説明 |
|---|---|
| **Pool RESUME で SERVICE は起動しない** | `ALTER COMPUTE POOL RESUME` は Pool を起動するが、SUSPENDED な SERVICE は SUSPENDED のまま |
| **Pool SUSPEND で SERVICE は暗黙停止する** | `ALTER COMPUTE POOL SUSPEND` は Pool 上の全 SERVICE を暗黙的に停止する |
| **SERVICE auto_resume = true だが条件付き** | SERVICE の auto_resume はエンドポイントへの直接アクセス時にのみ発動。Pool 起動では発動しない |
| **他アプリの SERVICE は ALTER できない** | `ALTER SERVICE <other_app_service> RESUME` は権限エラー（ACCOUNTADMIN でも不可） |
| **resume_service() が唯一の起動手段** | APPLICATION ROLE 経由で公開されたプロシージャのみが外部からの SERVICE 起動手段 |
| **レースコンディションは存在しない** | 停止後 10秒〜120秒のどのタイミングで再起動しても resume_service() で正常起動する |

### リソース管理フロー

```
[SaaS Gallery UI] → [SQL API] → [Gallery Operator Native App]
                                        │
                                        ├─ api.launch(app_name, duration_minutes, user_name)
                                        │    ├─ app_catalog からリソースを自動導出
                                        │    ├─ ALTER COMPUTE POOL <name> RESUME
                                        │    ├─ ALTER POSTGRES INSTANCE <name> RESUME (if registered)
                                        │    ├─ CALL <app_name>.app_setup.resume_service()
                                        │    │    ↑ app_catalog に service_name がある場合、自動で呼出し
                                        │    │    ↑ エラー時は service_warning を返して続行
                                        │    └─ OperatorResponse<LaunchData> を返却
                                        │
                                        ├─ api.extend(lease_id, duration_minutes, user_name)
                                        │    ├─ リソースの RESUME + resume_service() を再実行
                                        │    └─ OperatorResponse<ExtendData> を返却
                                        │
                                        ├─ api.stop(lease_id)
                                        │    ├─ ALTER COMPUTE POOL <name> SUSPEND
                                        │    │    └─ SERVICE は暗黙的に停止（明示呼出し不要）
                                        │    ├─ ALTER POSTGRES INSTANCE <name> SUSPEND (if suspend_on_stop)
                                        │    └─ OperatorResponse<StopData> を返却
                                        │
                                        └─ api.get_endpoints(app_name)
                                             ├─ SHOW ENDPOINTS IN SERVICE <service_name>
                                             └─ OperatorResponse<EndpointsData> を返却
```

> **重要**: 停止側は Pool SUSPEND で SERVICE が暗黙停止するため、アプリ側に停止用プロシージャは不要。
> 起動側だけが非対称 — Pool RESUME で SERVICE は起動しないため、`resume_service()` が必須。

---

## 4. Operator API v1.0 プロシージャ詳細

### 4.1 `api.get_version()` — バージョン・互換性確認

```sql
CALL BLUE_APP_GALLERY.api.get_version();
```

**レスポンス（data）**:

```json
{
  "operator_version": "1.0.0",
  "api_version": "1.0",
  "min_gallery_version": "1.0",
  "product_name": "Blue App Gallery Operator"
}
```

SaaS は `min_gallery_version` と自身のバージョンを比較して互換性を確認する。

### 4.2 `api.launch(app_name, duration_minutes, user_name)` — アプリ起動

```sql
CALL BLUE_APP_GALLERY.api.launch('PLEASANTER_APP', 60, 'user@example.com');
```

| 引数 | 型 | 説明 |
|---|---|---|
| `app_name` | VARCHAR | app_catalog に登録されたアプリ名 |
| `duration_minutes` | INTEGER | リース時間（分） |
| `user_name` | VARCHAR | 起動ユーザー（NULL 可） |

**成功レスポンス（data: LaunchData）**:

```json
{
  "action": "STARTED",
  "lease_id": "lease_abc123",
  "app_name": "PLEASANTER_APP",
  "compute_pool": "PLEASANTER_POOL",
  "resource_summary": "1 compute pool, 1 service",
  "resources": [
    { "name": "PLEASANTER_POOL", "type": "COMPUTE_POOL" },
    { "name": "PLEASANTER_SERVICE", "type": "SERVICE" }
  ],
  "expires_at": "2026-03-13T15:00:00Z",
  "remaining_minutes": 60,
  "message": "App started successfully",
  "service_warning": null
}
```

**エラーケース**:
- `APP_NOT_FOUND` — app_catalog にアプリが存在しない
- `LEASE_ALREADY_EXISTS` — 同一アプリに既存リースあり（`error.lease_id` を含む）
- `PERMISSION_NOT_GRANTED` — リソースへの GRANT 不足
- `START_FAILED` — リソースの RESUME に失敗

> **SaaS 側の自動リダイレクト**: `LEASE_ALREADY_EXISTS` エラー時、SaaS は `error.lease_id` を使って
> 自動的に `api.extend()` にリダイレクトする（シームレスな UX）。

### 4.3 `api.extend(lease_id, duration_minutes, user_name)` — リース延長

```sql
CALL BLUE_APP_GALLERY.api.extend('lease_abc123', 30, 'user@example.com');
```

| 引数 | 型 | 説明 |
|---|---|---|
| `lease_id` | VARCHAR | 延長対象のリース ID |
| `duration_minutes` | INTEGER | 追加時間（分） |
| `user_name` | VARCHAR | 延長ユーザー（NULL 可） |

**成功レスポンス（data: ExtendData）**:

```json
{
  "action": "EXTENDED",
  "lease_id": "lease_abc123",
  "app_name": "PLEASANTER_APP",
  "compute_pool": "PLEASANTER_POOL",
  "resource_summary": "1 compute pool, 1 service",
  "resources": [...],
  "expires_at": "2026-03-13T15:30:00Z",
  "remaining_minutes": 90,
  "message": "Lease extended successfully",
  "service_warning": null
}
```

> **重要**: extend 時もリソースの RESUME + `resume_service()` を再実行する。
> これによりリース中に Pool/Service が不意に停止した場合も復旧できる。

### 4.4 `api.stop(lease_id)` — リース停止

```sql
CALL BLUE_APP_GALLERY.api.stop('lease_abc123');
```

**成功レスポンス（data: StopData）**:

```json
{
  "action": "STOPPED",
  "lease_id": "lease_abc123",
  "app_name": "PLEASANTER_APP",
  "compute_pool": "PLEASANTER_POOL",
  "message": "Lease stopped successfully"
}
```

### 4.5 `api.get_status(app_name)` — リース状態取得

`app_name = NULL` で全アクティブリースを取得。

```sql
-- 特定アプリ
CALL BLUE_APP_GALLERY.api.get_status('PLEASANTER_APP');

-- 全アプリ
CALL BLUE_APP_GALLERY.api.get_status(NULL);
```

**特定アプリ（アクティブリースあり）— StatusDataSingle**:

```json
{
  "app_name": "PLEASANTER_APP",
  "lease_id": "lease_abc123",
  "lease_status": "ACTIVE",
  "compute_pool": "PLEASANTER_POOL",
  "resource_summary": "1 compute pool, 1 service",
  "resources": [...],
  "started_at": "2026-03-13T14:00:00Z",
  "expires_at": "2026-03-13T15:00:00Z",
  "remaining_minutes": 45,
  "initiated_by": "user@example.com",
  "active_user_count": 2
}
```

**特定アプリ（アクティブリースなし）— StatusDataNone**:

```json
{
  "app_name": "PLEASANTER_APP",
  "lease_status": "NO_ACTIVE_LEASE"
}
```

**全アプリ一覧 — StatusDataAll**:

```json
{
  "active_leases": [
    {
      "app_name": "PLEASANTER_APP",
      "lease_id": "lease_abc123",
      "compute_pool": "PLEASANTER_POOL",
      "resource_summary": "...",
      "expires_at": "2026-03-13T15:00:00Z",
      "remaining_minutes": 45
    }
  ],
  "total_count": 1
}
```

### 4.6 `api.heartbeat(lease_id, user_name)` — ハートビート

```sql
CALL BLUE_APP_GALLERY.api.heartbeat('lease_abc123', 'user@example.com');
```

**成功レスポンス（data: HeartbeatData）**:

```json
{
  "lease_id": "lease_abc123",
  "user_name": "user@example.com",
  "heartbeat_at": "2026-03-13T14:30:00Z"
}
```

### 4.7 `api.list_apps()` — 管理アプリ一覧

```sql
CALL BLUE_APP_GALLERY.api.list_apps();
```

**成功レスポンス（data: ListAppsData）**:

```json
{
  "apps": [
    {
      "app_name": "PLEASANTER_APP",
      "app_version": "1.0.0",
      "app_comment": "Pleasanter on Snowflake",
      "app_type": "native_app",
      "compute_pool": "PLEASANTER_POOL",
      "service_name": "PLEASANTER_SERVICE",
      "gallery_compatible": true,
      "managed_status": "MANAGED",
      "postgres_mode": "NONE",
      "registered_at": "2026-03-01T00:00:00Z",
      "registered_by": "admin"
    }
  ],
  "total_count": 1
}
```

### 4.8 `api.get_endpoints(app_name)` — エンドポイント取得

```sql
CALL BLUE_APP_GALLERY.api.get_endpoints('PLEASANTER_APP');
```

**READY レスポンス（data: EndpointsDataReady）**:

```json
{
  "app_name": "PLEASANTER_APP",
  "service_name": "PLEASANTER_SERVICE",
  "endpoint_status": "READY",
  "ingress_url": "xxx-yyy.snowflakecomputing.app",
  "endpoints": [
    {
      "name": "app",
      "port": "8080",
      "protocol": "HTTP",
      "is_public": "true",
      "ingress_url": "xxx-yyy.snowflakecomputing.app"
    }
  ],
  "endpoint_count": 1
}
```

**NOT READY レスポンス（data: EndpointsDataNotReady）**:

```json
{
  "app_name": "PLEASANTER_APP",
  "service_name": "PLEASANTER_SERVICE",
  "endpoint_status": "STARTING",
  "message": "Service is starting, endpoints not yet available"
}
```

> **注意**: `ingress_url` には `https://` プレフィックスが含まれない。
> SaaS 側で `https://` を付与してリンクを生成する。

---

## 5. Native App が提供すべきインターフェース

### 5.1 必須: `app_setup.resume_service()` — SERVICE 起動

Gallery Operator が `api.launch` / `api.extend` の一部として自動呼出しする。
**これが Gallery Compatible App の最も重要な要件。**

```sql
-- ============================================================
-- 必須: resume_service() プロシージャ
-- Gallery Operator が CALL <app_name>.app_setup.resume_service() で呼ぶ
-- ============================================================
CREATE OR REPLACE PROCEDURE app_setup.resume_service()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_err VARCHAR;
BEGIN
    BEGIN
        ALTER SERVICE app_services.<YOUR_SERVICE_NAME> RESUME;
        RETURN 'RESUMED';
    EXCEPTION WHEN OTHER THEN
        v_err := SQLERRM;
        IF (:v_err ILIKE '%already%started%' OR :v_err ILIKE '%already%running%') THEN
            RETURN 'ALREADY_RUNNING';
        END IF;
        RETURN 'ERROR: ' || :v_err;
    END;
END;
$$;

-- APPLICATION ROLE に公開（Gallery Operator がこのロールを通じて CALL する）
GRANT USAGE ON PROCEDURE app_setup.resume_service() TO APPLICATION ROLE app_admin;
```

**呼出し元**: Gallery Operator の `api.launch` / `api.extend`
**呼出し条件**: `app_catalog.service_name IS NOT NULL`
**エラー処理**: Gallery Operator 側で EXCEPTION を捕捉し、`service_warning` フィールドに格納して応答を返す（エラーでも起動フロー全体は続行）

### 5.2 推奨: `app_setup.service_status()` — ヘルスチェック

```sql
CREATE OR REPLACE PROCEDURE app_setup.service_status()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
BEGIN
    SHOW SERVICES LIKE '<YOUR_SERVICE_NAME>' IN SCHEMA app_services;
    LET rs RESULTSET := (SELECT "status" FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())));
    LET cur CURSOR FOR rs;
    FOR rec IN cur DO
        RETURN rec."status";  -- RUNNING, SUSPENDED, PENDING, etc.
    END FOR;
    RETURN 'NOT_FOUND';
END;
$$;

GRANT USAGE ON PROCEDURE app_setup.service_status() TO APPLICATION ROLE app_admin;
```

### 5.3 推奨: `app_setup.service_url()` — エンドポイント取得

```sql
CREATE OR REPLACE PROCEDURE app_setup.service_url()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
BEGIN
    SHOW ENDPOINTS IN SERVICE app_services.<YOUR_SERVICE_NAME>;
    LET rs RESULTSET := (SELECT "ingress_url" FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())));
    LET cur CURSOR FOR rs;
    FOR rec IN cur DO
        RETURN rec."ingress_url";
    END FOR;
    RETURN NULL;
END;
$$;

GRANT USAGE ON PROCEDURE app_setup.service_url() TO APPLICATION ROLE app_admin;
```

### 5.4 Gallery Operator 連携（アプリ側の検知は不要）

> **v3.1 変更**: Gallery Operator がアプリを **Discovery 機能で自動検知** するため、
> アプリ側で Operator の存在を検知する必要はなくなった。

#### Operator による Discovery フロー

1. **Consumer が Gallery Operator をインストール**
2. **Operator Dashboard で「Discover Apps」を実行**
   - Operator が `SHOW APPLICATIONS` + `SHOW STREAMLITS` でアカウント内のアプリを検出
   - `app_setup.resume_service()` の存在を確認し、Gallery Compatible フラグを自動設定
3. **Consumer が「Add」でアプリを管理対象に登録**
   - Operator が必要な GRANT 文を自動生成・表示
4. **Consumer が GRANT 文を実行**
   - OPERATE/MONITOR ON COMPUTE POOL
   - APPLICATION ROLE app_admin TO APPLICATION BLUE_APP_GALLERY

#### アプリ側の責務

- `app_setup.resume_service()` を実装する（必須）
- `app_setup.service_status()` / `app_setup.service_url()` を実装する（推奨）
- **Operator 検知ロジックは不要** — Operator 側が検知する

#### （任意）アプリ UI に Gallery 案内を表示

アプリの Setup UI で Gallery Operator の利用を案内したい場合は、以下のような静的テキストを表示する:
    st.code(
        f"-- ACCOUNTADMIN で実行\n"
```python
st.info(
    "**Gallery Operator をお使いの場合:**\n\n"
    "1. Gallery Operator Dashboard で「Discover Apps」を実行\n"
    "2. このアプリが検出されたら「Add」をクリック\n"
    "3. 表示された GRANT 文を ACCOUNTADMIN で実行\n\n"
    "これにより Gallery UI からこのアプリの起動/停止を管理できます。"
)
```

### 5.5 不要: `suspend_service()`

**提供不要。** Pool SUSPEND で SERVICE は暗黙停止される。
既存の `suspend_service()` があっても害はないが、Gallery Operator は呼ばない。

### 5.6 任意: `gallery_managed` 設定

アプリに独自の auto-stop タスクがある場合、Gallery Operator のリース管理と競合する。
以下のパターンで切り替えを実装する:

```sql
CREATE TABLE IF NOT EXISTS app_config.settings (
    key VARCHAR NOT NULL PRIMARY KEY,
    value VARCHAR,
    updated_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE PROCEDURE app_setup.set_gallery_managed(p_enabled BOOLEAN)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
BEGIN
    MERGE INTO app_config.settings AS t
    USING (SELECT 'gallery_managed' AS key,
           CASE WHEN :p_enabled THEN 'true' ELSE 'false' END AS value) AS s
    ON t.key = s.key
    WHEN MATCHED THEN UPDATE SET value = s.value, updated_at = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT (key, value) VALUES (s.key, s.value);

    RETURN CASE WHEN :p_enabled THEN 'Gallery management enabled.' ELSE 'Gallery management disabled.' END;
END;
$$;

GRANT USAGE ON PROCEDURE app_setup.set_gallery_managed(BOOLEAN) TO APPLICATION ROLE app_admin;
```

auto-stop タスク内でのガード:

```sql
LET v_managed VARCHAR;
SELECT value INTO :v_managed FROM app_config.settings WHERE key = 'gallery_managed';
IF (:v_managed = 'true') THEN
    RETURN 'SKIPPED: Gallery managed';
END IF;
```

### 5.7 manifest.yml テンプレート

以下は Gallery Compatible App の最小構成 manifest.yml である。
`<PLACEHOLDER>` 部分をアプリ固有の値に置き換えて使用する。

```yaml
manifest_version: 2

version:
  name: "1.0.0"
  # comment は Gallery カタログの説明文として表示される
  comment: "<アプリの説明（英語）>"

artifacts:
  setup_script: scripts/setup.sql
  default_streamlit: streamlit/setup_ui.py

privileges:
  # --- Gallery Compatible に必須 ---
  - CREATE COMPUTE POOL:
      description: "Run application containers"
  - BIND SERVICE ENDPOINT:
      description: "Expose public endpoints for user access"

  # --- アプリ要件に応じて追加 ---
  # - CREATE DATABASE:
  #     description: "Store persistent application data"
  # - CREATE WAREHOUSE:
  #     description: "Execute queries"

references:
  # --- 外部通信が必要な場合のみ ---
  # 論理参照名（任意の名前）。コンシューマーは自分の EAI をこの参照にバインドする。
  # アプリ内コードでは REFERENCE('<論理参照名>') で実体に解決される。
  - <your_eai_ref>:
      label: "<UI に表示するラベル（英語）>"
      object_type: EXTERNAL ACCESS INTEGRATION
      required_at_setup: false
      register_callback: app_setup.register_reference
      configuration_callback: app_setup.get_eai_configuration

container_services:
  images:
    - repository: <your_repo>
      images:
        - /<image_path>:latest
```

#### privileges の解説

| 権限 | 必須/任意 | 用途 |
|---|---|---|
| `CREATE COMPUTE POOL` | **必須** | SERVICE を動かす Pool の作成 |
| `BIND SERVICE ENDPOINT` | **必須** | public endpoint の公開（ユーザーがブラウザからアクセス） |
| `CREATE DATABASE` | 任意 | アプリが永続データを保持する場合 |
| `CREATE WAREHOUSE` | 任意 | アプリが SQL クエリを実行する場合 |

> **注意**: これらは **Native App がコンシューマーに要求する権限** である。
> Gallery Operator への GRANT（OPERATE ON COMPUTE POOL 等）とは別の概念。
> `privileges` はアプリのインストール/セットアップ時にコンシューマーが承認する。

#### references の解説

`references` の名前（例: `postgres_eai`）は **アプリ内部の論理参照名** であり、
コンシューマーが作成する EAI の実際の名前ではない。

```
manifest.yml:  postgres_eai  ← 論理参照名（アプリ開発者が決める）
                    ↓
Consumer:      SYSTEM$SET_REFERENCE('postgres_eai', 'MY_CUSTOM_EAI')
                    ↓
App 内コード:   REFERENCE('postgres_eai')  → 実体 MY_CUSTOM_EAI に解決
```

- **外部通信が不要なアプリ**: `references` セクション自体を削除してよい
- **複数の外部通信先があるアプリ**: 論理参照名を分けて複数定義する

---

## 6. 必須要件チェックリスト

### manifest.yml

- [ ] `manifest_version: 2` を使用
- [ ] `version.comment` にアプリの説明を記載（Gallery カタログの説明文として使用される）
- [ ] `privileges` に `CREATE COMPUTE POOL` と `BIND SERVICE ENDPOINT` を定義
- [ ] SERVICE を使用する場合、`container_services.images` にイメージを定義
- [ ] 外部通信が必要な場合、`references` に EAI の論理参照を定義

### SERVICE 管理（アプリ開発者の責務）

- [ ] SERVICE は SUSPEND/RESUME で管理（**DROP しない**）
  - `resume_service()` 内で `CREATE SERVICE IF NOT EXISTS` + `ALTER SERVICE RESUME` のパターンも可
- [ ] SERVICE に public endpoint が定義されている
- [ ] `app_setup.resume_service()` プロシージャを作成（**必須**）
- [ ] `resume_service()` を APPLICATION ROLE `app_admin` に GRANT

### Gallery Operator 登録（Consumer の作業）

以下は Consumer が Gallery Operator Dashboard から実行する。アプリ側での実装は不要。

- [ ] Operator Dashboard で「Discover Apps」を実行
- [ ] アプリを「Add」して管理対象に登録
- [ ] Operator が生成した GRANT 文を ACCOUNTADMIN で実行:
  - `GRANT OPERATE ON COMPUTE POOL <pool> TO APPLICATION BLUE_APP_GALLERY`
  - `GRANT MONITOR ON COMPUTE POOL <pool> TO APPLICATION BLUE_APP_GALLERY`
  - `GRANT APPLICATION ROLE <app>.app_admin TO APPLICATION BLUE_APP_GALLERY`
- [ ] 「Validate」で権限を確認
- [ ] Gallery から `api.launch()` → エンドポイント到達を確認

---

## 7. 実装手順

### Step 1: setup.sql に Gallery Compatible インターフェースを追加

```sql
-- ============================================================
-- Schema & APPLICATION ROLE
-- ============================================================
CREATE SCHEMA IF NOT EXISTS app_setup;
CREATE APPLICATION ROLE IF NOT EXISTS app_admin;

-- ============================================================
-- resume_service() — Gallery Operator が呼び出す SERVICE 起動プロシージャ
-- ============================================================
CREATE OR REPLACE PROCEDURE app_setup.resume_service()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_err VARCHAR;
BEGIN
    ALTER SERVICE app_services.<YOUR_SERVICE_NAME> RESUME;
    RETURN 'RESUMED';
EXCEPTION WHEN OTHER THEN
    v_err := SQLERRM;
    IF (:v_err ILIKE '%already%started%' OR :v_err ILIKE '%already%running%') THEN
        RETURN 'ALREADY_RUNNING';
    END IF;
    RETURN 'ERROR: ' || :v_err;
END;
$$;

GRANT USAGE ON PROCEDURE app_setup.resume_service() TO APPLICATION ROLE app_admin;

-- ============================================================
-- service_status() — ヘルスチェック（推奨）
-- ============================================================
CREATE OR REPLACE PROCEDURE app_setup.service_status()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
BEGIN
    SHOW SERVICES LIKE '<YOUR_SERVICE_NAME>' IN SCHEMA app_services;
    LET rs RESULTSET := (SELECT "status" FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())));
    LET cur CURSOR FOR rs;
    FOR rec IN cur DO
        RETURN rec."status";
    END FOR;
    RETURN 'NOT_FOUND';
END;
$$;

GRANT USAGE ON PROCEDURE app_setup.service_status() TO APPLICATION ROLE app_admin;

-- ============================================================
-- service_url() — エンドポイント取得（推奨）
-- ============================================================
CREATE OR REPLACE PROCEDURE app_setup.service_url()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
BEGIN
    SHOW ENDPOINTS IN SERVICE app_services.<YOUR_SERVICE_NAME>;
    LET rs RESULTSET := (SELECT "ingress_url" FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())));
    LET cur CURSOR FOR rs;
    FOR rec IN cur DO
        RETURN rec."ingress_url";
    END FOR;
    RETURN NULL;
END;
$$;

GRANT USAGE ON PROCEDURE app_setup.service_url() TO APPLICATION ROLE app_admin;
```

### Step 2: SERVICE は DROP しない設計にする

```sql
-- NG: SERVICE を DROP する（Gallery から復帰不可）
DROP SERVICE IF EXISTS app_services.my_service;

-- OK: SERVICE を SUSPEND する（resume_service で復帰可能）
ALTER SERVICE app_services.my_service SUSPEND;
```

`start_service()` 内で毎回 `DROP → CREATE` するパターンがある場合、
`CREATE SERVICE IF NOT EXISTS ... ; ALTER SERVICE ... RESUME;` に変更する。

### Step 3: Streamlit UI に Gallery Integration セクションを追加

セクション 5.4 のリファレンス実装を参照。

1. `BLUE_APP_GALLERY_REGISTRY` からの Gallery Operator 検知
2. 未検出時: GRANT SQL の表示
3. 検出時: gallery_managed トグル + GRANT APPLICATION ROLE SQL の表示

### Step 4: gallery_managed の実装（auto-stop がある場合のみ）

アプリに独自の auto-stop タスクがある場合のみ。セクション 5.6 参照。

### Step 5: デプロイ＆検証

```sql
-- 1. アプリをデプロイ
ALTER APPLICATION <app_name> UPGRADE USING @<stage>;
-- または新規インストール:
-- CREATE APPLICATION <app_name> FROM APPLICATION PACKAGE <pkg> USING @<stage>;

-- 2. レジストリへのアクセスを許可（ACCOUNTADMIN）
GRANT USAGE ON DATABASE BLUE_APP_GALLERY_REGISTRY TO APPLICATION <app_name>;
GRANT USAGE ON SCHEMA BLUE_APP_GALLERY_REGISTRY.PUBLIC TO APPLICATION <app_name>;
GRANT SELECT ON TABLE BLUE_APP_GALLERY_REGISTRY.PUBLIC.OPERATOR TO APPLICATION <app_name>;

-- 3. Compute Pool / Postgres Instance の権限を Gallery Operator に付与（ACCOUNTADMIN）
GRANT OPERATE ON COMPUTE POOL <pool> TO APPLICATION BLUE_APP_GALLERY;
GRANT MONITOR ON COMPUTE POOL <pool> TO APPLICATION BLUE_APP_GALLERY;

-- 4. APPLICATION ROLE を Gallery Operator に付与（ACCOUNTADMIN）
GRANT APPLICATION ROLE <app_name>.app_admin TO APPLICATION BLUE_APP_GALLERY;

-- 5. resume_service の動作確認
CALL <app_name>.app_setup.resume_service();
-- 期待値: 'RESUMED' または 'ALREADY_RUNNING'

-- 6. Gallery Operator の app_catalog を更新
--    SaaS Settings > Catalog から gallery_compatible = TRUE に設定
--    または直接:
UPDATE BLUE_APP_GALLERY.core.app_catalog
SET gallery_compatible = TRUE
WHERE app_name = '<app_name>';

-- 7. SaaS Gallery から Launch を実行して E2E 検証
--    api.launch() → api.get_endpoints() → ブラウザでアクセス確認
```

---

## 8. アプリ種類別のパターン

### パターン 1: SPCS アプリ（Compute Pool + SERVICE）

最も一般的なパターン。

```
api.launch(app_name, duration, user):
    ├─ app_catalog から compute_pool, service_name を取得
    ├─ ALTER COMPUTE POOL <pool> RESUME          ← Pool 起動
    └─ CALL <app>.app_setup.resume_service()     ← SERVICE 起動（必須）

api.stop(lease_id):
    └─ ALTER COMPUTE POOL <pool> SUSPEND         ← Pool + SERVICE 暗黙停止
```

### パターン 2: SPCS + Postgres Instance

```
api.launch(app_name, duration, user):
    ├─ app_catalog から compute_pool, service_name, postgres_instance を取得
    ├─ ALTER COMPUTE POOL <pool> RESUME
    ├─ ALTER POSTGRES INSTANCE <pg> RESUME
    └─ CALL <app>.app_setup.resume_service()

api.stop(lease_id):
    ├─ ALTER COMPUTE POOL <pool> SUSPEND         ← SERVICE 暗黙停止
    └─ ALTER POSTGRES INSTANCE <pg> SUSPEND
```

### パターン 3: Streamlit Only（Compute Pool なし）

Gallery Operator では管理不要。

---

## 9. 外部データベース接続の設計パターン

Marketplace で出品するアプリは、**コンシューマーの環境にあるデータベースに接続する**必要がある。
接続先のホスト名・ポート・認証情報をアプリ内にハードコードしてはならない。

以下のパターンで、コンシューマーが Setup UI から接続先を設定し、
コンテナに動的に注入する設計にする。

### 9.1 全体アーキテクチャ

```
[Setup UI (Streamlit)]
    │
    ├─ configure_database(host, port, user, pass)
    │   ├─ app_config.settings テーブルに host/port を保存
    │   └─ Snowflake SECRET に認証情報を保存
    │
    ├─ get_eai_configuration(ref_name)
    │   └─ settings から host:port を読み、EAI の host_ports を動的生成
    │
    └─ start_service() / resume_service()
        └─ CREATE SERVICE ... FROM SPECIFICATION_TEMPLATE_FILE
            ├─ テンプレート変数 {{DB_HOST}} を注入
            └─ SECRET をコンテナにマウント → 環境変数で読み取り
```

### 9.2 設定保存プロシージャ

コンシューマーが Setup UI で入力した接続情報を保存する。
**認証情報は Snowflake SECRET に格納**し、平文テーブルには保存しない。

```sql
-- 設定テーブル（ホスト・ポートなど非機密情報）
CREATE SCHEMA IF NOT EXISTS app_config;
CREATE TABLE IF NOT EXISTS app_config.settings (
    key VARCHAR NOT NULL PRIMARY KEY,
    value VARCHAR,
    updated_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- 接続設定プロシージャ
CREATE OR REPLACE PROCEDURE app_setup.configure_database(
    p_host VARCHAR,
    p_port VARCHAR DEFAULT '5432',
    p_admin_user VARCHAR DEFAULT 'admin',
    p_admin_pass VARCHAR DEFAULT ''
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
    -- SQLインジェクション対策: シングルクォートをエスケープ
    safe_user := REPLACE(:p_admin_user, '''', '''''');
    safe_pass := REPLACE(:p_admin_pass, '''', '''''');

    -- SECRET に認証情報を保存（コンテナから安全にアクセス可能）
    EXECUTE IMMEDIATE
        'CREATE OR REPLACE SECRET app_config.db_secret '
        || 'TYPE = PASSWORD '
        || 'USERNAME = ''' || :safe_user || ''' '
        || 'PASSWORD = ''' || :safe_pass || '''';

    -- 非機密情報を設定テーブルに保存
    MERGE INTO app_config.settings AS t
    USING (
        SELECT column1 AS key, column2 AS value FROM VALUES
            ('db_host', :p_host),
            ('db_port', :p_port),
            ('db_configured', 'true')
    ) AS s ON t.key = s.key
    WHEN MATCHED THEN UPDATE SET value = s.value, updated_at = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT (key, value) VALUES (s.key, s.value);

    RETURN 'Database configured: ' || :p_host || ':' || :p_port;
END;
$$;

GRANT USAGE ON PROCEDURE app_setup.configure_database(
    VARCHAR, VARCHAR, VARCHAR, VARCHAR
) TO APPLICATION ROLE app_admin;
```

### 9.3 EAI 動的構成コールバック

manifest.yml の `configuration_callback` で呼ばれ、
**コンシューマーが設定したホスト:ポートに対して動的にネットワークルールを生成**する。

```sql
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

    IF (:db_host IS NULL) THEN
        RETURN '{
            "type": "CONFIGURATION",
            "payload": {
                "host_ports": ["example.com:5432"],
                "allowed_secrets": "ALL"
            }
        }';
    END IF;

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
```

> **ポイント**: `host_ports` はコンシューマーが入力した値から動的に生成される。
> アプリ開発者がハードコードする必要はない。未設定時はダミー値を返す。

### 9.4 service_spec.yml — テンプレート変数と SECRET マウント

```yaml
spec:
  containers:
  - name: app
    image: /<DB_NAME>/<SCHEMA>/<REPO>/<IMAGE>:latest

    # SECRET からの認証情報注入
    secrets:
    - snowflakeSecret: app_config.db_secret
      secretKeyRef: username
      envVarName: DB_USER
    - snowflakeSecret: app_config.db_secret
      secretKeyRef: password
      envVarName: DB_PASSWORD

    # テンプレート変数による動的設定
    env:
      DB_HOST: {{DB_HOST}}           # start_service() から注入
      DB_PORT: {{DB_PORT}}           # start_service() から注入
      DB_NAME: {{DB_NAME}}           # start_service() から注入

  endpoints:
  - name: app
    port: 8080
    public: true
```

> **`{{変数名}}`** は Snowflake の `SPECIFICATION_TEMPLATE_FILE` 機能。
> `CREATE SERVICE ... USING (DB_HOST => 'xxx')` で値が注入される。
> ハードコードではなく、SQL プロシージャから動的に渡す。

### 9.5 SERVICE 作成時のテンプレート変数注入

```sql
CREATE OR REPLACE PROCEDURE app_setup.start_service(pool_name VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    db_host VARCHAR;
    db_port VARCHAR;
    create_sql VARCHAR;
BEGIN
    -- 設定テーブルからコンシューマーの接続先を取得
    SELECT value INTO :db_host FROM app_config.settings WHERE key = 'db_host';
    SELECT value INTO :db_port FROM app_config.settings WHERE key = 'db_port';

    IF (:db_host IS NULL) THEN
        RETURN 'ERROR: Database not configured. Run configure_database() first.';
    END IF;

    create_sql := 'CREATE SERVICE IF NOT EXISTS app_services.<YOUR_SERVICE_NAME> '
        || 'IN COMPUTE POOL IDENTIFIER(''' || :pool_name || ''') '
        || 'MIN_INSTANCES = 1 MAX_INSTANCES = 1 '
        || 'EXTERNAL_ACCESS_INTEGRATIONS = (REFERENCE(''<your_eai_ref>'')) '
        || 'FROM SPECIFICATION_TEMPLATE_FILE = ''/service_spec.yml'' '
        || 'USING ('
        || 'DB_HOST => ''"' || :db_host || '"'', '
        || 'DB_PORT => ''"' || :db_port || '"'', '
        || 'DB_NAME => ''"<default_db_name>"'''
        || ')';

    EXECUTE IMMEDIATE :create_sql;
    ALTER SERVICE app_services.<YOUR_SERVICE_NAME> RESUME;
    RETURN 'SERVICE started';
END;
$$;
```

### 9.6 コンテナ側の読み取り（entrypoint.sh）

```bash
#!/bin/bash

# Snowflake SECRET からの認証情報読み取り
SECRET_PATH="/snowflake/session/secrets/db_secret"

if [ -f "${SECRET_PATH}/username" ]; then
    export DB_USER=$(cat "${SECRET_PATH}/username")
    export DB_PASSWORD=$(cat "${SECRET_PATH}/password")
    echo "Credentials loaded from Snowflake Secret"
fi

# 環境変数の検証（テンプレート変数から注入済み）
export DB_HOST=${DB_HOST:?DB_HOST is required}
export DB_PORT=${DB_PORT:-5432}
export DB_NAME=${DB_NAME:-mydb}

echo "Connecting to ${DB_HOST}:${DB_PORT}/${DB_NAME}"
exec python app.py
```

> **SECRET のマウントパス**: `/snowflake/session/secrets/<secret_name>/`
> 配下に `username` と `password` ファイルが自動生成される。

### 9.7 データフロー全体像

```
┌─────────────────────────────────────────────────────────────┐
│  Setup UI (Streamlit)                                       │
│                                                             │
│  Host: [consumer-pg.example.com]  Port: [5432]              │
│  User: [admin]  Password: [****]                            │
│  [Save Configuration]                                       │
└──────────┬──────────────────────────────────────────────────┘
           │
           ▼
┌──────────────────────────────┐    ┌─────────────────────────┐
│  app_config.settings         │    │  app_config.db_secret   │
│  ┌──────────┬──────────────┐ │    │  (Snowflake SECRET)     │
│  │ db_host  │ consumer-pg… │ │    │  username = admin       │
│  │ db_port  │ 5432         │ │    │  password = ****        │
│  └──────────┴──────────────┘ │    └────────────┬────────────┘
└──────────┬───────────────────┘                 │
           │                                     │
           ▼                                     │
┌──────────────────────────┐                     │
│  get_eai_configuration() │                     │
│  → host_ports:           │                     │
│    ["consumer-pg…:5432"] │                     │
└──────────────────────────┘                     │
                                                 │
┌────────────────────────────────────────────────┐│
│  CREATE SERVICE ... USING (                    ││
│    DB_HOST => 'consumer-pg…',                  ││
│    DB_PORT => '5432'                           ││
│  )                                             ││
└──────────┬─────────────────────────────────────┘│
           │                                      │
           ▼                                      ▼
┌─────────────────────────────────────────────────────────────┐
│  Container                                                  │
│  ┌─────────────────────┐  ┌───────────────────────────────┐ │
│  │ ENV: DB_HOST, DB_PORT│  │ /snowflake/session/secrets/  │ │
│  │ (from template vars) │  │ db_secret/username            │ │
│  │                      │  │ db_secret/password            │ │
│  └──────────┬───────────┘  └──────────────┬───────────────┘ │
│             └──────────┬──────────────────┘                  │
│                        ▼                                     │
│             connect(host, port, user, pass)                  │
│                        │                                     │
└────────────────────────┼─────────────────────────────────────┘
                         │  EAI が許可
                         ▼
              ┌──────────────────────┐
              │  Consumer's Database │
              │  (任意のホスト名)      │
              └──────────────────────┘
```

> **要約**: アプリコード内にホスト名・認証情報を一切ハードコードしない。
> コンシューマーが Setup UI で入力 → SECRET + 設定テーブルに保存 →
> テンプレート変数と SECRET マウントでコンテナに注入。
> Marketplace で出品しても、各コンシューマーが自分の DB に接続できる。

---

## 10. SaaS 側の仕様（参考情報）

### 10.1 SaaS → Operator 通信

SaaS は Snowflake SQL API（JWT 認証）経由で Operator の `api.*` プロシージャを呼び出す。

- **認証**: キーペア JWT（`accountLocator` ベース）
- **デフォルト設定**: database=`BLUE_APP_GALLERY`, role=`operator_saas`
- **リクエスト**: `POST https://{account}.snowflakecomputing.com/api/v2/statements`

### 10.2 Launch フロー（SaaS 視点）

```
1. ユーザーが Gallery UI で「Launch」をクリック
2. CALL BLUE_APP_GALLERY.api.launch(app_name, duration, user)
4. 成功: ローカル DB にリースを記録
   エラー LEASE_ALREADY_EXISTS: 自動で api.extend() にリダイレクト
5. CALL BLUE_APP_GALLERY.api.get_endpoints(app_name) をポーリング（10秒間隔、最大5分）
6. endpoint_status = 'READY' でエンドポイント URL を表示
```

---

## 11. トラブルシューティング

### Q: resume_service() が 'ERROR: ...' を返す

**原因**: SERVICE がまだ CREATE されていない（初回デプロイ後に一度も start_service を実行していない）。
**対策**: `resume_service()` 内に `CREATE SERVICE IF NOT EXISTS` のフォールバックを追加。

### Q: エンドポイントに到達できない（upstream connect error）

**原因**: SERVICE は RUNNING だが、コンテナ内のアプリがまだ HTTP を受け付けていない。
**対策**: 通常 30秒〜1分で解消。SaaS 側のポーリングで自動検出される。

### Q: api.get_endpoints() で endpoint_status = 'STARTING'

**原因**: SERVICE がまだ RUNNING 状態ではない。
**対策**: SaaS のポーリング（10秒間隔、最大5分）で自動検出。

### Q: GRANT APPLICATION ROLE が失敗する

**原因**: setup.sql で APPLICATION ROLE が作成されていない。
**対策**: `CREATE APPLICATION ROLE IF NOT EXISTS app_admin;` を setup.sql に追加。

### Q: 自アプリの auto-stop と Gallery リースが競合する

**対策**: `gallery_managed` フラグで auto-stop を無効化（セクション 5.6 参照）。

### Q: resume_service() 後にエンドポイントに到達できない（no service hosts found）

**原因**: 過去に別バージョンで作成された SERVICE が残存し、古いイメージパスを参照している。
`SYSTEM$GET_SERVICE_STATUS` で `Failed to pull image` + `restartCount` が増加し続ける状態。

**対策**: `resume_service()` 内で RESUME 後にステータスを確認し、
`Failed to pull image` 検出時は SERVICE を DROP → 再作成する:

```sql
BEGIN
    SELECT SYSTEM$GET_SERVICE_STATUS('app_services.<service_name>') INTO :v_status;
    IF (:v_status ILIKE '%Failed to pull image%') THEN
        DROP SERVICE IF EXISTS app_services.<service_name>;
        CALL app_setup.start_service();
        RETURN 'RECREATED: stale image detected';
    END IF;
EXCEPTION WHEN OTHER THEN
    NULL;
END;
```

### Q: api.launch() で LEASE_ALREADY_EXISTS が返る

**原因**: 同一アプリに既存のアクティブリースがある。
**対策**: SaaS は自動的に `api.extend()` にリダイレクト。
手動テスト時は `api.stop(lease_id)` で停止してから再度 launch する。

### Q: api.launch() で PERMISSION_NOT_GRANTED が返る

**原因**: OPERATE/MONITOR 権限が Gallery Operator に付与されていない。
**対策**: セクション 6 のチェックリスト「権限委任」を確認。

---

## Appendix A: Gallery Operator API v1.0 プロシージャ一覧

### api.* スキーマ（SaaS からの呼出し用）

| プロシージャ | 引数 | 用途 |
|---|---|---|
| `api.get_version()` | — | Operator バージョン・互換性情報 |
| `api.launch(app_name, duration_minutes, user_name)` | VARCHAR, INTEGER, VARCHAR | アプリ起動（リース開始） |
| `api.extend(lease_id, duration_minutes, user_name)` | VARCHAR, INTEGER, VARCHAR | リース延長 |
| `api.stop(lease_id)` | VARCHAR | リース停止 |
| `api.get_status(app_name)` | VARCHAR (NULL可) | リース状態取得 |
| `api.heartbeat(lease_id, user_name)` | VARCHAR, VARCHAR | ハートビート |
| `api.list_apps()` | — | 管理アプリ一覧 |
| `api.get_endpoints(app_name)` | VARCHAR | エンドポイント取得 |

### config.* / core.* スキーマ（Operator 内部用 — SaaS からは非公開）

| プロシージャ | 用途 |
|---|---|
| `config.save_discovered_apps(data)` | ACCOUNTADMIN 発見スクリプトの結果を保存 |
| `config.manage_app(app_name, TRUE/FALSE)` | アプリの管理/非管理を切り替え |
| `config.validate_managed_app(app_name)` | リソース権限を検証 |
| `core.stop_if_expired()` | 期限切れリース自動停止（Watchdog） |
| `core.sync_app_catalog()` | アプリカタログ同期 |

> `api.*` スキーマが SaaS との公式インターフェース。
> `core.*` / `config.*` は Operator 内部の実装詳細であり、SaaS は直接呼び出さない。
> `api.*` プロシージャは内部で `core.*` / `config.*` を呼び出すラッパーとして機能する。

---

## Appendix B: リファレンス実装

**Postgres Learning Studio** が Gallery Compatible App のリファレンス実装である。

| ファイル | 内容 |
|---|---|
| `streamlit/setup_ui.py` Section 6 | Gallery Integration UI（検知、GRANT 案内） |
| `services.sql` `resume_service()` | Service RESUME/CREATE のフォールバックパターン |
| `services.sql` `service_status()` | SHOW SERVICES による状態取得 |
| `services.sql` `service_url()` | SHOW ENDPOINTS による ingress_url 取得 |

> **注意**: v3 ではアプリ側の auto-stop を完全排除し、Gallery Operator にライフサイクルを委任する設計のため、
> `set_gallery_managed()` トグルや Start/Stop ボタンは不要。

### Streamlit Gallery Integration セクションの実装ポイント

1. **検知**: `BLUE_APP_GALLERY_REGISTRY.PUBLIC.OPERATOR` を SELECT（`WHERE app_name = 'BLUE_APP_GALLERY'`、try/except）
2. **未検出時**: `CURRENT_DATABASE()` でアプリ名を取得し、GRANT SQL を動的生成
3. **検出時**: expandable セクションに GRANT APPLICATION ROLE SQL を表示（`TO APPLICATION BLUE_APP_GALLERY`）
4. **Overview ページ**: 常に「Gallery Operator で管理中」メッセージを表示
5. **Setup ページ**: Start/Stop ボタンなし（Gallery から制御）
