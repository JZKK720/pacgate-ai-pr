-- Pacgate-ai data classification: T1-T4 data level
-- Migration 004 — adds data_level column to kb_chunks for the archive taxonomy

-- Add data_level column (stores DataLevel enum as T-code string: T1, T2, T3, T4)
-- T1 = 全所共享模板 (shared template, no client identity)
-- T2 = 所内受限种子 (restricted seed, retains client context, no cross-project search)
-- T3 = 项目专属资料 (project-specific, MatterId-scoped only)
-- T4 = 特别敏感资料 (special sensitive, strict isolation, special approval)
ALTER TABLE kb_chunks ADD COLUMN
IF NOT EXISTS data_level TEXT DEFAULT 'T2';

-- Index for data_level filtering
CREATE INDEX
IF NOT EXISTS idx_kb_chunks_data_level ON kb_chunks
(data_level)
    WHERE data_level IS NOT NULL;

-- Composite index for matter + data_level filtering (T2+ require matter scoping)
CREATE INDEX
IF NOT EXISTS idx_kb_chunks_matter_data_level
    ON kb_chunks
(tenant_id, matter_id, data_level)
    WHERE data_level IS NOT NULL;