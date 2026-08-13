-- Pacgate-ai initial schema: tenants, users, matters, documents
-- All UUIDs stored as UUID type (Postgres native).

-- ─── Extensions ──────────────────────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
-- pgvector is optional (added when pacgate-rag is wired):
-- CREATE EXTENSION IF NOT EXISTS "vector";

-- ─── Tenants ─────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS tenants (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name        TEXT NOT NULL,
    slug        TEXT NOT NULL UNIQUE,          -- URL-safe identifier
    config_json JSONB NOT NULL DEFAULT '{}'::JSONB,  -- model_overrides, security posture, etc.
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─── Users ───────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS users (
    id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id     UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    email         TEXT NOT NULL,
    password_hash TEXT,                        -- NULL for SSO-only users
    role          TEXT NOT NULL DEFAULT 'attorney',  -- admin | attorney | paralegal | partner
    system_role   TEXT NOT NULL DEFAULT 'user',      -- admin | user (platform-level)
    display_name  TEXT,
    soul_id       UUID,                        -- assigned SOUL persona (nullable)
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(tenant_id, email)
);

CREATE INDEX IF NOT EXISTS idx_users_tenant ON users(tenant_id);
CREATE INDEX IF NOT EXISTS idx_users_email  ON users(email);

-- ─── Matters ─────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS matters (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id   UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    name        TEXT NOT NULL,
    description TEXT,
    persona_id  UUID,                           -- references persona config (not a table yet)
    created_by  UUID NOT NULL REFERENCES users(id),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_matters_tenant ON matters(tenant_id);

-- ─── Documents ───────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS documents (
    id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    matter_id    UUID NOT NULL REFERENCES matters(id) ON DELETE CASCADE,
    tenant_id    UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    name         TEXT NOT NULL,
    format       TEXT NOT NULL DEFAULT 'docx',  -- docx | pdf | txt | markdown
    version      INTEGER NOT NULL DEFAULT 1,
    storage_path TEXT NOT NULL,                 -- relative to DATA_DIR: tenants/{t}/matters/{m}/docs/{name}_v{n}.docx
    owner_id     UUID NOT NULL REFERENCES users(id),
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_documents_matter  ON documents(matter_id);
CREATE INDEX IF NOT EXISTS idx_documents_tenant  ON documents(tenant_id);
CREATE INDEX IF NOT EXISTS idx_documents_owner   ON documents(owner_id);
-- Only one current version per (matter, name) — enforced at application level
-- (previous versions are kept but only the highest version is "current")

-- ─── Audit log ───────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS audit_log (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id   UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    user_id     UUID REFERENCES users(id),
    action      TEXT NOT NULL,                  -- document.read | document.create | matter.create | etc.
    resource    TEXT NOT NULL,                  -- document:{id} | matter:{id}
    scope       TEXT,                           -- tenant:{id} | matter:{id}
    metadata    JSONB,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_audit_tenant  ON audit_log(tenant_id);
CREATE INDEX IF NOT EXISTS idx_audit_user    ON audit_log(user_id);
CREATE INDEX IF NOT EXISTS idx_audit_action  ON audit_log(action);