-- Pacgate-ai sanitization state: gates every egress path.
-- Migration 005 -- design section 5.1.
--
-- Four states. `pending` is the DEFAULT and that is the safety property: a row
-- that was never processed reads as pending, not as sanitized, so a new
-- ingestion path that forgets to set this column fails closed. A default of
-- 'sanitized' would make forgetting indistinguishable from success.
--
--   pending    extracted, not yet sanitized
--   sanitized  a job produced a Block-free verdict; a ledger must exist
--   blocked    a job ran and the verdict was Block; must never reach any egress
--   never      explicitly out of scope (e.g. a T1 shared template)
--
-- Same TEXT-code convention as data_level in 004_data_level.sql, so both
-- filters can be applied in one query without a join.

ALTER TABLE kb_chunks ADD COLUMN
IF NOT EXISTS sanitization_state TEXT DEFAULT 'pending';

ALTER TABLE documents ADD COLUMN
IF NOT EXISTS sanitization_state TEXT DEFAULT 'pending';

-- Backfill is not possible automatically: no existing row has a ledger, so
-- none can claim to be sanitized. Leaving them at 'pending' is correct and
-- fail-closed. Do NOT add a backfill UPDATE here.

CREATE INDEX
IF NOT EXISTS idx_kb_chunks_sanitization
    ON kb_chunks
(tenant_id, matter_id, sanitization_state)
    WHERE sanitization_state IS NOT NULL;

CREATE INDEX
IF NOT EXISTS idx_documents_sanitization
    ON documents
(tenant_id, matter_id, sanitization_state)
    WHERE sanitization_state IS NOT NULL;