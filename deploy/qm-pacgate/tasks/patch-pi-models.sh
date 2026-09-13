#!/bin/sh
# Patch pi-models.ts inside qm-pacgate-core:
# 1. Add glm-5.3-flash:cloud (Ollama cloud tag) to MODEL_REGISTRY
# 2. Make defaultModelForProvider return it for the openai provider (Ollama
#    OpenAI-compatible endpoint), so auxiliary calls (detect/title/judge) stop
#    resolving to gpt-5.6-sol -> real api.openai.com -> 401.
set -e
F=/app/src/model/pi-models.ts

if grep -q 'glm-5.3-flash:cloud' "$F"; then
  echo "already patched"
  exit 0
fi

# 1. Insert the model entry at the top of MODEL_REGISTRY
sed -i 's|export const MODEL_REGISTRY: readonly ModelEntry\[\] = \[|export const MODEL_REGISTRY: readonly ModelEntry[] = [\n  { id: "glm-5.3-flash:cloud", name: "GLM 5.3 Flash (Ollama cloud)", fastMode: true, webui: true, base: true },|' "$F"

# 2. Override defaultModelForProvider for the openai provider
sed -i 's|export function defaultModelForProvider(harness: string, provider: ModelProvider): string \| undefined {|export function defaultModelForProvider(harness: string, provider: ModelProvider): string \| undefined {\n  if (provider === "openai") return "glm-5.3-flash:cloud";|' "$F"

echo "patched:"
grep -n 'glm-5.3-flash:cloud' "$F"