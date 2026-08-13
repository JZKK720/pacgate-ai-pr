-- Pacgate-ai RAG enrichment: jurisdiction + source level tagging
-- Migration 003 — adds jurisdiction and source_level columns to kb_chunks

-- Add jurisdiction column (stores Jurisdiction enum as snake_case string)
ALTER TABLE kb_chunks ADD COLUMN
IF NOT EXISTS jurisdiction TEXT;

-- Add source_level column (stores SourceLevel enum as snake_case string)
ALTER TABLE kb_chunks ADD COLUMN
IF NOT EXISTS source_level TEXT;

-- Index for jurisdiction filtering
CREATE INDEX
IF NOT EXISTS idx_kb_chunks_jurisdiction ON kb_chunks
(jurisdiction)
    WHERE jurisdiction IS NOT NULL;

-- Index for source_level filtering
CREATE INDEX
IF NOT EXISTS idx_kb_chunks_source_level ON kb_chunks
(source_level)
    WHERE source_level IS NOT NULL;

-- Composite index for combined jurisdiction + matter filtering
CREATE INDEX
IF NOT EXISTS idx_kb_chunks_jurisdiction_matter
    ON kb_chunks
(tenant_id, matter_id, jurisdiction)
    WHERE jurisdiction IS NOT NULL;