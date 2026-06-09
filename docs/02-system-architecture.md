# Professional Chef Agent — System Architecture Document

**Version:** 2.0
**Date:** June 8, 2026
**Author:** Backend Architect, DevOps Engineer, ML/AI Engineer
**Status:** Draft — Pending Stakeholder Review

**Revision Notes (v2.0):**
- Changed from SwiftUI (iOS-only) to React Native with Expo (iOS + Android)
- Added LLM Abstraction Layer for swappable providers (local Ollama → AWS production)
- Replaced SQLite with PostgreSQL for dev/prod parity

---

## 1. Architecture Overview

Professional Chef Agent follows a **client-server architecture** with a clear separation between a cross-platform React Native frontend and a Python backend. The backend orchestrates all AI interactions, caching, and governance logging. Two AI providers serve distinct roles: OpenAI handles vision tasks (ingredient detection) while a self-hosted LLM handles text generation (recipes), accessed through a provider-agnostic abstraction layer.

**Architecture Principles:**

- React Native (Expo) delivers a single codebase to iOS and Android
- Mobile app is a pure API consumer — no direct AI provider calls
- All secrets (API keys) live server-side exclusively
- LLM Abstraction Layer enables zero-code switching between local Ollama (dev) and AWS (prod)
- Docker encapsulates the backend API, Redis, PostgreSQL, and supporting infrastructure
- Ollama runs natively on macOS during development for Metal GPU acceleration
- Every AI interaction is logged to PostgreSQL for governance and future fine-tuning
- Cache-first strategy minimizes redundant generation
- Dev and production environments use identical database engines (PostgreSQL)

---

## 2. Component Inventory

### 2.1 Mobile Client (React Native + Expo)

| Component | Responsibility |
|---|---|
| Camera Module | Expo Camera + ImagePicker, supports 1–3 images, iOS + Android |
| Ingredient Confirmation View | Editable chip list with confidence indicators, manual add/remove |
| Preferences View | Skill level selector + dietary restriction multi-select, persisted locally |
| Recipe Browser | Card-based display of 3–5 generated recipes |
| Cook Mode | Full-screen step-by-step view with timers, wake lock, progress navigation |
| API Client Layer | Axios/fetch service layer consuming FastAPI endpoints |
| Local Storage | AsyncStorage for skill level and dietary preferences |
| Push Notifications | Expo Notifications for timer alerts (background) |

**Platform Support:**
- iOS 16+ via App Store
- Android 12+ via Google Play Store
- Shared codebase: ~95% code reuse between platforms
- Platform-specific: camera permissions, haptic feedback (iOS), notification channels (Android)

**Why React Native + Expo:**
- Reuses existing React component library and design tokens from prior work
- Single codebase for iOS + Android eliminates maintaining two native apps
- Expo provides managed camera, image picker, notifications, and OTA updates
- EAS Build handles app store submissions for both platforms

### 2.2 FastAPI Backend (Dockerized)

| Service | Responsibility | Dependencies |
|---|---|---|
| API Gateway / Router | Request routing, validation, auth (future), rate limiting | — |
| Ingredient Detection Service | Receives photos, calls OpenAI GPT-4o Vision, returns structured ingredient list | OpenAI API |
| Ingredient Categorizer | Classifies ingredients into categories (protein, produce, spice, pantry staple) with interchangeable flags | — |
| Recipe Generation Service | Builds prompts from confirmed ingredients + preferences, calls LLM via abstraction layer, parses structured output | LLM Abstraction Layer, Cache Service |
| LLM Abstraction Layer | Provider-agnostic interface to LLM backends (Ollama, AWS ECS, SageMaker) | Configured via environment variable |
| Cache Service | Manages Redis cache — exact match lookup, weighted similarity search, TTL, invalidation | Redis |
| Cook Session Service | Serves step-by-step recipe data, manages active cooking sessions | — |
| Audit & Governance Service | Logs every request/response in the decision chain, manages prompt version registry | PostgreSQL |
| Admin API | Exposes audit logs and feedback data for QLoRA pipeline extraction | PostgreSQL |

### 2.3 LLM Abstraction Layer

The abstraction layer is the critical architectural piece enabling the local→cloud transition without code changes.

**Common Interface:**

```python
class LLMProvider(ABC):
    @abstractmethod
    async def generate(self, prompt: str, config: GenerationConfig) -> LLMResponse:
        """Generate text from prompt. Returns structured response."""
        pass

    @abstractmethod
    async def health_check(self) -> bool:
        """Check if the provider is reachable and healthy."""
        pass

    @abstractmethod
    def model_info(self) -> ModelMetadata:
        """Return model name, version, quantization for audit logging."""
        pass
```

**Provider Implementations:**

| Provider | Class | Config | When Used |
|---|---|---|---|
| Ollama (local) | `OllamaProvider` | `OLLAMA_HOST=host.docker.internal:11434` | Development on M3 Air |
| AWS ECS | `AWSECSProvider` | `ECS_ENDPOINT=https://...` | Staging / early production |
| AWS SageMaker | `AWSSageMakerProvider` | `SAGEMAKER_ENDPOINT=https://...` | Production at scale |

**Environment-driven selection:**

```python
LLM_PROVIDER=ollama        # Development
LLM_PROVIDER=aws_ecs       # Staging
LLM_PROVIDER=aws_sagemaker # Production
```

**What stays constant across providers:**
- Prompt templates (same prompt, same expected output)
- Response parsing logic
- Audit logging (model_info() returns provider-specific metadata)
- Cache key computation (model-version included — cache invalidates on provider switch)

### 2.4 Redis (Dockerized)

| Aspect | Detail |
|---|---|
| Purpose | Recipe result cache |
| Key format | `recipes:{sha256(sorted_ingredients + skill_level + dietary_restrictions)}` |
| Value format | JSON-serialized recipe set with metadata |
| TTL | 72 hours |
| Similarity index | Secondary index of ingredient sets for weighted overlap queries |
| Persistence | AOF (Append Only File) enabled — survives container restarts |
| Failure mode | Transparent fallthrough to live LLM generation |

### 2.5 PostgreSQL (Dockerized, volume-mounted)

| Aspect | Detail |
|---|---|
| Purpose | Governance audit trail, feedback storage, prompt version registry, session data |
| Version | PostgreSQL 16 |
| Dev access | `localhost:5432` from host, `postgres:5432` from Docker network |
| Prod target | AWS RDS PostgreSQL |
| Migrations | Alembic for schema versioning |
| Connection | SQLAlchemy async with asyncpg driver |
| Backup (dev) | Volume-mounted to host filesystem |
| Backup (prod) | RDS automated snapshots |

**Key Tables:**

| Table | Purpose |
|---|---|
| sessions | Top-level session record with UUID, timestamps |
| detection_logs | Ingredient detection results per session |
| generation_logs | Recipe generation inputs/outputs per session |
| cook_sessions | Active cooking session tracking |
| feedback | User thumbs up/down linked to session chain |
| safety_flags | Flagged recipes with severity and description |
| prompt_versions | Prompt template registry with versioning |
| ingredient_categories | Category definitions with weights and interchangeable groups |

### 2.6 OpenAI GPT-4o Vision (External)

| Aspect | Detail |
|---|---|
| Purpose | Ingredient detection from fridge photos |
| Endpoint | `POST https://api.openai.com/v1/chat/completions` |
| Model | `gpt-4o` |
| Input | Base64-encoded image(s) + structured detection prompt |
| Output | JSON array of `{name, confidence, category}` |
| Budget | $500/month development ceiling |
| Retry policy | 2 retries with exponential backoff (1s, 3s) |
| Key storage | Environment variable in Docker, never in mobile app |

### 2.7 Ollama + Llama 3.1 8B (Development Only — Native macOS)

| Aspect | Detail |
|---|---|
| Purpose | Recipe generation during development |
| Host | MacBook Air M3, 16GB RAM |
| Execution | Native macOS process — Metal GPU acceleration |
| API | `http://localhost:11434/api/generate` |
| Docker access | `http://host.docker.internal:11434` from containers |
| Model | `llama3.1:8b-instruct-q4_0` (quantized for 16GB) |
| Future | QLoRA adapter loaded via Ollama Modelfile |
| Concurrency | Single-request — queue at API layer if needed |
| Production replacement | AWS ECS or SageMaker running the same model + adapter |

---

## 3. Network Topology

### 3.1 Development (Local M3 Air)

```
┌─────────────────────────────────────────────────────────────────┐
│  MacBook Air M3 (16GB)                                          │
│                                                                  │
│  ┌──────────────────────────────────────────────┐               │
│  │  Docker Network (bridge: chef-network)        │               │
│  │                                                │               │
│  │  ┌──────────────┐    ┌─────────────────────┐  │               │
│  │  │  FastAPI      │    │  Redis               │  │               │
│  │  │  :8000        │◄──►│  :6379               │  │               │
│  │  │               │    └─────────────────────┘  │               │
│  │  │               │                              │               │
│  │  │               │    ┌─────────────────────┐  │               │
│  │  │               │──► │  PostgreSQL          │  │               │
│  │  │               │    │  :5432               │  │               │
│  │  └───────┬───────┘    └─────────────────────┘  │               │
│  │          │                                      │               │
│  └──────────┼──────────────────────────────────────┘               │
│             │ host.docker.internal:11434                           │
│             ▼                                                      │
│  ┌──────────────────┐                                              │
│  │  Ollama (native)  │                                              │
│  │  Llama 3.1 8B     │                                              │
│  │  :11434            │                                              │
│  └──────────────────┘                                              │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
         │ :8000                          │ HTTPS
         ▼                                ▼
  ┌────────────────┐              ┌──────────────┐
  │  React Native   │              │  OpenAI API   │
  │  (Expo Dev)     │              │  (gpt-4o)     │
  │  iOS + Android  │              └──────────────┘
  └────────────────┘
```

### 3.2 Production (AWS)

```
┌──────────────────────────────────────────────────────────────────┐
│  AWS VPC                                                          │
│                                                                    │
│  ┌─────────────────┐    ┌─────────────────┐   ┌──────────────┐  │
│  │  ECS Fargate     │    │  ElastiCache     │   │  RDS          │  │
│  │  FastAPI          │◄──►│  Redis           │   │  PostgreSQL   │  │
│  │  (Auto-scaling)   │    │  (Cluster)       │   │  (Multi-AZ)   │  │
│  └────────┬──────────┘    └─────────────────┘   └──────────────┘  │
│           │                                                        │
│           ▼                                                        │
│  ┌─────────────────┐                                              │
│  │  ECS Fargate     │     or     ┌─────────────────┐             │
│  │  Ollama + Model  │            │  SageMaker       │             │
│  │  (GPU instance)  │            │  Endpoint         │             │
│  └─────────────────┘            └─────────────────┘             │
│                                                                    │
│  ┌─────────────────┐    ┌─────────────────┐                      │
│  │  ECR             │    │  ALB             │                      │
│  │  Container Reg.  │    │  Load Balancer   │                      │
│  └─────────────────┘    └────────┬────────┘                      │
│                                   │                                │
└───────────────────────────────────┼────────────────────────────────┘
                                    │ HTTPS
                    ┌───────────────┼───────────────┐
                    ▼               ▼               ▼
             ┌──────────┐   ┌──────────┐   ┌──────────────┐
             │  iOS App   │   │ Android  │   │  OpenAI API   │
             │ App Store  │   │ Play St. │   │  (gpt-4o)     │
             └──────────┘   └──────────┘   └──────────────┘
```

---

## 4. Data Models

### 4.1 Ingredient

```python
class IngredientCategory(str, Enum):
    PROTEIN = "protein"           # weight: 0.8x — often interchangeable
    PRODUCE = "produce"           # weight: 1.0x — standard
    SPICE = "spice"               # weight: 1.5x — defines cuisine
    DAIRY = "dairy"               # weight: 1.0x
    GRAIN = "grain"               # weight: 0.8x
    PANTRY_STAPLE = "pantry"      # weight: 0.3x — assumed available

class Ingredient(BaseModel):
    name: str
    confidence: Literal["high", "medium", "low"]
    category: IngredientCategory
    interchangeable: bool = False
    interchangeable_group: Optional[str] = None  # e.g., "poultry", "allium"
```

### 4.2 User Preferences

```python
class SkillLevel(str, Enum):
    BEGINNER = "beginner"
    INTERMEDIATE = "intermediate"
    ADVANCED = "advanced"

class DietaryRestriction(str, Enum):
    VEGETARIAN = "vegetarian"
    VEGAN = "vegan"
    GLUTEN_FREE = "gluten_free"
    DAIRY_FREE = "dairy_free"
    NUT_FREE = "nut_free"
    SHELLFISH_FREE = "shellfish_free"
    HALAL = "halal"
    KOSHER = "kosher"

class UserPreferences(BaseModel):
    skill_level: SkillLevel
    dietary_restrictions: list[DietaryRestriction] = []
    custom_restrictions: Optional[str] = None
```

### 4.3 Recipe

```python
class RecipeIngredient(BaseModel):
    name: str
    quantity: str
    unit: str
    from_detected: bool
    assumed_available: bool

class RecipeStep(BaseModel):
    step_number: int
    instruction: str
    duration_minutes: Optional[int] = None
    technique: Optional[str] = None

class Recipe(BaseModel):
    id: str                       # UUID
    title: str
    cuisine: str
    difficulty: SkillLevel
    prep_time_minutes: int
    cook_time_minutes: int
    total_time_minutes: int
    servings: int
    ingredients: list[RecipeIngredient]
    steps: list[RecipeStep]
    missing_ingredients: list[str]
    dietary_tags: list[DietaryRestriction]
```

### 4.4 Audit Record

```python
class AuditRecord(BaseModel):
    session_id: str               # UUID
    timestamp: datetime
    photo_hashes: list[str]       # SHA-256, images not stored
    detection_model: str          # "gpt-4o-2024-xx-xx"
    detection_prompt_version: str
    detected_ingredients: list[Ingredient]
    confirmed_ingredients: list[str]
    removed_ingredients: list[str]
    added_ingredients: list[str]
    skill_level: SkillLevel
    dietary_restrictions: list[DietaryRestriction]
    generation_model: str         # From LLMProvider.model_info()
    generation_provider: str      # "ollama" | "aws_ecs" | "aws_sagemaker"
    generation_prompt_version: str
    cache_hit: bool
    recipes_returned: list[str]
    recipe_selected: Optional[str]
    cook_completed: bool
    user_feedback: Optional[Literal["thumbs_up", "thumbs_down"]]
    feedback_text: Optional[str]
    flagged_safety: bool
```

---

## 5. Cache Architecture

### 5.1 Cache Key Strategy

```
Primary key:   SHA-256(sorted(confirmed_ingredients) + skill_level + sorted(dietary_restrictions))
Lookup:        O(1) exact match via Redis GET

Similarity:    Stored as Redis SET per cache entry with weighted ingredient members
               Spices:         1.5x weight
               Produce/Dairy:  1.0x weight
               Proteins/Grain: 0.8x weight (interchangeable flag considered)
               Pantry staples: 0.3x weight
```

### 5.2 Similarity Matching Algorithm

```
1. Incoming ingredient set categorized and weighted
2. Scan recent cache entries (bounded to last 100 entries)
3. Compute weighted Jaccard similarity:
   - Intersection: sum of weights for matching ingredients
   - Union: sum of weights for all unique ingredients across both sets
   - Score = weighted_intersection / weighted_union
4. If interchangeable flag set, items in same group count as match
5. Score >= 0.80 AND same skill + dietary = cache hit
6. Return highest-scoring match
```

### 5.3 Cache Invalidation

| Trigger | Action |
|---|---|
| TTL expiry (72 hours) | Auto-delete by Redis |
| Model version change | Flush all cache entries |
| QLoRA adapter deploy | Flush all cache entries |
| LLM provider switch | Flush all cache entries (different provider = different outputs) |
| Manual admin action | Admin API endpoint to flush specific or all entries |

---

## 6. Governance Architecture

### 6.1 Prompt Version Registry (PostgreSQL)

```sql
CREATE TABLE prompt_versions (
    id SERIAL PRIMARY KEY,
    prompt_name VARCHAR(100) NOT NULL,  -- 'ingredient_detection' | 'recipe_generation'
    version VARCHAR(20) NOT NULL,        -- 'v1.0', 'v1.1'
    template TEXT NOT NULL,
    effective_date TIMESTAMPTZ NOT NULL,
    deprecated_date TIMESTAMPTZ,
    notes TEXT,
    UNIQUE(prompt_name, version)
);
```

### 6.2 Feedback to Fine-Tuning Pipeline

```
Admin API: GET /admin/v1/training-data?min_feedback=thumbs_up&limit=1000

Returns:
[
  {
    "input": {
      "ingredients": [...],
      "skill_level": "intermediate",
      "dietary": ["gluten_free"],
      "prompt_version": "v1.2"
    },
    "output": {
      "recipes": [...]
    },
    "feedback": "thumbs_up",
    "model_version": "llama3.1:8b-instruct-q4_0",
    "provider": "ollama"
  }
]
```

### 6.3 Safety Flag Flow (MVP)

In MVP, safety flags are logged but not automatically acted upon:

```
1. User taps "Report Issue" on a recipe
2. API creates safety_flag record linked to full audit chain
3. Flag stored in PostgreSQL with severity and description
4. Admin API: GET /admin/v1/safety-flags returns all flagged sessions
5. Phase 2: Automated quarantine removes flagged recipes from cache
```

---

## 7. Docker Infrastructure

### 7.1 docker-compose.yml Structure

```yaml
services:
  api:
    build: ./backend
    ports:
      - "8000:8000"
    environment:
      - OPENAI_API_KEY=${OPENAI_API_KEY}
      - LLM_PROVIDER=ollama
      - OLLAMA_HOST=host.docker.internal:11434
      - REDIS_URL=redis://redis:6379
      - DATABASE_URL=postgresql+asyncpg://chef:chef_dev@postgres:5432/chef_agent
    volumes:
      - ./backend:/app
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_started
    extra_hosts:
      - "host.docker.internal:host-gateway"

  postgres:
    image: postgres:16-alpine
    ports:
      - "5432:5432"
    environment:
      - POSTGRES_USER=chef
      - POSTGRES_PASSWORD=chef_dev
      - POSTGRES_DB=chef_agent
    volumes:
      - pg-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U chef -d chef_agent"]
      interval: 5s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    ports:
      - "6379:6379"
    volumes:
      - redis-data:/data
    command: redis-server --appendonly yes

volumes:
  pg-data:
  redis-data:
```

### 7.2 Production docker-compose.prod.yml (Override)

```yaml
services:
  api:
    environment:
      - LLM_PROVIDER=aws_ecs  # or aws_sagemaker
      - ECS_ENDPOINT=${ECS_ENDPOINT}
      - AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
      - AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
      - DATABASE_URL=postgresql+asyncpg://${RDS_USER}:${RDS_PASS}@${RDS_HOST}:5432/chef_agent
      - REDIS_URL=redis://${ELASTICACHE_HOST}:6379
    extra_hosts: []  # No host.docker.internal needed in prod
```

### 7.3 Makefile Targets

```makefile
setup:       Install Ollama, pull Llama 3.1 8B, build Docker images, run migrations
dev:         Start docker-compose + Ollama in background
stop:        Stop all services
test:        Run test suite inside Docker
logs:        Tail FastAPI logs
migrate:     Run Alembic database migrations
cache:       Show Redis cache stats
audit:       Query recent audit log entries
reset:       Flush cache + reset test database
db-shell:    Open psql shell to local PostgreSQL
```

### 7.4 Ollama Setup (Development Only — Native macOS)

```bash
# One-time setup
brew install ollama
ollama pull llama3.1:8b-instruct-q4_0

# Start server
ollama serve

# Verify
curl http://localhost:11434/api/tags
```

---

## 8. API Endpoint Summary

| Method | Endpoint | Service | Description |
|---|---|---|---|
| POST | /api/v1/detect | Ingredient Detection | Upload 1–3 photos, returns ingredient list |
| POST | /api/v1/confirm | Ingredient Confirmation | Submit edited ingredient list |
| POST | /api/v1/generate | Recipe Generation | Generate recipes from ingredients + preferences |
| GET | /api/v1/recipes/{id} | Recipe Detail | Get full recipe by ID |
| GET | /api/v1/cook/{recipe_id}/steps | Cook Session | Get step-by-step cook mode data |
| POST | /api/v1/feedback | Feedback | Submit thumbs up/down + optional text |
| POST | /api/v1/safety-flag | Safety | Flag a recipe as dangerous/incorrect |
| GET | /api/v1/health | Health Check | Service health + LLM + Redis + PostgreSQL connectivity |
| GET | /admin/v1/audit-logs | Admin | Query audit trail (QLoRA pipeline) |
| GET | /admin/v1/training-data | Admin | Export feedback-linked data for fine-tuning |
| GET | /admin/v1/safety-flags | Admin | List all safety-flagged sessions |
| GET | /admin/v1/cache-stats | Admin | Redis cache hit rates and storage |
| DELETE | /admin/v1/cache | Admin | Flush cache (model version updates) |

---

## 9. Security Considerations

| Concern | MVP Mitigation | Production Mitigation |
|---|---|---|
| OpenAI API key | Docker env var, never in mobile app | AWS Secrets Manager |
| Photo privacy | Processed in-memory, only SHA-256 hash in audit log | Same + S3 lifecycle policies |
| Admin API access | Localhost-only binding | API key + IAM role-based access |
| Database credentials | Docker env var | RDS IAM auth + Secrets Manager |
| Network exposure | FastAPI on local network only | ALB + WAF + private subnets |
| Input validation | Pydantic models on all endpoints | Same + rate limiting per client |
| Mobile app secrets | No secrets in app bundle | Same — all server-side |
| Stripe keys (Phase 2) | N/A — no Stripe in MVP | Secret key in Secrets Manager; publishable key only in mobile app; webhook signature verification on all events |
| User auth (Phase 2) | N/A — anonymous usage | JWT with refresh tokens; bcrypt password hashing; rate-limited auth endpoints |
| Payment data | N/A | Never touches our servers — Stripe Checkout handles all card input |

---

## 10. Phase 2 Architecture: Stripe & Membership Tiers

### 10.1 Membership Model

| Tier | Price | Features | Token Budget |
|---|---|---|---|
| Normal | TBD | Core loop (detect → recipes → cook mode) | Standard |
| Premium | TBD | Core loop + progress photo feedback + voice cook mode + unlimited saved recipes | Higher per-user allocation |

### 10.2 Stripe Integration Components

| Component | Purpose |
|---|---|
| Stripe Checkout | Subscription creation with hosted payment page |
| Stripe Customer Portal | Self-service plan changes, payment method updates, cancellation |
| Stripe Webhooks | Real-time event processing for subscription lifecycle |
| Membership Middleware | FastAPI dependency that checks user tier before premium endpoints |
| Token Usage Tracker | Per-user token consumption logging linked to audit trail |

### 10.3 Stripe Webhook Events to Handle

| Event | Action |
|---|---|
| `checkout.session.completed` | Create user account, set tier to Premium |
| `customer.subscription.updated` | Update tier (upgrade/downgrade) |
| `customer.subscription.deleted` | Downgrade to Normal tier |
| `invoice.payment_failed` | Grace period → downgrade if unresolved |
| `invoice.paid` | Confirm active subscription, reset billing cycle |

### 10.4 Premium Endpoint Gating

```python
# FastAPI dependency for premium-only endpoints
async def require_premium(user: User = Depends(get_current_user)):
    if user.membership_tier != MembershipTier.PREMIUM:
        raise HTTPException(
            status_code=403,
            detail="Premium membership required for this feature"
        )
    return user

# Usage on premium endpoints
@router.post("/api/v1/cook/{recipe_id}/progress-photo")
async def analyze_progress_photo(
    recipe_id: str,
    photo: UploadFile,
    user: User = Depends(require_premium)  # Tier gate
):
    ...
```

### 10.5 Phase 2 Data Models

```python
class MembershipTier(str, Enum):
    NORMAL = "normal"
    PREMIUM = "premium"

class User(BaseModel):
    id: str                          # UUID
    email: str
    stripe_customer_id: Optional[str]
    membership_tier: MembershipTier
    subscription_status: str         # "active", "past_due", "cancelled"
    token_usage_current_period: int  # Tokens consumed this billing cycle
    created_at: datetime

class TokenUsageLog(BaseModel):
    user_id: str
    session_id: str
    endpoint: str                    # Which premium feature consumed tokens
    tokens_used: int
    provider: str                    # "openai" for vision calls
    cost_estimate_usd: float
    timestamp: datetime
```

### 10.6 Phase 2 Database Tables (Additions)

| Table | Purpose |
|---|---|
| users | User accounts with email, auth, Stripe customer ID |
| memberships | Tier, subscription status, Stripe subscription ID |
| token_usage | Per-user, per-session token consumption log |
| stripe_events | Raw webhook event log for debugging and reconciliation |

---

## 11. AWS Production Architecture (Future)

| Component | AWS Service | Notes |
|---|---|---|
| Container registry | ECR | FastAPI + Ollama images |
| API hosting | ECS Fargate | Auto-scaling, no server management |
| LLM hosting | ECS Fargate (GPU) or SageMaker | Depends on scale/cost tradeoff |
| Load balancer | ALB | HTTPS termination, health checks |
| Database | RDS PostgreSQL | Multi-AZ, automated backups |
| Cache | ElastiCache Redis | Cluster mode for production scale |
| Secrets | Secrets Manager | API keys, DB credentials, Stripe keys |
| Monitoring | CloudWatch + X-Ray | Logs, metrics, distributed tracing |
| CDN | CloudFront | Static assets for mobile app |
| CI/CD | CodePipeline + CodeBuild | Or GitHub Actions → ECR → ECS |
| Payments | Stripe (external) | Webhooks via ALB → FastAPI |
| Auth | Cognito or custom JWT | User identity + session management |

---

## 12. Migration Path: Local → AWS

| Phase | LLM_PROVIDER | Database | Cache | Notes |
|---|---|---|---|---|
| Development | `ollama` (local M3) | PostgreSQL (Docker) | Redis (Docker) | Current state |
| Staging | `aws_ecs` | RDS PostgreSQL | ElastiCache Redis | Validate cloud infra |
| Production | `aws_ecs` or `aws_sagemaker` | RDS PostgreSQL (Multi-AZ) | ElastiCache Redis (Cluster) | Full production |

**What changes between environments:**
- Environment variables only (LLM_PROVIDER, connection strings)
- No code changes required
- Alembic migrations run against RDS with same schema
- Cache invalidates on provider switch (different model outputs)

**What stays the same:**
- FastAPI application code
- React Native mobile app (just points to different API URL)
- Prompt templates
- Audit logging logic
- All data models

---

## Approvals

| Role | Name | Status |
|---|---|---|
| Backend Architect | — | ✅ Author |
| DevOps Engineer | — | ✅ Co-author |
| ML/AI Engineer | — | ✅ Co-author |
| Product Manager | — | ⬜ Pending |
| UI/UX Designer | — | ⬜ Pending |
| QA Engineer | — | ⬜ Pending |
| CI/CD Engineer | — | ⬜ Pending |
