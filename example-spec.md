# example-spec.md — Example phased spec for cc-orchestrate.sh
#
# Copy and adapt this file for your own builds.
# Each phase runs independently. Metadata lines before '---' configure
# the executor. The instruction block after '---' is the Claude Code prompt.

## Phase 1: Data Models
model: fast
max_turns: 15
timeout: 200
verify: python3 -c "from myapp.models import User, Profile; print('Models OK')"
---
Create the following Pydantic v2 models in a file called models.py:

1. User model with fields: id (int), name (str), email (EmailStr), 
   avatar_url (str | None), created_at (datetime)
2. Profile model with fields: id (int), user_id (int), bio (str | None),
   theme (str, default='light'), notifications_enabled (bool, default=True)

Use pydantic.BaseModel and pydantic.EmailStr. Export both from the module.

## Phase 2: Service Layer
model: exact
max_turns: 25
timeout: 400
verify: python3 -c "from myapp.services import UserService; print('Service OK')"
---
Implement UserService class in services.py with these async methods:

- create_user(name, email) -> User: creates user, returns model
- get_user(user_id) -> User | None: fetches by ID
- update_profile(user_id, **fields) -> Profile: updates profile fields
- delete_user(user_id) -> bool: soft-delete (sets deleted_at)

Use SQLAlchemy async session for persistence. The file models.py from Phase 1 
contains the ORM models. The database URL is read from DATABASE_URL env var.

## Phase 3: API Routes
model: exact
max_turns: 20
timeout: 300
verify: python3 -c "from myapp.routes import router; print('Routes OK')"
---
Create FastAPI router in routes.py with these endpoints:

POST /api/users — create user (body: name, email)
GET  /api/users/{user_id} — get user
PATCH /api/users/{user_id}/profile — update profile
DELETE /api/users/{user_id} — delete user

Use the UserService from services.py. Return proper HTTP status codes.
Include error handling for 404 (not found) and 422 (validation error).

## Phase 4: Tests
model: fast
max_turns: 15
timeout: 200
skip: true
---
Create pytest tests in tests/ directory covering:

- test_create_user: valid and invalid email
- test_get_user: existing and non-existing
- test_update_profile: partial update
- test_delete_user: soft delete verification

Use pytest-asyncio and httpx.AsyncClient for API testing.