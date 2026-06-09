# Professional Chef Agent — Product Requirements Document (PRD)

**Version:** 2.0
**Date:** June 8, 2026
**Author:** Product Manager
**Status:** Draft — Pending Stakeholder Review

**Revision Notes (v2.0):**
- Changed from SwiftUI (iOS-only) to React Native with Expo (iOS + Android)
- Added LLM Abstraction Layer for local dev → AWS production path
- Replaced SQLite with PostgreSQL for dev/prod parity
- Added dietary restrictions as P0 requirement
- Resolved all open questions

---

## 1. Executive Summary

Professional Chef Agent is a mobile-first AI-powered cooking assistant that transforms the contents of a user's refrigerator into actionable, skill-appropriate recipes. Users photograph their available ingredients, confirm what's detected, select their cooking skill level, and receive 3–5 curated recipes they can cook right now. A guided step-by-step cook mode walks them through their chosen recipe.

The MVP focuses on the core loop: **photo → ingredients → recipes → cook mode**. Premium features like real-time cooking feedback via progress photos are deferred to Phase 2.

---

## 2. Problem Statement

Home cooks face a daily friction point: they open the fridge, see a collection of ingredients, and struggle to decide what to make. Existing solutions either require manual ingredient entry (tedious), suggest recipes that need items the user doesn't have (frustrating), or ignore the user's skill level (overwhelming or boring).

**Professional Chef Agent eliminates that friction** by using the phone's camera to identify what's available and generating recipes that match both the ingredients and the cook's ability.

---

## 3. Target Users

### 3.1 Primary Persona — "The Weeknight Cook"

- Age 25–45, cooking 3–5 times per week
- Has a stocked fridge but limited meal planning
- Intermediate skill level, comfortable with basic techniques
- Time-constrained — wants dinner ideas in under 60 seconds
- Uses a smartphone (iPhone or Android) as their primary device

### 3.2 Secondary Persona — "The Aspiring Home Chef"

- Age 20–35, learning to cook more adventurously
- Beginner to intermediate, wants to build skills
- Values diverse cuisine exposure
- Appreciates step-by-step guidance with clear explanations

### 3.3 Tertiary Persona — "The Experienced Cook"

- Age 30–60, confident in the kitchen
- Advanced skill level, wants inspiration not instruction
- Interested in creative combinations and unusual pairings
- Uses the app for idea generation, skips detailed steps

---

## 4. MVP Feature Requirements

### 4.1 Ingredient Detection via Photo Upload

**Owner:** ML/AI Engineer + Backend Architect
**Priority:** P0 — Critical

| Requirement | Detail |
|---|---|
| Photo capture | User takes a photo or selects from camera roll |
| API integration | OpenAI GPT-4o Vision analyzes the image |
| Structured output | Returns a list of detected ingredients with confidence scores |
| Multiple photos | Support 1–3 photos per session to capture full fridge contents |
| Response time | Detection completes within 5 seconds |

**Acceptance Criteria:**
- Given a well-lit fridge photo, the system detects ≥80% of visible ingredients
- Each ingredient returns with a name and confidence score (high/medium/low)
- Unrecognizable items are flagged as "unknown" rather than guessed

### 4.2 Ingredient Confirmation UI

**Owner:** Mobile Engineer + UI/UX Designer
**Priority:** P0 — Critical

| Requirement | Detail |
|---|---|
| Editable list | Detected ingredients displayed as removable chips/badges |
| Add manually | User can type additional ingredients not in the photo |
| Confidence indicators | Visual distinction between high/medium/low confidence items |
| Persistence | Ingredient list persists until user starts a new session |

**Acceptance Criteria:**
- User can remove any incorrectly detected ingredient with one tap
- User can add ingredients via a text input field
- Low-confidence items are visually distinct (different color or icon)

### 4.3 Skill Level Selection

**Owner:** Product Manager + UI/UX Designer
**Priority:** P0 — Critical

| Requirement | Detail |
|---|---|
| Three tiers | Beginner, Intermediate, Advanced |
| Persistent preference | Remembered across sessions (local storage) |
| Affects output | Directly influences recipe complexity and instruction detail |

**Skill Level Definitions:**

- **Beginner:** Simple techniques (boil, sauté, bake), under 30 min, detailed explanations for every step, no specialized equipment
- **Intermediate:** Moderate techniques (deglaze, braise, emulsify), 30–60 min, standard explanations, basic kitchen equipment assumed
- **Advanced:** Complex techniques (sous vide, fermentation, reduction sauces), any duration, concise instructions, assumes full kitchen competency

**Acceptance Criteria:**
- Skill level selection is required before recipe generation
- Selected level is saved locally and pre-selected on return visits

### 4.4 Dietary Restrictions & Allergies

**Owner:** Product Manager + Mobile Engineer + ML/AI Engineer
**Priority:** P0 — Critical

| Requirement | Detail |
|---|---|
| Restriction types | Vegetarian, Vegan, Gluten-Free, Dairy-Free, Nut-Free, Shellfish-Free, Halal, Kosher |
| Custom restrictions | Free-text field for unlisted allergies or preferences |
| Persistent preference | Saved locally, pre-loaded on return visits |
| Hard vs. soft constraints | Allergies are hard constraints (never violated); dietary preferences are soft (can be toggled per session) |
| Recipe filtering | Recipes must respect all active restrictions — no exceptions |
| Ingredient flagging | Detected ingredients that conflict with active restrictions are visually flagged |

**Acceptance Criteria:**
- User can select multiple dietary restrictions during onboarding or before recipe generation
- No generated recipe violates a hard constraint (allergy)
- Conflicting detected ingredients show a warning icon
- Restrictions are passed to both the recipe generation prompt and cache key

### 4.5 Recipe Generation

**Owner:** ML/AI Engineer + Backend Architect
**Priority:** P0 — Critical

| Requirement | Detail |
|---|---|
| Model | Ollama running Llama 3.1 8B locally on M3 MacBook Air |
| Output count | 3–5 recipes per request |
| Cuisine diversity | Recipes should span at least 2 different cuisines |
| Ingredient usage | Recipes should use a subset of confirmed ingredients (not necessarily all) |
| Missing ingredients | Each recipe may note up to 2 common pantry items assumed available (salt, oil, butter, etc.) |
| Skill matching | Recipe complexity matches the selected skill level |
| Structured format | Each recipe returns: title, cuisine, difficulty, prep time, cook time, ingredient list with quantities, and ordered steps |
| Response time | Full recipe set generated within 15 seconds |

**Acceptance Criteria:**
- Given 5+ confirmed ingredients, the system returns 3–5 valid recipes
- No recipe requires more than 2 ingredients not in the confirmed list
- Recipes are structurally complete (no missing steps or quantities)
- Cuisine diversity achieved — not all recipes from the same tradition

### 4.6 Step-by-Step Cook Mode

**Owner:** Mobile Engineer + UI/UX Designer
**Priority:** P0 — Critical

| Requirement | Detail |
|---|---|
| One step at a time | Large, readable text optimized for kitchen distance viewing |
| Navigation | Forward/back between steps, progress indicator |
| Timer integration | Steps with time durations show a tap-to-start timer |
| Screen wake lock | Screen stays on during active cooking |
| Ingredient callouts | Quantities highlighted or bolded within step text |

**Acceptance Criteria:**
- Each step is displayed individually with clear, large typography
- User can navigate between steps without losing position
- Timer starts with a single tap and provides audio notification on completion
- Screen does not dim or lock during cook mode

### 4.7 Result Cache Layer

**Owner:** Backend Architect + DevOps Engineer
**Priority:** P0 — Critical

| Requirement | Detail |
|---|---|
| Cache storage | Redis — runs in Docker alongside FastAPI |
| Cache key strategy | Hash of sorted ingredient set + skill level + active dietary restrictions |
| Similarity matching | Ingredients within 80% overlap of a cached set return cached recipes with a "Generate fresh" option |
| TTL | Cached recipe sets expire after 72 hours |
| Cache bypass | User can explicitly request fresh generation ("Generate new recipes" button) |
| Transparency | Cached results served seamlessly — no "this is cached" messaging unless user requests fresh |
| Invalidation | Cache entries invalidated when model version changes (QLoRA adapter updates) |

**User-Facing Behavior:**

- First scan with a new ingredient set → full Ollama generation (15s)
- Repeat scan with identical or near-identical ingredients → instant cached results (<500ms)
- User taps "Generate new recipes" → bypasses cache, runs fresh generation
- Different skill level with same ingredients → separate cache entry

**Acceptance Criteria:**
- Identical ingredient + skill level combination returns cached results in under 500ms
- 80%+ ingredient overlap triggers cache hit with a visible "Generate new recipes" option
- Cache miss gracefully falls through to live Ollama generation
- Redis persistence survives container restarts

### 4.8 Governance, Traceability & Audit

**Owner:** Backend Architect + ML/AI Engineer + QA Engineer
**Priority:** P0 — Critical

| Requirement | Detail |
|---|---|
| Request logging | Every API call (ingredient detection + recipe generation) logged with unique session ID |
| Input capture | Photos (hash only — not stored), detected ingredients, confirmed ingredients (post-edit), skill level |
| Output capture | Full model responses stored: raw ingredient detection JSON, raw recipe generation output |
| Prompt versioning | Every prompt template version-tagged; logs reference which prompt version produced each output |
| Model versioning | Ollama model name + tag logged per request (e.g., llama3.1:8b-instruct-q4_0) |
| Decision chain | End-to-end trace: photo hash → detected ingredients → user edits → confirmed list → prompt sent → recipes returned → user selection → cook session |
| Feedback linkage | Thumbs up/down on a recipe links back to the full decision chain for fine-tuning data |
| Safety audit | Any recipe flagged by a user as "dangerous" or "incorrect" triggers a traceable incident record |
| Retention policy | Audit logs retained for 90 days minimum; feedback-linked records retained indefinitely (fine-tuning dataset) |
| Storage | Structured logs in PostgreSQL (same engine in dev and production) |

**Audit Trail Schema (per session):**

```
session_id          UUID — unique per user session
timestamp           ISO 8601
photo_hashes        [hash1, hash2, ...] — SHA-256 of uploaded images
detection_model     "gpt-4o" + API version
detection_prompt_v  Prompt template version (e.g., "v1.2")
detected_items      [{name, confidence}, ...]
confirmed_items     [{name}, ...] — after user edits
removed_items       [{name}, ...] — items user deleted
added_items         [{name}, ...] — items user manually added
skill_level         "beginner" | "intermediate" | "advanced"
generation_model    "llama3.1:8b-instruct-q4_0"
generation_prompt_v Prompt template version
cache_hit           boolean — was this served from cache?
recipes_returned    [{id, title, cuisine, ...}, ...]
recipe_selected     recipe_id — which recipe user chose to cook
cook_completed      boolean
user_feedback       "thumbs_up" | "thumbs_down" | null
feedback_text       Optional free-text feedback
flagged_safety      boolean — user reported safety concern
```

**Acceptance Criteria:**
- Every session produces a complete audit trail record
- Any recipe can be traced back to its exact input ingredients, prompt, and model version
- Feedback records are queryable for fine-tuning dataset extraction
- Safety flags trigger a separate incident log entry
- Prompt version changes are tracked in a version registry

### 4.8 Dietary Restrictions & Allergy Filtering

**Owner:** ML/AI Engineer + Mobile Engineer
**Priority:** P0 — Critical

| Requirement | Detail |
|---|---|
| Restriction types | Common allergies (nuts, dairy, gluten, shellfish, eggs, soy) + dietary preferences (vegetarian, vegan, halal, kosher, keto, paleo) |
| Selection UI | Multi-select during onboarding, editable in settings |
| Persistent preference | Stored locally, sent with every recipe generation request |
| Prompt integration | Restrictions injected into Ollama recipe prompt — recipes must not include restricted ingredients |
| Allergen flagging | Any recipe containing a common allergen displays a visible warning badge |
| Override option | User can temporarily disable a restriction for a single session |

**Acceptance Criteria:**
- A user with "nut allergy" selected never receives recipes containing nuts or nut-derived ingredients
- Dietary preferences are respected in recipe generation (no meat in vegetarian recipes)
- Restrictions are included in the governance audit trail per session
- User can modify restrictions without losing other preferences

---

## 5. User Flow

```
1. LAUNCH → Home screen with "Scan Ingredients" CTA
2. CAPTURE → Camera opens, user photographs fridge contents (1–3 photos)
3. DETECT → Loading state while GPT-4o analyzes images
4. CONFIRM → Ingredient list displayed as editable chips
   ├── Remove incorrect items (tap X)
   ├── Add missing items (text input)
   ├── Conflicting items flagged if dietary restrictions active
   └── Confirm ingredients
5. PREFERENCES → Skill level + dietary restrictions (both remembered)
   ├── Skill: Beginner / Intermediate / Advanced
   └── Restrictions: multi-select + custom free-text
6. GENERATE → Loading state while Ollama generates recipes (or cache hit)
7. BROWSE → 3–5 recipe cards displayed with title, cuisine, time, difficulty
8. SELECT → Tap a recipe to see full detail (ingredients + all steps)
9. COOK → Enter cook mode (step-by-step, timers, wake lock)
10. COMPLETE → "Finished!" screen with thumbs up/down feedback
```

---

## 6. Non-Functional Requirements

### 6.1 Performance

| Metric | Target |
|---|---|
| Ingredient detection latency | < 5 seconds |
| Recipe generation latency (cache miss) | < 15 seconds |
| Recipe generation latency (cache hit) | < 500 milliseconds |
| Cache similarity lookup | < 100 milliseconds |
| App cold start | < 3 seconds |
| Cook mode step transition | Instant (< 100ms) |

### 6.2 Reliability

- Graceful degradation if Ollama is unreachable (clear error messaging)
- Retry logic on OpenAI API failures (up to 2 retries with exponential backoff)
- Offline cook mode: once recipes are loaded, cook mode works without network
- Redis cache failure falls through to live generation (never blocks the user)

### 6.3 Governance & Data Integrity

- Every session produces a complete, immutable audit trail record
- Audit logs are append-only — no updates or deletions to historical records
- Prompt version registry tracks all template changes with effective dates
- Safety-flagged sessions are escalated and retained separately
- Feedback data is exportable in a format suitable for QLoRA fine-tuning pipelines

### 6.3 Security

- OpenAI API key stored server-side only, never in the mobile app
- User photos processed and discarded — not stored on the server
- No user authentication required for MVP (anonymous usage)

### 6.5 Device Support

- iOS 16+ (iPhone and iPad) via App Store
- Android 12+ (phones and tablets) via Google Play Store
- React Native (Expo) — single codebase, ~95% code reuse
- Optimized for one-handed phone operation
- Tablet layouts adapt for larger screens (side-by-side ingredients + recipes)

---

## 7. Out of Scope (MVP)

The following are explicitly deferred:

| Feature | Rationale | Target Phase |
|---|---|---|
| Stripe integration + membership tiers | Monetization layer — Normal vs. Premium subscriptions, pricing TBD | Phase 2 |
| User accounts / auth | Required for Stripe, saved recipes, and tier enforcement | Phase 2 |
| Progress photo feedback | Premium-only feature — token cost per user is high, gated by Stripe tier | Phase 2 |
| Automated safety quarantine | Manual + automated review pipeline for flagged recipes | Phase 2 |
| QLoRA fine-tuning | Need real usage data before fine-tuning is valuable | Phase 2 |
| Saved/favorited recipes | Requires user accounts | Phase 2 |
| Voice-guided cook mode | Text-to-speech for steps — premium enhancement candidate | Phase 2 |
| Nutrition information | Adds complexity without validating core loop | Phase 3 |
| Shopping list generation | Nice-to-have, not core | Phase 3 |
| Social sharing | Growth feature, not core value | Phase 3 |
| Pantry/inventory management | Over-engineering for MVP | Phase 3 |

### Phase 2 Membership Model

**Two tiers (pricing TBD):**

| Feature | Normal | Premium |
|---|---|---|
| Ingredient photo detection | ✅ | ✅ |
| Recipe generation (3–5) | ✅ | ✅ |
| Dietary restrictions | ✅ | ✅ |
| Step-by-step cook mode | ✅ | ✅ |
| Progress photo feedback | ❌ | ✅ |
| Voice-guided cook mode | ❌ | ✅ (candidate) |
| Saved/favorited recipes | Limited | Unlimited |
| Priority generation queue | ❌ | ✅ (candidate) |

**Stripe Integration Requirements (Phase 2):**

- Stripe Checkout for subscription creation and management
- Stripe Customer Portal for self-service plan changes and cancellation
- Stripe Webhooks for real-time payment event processing (subscription created, cancelled, payment failed, invoice paid)
- Backend middleware gate: premium endpoints check user tier before processing
- Graceful degradation: if Stripe is unreachable, default to normal tier (never block core features)
- Token budget tracking per user: enables cost monitoring and per-tier usage caps

---

## 8. Success Metrics

### 8.1 MVP Validation Metrics

| Metric | Target | How Measured |
|---|---|---|
| Ingredient detection accuracy | ≥ 80% of visible items correctly identified | Manual QA testing with 20 fridge photos |
| Recipe relevance | ≥ 4/5 generated recipes are cookable with listed ingredients | Manual review |
| End-to-end completion rate | ≥ 60% of sessions reach cook mode | Local analytics logging |
| Recipe generation quality | ≥ 3/5 average user satisfaction | Post-cook thumbs up/down |
| Total session time (scan → cook start) | < 90 seconds | Local timing |

### 8.2 Post-MVP Growth & Monetization Metrics

- Daily active users (DAU) and monthly active users (MAU)
- Recipes cooked per user per week
- Premium conversion rate (Normal → Premium subscription)
- Monthly recurring revenue (MRR) via Stripe
- Premium feature usage rate (progress photos per premium user)
- Token cost per user (Normal vs. Premium)
- Churn rate by tier
- Retention: 7-day and 30-day return rate by tier

---

## 9. Technical Constraints

| Constraint | Detail |
|---|---|
| Self-hosted LLM (dev) | Ollama on MacBook Air M3 (16GB RAM) — Llama 3.1 8B |
| LLM abstraction layer | Provider-agnostic interface: Ollama (dev) → AWS ECS/SageMaker (prod) |
| Ollama runs outside Docker | Metal GPU acceleration requires native execution (dev only) |
| FastAPI in Docker | Backend container calls Ollama at host.docker.internal:11434 |
| Redis in Docker | Cache layer for recipe results, co-located with FastAPI |
| PostgreSQL in Docker | Governance/traceability/session storage — same engine dev and prod |
| OpenAI API dependency | Ingredient detection requires internet + valid API key |
| OpenAI API budget | $500/month ceiling during development phase |
| Cross-platform mobile | React Native (Expo) — iOS 16+ and Android 12+ |

---

## 10. Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Poor ingredient detection from dark/cluttered fridge photos | High | High | Allow manual addition/removal, support multiple photos, provide photo tips |
| Llama 3.1 8B generates low-quality or incomplete recipes | Medium | High | Rigorous prompt engineering, structured output enforcement, fallback to simpler prompts |
| Ollama latency on M3 Air exceeds 15s | Low | Medium | Streaming responses, show recipes as they complete |
| OpenAI API costs exceed budget | Medium | Medium | Cache common ingredient lists, batch multiple photos per call |
| User abandons flow before cooking | Medium | Medium | Minimize steps, keep UI fast and frictionless |
| Cache serves stale or low-quality recipes | Medium | Medium | 72-hour TTL, cache invalidation on model updates, "Generate fresh" escape hatch |
| Cache similarity matching returns irrelevant results | Low | High | Conservative 80% threshold, always show ingredients used in cached recipes |
| Audit log storage grows unbounded | Low | Low | 90-day retention policy with automated cleanup, PostgreSQL partitioning |
| Recipe causes allergic reaction or safety issue | Low | Critical | Governance trail enables rapid investigation, safety flag system, allergen disclaimer in UI |
| Prompt version drift causes quality regression | Medium | High | Prompt version registry, A/B comparison before deploying new prompt versions |

---

## 11. Release Plan

| Milestone | Description | Timeline |
|---|---|---|
| Iteration 1 | Infrastructure: Docker + FastAPI + Ollama + Redis connectivity | Week 1 |
| Iteration 2 | Ingredient detection: OpenAI GPT-4o endpoint + audit logging foundation | Week 2 |
| Iteration 3 | Recipe generation: Ollama integration + structured output + result cache | Week 3 |
| Iteration 4 | Cook mode: Step-by-step API + session management + governance trail | Week 4 |
| Mobile Integration | React Native (Expo) frontend connecting to all endpoints, iOS + Android | Weeks 5–6 |
| QA + Polish | Testing, bug fixes, UX refinement, cache tuning, audit verification | Week 7 |
| Internal Beta | Testflight distribution | Week 8 |

---

## 12. Resolved Decisions (from Open Questions)

| # | Question | Decision |
|---|---|---|
| 1 | Dietary restrictions/allergies in MVP? | **Yes — P0.** Core to recipe generation. Add to skill selection flow. |
| 2 | OpenAI API budget ceiling? | **$500/month** during development phase. |
| 3 | Cost per serving on recipes? | **No.** User already has ingredients — adds no value. |
| 4 | Voice-guided cook mode (TTS)? | **Deferred to Phase 2** as an enhancement. |
| 5 | Cache hit indicator to users? | **No indicator.** Serve cached results seamlessly. |
| 6 | Safety flag escalation path? | **Phase 2.** Automated quarantine + manual review pipeline deferred. MVP logs safety flags for later review. |
| 7 | Audit log access method? | **Admin API endpoint.** Accessible for QLoRA data pipeline extraction. |
| 8 | Cache similarity weighting? | **Spices weighted higher than proteins.** Proteins are often interchangeable across dishes; spices define cuisine. Add an `interchangeable` flag to ingredient categorization. |

---

## Approvals

| Role | Name | Status |
|---|---|---|
| Product Manager | — | ✅ Author |
| UI/UX Designer | — | ⬜ Pending |
| Backend Architect | — | ⬜ Pending |
| ML/AI Engineer | — | ⬜ Pending |
| Mobile Engineer | — | ⬜ Pending |
| DevOps Engineer | — | ⬜ Pending |
| QA Engineer | — | ⬜ Pending |
| CI/CD Engineer | — | ⬜ Pending |
