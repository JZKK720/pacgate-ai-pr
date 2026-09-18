-- Pacgate-ai sanitizer job store + redaction ledger (evidence half).
-- Migration 007 - design sections 3.3, 5.1, 6.1-6.3.
--
-- sanitizer_jobs : one row per sanitize job. The mapping (vault) is stored
--                  HERE ONLY - never in a lane deer-flow can read. Restoring
--                  requires this row plus the caller knowing the job id.
-- redaction_ledger_rows : the RedactionLedger JSON per (job, document),
--                  keyed to the document VERSION the job actually read.
--                  Evidence for "this artifact was really redacted".

CREATE TABLE IF NOT EXISTS sanitizer_jobs (
    id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id     UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    matter_id     UUID NOT NULL REFERENCES matters(id) ON DELETE CASCADE,
    data_level    TEXT NOT NULL,             -- T1|T2|T3|T4 (004 convention)
    mapping_version INTEGER NOT NULL,
    -- The vault. JSON of Mapping entries: placeholder -> (entity, original).
    -- This column never leaves pacgate-api (no MCP tool reads it).
    mapping       JSONB NOT NULL,
    mapping_count INTEGER NOT NULL,
    verdict       TEXT NOT NULL,             -- pass | block
    created_by    UUID REFERENCES users(id),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_sanitizer_jobs_tenant
    ON sanitizer_jobs (tenant_id, created_at);

CREATE TABLE IF NOT EXISTS redaction_ledger_rows (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    job_id          UUID NOT NULL REFERENCES sanitizer_jobs(id) ON DELETE CASCADE,
    tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    matter_id       UUID NOT NULL REFERENCES matters(id) ON DELETE CASCADE,
    document_id     UUID NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    document_version INTEGER NOT NULL,
    input_sha256    TEXT NOT NULL,
    output_sha256   TEXT NOT NULL,
    redaction_count INTEGER NOT NULL,
    verdict         TEXT NOT NULL,           -- pass | block
    ledger_json     JSONB NOT NULL,          -- full RedactionLedger (no originals)
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_redaction_ledger_doc
    ON redaction_ledger_rows (tenant_id, matter_id, document_id, document_version);