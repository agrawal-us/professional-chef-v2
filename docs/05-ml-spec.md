# Professional Chef Agent — AI/ML Specification

**Version:** 1.0
**Date:** June 8, 2026
**Author:** ML/AI Engineer
**Status:** Draft — Pending Stakeholder Review

---

## 1. Overview

Two AI providers serve distinct roles in the system. Each is selected for the specific characteristics of its task:

| Provider | Model | Task | Why |
|---|---|---|---|
| OpenAI | GPT-4o Vision | Ingredient detection from photos | Best-in-class real-world image understanding, handles poor lighting, overlapping items, branded packaging |
| Ollama (self-hosted) | Llama 3.1 8B (q4_0) | Recipe generation | High-quality structured text generation, runs locally on M3 Air with Metal acceleration, zero marginal cost per recipe |

All prompts are versioned and stored in the PostgreSQL `prompt_versions` table. Every AI call logs which prompt version produced its output — enabling full traceability and A/B comparison across prompt iterations.

---

## 2. Ingredient Detection — OpenAI GPT-4o Vision

### 2.1 Task Definition

Given 1–3 photos of fridge or pantry contents, identify all visible food ingredients, assign a confidence score to each, categorize them, and flag interchangeable items. Return structured JSON only — no prose.

### 2.2 System Prompt (v1.0)

```
You are a professional sous chef and food inventory specialist. Your task is to analyze 
photos of refrigerator or pantry contents and identify every visible food ingredient.

Rules you must follow:
1. Return ONLY valid JSON — no prose, no markdown, no explanation.
2. Identify every distinct food item you can see, however partially.
3. Assign confidence based on visual clarity: "high" (clearly visible, identifiable), 
   "medium" (partially visible or could be one of a few things), "low" (barely visible 
   or uncertain).
4. Never guess brand names — use generic ingredient names only (e.g., "soy sauce" 
   not "Kikkoman").
5. Flag items as "unknown" if you genuinely cannot identify them.
6. Assign the most specific category that applies.
7. Mark proteins as interchangeable when a similar protein could substitute 
   (e.g., chicken breast and chicken thigh are both "poultry").
8. Pantry staples (salt, oil, butter, basic spices) should only be listed if 
   explicitly visible — do not assume they are present.
```

### 2.3 User Prompt Template (v1.0)

```
Analyze the attached photo(s) of food storage contents. Identify every visible 
food ingredient.

Return a JSON object in exactly this format:
{
  "detected_ingredients": [
    {
      "name": "string (generic ingredient name, lowercase)",
      "confidence": "high" | "medium" | "low",
      "category": "protein" | "produce" | "spice" | "dairy" | "grain" | "pantry" | "unknown",
      "interchangeable": true | false,
      "interchangeable_group": "string | null (e.g. 'poultry', 'allium', 'leafy greens')"
    }
  ],
  "photo_quality": "good" | "acceptable" | "poor",
  "detection_notes": "string | null (only if something notable affected detection)"
}

Return nothing outside this JSON object.
```

### 2.4 Output Schema

```python
class DetectionOutput(BaseModel):
    detected_ingredients: list[DetectedIngredient]
    photo_quality: Literal["good", "acceptable", "poor"]
    detection_notes: Optional[str] = None

class DetectedIngredient(BaseModel):
    name: str                          # lowercase, generic (e.g. "chicken breast")
    confidence: Literal["high", "medium", "low"]
    category: IngredientCategory
    interchangeable: bool = False
    interchangeable_group: Optional[str] = None
```

### 2.5 Confidence Scoring Criteria

| Level | Criteria | Example |
|---|---|---|
| High | Clearly visible, unambiguous, full label or shape identifiable | Whole broccoli head, labeled milk carton, whole garlic bulb |
| Medium | Partially visible, could be one of a few similar items, label partially obscured | Partially visible leafy vegetable, unlabeled bottle, item behind other items |
| Low | Barely visible, highly uncertain, or unusual item | Corner of a package, something in a container, unusual produce |

Low-confidence items are displayed with a warning indicator in the UI and are more likely to be removed by the user during confirmation.

### 2.6 Interchangeable Groups

| Group Name | Members |
|---|---|
| `poultry` | chicken breast, chicken thigh, chicken drumstick, turkey, duck |
| `ground_meat` | ground beef, ground turkey, ground pork, ground chicken |
| `white_fish` | cod, tilapia, halibut, sea bass, snapper |
| `fatty_fish` | salmon, tuna, mackerel, trout |
| `allium` | garlic, shallot, onion, green onion, leek |
| `leafy_greens` | spinach, kale, chard, arugula, baby greens |
| `brassica` | broccoli, cauliflower, Brussels sprouts, cabbage |
| `stone_fruit` | peach, nectarine, plum, apricot |
| `citrus` | lemon, lime, orange, grapefruit |
| `root_vegetable` | carrot, parsnip, turnip, sweet potato |

When two items share an interchangeable group, the cache similarity algorithm treats them as matching for weighted overlap calculation.

### 2.7 Category Weight Mapping (for Cache Similarity)

| Category | Weight | Rationale |
|---|---|---|
| `spice` | 1.5x | Spices define cuisine — cumin vs. ginger are not interchangeable |
| `produce` | 1.0x | Standard weight |
| `dairy` | 1.0x | Standard weight |
| `protein` | 0.8x | Proteins are often interchangeable within a group |
| `grain` | 0.8x | Rice, pasta, quinoa are often substitutable |
| `pantry` | 0.3x | Assumed always available — low discriminating power |
| `unknown` | 0.0x | Not counted in similarity score |

### 2.8 Image Preprocessing (Mobile Client Responsibility)

Before upload, the iOS/Android app must:

```
1. Compress to JPEG at 80% quality
2. Resize to max 2048px on longest edge (maintain aspect ratio)
3. Strip EXIF metadata (privacy)
4. Target < 2MB per image after compression
```

If `photo_quality: "poor"` is returned, the API should suggest the user retake with better lighting before proceeding.

### 2.9 API Call Configuration

```python
detection_config = {
    "model": "gpt-4o",
    "max_tokens": 1000,
    "temperature": 0,          # Deterministic — detection is not creative
    "response_format": {"type": "json_object"},
    "messages": [
        {"role": "system", "content": SYSTEM_PROMPT_V1},
        {"role": "user", "content": [
            *[{"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{img}"}} for img in images],
            {"type": "text", "text": USER_PROMPT_V1}
        ]}
    ]
}
```

### 2.10 Cost Management

| Item | Value |
|---|---|
| Budget ceiling | $500/month |
| Estimated cost per detection call | ~$0.01–0.03 (1–3 images at gpt-4o vision pricing) |
| Budget at 2 images avg | ~16,000–50,000 detection calls/month |
| Cache impact | Recipe generation cache reduces generation calls but not detection calls |
| Rate limit | 10 detection requests/minute per the API contract |

To stay within budget: cache ingredient lists for sessions where the user re-scans within 30 minutes of a previous session (same session_id, same photo hash).

---

## 3. Recipe Generation — Ollama Llama 3.1 8B

### 3.1 Task Definition

Given a confirmed list of ingredients, a skill level, and dietary restrictions, generate 3–5 complete, diverse, cookable recipes in a single LLM call. All recipes returned at once (batch, not streaming). Output must be valid JSON only.

### 3.2 System Prompt (v1.0)

```
You are a professional chef with expertise across world cuisines. You create practical, 
delicious recipes for home cooks using the ingredients they actually have available.

Rules you must follow:
1. Return ONLY valid JSON — no prose, no markdown, no preamble, no explanation.
2. Generate ALL recipes in a single response — never ask for clarification.
3. Every recipe MUST use at least 3 of the provided confirmed ingredients.
4. Each recipe may include at most 2 additional ingredients not in the confirmed list, 
   and only if they are common pantry staples (salt, pepper, oil, butter, flour, 
   sugar, basic dried spices). Never add fresh produce or proteins not in the list.
5. HARD CONSTRAINT: Never include any ingredient that violates the stated dietary 
   restrictions. This includes hidden ingredients (e.g., soy sauce contains gluten, 
   butter contains dairy). When in doubt, omit the ingredient.
6. Recipes must span at least 2 different cuisine traditions.
7. Adapt complexity, technique vocabulary, and instruction detail to the stated skill level.
8. Steps must be actionable and sequential — a home cook must be able to follow 
   them without additional knowledge.
9. All time estimates must be realistic for a home kitchen, not a professional one.
```

### 3.3 User Prompt Template (v1.0)

```
Generate {recipe_count} recipes using these confirmed ingredients:

INGREDIENTS:
{ingredient_list}

PREFERENCES:
- Skill level: {skill_level}
- Dietary restrictions: {dietary_restrictions}
- Custom restrictions: {custom_restrictions}

SKILL LEVEL GUIDANCE:
{skill_level_guidance}

Return a JSON object in exactly this format:
{
  "recipes": [
    {
      "id": "string (uuid)",
      "title": "string",
      "cuisine": "string",
      "difficulty": "beginner" | "intermediate" | "advanced",
      "prep_time_minutes": integer,
      "cook_time_minutes": integer,
      "total_time_minutes": integer,
      "servings": integer,
      "ingredients": [
        {
          "name": "string",
          "quantity": "string",
          "unit": "string",
          "from_detected": true | false,
          "assumed_available": true | false
        }
      ],
      "steps": [
        {
          "step_number": integer,
          "instruction": "string",
          "duration_minutes": integer | null,
          "technique": "string | null"
        }
      ],
      "missing_ingredients": ["string"],
      "dietary_tags": ["string"]
    }
  ]
}

Return nothing outside this JSON object.
```

### 3.4 Skill Level Guidance Strings

These are injected into the `{skill_level_guidance}` placeholder:

**Beginner:**
```
- Use only simple techniques: boiling, sautéing, roasting, baking
- Total cook time should be under 30 minutes
- Explain every technique in the step (e.g., "sauté means cook in oil over medium heat, 
  stirring occasionally")
- Assume no special equipment beyond a basic pan, pot, knife, and cutting board
- Use precise measurements — no "a pinch of" or "to taste" without explanation
- Avoid raw meat handling complexity — prefer pre-cut or simple cuts
```

**Intermediate:**
```
- Moderate techniques are appropriate: deglazing, braising, emulsifying, reduction
- Total cook time 20–60 minutes
- Standard technique explanations — no need to define basic terms like "sauté"
- Assume standard home kitchen equipment (sheet pan, cast iron, basic knives)
- Can use judgment measurements where appropriate ("season to taste")
- Multi-step preparations are fine if clearly sequenced
```

**Advanced:**
```
- Complex techniques are appropriate: sous vide, fermentation, reduction sauces, 
  curing, tempering chocolate, laminating dough
- Any duration is acceptable
- Concise professional instructions — assume full kitchen competency
- Can reference professional techniques without explanation
- Plating and presentation instructions are appropriate
- Precision temperatures and timings expected
```

### 3.5 Dietary Restriction Enforcement

Dietary restrictions are **hard constraints** — the prompt alone is not sufficient. The Recipe Generation Service must validate output before returning it to the client:

```python
DIETARY_FORBIDDEN_INGREDIENTS = {
    "vegetarian": ["beef", "chicken", "pork", "lamb", "fish", "seafood", "gelatin", 
                   "lard", "anchovies", "worcestershire"],
    "vegan": ["beef", "chicken", "pork", "lamb", "fish", "seafood", "eggs", "milk",
              "cream", "butter", "cheese", "honey", "gelatin", "lard", "anchovies"],
    "gluten_free": ["wheat", "flour", "bread", "pasta", "soy sauce", "barley", 
                    "rye", "malt", "beer", "breadcrumbs", "semolina"],
    "dairy_free": ["milk", "cream", "butter", "cheese", "yogurt", "ghee", 
                   "whey", "casein", "lactose"],
    "nut_free": ["almonds", "walnuts", "cashews", "peanuts", "pistachios", 
                 "pecans", "hazelnuts", "pine nuts", "macadamia", "nut oil"],
    "shellfish_free": ["shrimp", "crab", "lobster", "crayfish", "clams", 
                       "oysters", "mussels", "scallops", "prawns"],
    "halal": ["pork", "bacon", "ham", "lard", "alcohol", "wine", "beer", "gelatin"],
    "kosher": ["pork", "shellfish", "mixing meat and dairy"]
}

def validate_recipe_compliance(recipe: Recipe, restrictions: list[str]) -> bool:
    """
    Returns False if any ingredient in the recipe violates an active restriction.
    Triggers re-generation if False.
    """
    for ingredient in recipe.ingredients:
        for restriction in restrictions:
            forbidden = DIETARY_FORBIDDEN_INGREDIENTS.get(restriction, [])
            if any(f in ingredient.name.lower() for f in forbidden):
                return False
    return True
```

If validation fails, the service re-prompts with an explicit list of the violation(s): `"The previous response included [ingredient] which violates the [restriction] restriction. Regenerate without it."` Up to 2 retry attempts before returning an error.

### 3.6 Output Validation

After parsing the JSON response, validate:

```python
def validate_recipe_output(recipe: Recipe, confirmed_ingredients: list[str]) -> list[str]:
    """Returns list of validation errors. Empty list = valid."""
    errors = []
    
    detected_used = sum(1 for i in recipe.ingredients if i.from_detected)
    if detected_used < 3:
        errors.append(f"Recipe uses only {detected_used} confirmed ingredients (minimum 3)")
    
    assumed = [i for i in recipe.ingredients if i.assumed_available]
    if len(assumed) > 2:
        errors.append(f"Recipe assumes {len(assumed)} pantry items (maximum 2)")
    
    if recipe.total_time_minutes != recipe.prep_time_minutes + recipe.cook_time_minutes:
        errors.append("total_time_minutes does not match prep + cook times")
    
    if not recipe.steps:
        errors.append("Recipe has no steps")
    
    for i, step in enumerate(recipe.steps):
        if step.step_number != i + 1:
            errors.append(f"Step numbering is not sequential at position {i}")
    
    return errors
```

### 3.7 Cuisine Diversity Enforcement

When generating 3+ recipes, the prompt must request diverse cuisines. The service validates that at least 2 different cuisines are represented in the returned set. If all recipes share the same cuisine, the service appends to the re-prompt:

```
"The recipes you returned are all [cuisine] cuisine. 
Please ensure recipes span at least 2 different culinary traditions."
```

### 3.8 Ollama API Call Configuration

```python
generation_config = {
    "model": "llama3.1:8b-instruct-q4_0",
    "stream": False,              # Batch — never stream recipe generation
    "options": {
        "temperature": 0.7,       # Some creativity, but not chaotic
        "top_p": 0.9,
        "repeat_penalty": 1.1,   # Reduce repetitive ingredient patterns
        "num_predict": 4096,      # Enough tokens for 3-5 full recipes
        "stop": []
    },
    "format": "json"              # Ollama JSON mode — enforces JSON output
}
```

### 3.9 Prompt Construction Example

```python
def build_recipe_prompt(
    confirmed_ingredients: list[ConfirmedIngredient],
    skill_level: SkillLevel,
    dietary_restrictions: list[DietaryRestriction],
    custom_restrictions: Optional[str],
    recipe_count: int = 3
) -> str:

    ingredient_list = "\n".join([
        f"- {i.name} (category: {i.category.value}"
        f"{', interchangeable: ' + i.interchangeable_group if i.interchangeable else ''})"
        for i in confirmed_ingredients
    ])

    dietary_str = (
        ", ".join([r.value.replace("_", "-") for r in dietary_restrictions])
        if dietary_restrictions else "none"
    )

    custom_str = custom_restrictions or "none"
    guidance = SKILL_LEVEL_GUIDANCE[skill_level]

    return USER_PROMPT_TEMPLATE_V1.format(
        recipe_count=recipe_count,
        ingredient_list=ingredient_list,
        skill_level=skill_level.value,
        dietary_restrictions=dietary_str,
        custom_restrictions=custom_str,
        skill_level_guidance=guidance
    )
```

---

## 4. Prompt Version Registry

### 4.1 Version Naming Convention

```
{prompt_name}_v{major}.{minor}

prompt_name: "ingredient_detection" | "recipe_generation"
major: incremented on breaking changes (output schema changes, behavior changes)
minor: incremented on tuning changes (wording, examples, constraint additions)
```

### 4.2 Deployment Process

```
1. New prompt version written and reviewed by ML/AI Engineer
2. A/B test run against last 50 sessions' inputs — compare output quality
3. If quality improves or holds (thumbs_up rate): deploy as active version
4. Old version marked deprecated_date = now() in prompt_versions table
5. Cache entries from old version invalidated (different prompt = different outputs)
6. New version logs its version tag on every subsequent generation
```

### 4.3 Version Registry Schema

```sql
CREATE TABLE prompt_versions (
    id SERIAL PRIMARY KEY,
    prompt_name VARCHAR(100) NOT NULL,
    version VARCHAR(20) NOT NULL,
    template TEXT NOT NULL,
    active BOOLEAN DEFAULT FALSE,
    effective_date TIMESTAMPTZ NOT NULL,
    deprecated_date TIMESTAMPTZ,
    thumbs_up_rate FLOAT,          -- Computed from feedback after deployment
    sample_count INTEGER,          -- Number of sessions using this version
    notes TEXT,
    UNIQUE(prompt_name, version)
);
```

---

## 5. Evaluation Criteria

### 5.1 Ingredient Detection Quality Metrics

| Metric | Target | Measurement Method |
|---|---|---|
| Detection recall | ≥ 80% of visible items identified | Manual QA with 20 labeled test photos |
| False positive rate | < 10% of items are incorrect | Manual review of detection results |
| Category accuracy | ≥ 95% correct category assignment | Manual audit of 200 detections |
| Confidence calibration | High-confidence items correct ≥ 95% of the time | Track user removal rate by confidence level |

**Key signal:** User removal rate per confidence level. If users remove 40% of "high" confidence items, the confidence threshold needs tuning. If users never remove "high" items but frequently remove "medium", calibration is good.

### 5.2 Recipe Generation Quality Metrics

| Metric | Target | Measurement Method |
|---|---|---|
| Ingredient compliance | 100% — no confirmed ingredient missing from any recipe | Automated validation in Recipe Generation Service |
| Dietary restriction compliance | 100% — no violations | Automated validation + safety flag monitoring |
| Cuisine diversity | ≥ 2 cuisines in every 3+ recipe set | Automated validation |
| Thumbs up rate | ≥ 60% across all sessions | Feedback endpoint → audit trail |
| Cook completion rate | ≥ 60% of sessions that enter cook mode reach step 6 | Cook session tracking |
| Structural validity | 100% — no missing fields, valid step ordering | Schema validation before response |

### 5.3 System-Level Metrics

| Metric | Target | Measurement |
|---|---|---|
| Detection latency | p95 < 5s | API response time logging |
| Generation latency (cache miss) | p95 < 15s | API response time logging |
| Generation latency (cache hit) | p95 < 500ms | Redis response time logging |
| Cache hit rate | ≥ 30% after 1 week of usage | Admin cache stats endpoint |
| Safety flag rate | < 0.5% of sessions | safety_flags table count / total sessions |

### 5.4 Feedback Loop Analysis

The audit trail enables tracking quality across prompt versions:

```sql
-- Thumbs up rate by prompt version
SELECT 
    generation_prompt_version,
    COUNT(*) as sessions,
    SUM(CASE WHEN user_feedback = 'thumbs_up' THEN 1 ELSE 0 END) as thumbs_up,
    ROUND(100.0 * SUM(CASE WHEN user_feedback = 'thumbs_up' THEN 1 ELSE 0 END) / COUNT(*), 1) as thumbs_up_rate
FROM generation_logs
WHERE user_feedback IS NOT NULL
GROUP BY generation_prompt_version
ORDER BY effective_date DESC;
```

---

## 6. Cache Similarity Algorithm (Full Specification)

### 6.1 Cache Key (Exact Match)

```python
import hashlib, json

def compute_cache_key(
    confirmed_ingredients: list[ConfirmedIngredient],
    skill_level: SkillLevel,
    dietary_restrictions: list[DietaryRestriction]
) -> str:
    sorted_ingredients = sorted([i.name.lower().strip() for i in confirmed_ingredients])
    sorted_dietary = sorted([r.value for r in dietary_restrictions])

    key_data = {
        "ingredients": sorted_ingredients,
        "skill_level": skill_level.value,
        "dietary": sorted_dietary
    }

    return hashlib.sha256(
        json.dumps(key_data, sort_keys=True).encode()
    ).hexdigest()
```

### 6.2 Similarity Score Computation

```python
CATEGORY_WEIGHTS = {
    "spice": 1.5,
    "produce": 1.0,
    "dairy": 1.0,
    "protein": 0.8,
    "grain": 0.8,
    "pantry": 0.3,
    "unknown": 0.0
}

def compute_weighted_jaccard(
    incoming: list[ConfirmedIngredient],
    cached: list[ConfirmedIngredient]
) -> float:
    """
    Weighted Jaccard similarity considering ingredient categories and 
    interchangeable groups.
    """
    def ingredient_key(i: ConfirmedIngredient) -> str:
        # Items in same interchangeable group count as matching
        if i.interchangeable and i.interchangeable_group:
            return f"group:{i.interchangeable_group}"
        return i.name.lower().strip()

    def weighted_set(ingredients: list[ConfirmedIngredient]) -> dict[str, float]:
        result = {}
        for i in ingredients:
            key = ingredient_key(i)
            weight = CATEGORY_WEIGHTS.get(i.category.value, 1.0)
            result[key] = max(result.get(key, 0), weight)
        return result

    incoming_set = weighted_set(incoming)
    cached_set = weighted_set(cached)

    all_keys = set(incoming_set.keys()) | set(cached_set.keys())

    intersection = sum(
        min(incoming_set.get(k, 0), cached_set.get(k, 0))
        for k in all_keys
    )
    union = sum(
        max(incoming_set.get(k, 0), cached_set.get(k, 0))
        for k in all_keys
    )

    return intersection / union if union > 0 else 0.0

SIMILARITY_THRESHOLD = 0.80
```

### 6.3 Cache Lookup Flow

```python
async def find_cache_match(
    incoming_ingredients: list[ConfirmedIngredient],
    skill_level: SkillLevel,
    dietary_restrictions: list[DietaryRestriction]
) -> Optional[CachedRecipeSet]:

    # 1. Exact match (O(1))
    exact_key = compute_cache_key(incoming_ingredients, skill_level, dietary_restrictions)
    exact_match = await redis.get(f"recipes:{exact_key}")
    if exact_match:
        return CachedRecipeSet.parse_raw(exact_match)

    # 2. Similarity search (bounded scan of last 100 entries, same skill+dietary)
    candidate_keys = await redis.smembers(
        f"index:{skill_level.value}:{':'.join(sorted(r.value for r in dietary_restrictions))}"
    )

    best_score = 0.0
    best_match = None

    for key in list(candidate_keys)[:100]:
        cached_entry = await redis.get(f"recipes:{key}")
        if not cached_entry:
            continue
        cached = CachedRecipeSet.parse_raw(cached_entry)
        score = compute_weighted_jaccard(incoming_ingredients, cached.ingredients)
        if score > best_score:
            best_score = score
            best_match = cached

    if best_score >= SIMILARITY_THRESHOLD and best_match:
        return best_match

    return None
```

---

## 7. QLoRA Fine-Tuning Roadmap

### 7.1 Rationale

The base Llama 3.1 8B model is a strong starting point for recipe generation. QLoRA fine-tuning is deferred to Phase 2 because:

- Fine-tuning without real usage data trains on imagined failure modes, not actual ones
- The feedback loop (thumbs up/down linked to full input/output context) builds the training dataset
- The prompt version registry tracks where the base model underperforms, targeting fine-tuning effort

**Trigger for starting QLoRA:** 500+ thumbs_up labeled sessions with at least 100 thumbs_down sessions for contrast.

### 7.2 Training Data Requirements

The Admin API endpoint `/admin/v1/training-data` exports data in the format needed for fine-tuning:

```json
{
  "input": {
    "ingredients": ["chicken breast", "broccoli", "garlic"],
    "skill_level": "intermediate",
    "dietary_restrictions": ["gluten_free"],
    "prompt_template": "...",
    "prompt_version": "v1.0"
  },
  "output": {
    "recipes": [...],
    "raw_llm_response": "..."
  },
  "feedback": {
    "rating": "thumbs_up",
    "text": "Family loved it",
    "cook_completed": true
  }
}
```

**Training set composition target:**
- 70% thumbs_up sessions (positive examples)
- 30% thumbs_down sessions (negative examples for DPO)
- Minimum 500 total before first training run
- Re-train every 500 new labeled sessions thereafter

### 7.3 Fine-Tuning Method

**Framework:** MLX (Apple's ML framework) — optimized for Apple Silicon, runs entirely on M3 Air with Metal acceleration.

```bash
# Install MLX fine-tuning tools
pip install mlx-lm

# Export training data from Admin API
curl "http://localhost:8000/admin/v1/training-data?feedback_filter=all&limit=1000" \
  > training_data.json

# Convert to MLX training format
python scripts/convert_to_mlx_format.py training_data.json

# Run QLoRA fine-tuning
mlx_lm.lora \
  --model ~/.ollama/models/llama3.1:8b \
  --train \
  --data ./mlx_training_data \
  --iters 1000 \
  --batch-size 4 \
  --lora-layers 16 \
  --learning-rate 1e-4 \
  --adapter-path ./adapters/chef-v1
```

**Expected training time on M3 Air (16GB):** 2–4 hours for 1000 iterations at batch size 4.

### 7.4 Adapter Deployment via Ollama

```bash
# Create Modelfile with adapter
cat > Modelfile << EOF
FROM llama3.1:8b
ADAPTER ./adapters/chef-v1
SYSTEM "You are a professional chef..."
EOF

# Build new model with adapter
ollama create chef-agent:v2 -f Modelfile

# Test the new model
ollama run chef-agent:v2 "Generate a recipe for chicken and broccoli"

# If quality passes evaluation, update environment variable
LLM_MODEL=chef-agent:v2
```

### 7.5 Pre-Deployment Evaluation

Before deploying any new adapter, evaluate against a held-out test set:

```
1. Hold out 100 sessions from training data for evaluation
2. Run both base model and fine-tuned model on identical inputs
3. Compare: thumbs_up rate (simulated via a judge LLM), dietary compliance, structure validity
4. Fine-tuned model must outperform or match base model on all metrics
5. If evaluation passes: update LLM_MODEL env var, flush cache, deploy
6. Monitor thumbs_up rate for 48 hours post-deployment
7. Rollback: revert LLM_MODEL to previous version if thumbs_up rate drops > 10%
```

### 7.6 Fine-Tuning Target Areas

Based on expected base model weaknesses for this specific use case:

| Issue | Expected Frequency | Fine-Tuning Fix |
|---|---|---|
| Recipes require ingredients not in confirmed list | Medium | Train on examples that strictly use confirmed + pantry items only |
| Step instructions too vague for beginner skill level | Medium | Train on examples with explicit, detailed beginner steps |
| Cuisine diversity not maintained across 3+ recipes | Low | Include training examples demonstrating diverse sets |
| Dietary restriction violations (subtle ingredients) | Low-medium | Heavy training signal on dietary compliance |
| Total time estimates unrealistic | Medium | Train on user-verified completion times |

---

## 8. Safety & Guardrails

### 8.1 Allergen Safety Model

Dietary restrictions passed by the user are treated as **hard constraints at multiple layers:**

```
Layer 1: Prompt instruction — "NEVER include [restriction] ingredients"
Layer 2: Output validation — validate_recipe_compliance() before returning
Layer 3: UI indicator — detected ingredients that conflict with restrictions 
         are flagged with a warning icon during confirmation
Layer 4: Safety flag system — users can report violations post-cook
```

No single layer is trusted alone. The combination of prompt + server-side validation ensures near-zero violation rate.

### 8.2 Hidden Ingredient Awareness

Some common ingredients violate restrictions in non-obvious ways. The validation function and the prompt both reference these:

| Ingredient | Violates |
|---|---|
| Soy sauce | Gluten-free (contains wheat) → use tamari instead |
| Worcestershire sauce | Vegetarian (contains anchovies) |
| Caesar dressing | Vegetarian (anchovies), dairy-free (parmesan) |
| Miso paste | Gluten-free (some contain barley) |
| Beer / wine | Halal |
| Gelatin | Vegetarian, halal, kosher |
| Ghee | Dairy-free (clarified butter) |

The prompt explicitly instructs the model to be aware of hidden violations.

### 8.3 Safety Flag Escalation (MVP)

Safety flags are logged but not auto-quarantined in MVP:

```python
class SafetyFlagHandler:
    async def handle_flag(self, flag: SafetyFlag) -> None:
        # Log to PostgreSQL with full audit chain linkage
        await self.db.insert_safety_flag(flag)
        
        # Auto-quarantine threshold (Phase 2 — not MVP):
        # If same recipe_id receives 3+ "high" or "critical" flags,
        # mark is_active=False on the recipe and flush from cache

        # For now: log and notify admin via console
        logger.warning(f"Safety flag received: {flag.severity} - {flag.reason} - recipe {flag.recipe_id}")
```

---

## 9. Prompt Improvement Process

### 9.1 When to Update a Prompt

| Signal | Action |
|---|---|
| Thumbs_up rate drops below 50% over 100 sessions | Investigate generation quality, review raw outputs |
| User removal rate for "high" confidence items > 20% | Review detection prompt, add clarifying instructions |
| Dietary restriction violations in safety flags | Strengthen constraint language in generation prompt + expand forbidden ingredient list |
| Cuisine diversity failures > 10% of sets | Add explicit cuisine diversity examples to generation prompt |
| Steps too vague (indicated by cook abandonment rate) | Expand skill level guidance strings, add more detail requirements |

### 9.2 Prompt A/B Testing

Before deploying a new prompt version to production:

```python
# A/B test configuration
AB_TEST_CONFIG = {
    "prompt_a": "recipe_generation_v1.0",  # Control
    "prompt_b": "recipe_generation_v1.1",  # Challenger
    "traffic_split": 0.5,                   # 50/50
    "min_sessions": 100,                    # Per variant before evaluating
    "success_metric": "thumbs_up_rate"
}

# Session routing
def get_active_prompt(session_id: str, ab_config: dict) -> str:
    if ab_config and hash(session_id) % 2 == 0:
        return ab_config["prompt_b"]
    return ab_config["prompt_a"]
```

Both prompt versions are logged in the audit trail, enabling statistical comparison after the test period.

---

## Approvals

| Role | Name | Status |
|---|---|---|
| ML/AI Engineer | — | ✅ Author |
| Backend Architect | — | ⬜ Pending |
| Product Manager | — | ⬜ Pending |
| QA Engineer | — | ⬜ Pending |
