-- Seed the org base model for the pacgate QM deployment.
-- Idempotent: upsert on the org scope id.
INSERT INTO base_model_configs (id, json)
VALUES ('org:pacgate', '{"modelId":"glm-5.3-flash:cloud"}'::jsonb)
ON CONFLICT (id) DO UPDATE SET json = EXCLUDED.json;
SELECT id, json FROM base_model_configs;