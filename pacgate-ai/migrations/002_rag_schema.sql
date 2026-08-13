-- Pacgate-ai RAG schema: knowledge chunks with pgvector + tsvector
-- Requires pgvector extension: CREATE EXTENSION IF NOT EXISTS vector;

CREATE EXTENSION IF NOT EXISTS vector;

-- ─── Knowledge chunks ────────────────────────────────────────────────────────
-- Each document is split into chunks, embedded, and stored here.
-- Both tsvector (keyword) and vector (semantic) search are supported.
CREATE TABLE IF NOT EXISTS kb_chunks (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    matter_id       UUID NOT NULL REFERENCES matters(id) ON DELETE CASCADE,
    document_id     UUID NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    chunk_index     INTEGER NOT NULL,          -- 0-based chunk order within the document
    content         TEXT NOT NULL,              -- the text content of this chunk
    page            INTEGER,                    -- page number if from a paginated document
    embedding       vector(768),               -- nomic-embed-text produces 768-dim vectors
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- tsvector column for full-text search (auto-updated from content)
ALTER TABLE kb_chunks ADD COLUMN IF NOT EXISTS content_tsv tsvector
    GENERATED ALWAYS AS (to_tsvector('english', content)) STORED;

CREATE INDEX IF NOT EXISTS idx_kb_chunks_tenant_matter ON kb_chunks(tenant_id, matter_id);
CREATE INDEX IF NOT EXISTS idx_kb_chunks_document ON kb_chunks(document_id);
CREATE INDEX IF NOT EXISTS idx_kb_chunks_embedding ON kb_chunks USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);
CREATE INDEX IF NOT EXISTS idx_kb_chunks_content_tsv ON kb_chunks USING gin(content_tsv);