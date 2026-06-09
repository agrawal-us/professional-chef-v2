# Professional Chef Agent — Test Strategy & QA Plan

**Version:** 1.0
**Date:** June 8, 2026
**Author:** QA Engineer
**Status:** Draft — Pending Stakeholder Review

---

## 1. Overview

This document defines the testing strategy for the Professional Chef Agent MVP. It covers all test layers from unit tests through end-to-end flows, device coverage, AI/ML-specific testing, performance benchmarks, and the bug triage process. Every acceptance criterion in the PRD maps to at least one test case in this document.

**Testing Philosophy:**
- Test at the lowest layer that gives confidence — unit tests for logic, integration tests for service contracts, E2E tests for user journeys
- AI outputs are non-deterministic — test structure and constraints, not exact content
- Every P0 feature must have automated regression coverage before it ships
- Device testing covers both iOS and Android on real hardware, not just simulators

---

## 2. Test Layers

### 2.1 Layer Summary

| Layer | Tool | Runs In | Triggered By | Coverage Target |
|---|---|---|---|---|
| Unit | pytest | Docker | Every commit | ≥ 85% backend logic |
| Integration | pytest + httpx | Docker | Every commit | All API endpoints |
| Contract | Pydantic validation | Docker | Every commit | All request/response schemas |
| E2E | Detox (mobile) | CI device farm | PR to main | All P0 user flows |
| Performance | Locust | Docker | Nightly | All latency SLAs |
| AI/ML | Custom eval suite | Docker | Per prompt version | Detection + generation quality |
| Security | Bandit + OWASP ZAP | Docker | Weekly | OWASP Top 10 |
| Manual | QA Engineer | Physical devices | Pre-release | UX + edge cases |

### 2.2 Coverage Targets by Component

| Component | Unit | Integration | E2E |
|---|---|---|---|
| Ingredient Detection Service | 90% | 100% of endpoints | 3 user flows |
| Recipe Generation Service | 90% | 100% of endpoints | 3 user flows |
| Cache Service | 95% | Cache hit + miss + similarity | 1 flow |
| Audit & Governance Service | 85% | Log completeness | 1 flow |
| LLM Abstraction Layer | 90% | Ollama + mock AWS provider | Covered by generation |
| Admin API | 80% | All admin endpoints | Manual |
| React Native App | 70% (components) | API integration | All P0 flows |

---

## 3. Unit Tests

### 3.1 Cache Service

```python
# test_cache_service.py

class TestCacheKeyComputation:
    def test_identical_ingredients_same_key(self):
        """Same ingredients in different order produce same cache key."""
        ingredients_a = [ConfirmedIngredient(name="chicken breast", ...),
                        ConfirmedIngredient(name="broccoli", ...)]
        ingredients_b = [ConfirmedIngredient(name="broccoli", ...),
                        ConfirmedIngredient(name="chicken breast", ...)]
        assert compute_cache_key(ingredients_a, SkillLevel.INTERMEDIATE, []) == \
               compute_cache_key(ingredients_b, SkillLevel.INTERMEDIATE, [])

    def test_different_skill_level_different_key(self):
        """Same ingredients + different skill level = different key."""
        ingredients = [ConfirmedIngredient(name="chicken breast", ...)]
        key_beginner = compute_cache_key(ingredients, SkillLevel.BEGINNER, [])
        key_advanced = compute_cache_key(ingredients, SkillLevel.ADVANCED, [])
        assert key_beginner != key_advanced

    def test_dietary_restrictions_affect_key(self):
        """Adding a dietary restriction changes the cache key."""
        ingredients = [ConfirmedIngredient(name="chicken breast", ...)]
        key_no_diet = compute_cache_key(ingredients, SkillLevel.INTERMEDIATE, [])
        key_gf = compute_cache_key(ingredients, SkillLevel.INTERMEDIATE,
                                   [DietaryRestriction.GLUTEN_FREE])
        assert key_no_diet != key_gf


class TestWeightedJaccardSimilarity:
    def test_identical_sets_score_one(self):
        """Identical ingredient sets should score 1.0."""
        ingredients = [
            ConfirmedIngredient(name="garlic", category="spice", ...),
            ConfirmedIngredient(name="chicken breast", category="protein", ...),
        ]
        assert compute_weighted_jaccard(ingredients, ingredients) == 1.0

    def test_no_overlap_score_zero(self):
        """Completely different ingredients should score 0.0."""
        set_a = [ConfirmedIngredient(name="salmon", category="protein", ...)]
        set_b = [ConfirmedIngredient(name="broccoli", category="produce", ...)]
        assert compute_weighted_jaccard(set_a, set_b) == 0.0

    def test_spices_weighted_higher_than_proteins(self):
        """Spice match raises score more than protein match."""
        base = [ConfirmedIngredient(name="cumin", category="spice", ...)]
        with_protein = base + [ConfirmedIngredient(name="chicken", category="protein", ...)]
        with_spice = base + [ConfirmedIngredient(name="paprika", category="spice", ...)]
        # Adding a matching spice to cached set improves score more than protein
        score_protein_match = compute_weighted_jaccard(with_protein, base + [
            ConfirmedIngredient(name="beef", category="protein", ...)])  # no match
        score_spice_match = compute_weighted_jaccard(with_spice, base + [
            ConfirmedIngredient(name="paprika", category="spice", ...)])  # match
        assert score_spice_match > score_protein_match

    def test_interchangeable_proteins_count_as_match(self):
        """Chicken breast and chicken thigh (same group) should match."""
        incoming = [ConfirmedIngredient(name="chicken breast", category="protein",
                                        interchangeable=True, interchangeable_group="poultry")]
        cached = [ConfirmedIngredient(name="chicken thigh", category="protein",
                                      interchangeable=True, interchangeable_group="poultry")]
        score = compute_weighted_jaccard(incoming, cached)
        assert score == 1.0

    def test_similarity_threshold_80_percent(self):
        """Sets with ≥80% weighted overlap should trigger cache hit."""
        full_set = [
            ConfirmedIngredient(name="garlic", category="spice", ...),
            ConfirmedIngredient(name="chicken breast", category="protein", ...),
            ConfirmedIngredient(name="broccoli", category="produce", ...),
            ConfirmedIngredient(name="rice", category="grain", ...),
        ]
        # Remove only a grain (low weight) — should still be ≥ 80%
        partial_set = full_set[:3]
        score = compute_weighted_jaccard(partial_set, full_set)
        assert score >= 0.80
```

### 3.2 Dietary Restriction Validation

```python
# test_dietary_validation.py

class TestDietaryCompliance:
    def test_gluten_free_rejects_soy_sauce(self):
        """Soy sauce contains wheat and should fail gluten-free check."""
        recipe = Recipe(ingredients=[
            RecipeIngredient(name="soy sauce", ...)
        ], ...)
        assert validate_recipe_compliance(recipe, ["gluten_free"]) is False

    def test_vegan_rejects_butter(self):
        recipe = Recipe(ingredients=[RecipeIngredient(name="butter", ...)], ...)
        assert validate_recipe_compliance(recipe, ["vegan"]) is False

    def test_nut_free_rejects_peanut_oil(self):
        recipe = Recipe(ingredients=[RecipeIngredient(name="peanut oil", ...)], ...)
        assert validate_recipe_compliance(recipe, ["nut_free"]) is False

    def test_halal_rejects_wine(self):
        recipe = Recipe(ingredients=[RecipeIngredient(name="white wine", ...)], ...)
        assert validate_recipe_compliance(recipe, ["halal"]) is False

    def test_compliant_recipe_passes(self):
        recipe = Recipe(ingredients=[
            RecipeIngredient(name="chicken breast", ...),
            RecipeIngredient(name="broccoli", ...),
            RecipeIngredient(name="olive oil", ...),
        ], ...)
        assert validate_recipe_compliance(recipe, ["gluten_free"]) is True

    def test_multiple_restrictions_all_enforced(self):
        """All active restrictions must pass simultaneously."""
        recipe = Recipe(ingredients=[
            RecipeIngredient(name="rice noodles", ...),   # GF ok
            RecipeIngredient(name="tofu", ...),            # Vegan ok
            RecipeIngredient(name="sesame oil", ...),      # Both ok
        ], ...)
        assert validate_recipe_compliance(recipe, ["gluten_free", "vegan"]) is True
```

### 3.3 Recipe Output Validation

```python
# test_recipe_validation.py

class TestRecipeStructure:
    def test_minimum_three_confirmed_ingredients(self):
        recipe = build_recipe_with_n_confirmed_ingredients(2)
        errors = validate_recipe_output(recipe, confirmed_ingredients)
        assert any("minimum 3" in e for e in errors)

    def test_maximum_two_pantry_assumptions(self):
        recipe = build_recipe_with_n_pantry_items(3)
        errors = validate_recipe_output(recipe, confirmed_ingredients)
        assert any("maximum 2" in e for e in errors)

    def test_step_numbering_sequential(self):
        recipe = build_recipe_with_misnumbered_steps()
        errors = validate_recipe_output(recipe, confirmed_ingredients)
        assert any("sequential" in e for e in errors)

    def test_total_time_matches_prep_plus_cook(self):
        recipe = Recipe(prep_time_minutes=10, cook_time_minutes=15,
                        total_time_minutes=30, ...)  # wrong total
        errors = validate_recipe_output(recipe, confirmed_ingredients)
        assert any("total_time_minutes" in e for e in errors)

    def test_valid_recipe_has_no_errors(self):
        recipe = build_valid_recipe()
        errors = validate_recipe_output(recipe, confirmed_ingredients)
        assert errors == []
```

---

## 4. Integration Tests

### 4.1 API Endpoint Tests

```python
# test_api_integration.py

class TestDetectEndpoint:
    async def test_valid_image_returns_ingredients(self, client, sample_image):
        response = await client.post("/api/v1/detect",
            files={"images": sample_image},
            headers=valid_headers())
        assert response.status_code == 200
        data = response.json()
        assert data["success"] is True
        assert len(data["data"]["detected_ingredients"]) > 0
        assert data["data"]["session_id"] is not None

    async def test_missing_image_returns_400(self, client):
        response = await client.post("/api/v1/detect", headers=valid_headers())
        assert response.status_code == 400
        assert response.json()["error"]["code"] == "VALIDATION_ERROR"

    async def test_image_too_large_returns_400(self, client, oversized_image):
        response = await client.post("/api/v1/detect",
            files={"images": oversized_image},
            headers=valid_headers())
        assert response.status_code == 400
        assert response.json()["error"]["code"] == "IMAGE_TOO_LARGE"

    async def test_too_many_images_returns_400(self, client, four_images):
        response = await client.post("/api/v1/detect",
            files={"images": four_images},
            headers=valid_headers())
        assert response.status_code == 400
        assert response.json()["error"]["code"] == "TOO_MANY_IMAGES"


class TestGenerateEndpoint:
    async def test_cache_hit_returns_fast(self, client, redis, seeded_cache):
        """Cached result should return in under 500ms."""
        start = time.monotonic()
        response = await client.post("/api/v1/generate",
            json=generate_request_matching_cache(),
            headers=valid_headers())
        elapsed_ms = (time.monotonic() - start) * 1000
        assert response.status_code == 200
        assert response.json()["data"]["cache_hit"] is True
        assert elapsed_ms < 500

    async def test_force_fresh_bypasses_cache(self, client, redis, seeded_cache):
        response = await client.post("/api/v1/generate",
            json={**generate_request_matching_cache(), "force_fresh": True},
            headers=valid_headers())
        assert response.json()["data"]["cache_hit"] is False

    async def test_dietary_restrictions_enforced_in_output(self, client, mock_ollama):
        """No recipe in the response should violate gluten_free."""
        response = await client.post("/api/v1/generate",
            json={"dietary_restrictions": ["gluten_free"], ...},
            headers=valid_headers())
        recipes = response.json()["data"]["recipes"]
        for recipe in recipes:
            for ingredient in recipe["ingredients"]:
                assert "soy sauce" not in ingredient["name"].lower()
                assert "wheat" not in ingredient["name"].lower()
                assert "flour" not in ingredient["name"].lower()

    async def test_insufficient_ingredients_returns_400(self, client):
        """Session with only 1 confirmed ingredient should fail."""
        response = await client.post("/api/v1/generate",
            json={"session_id": session_with_one_ingredient(), ...},
            headers=valid_headers())
        assert response.status_code == 400
        assert response.json()["error"]["code"] == "INSUFFICIENT_INGREDIENTS"

    async def test_cuisine_diversity_in_output(self, client, mock_ollama):
        """3+ recipes must span at least 2 cuisines."""
        response = await client.post("/api/v1/generate",
            json=valid_generate_request(),
            headers=valid_headers())
        cuisines = {r["cuisine"] for r in response.json()["data"]["recipes"]}
        assert len(cuisines) >= 2


class TestFeedbackEndpoint:
    async def test_feedback_linked_to_session(self, client, db, valid_session):
        response = await client.post("/api/v1/feedback",
            json={"session_id": valid_session, "recipe_id": valid_recipe,
                  "cook_session_id": valid_cook_session,
                  "rating": "thumbs_up", "cook_completed": True},
            headers=valid_headers())
        assert response.status_code == 200
        # Verify audit trail updated
        log = await db.fetch_one("SELECT user_feedback FROM generation_logs WHERE session_id = $1",
                                  valid_session)
        assert log["user_feedback"] == "thumbs_up"


class TestHealthEndpoint:
    async def test_healthy_when_all_deps_up(self, client):
        response = await client.get("/api/v1/health")
        assert response.status_code == 200
        data = response.json()["data"]
        assert data["status"] == "healthy"
        assert data["dependencies"]["postgres"]["status"] == "connected"
        assert data["dependencies"]["redis"]["status"] == "connected"

    async def test_degraded_when_ollama_down(self, client, kill_ollama):
        response = await client.get("/api/v1/health")
        assert response.status_code == 503
        assert response.json()["data"]["status"] == "degraded"
        assert response.json()["data"]["dependencies"]["llm"]["status"] == "unreachable"
```

### 4.2 Audit Trail Completeness Tests

```python
class TestAuditTrail:
    async def test_full_session_chain_logged(self, client, db):
        """Complete detect → confirm → generate → feedback flow creates full audit record."""
        session_id = await run_full_session_flow(client)

        log = await db.fetch_one(
            "SELECT * FROM generation_logs WHERE session_id = $1", session_id)

        assert log["photo_hashes"] is not None
        assert log["detection_prompt_version"] is not None
        assert log["confirmed_ingredient_count"] > 0
        assert log["generation_model"] is not None
        assert log["generation_prompt_version"] is not None
        assert log["cache_hit"] is not None
        assert log["recipe_count"] > 0

    async def test_feedback_updates_audit_record(self, client, db, valid_session):
        await submit_feedback(client, valid_session, "thumbs_up")
        log = await db.fetch_one(
            "SELECT user_feedback FROM generation_logs WHERE session_id = $1",
            valid_session)
        assert log["user_feedback"] == "thumbs_up"

    async def test_safety_flag_creates_incident(self, client, db, valid_recipe):
        await submit_safety_flag(client, valid_recipe, severity="high",
                                  reason="allergen_violation")
        flag = await db.fetch_one(
            "SELECT * FROM safety_flags WHERE recipe_id = $1", valid_recipe)
        assert flag is not None
        assert flag["severity"] == "high"
```

---

## 5. End-to-End Tests (React Native — Detox)

### 5.1 P0 Flow: Scan → Generate → Cook

```javascript
// e2e/fullCookingFlow.test.js

describe('Full Cooking Flow', () => {
  beforeAll(async () => {
    await device.launchApp({ newInstance: true });
  });

  it('should complete scan to cook mode in under 90 seconds', async () => {
    const start = Date.now();

    // Home screen
    await expect(element(by.id('scan-ingredients-btn'))).toBeVisible();
    await element(by.id('scan-ingredients-btn')).tap();

    // Camera screen
    await expect(element(by.id('camera-view'))).toBeVisible();
    await element(by.id('use-sample-image-btn')).tap(); // uses test fixture

    // Detecting screen - wait for completion
    await waitFor(element(by.id('confirm-screen')))
      .toBeVisible()
      .withTimeout(10000); // 10s max for detection

    // Confirm ingredients
    await expect(element(by.id('ingredient-list'))).toBeVisible();
    await expect(element(by.id('continue-btn'))).toBeVisible();
    await element(by.id('continue-btn')).tap();

    // Preferences
    await element(by.id('skill-intermediate')).tap();
    await element(by.id('generate-btn')).tap();

    // Wait for recipes
    await waitFor(element(by.id('recipe-browse-screen')))
      .toBeVisible()
      .withTimeout(20000); // 20s max for generation

    // Select first recipe
    await element(by.id('recipe-card-0')).tap();
    await element(by.id('start-cooking-btn')).tap();

    // Cook mode visible
    await expect(element(by.id('cook-mode-screen'))).toBeVisible();

    const elapsed = (Date.now() - start) / 1000;
    expect(elapsed).toBeLessThan(90); // PRD requirement: < 90 seconds
  });

  it('should display 3 or more recipe cards', async () => {
    await navigateToRecipeBrowse();
    const recipeCards = await element(by.id('recipe-card')).getAttributes();
    expect(recipeCards.elements.length).toBeGreaterThanOrEqual(3);
  });

  it('should navigate cook mode steps with back and next', async () => {
    await navigateToCookMode();
    await expect(element(by.text('Step 1'))).toBeVisible();
    await element(by.id('next-step-btn')).tap();
    await expect(element(by.text('Step 2'))).toBeVisible();
    await element(by.id('prev-step-btn')).tap();
    await expect(element(by.text('Step 1'))).toBeVisible();
  });

  it('should show timer button on timed steps', async () => {
    await navigateToTimedStep();
    await expect(element(by.id('timer-start-btn'))).toBeVisible();
    await expect(element(by.id('timer-display'))).toBeVisible();
  });
});
```

### 5.2 P0 Flow: Ingredient Confirmation Editing

```javascript
describe('Ingredient Confirmation', () => {
  it('should allow removing an ingredient chip', async () => {
    await navigateToConfirmScreen();
    const initialCount = await getIngredientCount();
    await element(by.id('remove-chicken-breast')).tap();
    const newCount = await getIngredientCount();
    expect(newCount).toBe(initialCount - 1);
  });

  it('should allow adding a manual ingredient', async () => {
    await navigateToConfirmScreen();
    await element(by.id('add-ingredient-btn')).tap();
    await element(by.id('ingredient-input')).typeText('onion');
    await element(by.id('ingredient-input')).tapReturnKey();
    await expect(element(by.text('onion'))).toBeVisible();
  });

  it('should show confidence color indicators', async () => {
    await navigateToConfirmScreen();
    await expect(element(by.id('confidence-high-indicator'))).toBeVisible();
    await expect(element(by.id('confidence-medium-indicator'))).toBeVisible();
  });
});
```

### 5.3 P0 Flow: Dietary Restrictions

```javascript
describe('Dietary Restrictions', () => {
  it('should persist dietary restrictions across sessions', async () => {
    await navigateToPreferences();
    await element(by.id('diet-gluten-free')).tap();
    await element(by.id('generate-btn')).tap();
    await device.reloadReactNative();
    await navigateToPreferences();
    await expect(element(by.id('diet-gluten-free'))).toHaveToggleValue(true);
  });

  it('should flag conflicting detected ingredients', async () => {
    await setDietaryRestriction('nut_free');
    await detectIngredientsWithPeanuts();
    await expect(element(by.id('allergen-warning-peanuts'))).toBeVisible();
  });
});
```

### 5.4 P0 Flow: Offline Cook Mode

```javascript
describe('Offline Cook Mode', () => {
  it('should continue cook mode without network', async () => {
    await navigateToCookMode();
    await device.setStatusBar({ networkActivityIndicatorVisible: false });
    await disableNetwork();
    // Step navigation should still work
    await element(by.id('next-step-btn')).tap();
    await expect(element(by.text('Step 2'))).toBeVisible();
  });
});
```

---

## 6. AI/ML Evaluation Tests

### 6.1 Ingredient Detection Quality

These tests run against a labeled test set of 20 fridge photos:

```python
# test_detection_quality.py

LABELED_TEST_SET = [
    {"photo": "fridge_01.jpg", "expected": ["chicken breast", "broccoli", "garlic", "milk"]},
    {"photo": "fridge_02.jpg", "expected": ["eggs", "cheese", "butter", "onion", "tomato"]},
    # ... 18 more labeled photos
]

class TestDetectionQuality:
    def test_detection_recall_above_80_percent(self):
        """At least 80% of visible ingredients detected across test set."""
        total_expected = 0
        total_detected_correctly = 0

        for test_case in LABELED_TEST_SET:
            result = run_detection(test_case["photo"])
            detected_names = [i["name"] for i in result["detected_ingredients"]
                             if i["confidence"] != "low"]
            for expected in test_case["expected"]:
                total_expected += 1
                if any(expected in d for d in detected_names):
                    total_detected_correctly += 1

        recall = total_detected_correctly / total_expected
        assert recall >= 0.80, f"Detection recall {recall:.1%} below 80% target"

    def test_high_confidence_items_are_accurate(self):
        """Items returned as 'high' confidence should be correct ≥95% of the time."""
        high_conf_correct = 0
        high_conf_total = 0

        for test_case in LABELED_TEST_SET:
            result = run_detection(test_case["photo"])
            for ingredient in result["detected_ingredients"]:
                if ingredient["confidence"] == "high":
                    high_conf_total += 1
                    if ingredient["name"] in test_case["expected"]:
                        high_conf_correct += 1

        accuracy = high_conf_correct / high_conf_total if high_conf_total > 0 else 0
        assert accuracy >= 0.95

    def test_detection_output_is_valid_json(self):
        """Detection output must parse cleanly as valid JSON."""
        for test_case in LABELED_TEST_SET[:5]:
            result = run_detection(test_case["photo"])
            assert DetectionOutput(**result)  # Pydantic validation
```

### 6.2 Recipe Generation Quality

```python
# test_generation_quality.py

TEST_INGREDIENT_SETS = [
    {"ingredients": ["chicken breast", "broccoli", "garlic", "rice"],
     "skill": "intermediate", "dietary": []},
    {"ingredients": ["tofu", "spinach", "mushrooms", "soy sauce", "ginger"],
     "skill": "beginner", "dietary": ["vegan"]},
    {"ingredients": ["salmon", "lemon", "dill", "capers", "cream cheese"],
     "skill": "advanced", "dietary": ["gluten_free"]},
]

class TestRecipeGenerationQuality:
    def test_always_returns_3_to_5_recipes(self):
        for test_case in TEST_INGREDIENT_SETS:
            result = run_generation(**test_case)
            assert 3 <= len(result["recipes"]) <= 5

    def test_all_recipes_structurally_valid(self):
        for test_case in TEST_INGREDIENT_SETS:
            result = run_generation(**test_case)
            for recipe in result["recipes"]:
                errors = validate_recipe_output(Recipe(**recipe),
                                                test_case["ingredients"])
                assert errors == [], f"Recipe validation errors: {errors}"

    def test_dietary_restrictions_never_violated(self):
        for test_case in TEST_INGREDIENT_SETS:
            if not test_case["dietary"]:
                continue
            result = run_generation(**test_case)
            for recipe in result["recipes"]:
                assert validate_recipe_compliance(
                    Recipe(**recipe), test_case["dietary"]
                ), f"Dietary violation in recipe: {recipe['title']}"

    def test_cuisine_diversity_across_recipes(self):
        for test_case in TEST_INGREDIENT_SETS:
            result = run_generation(**test_case)
            cuisines = {r["cuisine"] for r in result["recipes"]}
            assert len(cuisines) >= 2, "All recipes from same cuisine"

    def test_recipes_use_confirmed_ingredients(self):
        for test_case in TEST_INGREDIENT_SETS:
            result = run_generation(**test_case)
            for recipe in result["recipes"]:
                detected_used = sum(1 for i in recipe["ingredients"]
                                   if i["from_detected"])
                assert detected_used >= 3
```

---

## 7. Performance Tests

### 7.1 Load Test Configuration (Locust)

```python
# locustfile.py

class ChefAgentUser(HttpUser):
    wait_time = between(2, 5)

    @task(1)
    def health_check(self):
        self.client.get("/api/v1/health")

    @task(3)
    def generate_recipes_cache_hit(self):
        """80% of requests should hit cache after warmup."""
        with self.client.post("/api/v1/generate",
            json=seeded_generate_request(),
            headers=valid_headers(),
            catch_response=True) as response:
            if response.json().get("data", {}).get("cache_hit"):
                response.success()

    @task(1)
    def generate_recipes_cache_miss(self):
        with self.client.post("/api/v1/generate",
            json=random_generate_request(),  # unique ingredients
            headers=valid_headers(),
            catch_response=True) as response:
            response.success()
```

### 7.2 Latency SLA Assertions

| Endpoint | p50 Target | p95 Target | p99 Target |
|---|---|---|---|
| GET /health | < 50ms | < 100ms | < 200ms |
| POST /detect | < 2s | < 5s | < 8s |
| POST /confirm | < 100ms | < 200ms | < 500ms |
| POST /generate (cache hit) | < 100ms | < 500ms | < 1s |
| POST /generate (cache miss) | < 8s | < 15s | < 25s |
| GET /recipes/{id} | < 50ms | < 100ms | < 200ms |
| GET /cook/{id}/steps | < 50ms | < 100ms | < 200ms |
| POST /feedback | < 100ms | < 200ms | < 500ms |

### 7.3 Concurrent User Simulation

```
Scenario: 10 simultaneous users each complete a full session
Expected: No request exceeds 2x the p95 target under concurrent load
Ollama note: Single-request queue — generation requests will serialize.
             Cache hit rate must be ≥30% to maintain acceptable generation latency.
```

---

## 8. Security Tests

### 8.1 Input Validation

```python
class TestInputSecurity:
    def test_sql_injection_in_ingredient_name(self, client):
        """SQL injection in ingredient name should be rejected or sanitized."""
        response = await client.post("/api/v1/confirm",
            json={"confirmed_ingredients": [
                {"name": "'; DROP TABLE sessions; --", "category": "protein"}
            ]}, headers=valid_headers())
        # Should either reject with 400 or sanitize — must NOT 500
        assert response.status_code in [400, 422]

    def test_oversized_custom_restriction_rejected(self, client):
        """custom_restrictions field capped at 200 characters."""
        response = await client.post("/api/v1/generate",
            json={"custom_restrictions": "x" * 300, ...},
            headers=valid_headers())
        assert response.status_code == 400

    def test_invalid_image_format_rejected(self, client, gif_file):
        response = await client.post("/api/v1/detect",
            files={"images": gif_file},
            headers=valid_headers())
        assert response.status_code == 400
        assert response.json()["error"]["code"] == "INVALID_IMAGE_FORMAT"

    def test_openai_key_not_exposed_in_response(self, client):
        """OpenAI API key must never appear in any API response."""
        response = await client.get("/api/v1/health")
        assert "sk-" not in response.text
```

### 8.2 Rate Limiting

```python
class TestRateLimiting:
    async def test_detect_rate_limit_10_per_minute(self, client):
        """11th detect request within a minute should return 429."""
        for _ in range(10):
            await client.post("/api/v1/detect", files=..., headers=valid_headers())
        response = await client.post("/api/v1/detect",
            files=..., headers=valid_headers())
        assert response.status_code == 429
        assert "Retry-After" in response.headers

    async def test_generate_rate_limit_20_per_minute(self, client):
        for _ in range(20):
            await client.post("/api/v1/generate", json=..., headers=valid_headers())
        response = await client.post("/api/v1/generate",
            json=..., headers=valid_headers())
        assert response.status_code == 429
```

---

## 9. Device Testing Matrix

### 9.1 iOS Devices

| Device | OS | Priority | Type |
|---|---|---|---|
| iPhone 15 Pro | iOS 17 | P0 | Physical |
| iPhone 14 | iOS 16 | P0 | Physical |
| iPhone SE (3rd gen) | iOS 16 | P1 | Physical |
| iPhone 13 Mini | iOS 16 | P1 | Simulator |
| iPad Air (5th gen) | iOS 16 | P1 | Physical |
| iPad Pro 12.9" | iOS 17 | P2 | Simulator |

### 9.2 Android Devices

| Device | OS | Priority | Type |
|---|---|---|---|
| Samsung Galaxy S24 | Android 14 | P0 | Physical |
| Google Pixel 7 | Android 13 | P0 | Physical |
| Samsung Galaxy A54 | Android 13 | P1 | Physical |
| OnePlus 11 | Android 13 | P1 | Simulator |
| Samsung Galaxy Tab S9 | Android 13 | P2 | Physical |
| Budget Android (Moto G) | Android 12 | P2 | Physical |

### 9.3 Device-Specific Test Cases

| Test | iOS | Android | Notes |
|---|---|---|---|
| Camera permission request | ✅ | ✅ | Different permission flows |
| Photo library access | ✅ | ✅ | Scoped storage on Android 13+ |
| Screen wake lock in cook mode | ✅ | ✅ | Different APIs |
| Background timer notification | ✅ | ✅ | Notification channels on Android |
| HEIC image format | ✅ | ❌ | iOS-only format |
| Haptic feedback on timer | ✅ | ✅ | Different implementations |
| Safe area insets | ✅ | ✅ | Notch + punch hole cameras |

---

## 10. Test Data Management

### 10.1 Test Fixtures

```
/tests/fixtures/
  images/
    fridge_good_lighting.jpg      # Clear, well-lit fridge photo
    fridge_dark.jpg               # Low-light photo
    fridge_cluttered.jpg          # Overlapping items
    fridge_partial.jpg            # Partially open fridge
    not_a_fridge.jpg              # No food items — edge case
    oversized.jpg                 # 11MB — exceeds limit
    invalid.gif                   # Wrong format
  recipes/
    valid_recipe.json             # Well-formed recipe
    invalid_diet_recipe.json      # Contains gluten in GF recipe
    missing_steps_recipe.json     # No steps array
  sessions/
    complete_session.json         # Full audit chain
    incomplete_session.json       # Missing feedback
```

### 10.2 Database Seeding

```python
# conftest.py

@pytest.fixture
async def seeded_db(db):
    """Seeds database with known test sessions for integration tests."""
    await db.execute("""
        INSERT INTO sessions (id, created_at) VALUES
        ('test-session-001', NOW()),
        ('test-session-002', NOW() - INTERVAL '1 hour')
    """)
    await db.execute("""
        INSERT INTO generation_logs (session_id, cache_hit, recipe_count)
        VALUES ('test-session-001', false, 3)
    """)
    yield db
    await db.execute("DELETE FROM sessions WHERE id LIKE 'test-%'")
```

---

## 11. Bug Triage Process

### 11.1 Severity Levels

| Level | Definition | Response Time | Examples |
|---|---|---|---|
| P0 — Critical | App crashes, data loss, security vulnerability, dietary restriction violation | Immediate | Crash on launch, allergen in restricted recipe, API key exposed |
| P1 — High | Core feature broken, incorrect output, significant performance regression | Same day | Detection returns nothing, recipes don't generate, cache never hits |
| P2 — Medium | Feature degraded, minor incorrect output, UX issue | Next sprint | Timer doesn't persist, wrong confidence badge color, slow screen transition |
| P3 — Low | Cosmetic issue, edge case behavior, nice-to-have improvement | Backlog | Text truncation, minor layout shift, obscure error message |

### 11.2 Bug Report Template

```
Title: [Component] Short description of the bug

Severity: P0 / P1 / P2 / P3
Platform: iOS / Android / Backend / Both
Environment: Development / Staging

Steps to reproduce:
1. 
2. 
3. 

Expected behavior:

Actual behavior:

Session ID (if applicable):
Device + OS version:
App version:
Backend version:

Logs / screenshots:
```

### 11.3 Regression Test Policy

- Every P0 and P1 bug fix must include a new automated test that reproduces the bug
- Test added to the regression suite before the fix is merged
- Test must fail on the broken code and pass on the fix

---

## 12. Pre-Release Checklist

### 12.1 Internal Beta (TestFlight + Firebase App Distribution)

```
Backend:
[ ] All unit tests passing (≥85% coverage)
[ ] All integration tests passing
[ ] No P0 or P1 bugs open
[ ] Health check endpoint returns healthy
[ ] Audit trail verified for 5 complete sessions
[ ] Cache hit rate ≥20% on seeded test data
[ ] Dietary restriction validation confirmed for all 8 types

Mobile (iOS):
[ ] App builds and launches on iPhone 14 and iPhone 15 Pro
[ ] Camera permission flow works on first launch
[ ] Detect → Confirm → Generate → Cook flow completes on physical device
[ ] Cook mode screen stays awake
[ ] Timer fires audio notification
[ ] App works offline once recipes are loaded

Mobile (Android):
[ ] App builds and launches on Pixel 7 and Galaxy S24
[ ] Camera permission flow works on Android 13+
[ ] Same E2E flow confirmed on physical Android device
[ ] Background notifications work on Android

Performance:
[ ] p95 generation latency < 15s on M3 Air under no-cache conditions
[ ] p95 detection latency < 5s
[ ] Cache hit response < 500ms

Security:
[ ] No API keys in any response body
[ ] Rate limiting confirmed active on /detect and /generate
[ ] Input validation rejects SQL injection attempt
```

---

## 13. Acceptance Criteria Traceability

| PRD Section | Acceptance Criterion | Test Type | Test ID |
|---|---|---|---|
| 4.1 Ingredient Detection | ≥80% of visible items detected | AI/ML eval | `test_detection_recall_above_80_percent` |
| 4.1 Ingredient Detection | Each ingredient has confidence score | Integration | `test_valid_image_returns_ingredients` |
| 4.2 Ingredient Confirmation | Remove ingredient with one tap | E2E | `test_can_remove_ingredient_chip` |
| 4.2 Ingredient Confirmation | Add ingredient via text input | E2E | `test_can_add_manual_ingredient` |
| 4.3 Skill Level | Persists across sessions | E2E | `test_skill_level_persists` |
| 4.4 Dietary Restrictions | No recipe violates hard constraint | Unit + Integration | `test_dietary_compliance_*` |
| 4.5 Recipe Generation | 3–5 recipes returned | AI/ML eval | `test_always_returns_3_to_5_recipes` |
| 4.5 Recipe Generation | ≥2 cuisines in every set | AI/ML eval | `test_cuisine_diversity_across_recipes` |
| 4.6 Cook Mode | Steps navigate forward/back | E2E | `test_cook_mode_step_navigation` |
| 4.6 Cook Mode | Screen stays on | E2E | `test_screen_wake_lock_active` |
| 4.7 Cache | Cache hit < 500ms | Integration + Perf | `test_cache_hit_returns_fast` |
| 4.7 Cache | force_fresh bypasses cache | Integration | `test_force_fresh_bypasses_cache` |
| 4.8 Governance | Full audit record per session | Integration | `test_full_session_chain_logged` |
| 4.8 Governance | Safety flag creates incident | Integration | `test_safety_flag_creates_incident` |
| 6.1 Performance | Scan → cook < 90 seconds | E2E | `test_full_flow_under_90_seconds` |

---

## Approvals

| Role | Name | Status |
|---|---|---|
| QA Engineer | — | ✅ Author |
| Backend Architect | — | ⬜ Pending |
| Mobile Engineer | — | ⬜ Pending |
| ML/AI Engineer | — | ⬜ Pending |
| Product Manager | — | ⬜ Pending |
| CI/CD Engineer | — | ⬜ Pending |
