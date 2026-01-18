# Fine-Tuning de Modelos de Traducción para Idiomas Minoritarios

## Guía Completa: Español ↔ Aragonés

Esta guía documenta el proceso completo para crear un modelo de traducción fine-tuneado para el par de idiomas **Español ↔ Aragonés**, incluyendo requisitos, costes estimados, proceso paso a paso y opciones de deployment.

---

## 1. Resumen Ejecutivo

| Aspecto | Detalle |
|---------|---------|
| **Modelo recomendado** | NLLB-200-distilled-600M o Opus-MT |
| **Datos mínimos** | ~10,000 pares de oraciones paralelas |
| **Datos recomendados** | 50,000 - 120,000 pares |
| **GPU recomendada** | NVIDIA T4 (mínimo) / A100 (óptimo) |
| **Tiempo estimado** | 2-8 horas (según datos y hardware) |
| **Coste estimado** | $5 - $50 USD (entrenamiento) |
| **Coste deployment** | $0.03 - $1.80/hora |

---

## 2. Requisitos de Datos

### 2.1 Formato del Corpus Paralelo

El corpus debe contener pares de oraciones alineadas. Formatos soportados:

#### Opción A: Archivos separados (recomendado)
```
data/
├── train.es    # Oraciones en español (una por línea)
├── train.an    # Oraciones en aragonés (una por línea)
├── valid.es    # Validación español
├── valid.an    # Validación aragonés
├── test.es     # Test español
└── test.an     # Test aragonés
```

#### Opción B: Archivo TSV/CSV
```csv
source,target
"Hola, ¿cómo estás?","Ola, ¿cómo yes?"
"Buenos días","Buen día"
"Muchas gracias","Muitas grazias"
```

#### Opción C: Formato JSON Lines
```json
{"source": "Hola, ¿cómo estás?", "target": "Ola, ¿cómo yes?"}
{"source": "Buenos días", "target": "Buen día"}
```

### 2.2 Cantidad de Datos

| Cantidad | Calidad esperada | Uso recomendado |
|----------|------------------|-----------------|
| 1,000-5,000 pares | Básica (prueba de concepto) | Validar el proceso |
| 10,000-20,000 pares | Aceptable | MVP funcional |
| 50,000-100,000 pares | Buena | Producción |
| 100,000+ pares | Excelente | Producción de alta calidad |

### 2.3 Calidad de los Datos

**Requisitos:**
- Alineación correcta (cada línea source corresponde a su target)
- Sin duplicados excesivos
- Longitud similar entre source y target
- Gramática correcta en ambos idiomas
- Variedad de dominios (conversacional, formal, técnico)

**Script de limpieza básica:**
```python
import pandas as pd

def clean_parallel_corpus(source_file, target_file, max_length=200, min_length=3):
    """Limpia y filtra corpus paralelo."""
    with open(source_file, 'r', encoding='utf-8') as f:
        sources = f.readlines()
    with open(target_file, 'r', encoding='utf-8') as f:
        targets = f.readlines()

    cleaned_pairs = []
    for src, tgt in zip(sources, targets):
        src, tgt = src.strip(), tgt.strip()

        # Filtrar por longitud
        if len(src) < min_length or len(tgt) < min_length:
            continue
        if len(src) > max_length or len(tgt) > max_length:
            continue

        # Filtrar ratio de longitud extremo
        ratio = len(src) / len(tgt) if len(tgt) > 0 else 0
        if ratio < 0.5 or ratio > 2.0:
            continue

        cleaned_pairs.append((src, tgt))

    return cleaned_pairs
```

### 2.4 División de Datos

| Split | Porcentaje | Uso |
|-------|-----------|-----|
| Train | 90% | Entrenamiento |
| Validation | 5% | Monitoreo durante training |
| Test | 5% | Evaluación final |

---

## 3. Selección del Modelo Base

### 3.1 Comparativa de Modelos

| Modelo | Tamaño | Licencia | VRAM mínima | Calidad | Recomendación |
|--------|--------|----------|-------------|---------|---------------|
| **NLLB-200-distilled-600M** | 600M | CC-BY-NC 4.0 | 4GB | Alta | ⭐ Mejor calidad (no comercial) |
| **NLLB-200-1.3B** | 1.3B | CC-BY-NC 4.0 | 8GB | Muy alta | Calidad premium |
| **Opus-MT (Helsinki-NLP)** | ~300M | MIT | 2GB | Buena | ⭐ Mejor para comercial |
| **mBART-large-50** | 610M | MIT* | 6GB | Buena | Alternativa |
| **madlad400** | Variable | Apache 2.0 | Variable | Variable | Comercial viable |

### 3.2 Recomendación

**Para investigación/proyecto personal:** NLLB-200-distilled-600M
- Mejor rendimiento en idiomas de bajos recursos
- Pre-entrenado con técnicas específicas para low-resource
- Transfer learning efectivo desde idiomas relacionados (español, catalán)

**Para uso comercial:** Opus-MT o madlad400
- Licencia permisiva (MIT / Apache 2.0)
- Comunidad activa y documentación extensa

---

## 4. Proceso de Fine-Tuning Paso a Paso

### 4.1 Configuración del Entorno

```bash
# Crear entorno virtual
python -m venv nllb_finetuning
source nllb_finetuning/bin/activate  # Linux/Mac
# o: nllb_finetuning\Scripts\activate  # Windows

# Instalar dependencias
pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118
pip install transformers datasets accelerate sentencepiece sacremoses
pip install evaluate sacrebleu wandb  # Métricas y logging
```

### 4.2 Preparación de Datos

```python
# prepare_data.py
from datasets import Dataset, DatasetDict
import pandas as pd

def load_parallel_data(source_file, target_file):
    """Carga corpus paralelo desde archivos."""
    with open(source_file, 'r', encoding='utf-8') as f:
        sources = [line.strip() for line in f.readlines()]
    with open(target_file, 'r', encoding='utf-8') as f:
        targets = [line.strip() for line in f.readlines()]

    return Dataset.from_dict({
        'source': sources,
        'target': targets
    })

def prepare_dataset(data_dir, train_split=0.9, val_split=0.05):
    """Prepara DatasetDict para entrenamiento."""

    # Cargar datos
    full_data = load_parallel_data(
        f"{data_dir}/corpus.es",
        f"{data_dir}/corpus.an"
    )

    # Dividir
    train_test = full_data.train_test_split(test_size=1-train_split, seed=42)
    test_val = train_test['test'].train_test_split(test_size=0.5, seed=42)

    return DatasetDict({
        'train': train_test['train'],
        'validation': test_val['train'],
        'test': test_val['test']
    })

if __name__ == "__main__":
    dataset = prepare_dataset("./data")
    dataset.save_to_disk("./prepared_dataset")
    print(f"Train: {len(dataset['train'])} ejemplos")
    print(f"Validation: {len(dataset['validation'])} ejemplos")
    print(f"Test: {len(dataset['test'])} ejemplos")
```

### 4.3 Script de Fine-Tuning (NLLB-200)

```python
# finetune_nllb.py
import torch
from transformers import (
    AutoModelForSeq2SeqLM,
    AutoTokenizer,
    Seq2SeqTrainingArguments,
    Seq2SeqTrainer,
    DataCollatorForSeq2Seq
)
from datasets import load_from_disk
import evaluate

# Configuración
MODEL_NAME = "facebook/nllb-200-distilled-600M"
OUTPUT_DIR = "./nllb-aragonese-finetuned"
MAX_LENGTH = 128

# Códigos de idioma NLLB (Aragonés no existe, usamos español como base)
# Para un idioma nuevo, podemos usar un código placeholder o spa_Latn
SRC_LANG = "spa_Latn"  # Español
TGT_LANG = "spa_Latn"  # Usaremos un token especial para Aragonés

def main():
    # Cargar modelo y tokenizer
    print("Cargando modelo...")
    tokenizer = AutoTokenizer.from_pretrained(MODEL_NAME)
    model = AutoModelForSeq2SeqLM.from_pretrained(MODEL_NAME)

    # Opcionalmente, añadir token especial para Aragonés
    # special_tokens = {"additional_special_tokens": ["arg_Latn"]}
    # tokenizer.add_special_tokens(special_tokens)
    # model.resize_token_embeddings(len(tokenizer))

    # Cargar datos
    print("Cargando datos...")
    dataset = load_from_disk("./prepared_dataset")

    # Función de preprocesamiento
    def preprocess_function(examples):
        inputs = examples['source']
        targets = examples['target']

        # Tokenizar
        model_inputs = tokenizer(
            inputs,
            max_length=MAX_LENGTH,
            truncation=True,
            padding="max_length"
        )

        labels = tokenizer(
            targets,
            max_length=MAX_LENGTH,
            truncation=True,
            padding="max_length"
        )

        model_inputs["labels"] = labels["input_ids"]
        return model_inputs

    # Preprocesar dataset
    print("Preprocesando datos...")
    tokenized_dataset = dataset.map(
        preprocess_function,
        batched=True,
        remove_columns=dataset['train'].column_names
    )

    # Métricas
    metric = evaluate.load("sacrebleu")

    def compute_metrics(eval_preds):
        preds, labels = eval_preds

        # Decodificar predicciones
        decoded_preds = tokenizer.batch_decode(preds, skip_special_tokens=True)

        # Reemplazar -100 en labels
        labels = [[l if l != -100 else tokenizer.pad_token_id for l in label] for label in labels]
        decoded_labels = tokenizer.batch_decode(labels, skip_special_tokens=True)

        # Calcular BLEU
        result = metric.compute(
            predictions=decoded_preds,
            references=[[label] for label in decoded_labels]
        )
        return {"bleu": result["score"]}

    # Argumentos de entrenamiento
    training_args = Seq2SeqTrainingArguments(
        output_dir=OUTPUT_DIR,
        evaluation_strategy="steps",
        eval_steps=500,
        save_strategy="steps",
        save_steps=500,
        learning_rate=2e-5,
        per_device_train_batch_size=8,  # Ajustar según GPU
        per_device_eval_batch_size=8,
        weight_decay=0.01,
        save_total_limit=3,
        num_train_epochs=3,
        predict_with_generate=True,
        fp16=True,  # Mixed precision para GPUs compatibles
        logging_dir="./logs",
        logging_steps=100,
        warmup_steps=500,
        gradient_accumulation_steps=2,  # Efectivo batch size = 16
        report_to="wandb",  # Opcional: logging a Weights & Biases
    )

    # Data collator
    data_collator = DataCollatorForSeq2Seq(
        tokenizer=tokenizer,
        model=model,
        padding=True
    )

    # Trainer
    trainer = Seq2SeqTrainer(
        model=model,
        args=training_args,
        train_dataset=tokenized_dataset['train'],
        eval_dataset=tokenized_dataset['validation'],
        tokenizer=tokenizer,
        data_collator=data_collator,
        compute_metrics=compute_metrics,
    )

    # Entrenar
    print("Iniciando entrenamiento...")
    trainer.train()

    # Guardar modelo final
    print("Guardando modelo...")
    trainer.save_model(f"{OUTPUT_DIR}/final")
    tokenizer.save_pretrained(f"{OUTPUT_DIR}/final")

    print("¡Entrenamiento completado!")

if __name__ == "__main__":
    main()
```

### 4.4 Fine-Tuning con LoRA (Más Eficiente)

```python
# finetune_nllb_lora.py
# Requiere: pip install peft

from peft import LoraConfig, get_peft_model, TaskType
from transformers import AutoModelForSeq2SeqLM, AutoTokenizer

MODEL_NAME = "facebook/nllb-200-distilled-600M"

# Cargar modelo base
model = AutoModelForSeq2SeqLM.from_pretrained(MODEL_NAME)

# Configurar LoRA
lora_config = LoraConfig(
    task_type=TaskType.SEQ_2_SEQ_LM,
    r=16,                    # Rank de las matrices LoRA
    lora_alpha=32,           # Scaling factor
    lora_dropout=0.1,
    target_modules=["q_proj", "v_proj"],  # Capas a adaptar
)

# Aplicar LoRA
model = get_peft_model(model, lora_config)
model.print_trainable_parameters()
# Output: trainable params: 3,538,944 || all params: 615,321,088 || trainable%: 0.575%

# El resto del entrenamiento es igual que antes
# Pero ahora solo se entrenan ~0.6% de los parámetros
# Esto reduce VRAM y tiempo de entrenamiento significativamente
```

### 4.5 Script de Inferencia

```python
# translate.py
from transformers import AutoModelForSeq2SeqLM, AutoTokenizer
import torch

class AragonesTranslator:
    def __init__(self, model_path="./nllb-aragonese-finetuned/final"):
        self.device = "cuda" if torch.cuda.is_available() else "cpu"
        self.tokenizer = AutoTokenizer.from_pretrained(model_path)
        self.model = AutoModelForSeq2SeqLM.from_pretrained(model_path).to(self.device)
        self.model.eval()

    def translate(self, text, max_length=128):
        """Traduce texto de español a aragonés."""
        inputs = self.tokenizer(
            text,
            return_tensors="pt",
            max_length=max_length,
            truncation=True
        ).to(self.device)

        with torch.no_grad():
            outputs = self.model.generate(
                **inputs,
                max_length=max_length,
                num_beams=5,
                early_stopping=True
            )

        return self.tokenizer.decode(outputs[0], skip_special_tokens=True)

    def translate_batch(self, texts, batch_size=8):
        """Traduce múltiples textos eficientemente."""
        results = []
        for i in range(0, len(texts), batch_size):
            batch = texts[i:i+batch_size]
            inputs = self.tokenizer(
                batch,
                return_tensors="pt",
                max_length=128,
                truncation=True,
                padding=True
            ).to(self.device)

            with torch.no_grad():
                outputs = self.model.generate(**inputs, max_length=128, num_beams=5)

            results.extend(self.tokenizer.batch_decode(outputs, skip_special_tokens=True))

        return results

# Uso
if __name__ == "__main__":
    translator = AragonesTranslator()

    # Prueba individual
    spanish_text = "Buenos días, ¿cómo estás?"
    aragonese = translator.translate(spanish_text)
    print(f"ES: {spanish_text}")
    print(f"AN: {aragonese}")

    # Prueba batch
    texts = [
        "Hace muy buen tiempo hoy",
        "¿Dónde está la biblioteca?",
        "Me gusta mucho este pueblo"
    ]
    translations = translator.translate_batch(texts)
    for es, an in zip(texts, translations):
        print(f"ES: {es} -> AN: {an}")
```

---

## 5. Hardware y Tiempos Estimados

### 5.1 Requisitos de VRAM por Modelo

| Modelo | Fine-tuning completo | Fine-tuning LoRA |
|--------|---------------------|------------------|
| NLLB-200-distilled-600M | 12GB | 4GB |
| NLLB-200-1.3B | 24GB | 8GB |
| NLLB-200-3.3B | 48GB+ | 16GB |
| Opus-MT (~300M) | 8GB | 3GB |

### 5.2 Tiempos de Entrenamiento Estimados

| Dataset | GPU | Modelo | Tiempo estimado |
|---------|-----|--------|-----------------|
| 10K pares | T4 (16GB) | NLLB-600M | 1-2 horas |
| 50K pares | T4 (16GB) | NLLB-600M | 4-6 horas |
| 100K pares | T4 (16GB) | NLLB-600M | 8-12 horas |
| 10K pares | A100 (40GB) | NLLB-600M | 30-45 min |
| 50K pares | A100 (40GB) | NLLB-600M | 1.5-2 horas |
| 100K pares | A100 (40GB) | NLLB-600M | 3-4 horas |

**Con LoRA:** Reduce tiempos aproximadamente 40-60%

---

## 6. Costes Detallados

### 6.1 Coste de Entrenamiento

#### Opción A: Google Colab (Gratis/Pro)
| Tier | GPU | Límite | Coste |
|------|-----|--------|-------|
| Gratis | T4 | ~12h/semana | $0 |
| Pro | T4/V100 | ~24h continuas | $10/mes |
| Pro+ | A100 | Prioridad alta | $50/mes |

**Recomendación:** Para datasets pequeños (<50K), Colab Pro es suficiente.

#### Opción B: RunPod
| GPU | Coste/hora | 10K pares | 50K pares | 100K pares |
|-----|------------|-----------|-----------|------------|
| T4 | $0.40 | ~$0.80 | ~$2.40 | ~$4.80 |
| A100 40GB | $1.29 | ~$0.65 | ~$2.00 | ~$4.00 |
| A100 80GB | $2.17 | ~$1.00 | ~$3.25 | ~$6.50 |

#### Opción C: Lambda Labs
| GPU | Coste/hora | Disponibilidad |
|-----|------------|----------------|
| A100 40GB | $1.29 | Bajo demanda |
| A100 80GB | $1.99 | Bajo demanda |
| H100 | $2.49-$3.29 | Bajo demanda |

#### Opción D: Google Vertex AI
| GPU | Coste/hora | Incluye |
|-----|------------|---------|
| T4 | ~$0.35 + VM | Gestión automática |
| A100 | ~$2.93 + VM | Escalado, MLOps |

**Estimación realista completa (50K pares, A100):**
- Entrenamiento: ~$3-5
- Experimentación y ajustes: ~$10-20
- **Total estimado: $15-30**

### 6.2 Coste de Deployment (Servicio de Traducción)

#### HuggingFace Inference Endpoints
| Hardware | Coste/hora | Coste/mes (24/7) |
|----------|------------|------------------|
| CPU (2 vCPU) | $0.03 | ~$22 |
| T4 GPU | $0.60 | ~$438 |
| A10G GPU | $1.00 | ~$730 |

#### Estrategia de Bajo Coste
- **Autoscaling:** Mínimo 0 réplicas cuando no hay tráfico
- **CPU para bajo volumen:** $0.03/hora es viable para <100 requests/día
- **Scale to zero:** Solo pagar cuando hay uso activo

#### RunPod Serverless
| Modelo | Cold start | Coste/segundo |
|--------|------------|---------------|
| NLLB-600M | ~10-15s | ~$0.0002 |

**Estimación mensual por volumen:**
| Traducciones/día | Estrategia | Coste/mes |
|------------------|------------|-----------|
| 100 | CPU endpoint | ~$5-10 |
| 1,000 | GPU con autoscaling | ~$20-50 |
| 10,000 | GPU dedicada | ~$200-400 |

---

## 7. Deployment como Servicio

### 7.1 Opción A: HuggingFace Inference Endpoints

```bash
# Subir modelo a HuggingFace Hub
pip install huggingface_hub
huggingface-cli login

# En Python:
from huggingface_hub import HfApi
api = HfApi()
api.upload_folder(
    folder_path="./nllb-aragonese-finetuned/final",
    repo_id="tu-usuario/nllb-aragonese",
    repo_type="model"
)
```

Luego crear endpoint desde la interfaz web de HuggingFace.

### 7.2 Opción B: FastAPI + Docker

```python
# api.py
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from translate import AragonesTranslator
import uvicorn

app = FastAPI(title="Aragonés Translation API")
translator = AragonesTranslator()

class TranslationRequest(BaseModel):
    text: str
    direction: str = "es_to_an"  # o "an_to_es"

class TranslationResponse(BaseModel):
    original: str
    translated: str
    direction: str

@app.post("/translate", response_model=TranslationResponse)
async def translate(request: TranslationRequest):
    try:
        translated = translator.translate(request.text)
        return TranslationResponse(
            original=request.text,
            translated=translated,
            direction=request.direction
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/translate/batch")
async def translate_batch(texts: list[str]):
    translations = translator.translate_batch(texts)
    return {"translations": translations}

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000)
```

```dockerfile
# Dockerfile
FROM python:3.10-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# Descargar modelo al construir imagen
RUN python -c "from translate import AragonesTranslator; AragonesTranslator()"

EXPOSE 8000
CMD ["uvicorn", "api:app", "--host", "0.0.0.0", "--port", "8000"]
```

### 7.3 Opción C: Google Cloud Run

```bash
# Construir y subir imagen
gcloud builds submit --tag gcr.io/PROJECT_ID/aragonese-translator

# Desplegar
gcloud run deploy aragonese-translator \
  --image gcr.io/PROJECT_ID/aragonese-translator \
  --platform managed \
  --memory 4Gi \
  --cpu 2 \
  --min-instances 0 \
  --max-instances 3
```

---

## 8. Métricas de Evaluación

### 8.1 Métricas Automáticas

```python
# evaluate_model.py
import evaluate
from datasets import load_from_disk

def evaluate_model(model_path, test_data_path):
    from translate import AragonesTranslator

    translator = AragonesTranslator(model_path)
    test_data = load_from_disk(test_data_path)['test']

    # Generar traducciones
    predictions = translator.translate_batch(test_data['source'])
    references = [[ref] for ref in test_data['target']]

    # Calcular métricas
    bleu = evaluate.load("sacrebleu")
    chrf = evaluate.load("chrf")

    bleu_score = bleu.compute(predictions=predictions, references=references)
    chrf_score = chrf.compute(predictions=predictions, references=references)

    print(f"BLEU: {bleu_score['score']:.2f}")
    print(f"chrF: {chrf_score['score']:.2f}")

    return {
        "bleu": bleu_score['score'],
        "chrf": chrf_score['score']
    }
```

### 8.2 Interpretación de Resultados

| BLEU Score | Calidad | Interpretación |
|------------|---------|----------------|
| < 10 | Muy baja | El modelo no está aprendiendo |
| 10-20 | Baja | Captura estructura básica |
| 20-30 | Aceptable | MVP funcional |
| 30-40 | Buena | Producción viable |
| > 40 | Muy buena | Alta calidad |

**Nota:** Para idiomas de bajos recursos, BLEU 20-30 ya es un resultado excelente.

---

## 9. Checklist de Implementación

### Fase 1: Preparación (1-2 días)
- [ ] Recopilar corpus paralelo ES-AN
- [ ] Limpiar y validar datos
- [ ] Dividir en train/val/test
- [ ] Configurar entorno de desarrollo

### Fase 2: Entrenamiento (1-2 días)
- [ ] Ejecutar entrenamiento inicial (dataset pequeño)
- [ ] Evaluar métricas base
- [ ] Ajustar hiperparámetros
- [ ] Entrenar modelo final

### Fase 3: Deployment (1 día)
- [ ] Subir modelo a HuggingFace Hub
- [ ] Crear API de traducción
- [ ] Configurar autoscaling
- [ ] Documentar endpoints

### Fase 4: Iteración
- [ ] Recopilar feedback de usuarios
- [ ] Ampliar corpus con nuevos datos
- [ ] Re-entrenar periódicamente

---

## 10. Recursos y Referencias

### Repositorios de Código
- [ymoslem/Adaptive-MT-LLM-Fine-tuning](https://github.com/ymoslem/Adaptive-MT-LLM-Fine-tuning)
- [gordicaleksa/Open-NLLB](https://github.com/gordicaleksa/Open-NLLB)
- [Helsinki-NLP/Opus-MT](https://github.com/Helsinki-NLP/Opus-MT)

### Tutoriales
- [Fine-tune NLLB-200 for new language](https://cointegrated.medium.com/how-to-fine-tune-a-nllb-200-model-for-translating-a-new-language-a37fc706b865)
- [HuggingFace Translation Tutorial](https://huggingface.co/learn/nlp-course/chapter7/4)
- [Expanding NLLB-200 to Kangri](https://medium.com/@karunsharma1920/expanding-nllb-200-to-kangri-a-step-by-step-guide-to-fine-tuning-metas-multilingual-model-for-an-885496835afc)

### Corpus y Datos
- [OPUS Parallel Corpora](https://opus.nlpl.eu/)
- [TAN-IBE Project (Aragonés)](https://www.uoc.edu/en/news/2023/167-neural-translation-languages)

### Plataformas Cloud
- [RunPod Pricing](https://www.runpod.io/pricing)
- [Lambda Labs](https://lambda.ai/pricing)
- [HuggingFace Inference Endpoints](https://huggingface.co/docs/inference-endpoints/en/pricing)
- [Google Vertex AI](https://cloud.google.com/vertex-ai/pricing)

---

## 11. FAQ

**¿Puedo usar el modelo NLLB fine-tuneado comercialmente?**
No directamente. NLLB tiene licencia CC-BY-NC 4.0. Para uso comercial, considera Opus-MT (MIT) o madlad400 (Apache 2.0).

**¿Cuántos datos necesito realmente?**
Con 10K pares puedes tener un MVP funcional. Para producción, apunta a 50K+. El paper "A Few Thousand Translations Go a Long Way" mostró mejoras significativas con solo 2K-5K pares.

**¿Puedo entrenar bidireccional (ES↔AN) con el mismo modelo?**
Sí, pero es mejor entrenar dos modelos especializados (ES→AN y AN→ES) para mejor calidad.

**¿Qué pasa si no tengo GPU?**
Puedes usar Google Colab (gratis con T4) o servicios como RunPod por ~$0.40/hora.

---

*Documento creado para el proyecto TranslateCall - Enero 2026*
