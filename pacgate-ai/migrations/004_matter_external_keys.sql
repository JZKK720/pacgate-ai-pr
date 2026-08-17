ALTER TABLE matters
    ADD COLUMN
IF NOT EXISTS external_key TEXT;

CREATE UNIQUE INDEX
IF NOT EXISTS idx_matters_tenant_external_key
    ON matters
(tenant_id, external_key)
    WHERE external_key IS NOT NULL;