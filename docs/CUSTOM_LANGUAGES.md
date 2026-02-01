# Custom Language Support for TranslateCall

## Extending TranslateCall Beyond Apple Intelligence Languages

This document describes how to add support for languages not covered by Apple Intelligence/Translation Framework to TranslateCall. This enables real-time voice translation for minority, regional, or low-resource languages.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Architecture](#2-architecture)
3. [Supported vs Custom Languages](#3-supported-vs-custom-languages)
4. [Adding a New Language: Step-by-Step](#4-adding-a-new-language-step-by-step)
5. [Technical Requirements](#5-technical-requirements)
6. [Deployment Options](#6-deployment-options)
7. [Voice Pipeline Integration](#7-voice-pipeline-integration)
8. [Latency Considerations](#8-latency-considerations)
9. [Cost Estimation](#9-cost-estimation)
10. [Example: Adding Aragonese (ES ↔ AN)](#10-example-adding-aragonese-es--an)
11. [Contributing a New Language](#11-contributing-a-new-language)

---

## 1. Overview

### The Problem

Apple Intelligence Translation Framework supports approximately 20 languages. Many regional, minority, and low-resource languages are not included:

- **Iberian Peninsula**: Aragonese, Asturian, Aranese, Basque (limited)
- **Other European**: Catalan (partial), Galician, Occitan, Breton, Welsh
- **Indigenous Languages**: Quechua, Guaraní, Mapudungun, Nahuatl
- **African Languages**: Most Sub-Saharan languages
- **Asian Languages**: Many Southeast Asian minority languages

### The Solution

TranslateCall implements a **hybrid architecture** that:

1. Uses **Apple Intelligence** for supported languages (on-device, low latency)
2. Uses **Custom Fine-tuned Models** for unsupported languages

This approach allows:
- Real-time voice translation for ANY language pair
- Privacy-first design (on-device when possible)
- Community-driven language expansion
- Both text and voice translation use cases

---

## 2. Architecture

### High-Level Design

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           TranslateCall                                 │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  Audio Input (Microphone)                                               │
│         │                                                               │
│         ▼                                                               │
│  ┌─────────────────┐                                                    │
│  │      VAD        │  Voice Activity Detection                          │
│  │  (Silero/etc)   │                                                    │
│  └────────┬────────┘                                                    │
│           │                                                             │
│           ▼                                                             │
│  ┌─────────────────┐                                                    │
│  │      STT        │  Speech-to-Text                                    │
│  │ (Apple Speech / │                                                    │
│  │  Whisper/etc)   │                                                    │
│  └────────┬────────┘                                                    │
│           │                                                             │
│           ▼                                                             │
│  ┌─────────────────┐     ┌──────────────────────────────────────────┐   │
│  │    Language     │     │         Language Registry                │   │
│  │    Detection    │────▶│                                          │   │
│  └────────┬────────┘     │  ┌────────────┐    ┌─────────────────┐   │   │
│           │              │  │   Apple    │    │     Custom      │   │   │
│           │              │  │ Languages  │    │    Languages    │   │   │
│           │              │  │            │    │                 │   │   │
│           │              │  │ • English  │    │ • Aragonese     │   │   │
│           │              │  │ • Spanish  │    │ • Asturian      │   │   │
│           │              │  │ • French   │    │ • [Your Lang]   │   │   │
│           │              │  │ • German   │    │                 │   │   │
│           │              │  │ • ...      │    │                 │   │   │
│           │              │  └────────────┘    └─────────────────┘   │   │
│           │              └──────────────────────────────────────────┘   │
│           │                                                             │
│           ▼                                                             │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │                    Translation Router                           │    │
│  │                                                                 │    │
│  │   if (sourceLanguage AND targetLanguage) in AppleLanguages:     │    │
│  │       → Use Apple Translation Framework (on-device)             │    │
│  │   else:                                                         │    │
│  │       → Use Custom Model (on-device CoreML or Cloud API)        │    │
│  │                                                                 │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│           │                                                             │
│           ▼                                                             │
│  ┌─────────────────┐                                                    │
│  │      TTS        │  Text-to-Speech                                    │
│  │ (AVSpeech/etc)  │                                                    │
│  └────────┬────────┘                                                    │
│           │                                                             │
│           ▼                                                             │
│  Audio Output (Speaker/Virtual Device)                                  │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### Translation Router Logic

```swift
// Pseudocode for Translation Router
func translate(text: String, from source: Language, to target: Language) async -> String {

    // Check if both languages are supported by Apple
    if AppleLanguages.contains(source) && AppleLanguages.contains(target) {
        // Use Apple Translation Framework (on-device, ~100ms)
        return await appleTranslate(text, from: source, to: target)
    }

    // Check if we have a custom model for this pair
    if let customModel = CustomLanguageRegistry.getModel(from: source, to: target) {

        // Prefer on-device if model is available locally
        if customModel.isAvailableOnDevice {
            // Use CoreML model (~150-300ms)
            return await customModel.translateOnDevice(text)
        } else {
            // Fall back to cloud API (~200-500ms)
            return await customModel.translateViaAPI(text)
        }
    }

    // No translation available
    throw TranslationError.unsupportedLanguagePair(source, target)
}
```

---

## 3. Supported vs Custom Languages

### Apple Intelligence Languages (as of 2026)

| Language | Code | STT | Translation | TTS |
|----------|------|-----|-------------|-----|
| Arabic | ar | ✅ | ✅ | ✅ |
| Chinese (Simplified) | zh-Hans | ✅ | ✅ | ✅ |
| Chinese (Traditional) | zh-Hant | ✅ | ✅ | ✅ |
| Dutch | nl | ✅ | ✅ | ✅ |
| English | en | ✅ | ✅ | ✅ |
| French | fr | ✅ | ✅ | ✅ |
| German | de | ✅ | ✅ | ✅ |
| Indonesian | id | ✅ | ✅ | ✅ |
| Italian | it | ✅ | ✅ | ✅ |
| Japanese | ja | ✅ | ✅ | ✅ |
| Korean | ko | ✅ | ✅ | ✅ |
| Polish | pl | ✅ | ✅ | ✅ |
| Portuguese | pt | ✅ | ✅ | ✅ |
| Russian | ru | ✅ | ✅ | ✅ |
| Spanish | es | ✅ | ✅ | ✅ |
| Thai | th | ✅ | ✅ | ✅ |
| Turkish | tr | ✅ | ✅ | ✅ |
| Ukrainian | uk | ✅ | ✅ | ✅ |
| Vietnamese | vi | ✅ | ✅ | ✅ |

### Custom Language Candidates

| Language | Region | ISO Code | Status | Notes |
|----------|--------|----------|--------|-------|
| Aragonese | Spain (Aragón) | an | 🔧 Planned | ~25K parallel corpus available |
| Asturian | Spain (Asturias) | ast | 📋 Candidate | TAN-IBE project data |
| Aranese | Spain (Catalonia) | oc-aranes | 📋 Candidate | Occitan variant |
| Basque | Spain/France | eu | 📋 Candidate | Some Apple support, may need enhancement |
| Galician | Spain (Galicia) | gl | 📋 Candidate | Close to Portuguese |
| Catalan | Spain/France | ca | 📋 Candidate | Partial Apple support |
| Welsh | UK (Wales) | cy | 📋 Candidate | Good corpus available |
| Breton | France (Brittany) | br | 📋 Candidate | Low-resource |

**Status Legend:**
- 🔧 Planned: Active development or data collection
- 📋 Candidate: Identified as potential addition
- ✅ Available: Model trained and integrated

---

## 4. Adding a New Language: Step-by-Step

### Phase 1: Data Collection

#### Required: Parallel Corpus

You need sentence-aligned translations between your target language and a pivot language (usually Spanish or English).

**Minimum Requirements:**

| Data Size | Expected Quality | Recommended For |
|-----------|------------------|-----------------|
| 5,000 pairs | Basic (proof of concept) | Testing pipeline |
| 10,000-25,000 pairs | Acceptable (MVP) | Initial deployment |
| 50,000-100,000 pairs | Good (production) | Public release |
| 100,000+ pairs | Excellent | High-quality service |

**Data Format:**

```
data/
├── train.{pivot_lang}    # e.g., train.es (Spanish)
├── train.{target_lang}   # e.g., train.an (Aragonese)
├── valid.{pivot_lang}
├── valid.{target_lang}
├── test.{pivot_lang}
└── test.{target_lang}
```

Each file contains one sentence per line, aligned by line number.

**Example:**
```
# train.es
Buenos días, ¿cómo estás?
Hace muy buen tiempo hoy.
Me gusta mucho este pueblo.

# train.an (aligned)
Buen diya, ¿cómo yes?
Fa muito buen tiempo hue.
Me cuaca muito iste lugar.
```

#### Data Quality Checklist

- [ ] Sentences are properly aligned (line N in source = line N in target)
- [ ] No duplicate sentence pairs
- [ ] Reasonable length (3-200 characters per sentence)
- [ ] Correct grammar in both languages
- [ ] Diverse domains (conversation, news, literature, technical)
- [ ] No machine-translated data (human translations only)

### Phase 2: Model Selection

#### Recommended Base Models

| Model | Parameters | License | Best For |
|-------|------------|---------|----------|
| **Opus-MT** | ~74M | Apache 2.0 | ✅ Commercial, low latency |
| NLLB-200-distilled-600M | 600M | CC-BY-NC | Research only |
| mBART-50 | 610M | MIT | Multilingual scenarios |
| madlad400 | Variable | Apache 2.0 | Commercial, many languages |

**Recommendation:** Start with **Opus-MT** for commercial flexibility and low resource requirements.

### Phase 3: Fine-tuning

See detailed instructions in [FINE_TUNING_GUIDE.md](./FINE_TUNING_GUIDE.md).

**Quick Start:**

```bash
# Clone the training repository
git clone https://github.com/TranslateCall/language-training.git
cd language-training

# Install dependencies
pip install -r requirements.txt

# Prepare your data
python scripts/prepare_data.py \
    --source data/train.es \
    --target data/train.an \
    --output prepared_data/

# Fine-tune (Google Colab or local GPU)
python scripts/finetune.py \
    --base-model Helsinki-NLP/opus-mt-es-en \
    --data prepared_data/ \
    --output models/opus-mt-es-an \
    --epochs 3
```

### Phase 4: Evaluation

```bash
# Evaluate on test set
python scripts/evaluate.py \
    --model models/opus-mt-es-an \
    --test-source data/test.es \
    --test-target data/test.an

# Output:
# BLEU: 32.5
# chrF: 0.58
# Latency (CPU): 45ms/sentence
# Latency (GPU): 12ms/sentence
```

**Quality Thresholds:**

| BLEU Score | Quality | Action |
|------------|---------|--------|
| < 15 | Poor | Need more/better data |
| 15-25 | Acceptable | MVP viable |
| 25-35 | Good | Production ready |
| > 35 | Excellent | High quality |

### Phase 5: Deployment

Choose deployment strategy based on your needs:

| Strategy | Latency | Privacy | Cost | Complexity |
|----------|---------|---------|------|------------|
| On-device (CoreML) | ~150ms | ✅ Full | Free | High |
| Cloud API (HuggingFace) | ~300ms | ⚠️ External | $0.03-1/hr | Low |
| Self-hosted API | ~200ms | ✅ Full | $20-100/mo | Medium |

### Phase 6: Integration

Register your language in TranslateCall:

```swift
// CustomLanguageRegistry.swift
extension CustomLanguageRegistry {
    static func registerAragonese() {
        register(
            Language(
                code: "an",
                name: "Aragonese",
                nativeName: "Aragonés",
                script: .latin,
                region: "ES"
            ),
            translationPairs: [
                TranslationPair(
                    source: .spanish,
                    target: .aragonese,
                    model: AragonesTranslationModel()
                ),
                TranslationPair(
                    source: .aragonese,
                    target: .spanish,
                    model: AragonesTranslationModel(reverse: true)
                )
            ]
        )
    }
}
```

---

## 5. Technical Requirements

### For Fine-tuning

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| GPU VRAM | 4GB (LoRA) | 12GB+ (full fine-tune) |
| RAM | 16GB | 32GB |
| Storage | 10GB | 50GB |
| Time | 1-2 hours | 4-8 hours |

**Supported Platforms:**
- Google Colab (free tier works for small datasets)
- RunPod ($0.40-2/hour)
- Lambda Labs ($1.29/hour)
- Local GPU (NVIDIA GTX 1080 or better)

### For On-device Deployment (CoreML)

| Resource | Requirement |
|----------|-------------|
| Model Size | < 500MB recommended |
| macOS | 14.0+ (Sonoma) |
| iOS | 17.0+ |
| RAM | ~200MB during inference |
| Latency | ~100-300ms per translation |

### For Cloud API Deployment

| Resource | Requirement |
|----------|-------------|
| Endpoint | HuggingFace Inference, Cloud Run, etc. |
| Latency | ~200-500ms (including network) |
| Availability | 99.9% recommended |
| Cost | $0.03-2/hour depending on hardware |

---

## 6. Deployment Options

### Option A: On-device with CoreML (Recommended for Privacy)

Convert your PyTorch model to CoreML:

```python
# convert_to_coreml.py
import coremltools as ct
from transformers import MarianMTModel, MarianTokenizer

# Load fine-tuned model
model = MarianMTModel.from_pretrained("./models/opus-mt-es-an")
tokenizer = MarianTokenizer.from_pretrained("./models/opus-mt-es-an")

# Trace and convert
# (Simplified - actual conversion requires more steps)
traced_model = torch.jit.trace(model, example_input)
mlmodel = ct.convert(
    traced_model,
    inputs=[ct.TensorType(shape=(1, 128), dtype=np.int32, name="input_ids")],
    minimum_deployment_target=ct.target.macOS14
)
mlmodel.save("AragonesTranslation.mlpackage")
```

**Advantages:**
- Full privacy (no data leaves device)
- No network latency
- Works offline
- Free (no API costs)

**Disadvantages:**
- Larger app size (~300MB per language pair)
- More complex integration
- Device resource usage

### Option B: HuggingFace Inference Endpoints

```python
# Deploy to HuggingFace
from huggingface_hub import HfApi

api = HfApi()
api.upload_folder(
    folder_path="./models/opus-mt-es-an",
    repo_id="TranslateCall/opus-mt-es-an",
    repo_type="model"
)

# Create endpoint via HuggingFace UI or API
# Endpoint URL: https://api-inference.huggingface.co/models/TranslateCall/opus-mt-es-an
```

**Client Integration:**

```swift
// HuggingFaceTranslationClient.swift
class HuggingFaceTranslationClient {
    let endpoint = "https://api-inference.huggingface.co/models/TranslateCall/opus-mt-es-an"
    let apiKey: String

    func translate(_ text: String) async throws -> String {
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["inputs": text])

        let (data, _) = try await URLSession.shared.data(for: request)
        let result = try JSONDecoder().decode([[String: String]].self, from: data)
        return result.first?["translation_text"] ?? ""
    }
}
```

### Option C: Self-hosted API (Docker + FastAPI)

See [FINE_TUNING_GUIDE.md](./FINE_TUNING_GUIDE.md) for complete FastAPI example.

```bash
# Deploy with Docker
docker build -t translatecall-aragonese .
docker run -p 8000:8000 translatecall-aragonese

# Or deploy to Google Cloud Run
gcloud run deploy aragonese-translator \
    --image gcr.io/PROJECT/translatecall-aragonese \
    --platform managed \
    --memory 2Gi
```

---

## 7. Voice Pipeline Integration

### The Complete Flow for Voice Translation

```
┌─────────────────────────────────────────────────────────────────┐
│                    Voice Translation Pipeline                   │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. AUDIO INPUT                                                 │
│     └─▶ Microphone captures speech                              │
│                                                                 │
│  2. VAD (Voice Activity Detection)              [~10ms]         │
│     └─▶ Detects when speaker starts/stops                       │
│                                                                 │
│  3. STT (Speech-to-Text)                        [~500-1000ms]   │
│     └─▶ Apple Speech Recognition                                │
│     └─▶ Or Whisper for unsupported languages                    │
│                                                                 │
│  4. TRANSLATION                                 [~100-300ms]    │
│     ├─▶ Apple Translation (supported languages)                 │
│     └─▶ Custom Model (unsupported languages)    ◀── THIS DOC    │
│                                                                 │
│  5. TTS (Text-to-Speech)                        [~200-500ms]    │
│     └─▶ AVSpeechSynthesizer                                     │
│     └─▶ Or custom voice model                                   │
│                                                                 │
│  6. AUDIO OUTPUT                                                │
│     └─▶ Virtual audio device / Speaker                          │
│                                                                 │
│  TOTAL LATENCY: ~1.5-3 seconds (acceptable for conversation)    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Latency Budget for Real-time Voice

| Component | Target | Acceptable | Notes |
|-----------|--------|------------|-------|
| VAD | 10ms | 50ms | Very fast |
| STT | 500ms | 1000ms | Streaming helps |
| **Translation** | **100ms** | **300ms** | **Custom models here** |
| TTS | 200ms | 500ms | Can start before complete |
| **Total** | **~1.5s** | **~2.5s** | Professional interpreter ~2-3s |

### Custom Language STT Consideration

For languages not supported by Apple Speech Recognition:

1. **Whisper** (OpenAI) - Supports 100+ languages, including many minority languages
2. **Custom fine-tuned Whisper** - For very low-resource languages
3. **Hybrid approach** - Apple Speech for pivot language, custom for target

```swift
// Determining which STT to use
func selectSTTEngine(for language: Language) -> STTEngine {
    if AppleSpeechLanguages.contains(language) {
        return .appleSpeech
    } else if WhisperLanguages.contains(language) {
        return .whisper
    } else {
        return .customWhisper(modelPath: language.customSTTModel)
    }
}
```

---

## 8. Latency Considerations

### Translation Latency by Deployment

| Deployment | Model Load | First Request | Subsequent | P99 |
|------------|------------|---------------|------------|-----|
| CoreML (on-device) | 500ms | 200ms | 100-150ms | 200ms |
| HuggingFace Endpoints | N/A | 300-500ms | 200-300ms | 500ms |
| Self-hosted (GPU) | N/A | 150-250ms | 100-150ms | 300ms |
| Self-hosted (CPU) | N/A | 400-800ms | 300-500ms | 1000ms |

### Optimization Strategies

1. **Model Quantization** - Reduce model size and increase speed
   ```python
   # INT8 quantization
   from transformers import AutoModelForSeq2SeqLM
   model = AutoModelForSeq2SeqLM.from_pretrained("./model", load_in_8bit=True)
   ```

2. **Batching** - Process multiple sentences together (for text, not real-time voice)

3. **Caching** - Cache frequent translations
   ```swift
   // Simple translation cache
   class TranslationCache {
       private var cache: [String: String] = [:]

       func translate(_ text: String) -> String? {
           return cache[text.lowercased()]
       }
   }
   ```

4. **Warm-up** - Pre-load models on app start
   ```swift
   func applicationDidFinishLaunching() {
       Task {
           await CustomLanguageRegistry.warmUpModels()
       }
   }
   ```

---

## 9. Cost Estimation

### Fine-tuning Costs (One-time)

| Dataset Size | Platform | GPU | Time | Cost |
|--------------|----------|-----|------|------|
| 10K pairs | Colab Free | T4 | 1.5h | **$0** |
| 25K pairs | Colab Pro | T4 | 2.5h | **$10/mo** |
| 25K pairs | RunPod | A100 | 1h | **~$2** |
| 50K pairs | RunPod | A100 | 2h | **~$4** |
| 100K pairs | Lambda | A100 | 3-4h | **~$5-6** |

### Deployment Costs (Monthly)

| Strategy | Low Usage (<1K/day) | Medium (1K-10K/day) | High (>10K/day) |
|----------|---------------------|---------------------|-----------------|
| On-device | **$0** | **$0** | **$0** |
| HuggingFace CPU | $5-20 | $30-100 | $200+ |
| HuggingFace GPU | $50-200 | $200-500 | $500+ |
| Cloud Run | $5-30 | $30-150 | $150+ |

**Recommendation:** Start with on-device (CoreML) for privacy and zero ongoing cost. Fall back to cloud only if needed.

---

## 10. Example: Adding Aragonese (ES ↔ AN)

### Context

- **Language:** Aragonese (Aragonés)
- **Region:** Aragón, Spain
- **Speakers:** ~10,000-25,000 active speakers
- **Status:** UNESCO "Definitely Endangered"
- **Pivot Language:** Spanish (98%+ mutual intelligibility in written form)

### Available Resources

| Resource | URL | Notes |
|----------|-----|-------|
| TAN-IBE Project | [UOC](https://www.uoc.edu) | Academic MT research |
| Common Voice | [Mozilla](https://commonvoice.mozilla.org) | Audio data for STT |
| Aragonese Wikipedia | [Wikipedia](https://an.wikipedia.org) | Text corpus |
| Softaragones | [softaragones.org](http://softaragones.org) | Linguistic resources |

### Implementation Plan

```
Phase 1: Data (Week 1-2)
├── Collect/clean parallel corpus (~25K pairs)
├── Validate alignment and quality
└── Split into train/valid/test

Phase 2: Training (Week 3)
├── Fine-tune Opus-MT es→an
├── Fine-tune Opus-MT an→es (reverse)
├── Evaluate BLEU scores
└── Iterate if quality < threshold

Phase 3: Deployment (Week 4)
├── Convert to CoreML for on-device
├── Deploy cloud API as fallback
├── Integration testing
└── Performance benchmarking

Phase 4: Integration (Week 5)
├── Register in CustomLanguageRegistry
├── Update UI for language selection
├── End-to-end testing
└── Documentation
```

### Expected Results

| Metric | Target | Notes |
|--------|--------|-------|
| BLEU (es→an) | 25-35 | Good for minority language |
| BLEU (an→es) | 30-40 | Easier direction |
| Latency (CoreML) | <200ms | On M1+ Mac |
| Latency (API) | <400ms | Including network |
| Model size | ~300MB | Per direction |

---

## 11. Contributing a New Language

### Contribution Checklist

Before submitting a new language:

- [ ] **Data License** - Confirm corpus can be used (CC-BY, public domain, or permission)
- [ ] **Data Quality** - Human translations, not machine-translated
- [ ] **Minimum Size** - At least 10,000 parallel sentence pairs
- [ ] **Evaluation** - BLEU score > 20 on held-out test set
- [ ] **Documentation** - Language info, data sources, known limitations
- [ ] **Testing** - Manual quality check of 100+ translations

### Submission Process

1. **Open Issue** - Describe the language and available resources
2. **Data Review** - Team reviews data quality and licensing
3. **Training** - Fine-tune model (contributor or team)
4. **Evaluation** - Automated and manual quality checks
5. **Integration** - Add to CustomLanguageRegistry
6. **Release** - Include in next TranslateCall version

### Community Resources

| Resource | Purpose |
|----------|---------|
| [GitHub Discussions](https://github.com/TranslateCall/discussions) | Propose new languages |
| [Discord](https://discord.gg/translatecall) | Real-time coordination |
| [Wiki](https://github.com/TranslateCall/wiki) | Documentation |

---

## References

### Research Papers

- [No Language Left Behind (NLLB)](https://arxiv.org/abs/2207.04672) - Meta AI, 2022
- [OPUS-MT](https://aclanthology.org/2020.eamt-1.61/) - Helsinki-NLP, 2020
- [TAN-IBE: Neural MT for Iberian Languages](https://www.uoc.edu) - UOC, 2023
- [A Few Thousand Translations Go a Long Way](https://arxiv.org/abs/2111.02541) - Masakhane, 2021

### Tools & Platforms

- [HuggingFace Transformers](https://huggingface.co/docs/transformers)
- [OPUS Parallel Corpora](https://opus.nlpl.eu/)
- [Google Colab](https://colab.research.google.com)
- [RunPod](https://runpod.io)
- [CoreML Tools](https://coremltools.readme.io/)

### Related Projects

- [Argos Translate](https://github.com/argosopentech/argos-translate) - Offline translation
- [LibreTranslate](https://libretranslate.com/) - Self-hosted translation API
- [OpenVoiceOS](https://openvoiceos.org/) - Voice assistant with TTS for minority languages

---

*Document Version: 1.0*
*Last Updated: January 2026*
*TranslateCall Project*
