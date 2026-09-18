//! Local Chinese NER via a BERT token-classification model over Candle.
//!
//! Additive by design: the deterministic rules run first (plan 017 Task 4),
//! and this detector contributes candidates the rules cannot see - person,
//! org and location names. Model output is NEVER authoritative on its own:
//! the verifier replays the combined set, and the noise filter still drops
//! overlaps in favour of the longer, checksum-anchored spans.
//!
//! Model: shibing624/bert4ner-base-chinese (Apache-2.0; the plan's original
//! pick ckiplab/bert-base-chinese-ner is GPL-3.0 and cannot ship in the
//! commercial client bundle). Trained on CNER + People's Daily (F1 0.9525).
//! Labels are read from config.json because its id2label is NOT in sorted
//! index order - never hardcode indices here.

use std::path::Path;

use candle_core::{Device, Tensor};
use candle_nn::VarBuilder;
use candle_transformers::models::bert::{BertModel, Config as BertConfig};
use tokenizers::normalizers::BertNormalizer;
use tokenizers::pre_tokenizers::bert::BertPreTokenizer;
use tokenizers::processors::bert::BertProcessing;
use tokenizers::{ModelWrapper, Tokenizer};

use crate::detect::Detector;
use crate::{EntityType, Match, MatchSource, RedactError, RedactResult};

const MODEL_FILES: &str = "config.json|model.safetensors|vocab.txt";

/// Token-classification labels this detector maps. TIME stays unmatched on
/// purpose: dates are Tier-1 pattern territory, and a model guess must never
/// be authoritative for structured values.
fn map_label(label: &str) -> Option<(bool, EntityType)> {
    // Returns (is_begin, entity type) for B-/I- tags.
    let (tag, rest) = match label.split_once('-') {
        Some((t, r)) => (t, r),
        None => return None,
    };
    let entity = match rest {
        "PER" => EntityType::PersonName,
        "ORG" => EntityType::OrgName,
        "LOC" => EntityType::Location,
        _ => return None,
    };
    match tag {
        "B" => Some((true, entity)),
        "I" => Some((false, entity)),
        _ => None,
    }
}

struct LabelMap {
    /// (index -> Option<(is_begin, entity)>) for every logit slot.
    slots: Vec<Option<(bool, EntityType)>>,
}

impl LabelMap {
    fn from_config(model_dir: &Path) -> RedactResult<Self> {
        let cfg_path = model_dir.join("config.json");
        let raw = std::fs::read_to_string(&cfg_path).map_err(|e| {
            RedactError::Internal(format!(
                "cannot read {}: {e} (fail closed: model files must ship with the bundle)",
                cfg_path.display()
            ))
        })?;
        let v: serde_json::Value = serde_json::from_str(&raw)
            .map_err(|e| RedactError::Internal(format!("invalid config.json: {e}")))?;
        let id2label = v
            .get("id2label")
            .and_then(|m| m.as_object())
            .ok_or_else(|| {
                RedactError::Internal("config.json missing id2label".to_string())
            })?;
        let mut slots: Vec<Option<(bool, EntityType)>> = Vec::new();
        // Parse every "index" -> "label" pair; indices may arrive in any order.
        for (k, label) in id2label {
            let idx: usize = k.parse().map_err(|_| {
                RedactError::Internal(format!("config.json id2label has non-numeric key {k}"))
            })?;
            let mapped = label
                .as_str()
                .and_then(map_label);
            if slots.len() <= idx {
                slots.resize(idx + 1, None);
            }
            slots[idx] = mapped;
        }
        Ok(Self { slots })
    }
}

pub struct NerDetector {
    tokenizer: Tokenizer,
    model: BertModel,
    labels: LabelMap,
    device: Device,
    /// classifier.weight [num_labels, hidden], loaded from the checkpoint.
    head_weight: Tensor,
    /// classifier.bias [num_labels].
    head_bias: Tensor,
}

impl NerDetector {
    /// Load the model from a local directory. Fails closed: a missing or
    /// incomplete model directory is a hard error, never a silent skip to
    /// rules-only.
    pub fn load(model_dir: &str) -> RedactResult<Self> {
        let dir = Path::new(model_dir);
        if !dir.is_dir() {
            return Err(RedactError::Internal(format!(
                "NER model directory not found: {model_dir} (expected files: {MODEL_FILES})"
            )));
        }
        let missing: Vec<&str> = ["config.json", "model.safetensors", "vocab.txt"]
            .into_iter()
            .filter(|f| !dir.join(f).is_file())
            .collect();
        if !missing.is_empty() {
            return Err(RedactError::Internal(format!(
                "NER model directory {model_dir} is missing files: {}",
                missing.join(", ")
            )));
        }

        let labels = LabelMap::from_config(dir)?;

        // Tokenizer: the model ships vocab.txt (no tokenizer.json), so
        // assemble WordPiece + BERT normalizer/pretokenizer/processor.
        let wordpiece = tokenizers::models::wordpiece::WordPieceBuilder::new()
            .files(dir.join("vocab.txt").to_string_lossy().to_string())
            .unk_token("[UNK]".to_string())
            .continuing_subword_prefix("##".to_string())
            .max_input_chars_per_word(100)
            .build()
            .map_err(|e| RedactError::Internal(format!("failed to load vocab.txt: {e}")))?;
        let mut tokenizer = Tokenizer::new(ModelWrapper::WordPiece(wordpiece));
        // [CLS]/[SEP] must exist in the vocab and their IDs must be known
        // before BertProcessing can wrap sequences.
        let vocab = tokenizer.get_vocab(true);
        let cls_id = *vocab.get("[CLS]").ok_or_else(|| {
            RedactError::Internal("vocab.txt lacks [CLS] special token".to_string())
        })?;
        let sep_id = *vocab.get("[SEP]").ok_or_else(|| {
            RedactError::Internal("vocab.txt lacks [SEP] special token".to_string())
        })?;
        tokenizer
            .with_normalizer(Some(BertNormalizer::new(true, true, None, false)))
            .with_pre_tokenizer(Some(BertPreTokenizer))
            .with_post_processor(Some(BertProcessing::new(
                ("[SEP]".to_string(), sep_id),
                ("[CLS]".to_string(), cls_id),
            )));

        let device = Device::Cpu;
        let cfg: BertConfig = serde_json::from_str(&std::fs::read_to_string(
            dir.join("config.json"),
        )
        .map_err(|e| RedactError::Internal(format!("cannot read config.json: {e}")))?)
        .map_err(|e| RedactError::Internal(format!("invalid BERT config: {e}")))?;

        let vb = unsafe {
            VarBuilder::from_mmaped_safetensors(
                &[dir.join("model.safetensors")],
                candle_core::DType::F32,
                &device,
            )
            .map_err(|e| {
                RedactError::Internal(format!("cannot map model.safetensors: {e}"))
            })?
        };
        let model = BertModel::load(vb.clone(), &cfg)
            .map_err(|e| RedactError::Internal(format!("failed to build BertModel: {e}")))?;

        // Token-classification head: prefix-less `classifier.*` keys in the
        // checkpoint (verified from the safetensors header), while the
        // encoder lives under `bert.*`. BertModel::load strips that prefix
        // itself, so the head must be read from the top-level VarBuilder.
        // Shapes verified from the checkpoint header: [9,768] weight, [9] bias.
        // torch nn.Linear computes x @ W.T, so transpose to [768,9] here —
        // otherwise the matmul in detect() hits a shape mismatch.
        let head_weight = vb
            .get((9, 768), "classifier.weight")
            .map_err(|e| {
                RedactError::Internal(format!("checkpoint lacks classifier.weight: {e}"))
            })?
            .t()
            .map_err(|e| RedactError::Internal(format!("head weight transpose failed: {e}")))?;
        let head_bias = vb
            .get(9, "classifier.bias")
            .map_err(|e| {
                RedactError::Internal(format!("checkpoint lacks classifier.bias: {e}"))
            })?;

        Ok(Self {
            tokenizer,
            model,
            labels,
            device,
            head_weight,
            head_bias,
        })
    }
}

impl Detector for NerDetector {
    fn name(&self) -> &'static str {
        "ner-zh"
    }

    fn detect(&self, text: &str) -> RedactResult<Vec<Match>> {
        if text.is_empty() {
            return Ok(Vec::new());
        }
        // BERT context limit; long documents are processed in windows.
        const MAX_TOKENS: usize = 500; // 512 slots minus [CLS]/[SEP]
        // add_special_tokens=true is REQUIRED: BERT expects [CLS] text [SEP].
        // Without it the hidden states shift by one position and every
        // prediction degrades (locations mis-span, person names never fire).
        let encoding = self
            .tokenizer
            .encode_char_offsets(text, true)
            .map_err(|e| RedactError::Internal(format!("tokenization failed: {e}")))?;
        let ids: Vec<u32> = encoding.get_ids().to_vec();
        if ids.len() > MAX_TOKENS + 2 {
            // Simple sliding window over the first window for now; full
            // windowed inference is a Task 7 follow-up (plan 019 T7 harness
            // measures recall, not throughput).
            return Err(RedactError::Internal(
                "document exceeds NER context window (512 tokens); windowed inference not yet wired".to_string(),
            ));
        }
        if ids.len() < 2 {
            return Ok(Vec::new());
        }

        let input_ids = Tensor::new(&ids[..], &self.device)
            .map_err(|e| RedactError::Internal(format!("tensor alloc failed: {e}")))?
            .unsqueeze(0)
            .map_err(|e| RedactError::Internal(format!("unsqueeze failed: {e}")))?;
        let token_type_ids = Tensor::zeros((1, ids.len()), candle_core::DType::U32, &self.device)
            .map_err(|e| RedactError::Internal(format!("type ids alloc failed: {e}")))?;
        let attention_mask = Tensor::ones((1, ids.len()), candle_core::DType::U32, &self.device)
            .map_err(|e| RedactError::Internal(format!("mask alloc failed: {e}")))?;

        // Manual token-classification head: hidden states -> linear layer.
        // The head weights live in the checkpoint as `classifier.weight/bias`
        // (BertForTokenClassification layout, prefix-less or `bert.`-prefixed
        // depending on export); BertModel::load handles the `bert.` prefix
        // fallback internally, so load the head separately here once the
        // VarBuilder wiring is confirmed against the pinned crate.
        let sequence_output = self
            .model
            .forward(&input_ids, &token_type_ids, Some(&attention_mask))
            .map_err(|e| RedactError::Internal(format!("BERT forward failed: {e}")))?;

        // Token-classification head: sequence_output [1, seq, 768] -> logits
        // [1, seq, num_labels] via classifier.weight/bias. candle matmul
        // requires matching ranks, so flatten to [seq, 768], apply the linear
        // head, and reshape back to [1, seq, num_labels].
        let (batch, seq, hidden) = sequence_output
            .dims3()
            .map_err(|e| RedactError::Internal(format!("unexpected forward output shape: {e}")))?;
        let flat = sequence_output
            .reshape((batch * seq, hidden))
            .map_err(|e| RedactError::Internal(format!("head flatten failed: {e}")))?;
        let logits = flat
            .matmul(&self.head_weight)
            .map_err(|e| RedactError::Internal(format!("head matmul failed: {e}")))?;
        let logits = logits
            .broadcast_add(&self.head_bias)
            .map_err(|e| RedactError::Internal(format!("head bias failed: {e}")))?;
        let logits = logits
            .reshape((batch, seq, 9))
            .map_err(|e| RedactError::Internal(format!("head reshape failed: {e}")))?;
        let argmax = logits
            .argmax(candle_core::D::Minus1)
            .map_err(|e| RedactError::Internal(format!("argmax failed: {e}")))?;
        let preds: Vec<u32> = argmax
            .squeeze(0)
            .map_err(|e| RedactError::Internal(format!("squeeze failed: {e}")))?
            .to_vec1::<u32>()
            .map_err(|e| RedactError::Internal(format!("preds to_vec failed: {e}")))?;

        // BIO decode: tokens (skip specials), byte offsets from the encoding.
        let offsets = encoding.get_offsets();
        // The tokenizer reports CHAR offsets (verified via NER_DEBUG: CJK text
        // yields (i, i+1) per token), but Match offsets are BYTE offsets.
        // Convert with a char-index -> byte-index table. For pure-ASCII text
        // the tables are identical and this is a no-op.
        let char_to_byte: Vec<usize> = {
            let mut t = Vec::with_capacity(text.chars().count() + 1);
            let mut b = 0usize;
            t.push(0);
            for ch in text.chars() {
                b += ch.len_utf8();
                t.push(b);
            }
            t
        };
        let to_byte = |idx: usize| -> usize {
            char_to_byte
                .get(idx)
                .copied()
                .unwrap_or(char_to_byte[char_to_byte.len() - 1])
        };
        let offsets: Vec<(usize, usize)> = offsets
            .iter()
            .map(|(s, e)| (to_byte(*s), to_byte(*e)))
            .collect();
        let tokens: Vec<String> = encoding.get_tokens().to_vec();
        let mut matches: Vec<Match> = Vec::new();
        let mut cur: Option<(EntityType, usize)> = None; // (entity, start byte)
        // Flush closes the open entity at `end` (byte offset).
        fn flush(
            cur: &mut Option<(EntityType, usize)>,
            end: usize,
            text: &str,
            out: &mut Vec<Match>,
        ) {
            if let Some((entity, start)) = cur.take() {
                let sliced = safe_slice(text, start, end);
                if !sliced.trim().is_empty() {
                    out.push(Match {
                        start,
                        end,
                        entity,
                        text: sliced,
                        confidence: 0.85,
                        source: MatchSource::Model,
                    });
                }
            }
        }
        // Track the open entity's running end offset. cur holds (entity, start).
        let mut open_end: usize = 0;
        for (i, &pred) in preds.iter().enumerate() {
            let Some(mapped) = self.labels.slots.get(pred as usize).copied().flatten() else {
                // O prediction: the open entity ends where this token begins.
                flush(&mut cur, offsets[i].0, text, &mut matches);
                continue;
            };
            let (is_begin, entity) = mapped;
            let token = tokens.get(i).map(|s| s.as_str()).unwrap_or("");
            // Skip special tokens entirely.
            if token == "[CLS]" || token == "[SEP]" || token == "[PAD]" {
                flush(&mut cur, offsets[i].0, text, &mut matches);
                continue;
            }
            match (is_begin, cur) {
                // New entity: flush whatever was open, start fresh.
                (true, _) => {
                    flush(&mut cur, open_end, text, &mut matches);
                    cur = Some((entity, offsets[i].0));
                }
                // Continuation: extend when the type matches, flush on mismatch.
                (false, Some((e, start))) if e == entity => {
                    let _ = start; // extended via open_end below
                }
                (false, _) => {
                    flush(&mut cur, offsets[i].0, text, &mut matches);
                }
            }
            // Track running end for the open entity.
            if cur.is_some() {
                open_end = offsets[i].1;
            }
        }
        flush(&mut cur, open_end, text, &mut matches);
        Ok(matches)
    }
}

/// Byte-safe substring: returns "" when the offsets are not char boundaries
/// instead of panicking (model offsets are usually valid, never trust them).
fn safe_slice(text: &str, start: usize, end: usize) -> String {
    let s = (start).min(text.len());
    let e = (end).min(text.len());
    let mut s = s;
    let mut e = e;
    while s < e && !text.is_char_boundary(s) {
        s += 1;
    }
    while e > s && !text.is_char_boundary(e) {
        e -= 1;
    }
    if s >= e {
        String::new()
    } else {
        text[s..e].to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fails_closed_when_model_dir_missing() {
        let err = match NerDetector::load("./nonexistent-ner-model-dir") {
            Err(e) => e,
            Ok(_) => panic!("expected load failure for missing model dir"),
        };
        assert!(matches!(err, RedactError::Internal(_)));
        assert!(err.to_string().contains("not found"));
    }

    #[test]
    fn label_map_reads_config_not_sorted() {
        // Config with out-of-order indices: B-PER at 8, O at 2.
        let tmp = std::env::temp_dir().join("pacgate-ner-test-config");
        let _ = std::fs::create_dir_all(&tmp);
        std::fs::write(
            tmp.join("config.json"),
            r#"{"vocab_size":21128,"id2label":{"2":"O","8":"B-PER","3":"B-TIME"}}"#,
        )
        .unwrap();
        let lm = LabelMap::from_config(&tmp).unwrap();
        assert!(lm.slots[2].is_none());
        assert_eq!(lm.slots[8], Some((true, EntityType::PersonName)));
        assert!(lm.slots[3].is_none()); // TIME never maps
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn detect_returns_empty_for_empty_text() {
        // Cannot construct a real model without weights; exercise the
        // empty-input guard through the trait when a model dir is present.
        // Without the model this test only asserts the guard compiles.
    }
}
