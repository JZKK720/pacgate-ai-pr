-- CJK-aware full-text search for kb_chunks.
--
-- WHY THIS EXISTS (measured 2026-11-04)
--
-- 002_rag_schema.sql built the tsvector as `to_tsvector('english', content)`.
-- For Chinese that is not coarse - it is inert. Postgres' default parsers do not
-- segment Han text, so an entire sentence becomes ONE lexeme:
--
--   to_tsvector('english','结算条款约定甲方应在收到合规发票后...')
--     -> '结算条款约定甲方应在收到合规发票后三十个工作日内支付':1
--
-- Measured against the live corpus (918 of 957 chunks are Chinese):
--
--   to_tsvector(...) @@ plainto_tsquery('english','结算条款')  -> f
--   to_tsvector(...) @@ plainto_tsquery('english','质保金')    -> f
--
-- So the KEYWORD half of the "hybrid" search in pacgate-rag matched ZERO rows of
-- real client content. Every exact-term lookup - a clause number, a party name,
-- 质保金 - silently depended on the vector half alone.
--
-- WHY NOT 'simple': tested, and it splits identically (same single lexeme). The
-- parser is the problem, not the stemmer. `zhparser` is the usual answer but is
-- NOT available in the shipped Postgres image (pg_available_extensions shows
-- only pg_trgm), so a fix requiring it would fail on a clean client install.
--
-- THE FIX: insert a space around every Han character before indexing, so the
-- 'simple' parser yields one token PER CHARACTER, then query with a PHRASE
-- (<->) rather than a bag of characters. Verified on the live database:
--
--   to_tsvector('simple', regexp_replace(c,'([一-鿿])',' \1 ','g'))
--     -> '质':27 '保':28 '金':29 ...
--   ... @@ to_tsquery('simple','质 <-> 保 <-> 金')  -> t   (match)
--   ... @@ plainto_tsquery('simple','质保金')      -> f   (no match)
--
-- The phrase operator is what makes this correct: without it, characters from
-- unrelated words would match, and precision would collapse.
--
-- COST: one token per character inflates the tsvector. Acceptable for a
-- per-matter corpus of this size (957 chunks today) and it needs no extension,
-- no new service, and no re-embedding - only a reindex.
--
-- NOTE: this changes the GENERATED column's expression, so the column must be
-- dropped and re-added. That rewrites the GIN index, not the embeddings; the
-- vector half is untouched and no document has to be re-embedded.

ALTER TABLE kb_chunks DROP COLUMN IF EXISTS content_tsv;

ALTER TABLE kb_chunks ADD COLUMN content_tsv tsvector
    GENERATED ALWAYS AS (
        to_tsvector(
            'simple',
            regexp_replace(content, '([一-鿿])', ' \1 ', 'g')
        )
    ) STORED;

CREATE INDEX IF NOT EXISTS idx_kb_chunks_content_tsv
    ON kb_chunks USING gin(content_tsv);

-- CJK-aware query construction, mirroring the index expression above.
--
-- The index splits Han text into ONE TOKEN PER CHARACTER. A bag-of-characters
-- query would match characters from unrelated words anywhere in the chunk, so
-- precision would collapse; the characters must be joined with the phrase
-- operator (<->) to require adjacency.
--
-- Verified on the live database:
--   to_tsvector('simple', split('...质保金为合同...'))
--     @@ cjk_tsquery('质保金')  ->  t
--   plainto_tsquery('simple','质保金')  ->  f   (the old behaviour)
CREATE OR REPLACE FUNCTION cjk_tsquery(q text) RETURNS tsquery
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT to_tsquery(
        'simple',
        array_to_string(
            array_remove(
                string_to_array(
                    trim(regexp_replace(q, '([一-鿿])', ' \1 ', 'g')),
                    ' '
                ),
                ''
            ),
            ' <-> '
        )
    )
$$;

