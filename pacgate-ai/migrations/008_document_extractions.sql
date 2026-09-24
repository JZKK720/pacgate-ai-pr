-- Pacgate-ai extraction completeness record. Migration 008.
--
-- WHY THIS TABLE EXISTS
--
-- Extraction is cached so that a per-job sanitize costs ZERO OCR calls on a warm
-- cache, and so a bulk OCR pass can pre-warm it once for many later sanitizes.
-- The cached artifact is document_spans + kb_chunks.
--
-- But `incomplete` - whether every page was really read - had nowhere to live.
-- extract.rs's cache branch returned a hardcoded false, so any document with at
-- least one span read back as COMPLETE, however much of it was never parsed.
-- sanitize.rs refuses only on incomplete=true, so a partially-read document was
-- declared 'sanitized' and released through the egress gate.
--
-- This row is the missing fact. It is also the CACHE KEY: a document whose pages
-- all yielded nothing has zero spans, and keying the cache on "are there spans"
-- would have made that case a permanent cache miss (re-OCRing forever) while
-- still being unable to record that it was incomplete.
--
-- NO BACKFILL, deliberately. Rows extracted before this migration have unknown
-- completeness. Backfilling them as complete would bake the old defect into the
-- new column. They are treated as cache misses and re-extracted on first access,
-- which records the TRUE flag. That costs one OCR pass per pre-existing document
-- and cannot mislabel one.

CREATE TABLE IF NOT EXISTS document_extractions (
    id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id         UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    matter_id         UUID NOT NULL REFERENCES matters(id) ON DELETE CASCADE,
    document_id       UUID NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    document_version  INTEGER NOT NULL,
    -- TRUE when any page failed to parse or yielded no text. sanitize.rs refuses
    -- on TRUE, so this column is what keeps an unread document out of egress.
    incomplete        BOOLEAN NOT NULL,
    -- Which extractor produced this. 'paddleocr' today; a text-native converter
    -- will add its own label, and the label makes a stale cache detectable when
    -- the extractor changes.
    engine            TEXT,
    pages             INTEGER NOT NULL DEFAULT 0,
    extracted_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    -- One row per document version.
    --
    -- NOTE ON THE VERSION BINDING, corrected after review: this is NOT the
    -- protection it looks like. `FsDocumentStore::upload_bytes` ->
    -- `insert_doc_row` INSERTS A NEW ROW WITH A NEW document_id; `documents.version`
    -- is not bumped in place. So today (document_id, document_version) is
    -- effectively just document_id, and document_version is a constant per row.
    --
    -- The behaviour is correct either way - a re-upload is a different document_id,
    -- so the lookup misses and the new version is extracted fresh - but do NOT cite
    -- this constraint as the reason a stale row cannot be served. If a future
    -- refactor implements true version-in-place, this table's keying must be
    -- re-examined rather than assumed safe.
    UNIQUE (document_id, document_version)
);

CREATE INDEX IF NOT EXISTS idx_document_extractions_doc
    ON document_extractions (tenant_id, matter_id, document_id, document_version);
