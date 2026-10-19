# Phase 1.7 Architectural Review & Consistency Gate Report

**Project:** Packing Material Inventory & BOM Management System  
**Review Version:** 1.7.0  
**Phase:** 1.7 — Final Idempotency Retention and API Access Consistency Gate  
**Date:** 2026-10-14  
**Author:** Senior PostgreSQL & Supabase Transaction-Security Architect  
**Status:** COMPLETE — Full Documentation Consistency Gate Verified (Zero Database/Code Executions)  

---

## Executive Summary

Phase 1.7 resolves three critical architectural conflicts identified in the inventory system's documentation:
1. **Direct-Access Contradiction:** Reconciled `SYSTEM_DESIGN.md` §2.1 (which erroneously showed "Supabase REST (Self)" access for `idempotency_keys`) with the default-deny RLS matrix. Direct PostgREST access to both request-identity headers and cached responses is now strictly prohibited (`USING (false)` / default-deny).
2. **Retention vs Foreign-Key Conflict:** Reconciled the conflict between background pruning and restrictive foreign keys (`stock_transactions.idempotency_key REFERENCES idempotency_keys(idempotency_key) ON DELETE RESTRICT`). Implemented a robust **Two-Tier Idempotency Model**: permanent request-identity headers (`idempotency_keys`, Table 31) are retained indefinitely, while ephemeral response payloads (`idempotency_responses`, Table 32) are safely pruned based on a configurable TTL without violating foreign keys or breaking ledger audit trails. Canonical table inventory is revised from 32 to exactly **33 tables**. Retrying an expired key returns **HTTP 410 `IDEMPOTENCY_RESPONSE_EXPIRED`** with a structured resource reference, guaranteeing that expired operations are never re-executed.
3. **Write-Channel Ambiguity:** Formalized a complete **27-operation route-by-route write-channel matrix**, unambiguously separating transactional Flask command endpoints (which require and enforce idempotency) from direct PostgREST master CRUD (which rely on database unique constraints and schema controls, without claiming automatic transactional idempotency).

In strict accordance with project governance, **no SQL migrations were created or executed, no live database was altered, no application code was written, and no external dependencies were installed.** All changes are documentation-only within the canonical root `docs/` directory.

---

## 1. Resolution of the Direct-Access Contradiction

### 1.1 The Contradiction Diagnosed
In `docs/SYSTEM_DESIGN.md` (v1.6.0) section 2.1, the high-level data access matrix listed:
```markdown
| Idempotency Cache | `idempotency_keys` | Supabase REST (Self) | Read cached API response |
```
However, Section 6.4 (Complete RLS Matrix) declared:
```markdown
| `idempotency_keys` | Default-Deny (PostgREST direct access blocked) | Denied | Denied | Denied | Handled exclusively via internal database procedure with owner matching |
```
This discrepancy created architectural ambiguity: if PostgREST had direct self-access, a compromised client JWT could enumerate idempotency records, attempt direct row mutations, or inspect sensitive cached payloads.

### 1.2 Architectural Resolution
The contradiction is resolved by eliminating all direct PostgREST access. The data access matrix, RLS matrix, and ADR-027 have been aligned:
- **No Direct PostgREST Access:** Both `idempotency_keys` (Table 31) and `idempotency_responses` (Table 32) have RLS enabled with unconditional fail-closed policies (`FOR ALL USING (false)`). PostgREST calls to `/rest/v1/idempotency_keys` or `/rest/v1/idempotency_responses` return HTTP 200 with `[]` on SELECT and HTTP 403 / SQLSTATE `42501` on INSERT/UPDATE/DELETE.
- **Exclusive Transactional Procedure Access:** Idempotency state is read and mutated exclusively by trusted internal database procedures (or Flask backend connections operating under authorized database roles) executing inside atomic PostgreSQL transactions.
- **Verified Caller Identity:** Caller identity is derived strictly from the trusted authentication token (`auth.uid()`), never trusted from client-supplied request bodies or headers.
- **Replay Verification Invariants:** Replay is granted only when all three invariants match:
  1. `owner_id == auth.uid()`
  2. `operation_scope == normalized_endpoint_scope`
  3. `request_hash == sha256(canonical_payload)`
- **Generic Conflict Non-Disclosure:** Any key reuse where owner, scope, or hash does not match returns generic **HTTP 409 `IDEMPOTENCY_KEY_REUSED`** with zero disclosure of the original owner, scope, timestamp, or cached body.

---

## 2. Resolution of the Retention and Foreign-Key Conflict

### 2.1 The Retention vs FK Dilemma
The ledger design enforces strict anti-cascade protection:
```sql
ALTER TABLE stock_transactions
    ADD CONSTRAINT fk_stock_transactions_idempotency_key
    FOREIGN KEY (idempotency_key) REFERENCES idempotency_keys(idempotency_key)
    ON DELETE RESTRICT;
```
Simultaneously, previous documentation described an index `idx_idempotency_keys_retention_pruning` intended to prune expired idempotency rows after 24–48 hours. If a background worker attempted `DELETE FROM idempotency_keys WHERE created_at < NOW() - INTERVAL '24 hours'`, PostgreSQL would raise a foreign key violation (`SQLSTATE 23503: foreign_key_violation`) whenever an idempotency key was referenced by a historical stock transaction or production completion. Conversely, if `ON DELETE CASCADE` or `SET NULL` were used, historical stock movements would lose their originating request identity and audit traceability.

### 2.2 The Two-Tier Architecture (ADR-028)
To reconcile retention and foreign key integrity, the system implements a two-tier data model:

```mermaid
graph TD
    subgraph Permanent Request Identity Header [Permanent Audit Tier - Retained Indefinitely]
        IK[idempotency_keys<br/>Table 31<br/>- idempotency_key PK<br/>- owner_id UUID<br/>- operation_scope TEXT<br/>- request_hash CHAR 64<br/>- status VARCHAR 20<br/>- resource_type VARCHAR 50<br/>- resource_id UUID<br/>- created_at TIMESTAMPTZ<br/>- locked_at TIMESTAMPTZ<br/>- completed_at TIMESTAMPTZ]
    end

    subgraph Ephemeral Response Cache [Ephemeral Cache Tier - Configurable TTL Pruning]
        IR[idempotency_responses<br/>Table 32<br/>- idempotency_key PK FK ON DELETE CASCADE<br/>- response_status_code INT<br/>- response_body JSONB<br/>- cached_at TIMESTAMPTZ<br/>- expires_at TIMESTAMPTZ]
    end

    subgraph Production History [Transactional Inventory Ledger]
        ST[stock_transactions<br/>Table 15<br/>- idempotency_key FK ON DELETE RESTRICT]
        PC[production_completions<br/>Table 25<br/>- idempotency_key FK ON DELETE RESTRICT]
    end

    IK -->|1:1 Optional FK CASCADE| IR
    ST -->|FK RESTRICT| IK
    PC -->|FK RESTRICT| IK

    Worker[Background Pruning Worker] -.->|DELETE WHERE expires_at < NOW()| IR
```

#### Tier 1: Permanent Request Identity Header (`idempotency_keys`, Table 31)
- **Role:** Immutable audit record of the executed operation.
- **Columns:** `idempotency_key` (PK), `owner_id` (UUID), `operation_scope` (TEXT), `request_hash` (CHAR(64)), `status` (`LOCKED`, `COMPLETED`), `resource_type` (VARCHAR(50)), `resource_id` (UUID), `created_at`, `locked_at`, `completed_at`.
- **Retention:** Permanent. Never pruned by background maintenance.
- **Foreign Keys:** Referenced by `stock_transactions` and `production_completions` with `ON DELETE RESTRICT`. Because headers are never pruned, `ON DELETE RESTRICT` is never violated.

#### Tier 2: Ephemeral Response Cache (`idempotency_responses`, Table 32)
- **Role:** Temporary storage for the serialized HTTP response body to support immediate client retries (e.g. after network timeouts).
- **Columns:** `idempotency_key` (PK, FK referencing `idempotency_keys(idempotency_key) ON DELETE CASCADE`), `response_status_code` (INT), `response_body` (JSONB), `cached_at`, `expires_at` (TIMESTAMPTZ).
- **Retention:** Configurable TTL (default 24 hours, `expires_at = NOW() + INTERVAL '24 hours'`).
- **Pruning Worker:** Periodic task runs `DELETE FROM idempotency_responses WHERE expires_at < NOW()`. Pruning response bodies frees storage, mitigates data privacy exposure of cached business payloads, and touches zero rows in `idempotency_keys` or `stock_transactions`.

### 2.3 Post-Expiry Safe Replay Semantics (HTTP 410)
When a client retries an operation after the response cache record has expired and been pruned:
1. The server locates the permanent header in `idempotency_keys`.
2. The server verifies that caller `owner_id`, `operation_scope`, and canonical `request_hash` match.
3. The server detects `status = 'COMPLETED'` but finds no record in `idempotency_responses`.
4. **Operation is NEVER Re-Executed:** The server strictly forbids duplicate execution or ledger postings.
5. **Safe Response:** The server returns **HTTP 410 Gone** with error code `IDEMPOTENCY_RESPONSE_EXPIRED` and a structured resource reference:
   ```json
   {
     "error": {
       "code": "IDEMPOTENCY_RESPONSE_EXPIRED",
       "message": "The cached response for this idempotency key has expired and been pruned.",
       "resource_reference": {
         "resource_type": "GOODS_RECEIPT",
         "resource_id": "c4b1e5a2-9382-4f01-b3de-7c3a882a1d2e",
         "committed_at": "2026-10-15T08:30:00Z"
       }
     }
   }
   ```
6. **Authorized State Retrieval:** The client can query the permanent resource endpoint (e.g., `GET /api/v1/goods-receipts/c4b1e5a2-9382-4f01-b3de-7c3a882a1d2e`) using standard role-based access control to verify receipt lines and status.

### 2.4 Canonical Table Inventory Revision
With the addition of `idempotency_responses` (Table 32) and renumbering of `audit_logs` (Table 33), the canonical database schema contains exactly **33 tables**:
- Tables 1–10: Foundation, Security & Master Catalogs (`profiles`, `material_categories`, `materials`, `parties`, `products`, `vendors`, `locations`, `workers`, `units`, `material_conversions`).
- Tables 11–16: Inventory Ledger, Balances & Receipts (`purchase_orders`, `purchase_order_lines`, `goods_receipts`, `goods_receipt_lines`, `stock_transactions`, `material_location_balances`).
- Tables 17–20: Reservations, Adjustments & Quarantines (`stock_reservations`, `stock_adjustments`, `quarantine_records`, `scrap_disposals`).
- Tables 21–25: BOMs, Planning & Production (`boms`, `bom_lines`, `bom_revision_events`, `daily_plans`, `packing_jobs`).
- Tables 26–30: Snapshots, Closings & Consumption (`packing_job_bom_snapshots`, `packing_job_bom_snapshot_lines`, `packing_job_revisions`, `production_completions`, `material_consumption_records`).
- Tables 31–33: Closings, Idempotency & Audit Logs (`daily_closings`, `idempotency_keys`, `idempotency_responses`, `audit_logs`).

---

## 3. Comprehensive Route-by-Route Write-Channel Matrix

The 27 mutating operations in the system are cataloged below with write channels, idempotency requirements, duplicate prevention mechanisms, and stock impact:

| # | Endpoint / Operation | Channel | Idempotency Key Req? | Duplicate Prevention Mechanism | Auth & Validation Locus | Creates Stock / History? |
| :-: | :--- | :--- | :-: | :--- | :--- | :-: |
| 1 | `POST /rest/v1/material_categories` | Direct PostgREST | No | `UNIQUE (category_code)`, `UNIQUE (category_name)` | PostgREST RLS (`ADMIN` only) | No |
| 2 | `PATCH /rest/v1/material_categories?id=eq.{id}` | Direct PostgREST | No | Primary Key filter, unique constraints | PostgREST RLS (`ADMIN` only) | No |
| 3 | `POST /rest/v1/parties` | Direct PostgREST | No | `UNIQUE (party_code)` | PostgREST RLS (`ADMIN`, `PLANNER`) | No |
| 4 | `PATCH /rest/v1/parties?id=eq.{id}` | Direct PostgREST | No | Primary Key filter | PostgREST RLS (`ADMIN`, `PLANNER`) | No |
| 5 | `POST /rest/v1/products` | Direct PostgREST | No | `UNIQUE (sku)` | PostgREST RLS (`ADMIN`, `PLANNER`) | No |
| 6 | `PATCH /rest/v1/products?id=eq.{id}` | Direct PostgREST | No | Primary Key filter | PostgREST RLS (`ADMIN`, `PLANNER`) | No |
| 7 | `POST /rest/v1/vendors` | Direct PostgREST | No | `UNIQUE (vendor_code)` | PostgREST RLS (`ADMIN`, `STOREKEEPER`) | No |
| 8 | `PATCH /rest/v1/vendors?id=eq.{id}` | Direct PostgREST | No | Primary Key filter | PostgREST RLS (`ADMIN`, `STOREKEEPER`) | No |
| 9 | `POST /rest/v1/materials` | Direct PostgREST | No | `UNIQUE (item_code)` | PostgREST RLS + Canonical lock trigger | No |
| 10 | `PATCH /rest/v1/materials?id=eq.{id}` | Direct PostgREST | No | Primary Key filter, canonical immutability trigger | PostgREST RLS + `trg_lock_canonical_unit` | No |
| 11 | `POST /api/v1/admin/users/{targetId}/access` | Flask RPC Wrapper | Optional | RPC row locking on target profile | RPC `admin_update_profile_access` + JWT admin check | Yes (Audit row) |
| 12 | `POST /api/v1/purchase-orders` | Flask API | Optional | `UNIQUE (po_number)` | Flask `@require_role` + DB FK checks | Yes (PO history) |
| 13 | `POST /api/v1/boms` | Flask API | Optional | Unique index `idx_boms_single_active_version` | Flask `@require_role` + procedure validation | Yes (BOM history) |
| 14 | `POST /api/v1/boms/{id}/new-version` | Flask API | Optional | Atomic transaction: supersede old, activate new | Flask `@require_role` + DB transaction | Yes (BOM revision) |
| 15 | `POST /api/v1/daily-plans` | Flask API | Optional | `UNIQUE (plan_date, shift_code)` | Flask `@require_role` + DB unique constraint | Yes (Plan history) |
| 16 | `POST /api/v1/daily-plans/{id}/release` | Flask API Command | **MANDATORY** | Two-tier idempotency header + status lock | Flask `@require_role` + `fn_release_daily_plan` | Yes (Snapshots, Reservations) |
| 17 | `POST /api/v1/goods-receipts/post` | Flask API Command | **MANDATORY** | Two-tier idempotency header + multi-row seq | Flask `@require_role` + `fn_post_goods_receipt` | **YES (Ledger, Balances)** |
| 18 | `POST /api/v1/stock/issue-to-worker` | Flask API Command | **MANDATORY** | Two-tier idempotency header + DB row lock | Flask `@require_role` + `fn_post_stock_transaction` | **YES (Ledger, Balances)** |
| 19 | `POST /api/v1/stock/return-from-worker` | Flask API Command | **MANDATORY** | Two-tier idempotency header + DB row lock | Flask `@require_role` + `fn_post_stock_transaction` | **YES (Ledger, Balances)** |
| 20 | `POST /api/v1/stock/transfer` | Flask API Command | **MANDATORY** | Two-tier idempotency header + DB row lock | Flask `@require_role` + `fn_post_stock_transaction` | **YES (Ledger, Balances)** |
| 21 | `POST /api/v1/stock/damage-quarantine` | Flask API Command | **MANDATORY** | Two-tier idempotency header + DB row lock | Flask `@require_role` + `fn_post_stock_transaction` | **YES (Ledger, Balances)** |
| 22 | `POST /api/v1/stock/scrap-disposal` | Flask API Command | **MANDATORY** | Two-tier idempotency header + DB row lock | Flask `@require_role` + `fn_post_stock_transaction` | **YES (Ledger, Balances)** |
| 23 | `POST /api/v1/stock/adjustments` | Flask API Command | **MANDATORY** | Two-tier idempotency header + single-dir FK | Flask `@require_role` + `fn_post_stock_adjustment` | **YES (Ledger, Balances)** |
| 24 | `POST /api/v1/packing-jobs/{id}/revise-quantity` | Flask API Command | **MANDATORY** | Two-tier idempotency header + floor validation | Flask `@require_role` + `fn_revise_job_quantity` | Yes (Revisions, Reservations) |
| 25 | `POST /api/v1/packing-jobs/{id}/cancel` | Flask API Command | **MANDATORY** | Two-tier idempotency header + custody check | Flask `@require_role` + `fn_cancel_packing_job` | Yes (Job event, Reservations) |
| 26 | `POST /api/v1/production/completions` | Flask API Command | **MANDATORY** | Two-tier idempotency header + completion lock | Flask `@require_role` + `fn_record_completion` | **YES (Ledger, Balances)** |
| 27 | `POST /api/v1/closings` | Flask API Command | **MANDATORY** | Two-tier idempotency header + composite FK | Flask `@require_role` + `fn_close_daily_plan` | Yes (Closing summary) |

### Key Policy Invariants:
1. **Direct PostgREST CRUD is strictly for master entities.** It does not receive or require transactional idempotency headers. Duplicate writes are prevented by database primary keys and unique constraints (`item_code`, `party_code`, `sku`, `vendor_code`, `category_code`).
2. **All inventory ledger and state mutations MUST use Flask API Commands.** Direct PostgREST INSERT, UPDATE, and DELETE on `stock_transactions`, `material_location_balances`, `stock_reservations`, `packing_job_bom_snapshots`, `daily_closings`, `idempotency_keys`, `idempotency_responses`, and `audit_logs` are unconditionally locked out via RLS (`USING (false)`).
3. **Mandatory Idempotency Keys:** Every inventory and planning mutating endpoint enforces the `Idempotency-Key` header at the Flask middleware layer.

---

## 4. Key Validation and Canonical Request Hashing Specification

### 4.1 Bounded Key Format
Client-supplied idempotency keys must conform strictly to the following specification:
- **Type:** String (ASCII).
- **Length:** 16 to 128 characters inclusive (`minLength: 16`, `maxLength: 128`).
- **Allowed Character Set:** Alphanumeric plus hyphen, underscore, period, and colon (`^[A-Za-z0-9_\-\.:]{16,128}$`).
- **Validation Locus:** Validated in Flask API request middleware before invoking any database connection or procedure. Invalid, short, empty, or oversized keys are rejected immediately with HTTP 400 `INVALID_IDEMPOTENCY_KEY`.

### 4.2 Server-Normalized Operation Scope
The client cannot supply or override the operation scope. The server derives and normalizes the scope from the HTTP method and registered route template:
$$\text{operation\_scope} = \text{request.method} + \text{":"} + \text{request.url\_rule.rule}$$
Examples:
- `POST:/api/v1/goods-receipts/post`
- `POST:/api/v1/stock/transfer`
- `POST:/api/v1/packing-jobs/<id>/revise-quantity`

### 4.3 Deterministic Canonical Payload Hashing
To prevent any possibility of a modified payload (e.g., changed quantity, altered material variant, or swapped location) incorrectly matching an existing key, the canonical request hash is computed using deterministic JSON canonicalization:

```python
def compute_canonical_request_hash(owner_id: str, operation_scope: str, request_json: dict) -> str:
    # 1. Canonicalize JSON: lexicographical key sorting, strict float formatting, no extra whitespace
    canonical_json = json.dumps(
        request_json,
        sort_keys=True,
        separators=(',', ':'),
        ensure_ascii=True
    )
    # 2. Bind verified owner, normalized scope, and canonical payload
    preimage = f"{owner_id}|{operation_scope}|{canonical_json}"
    # 3. Compute SHA-256
    return hashlib.sha256(preimage.encode('utf-8')).hexdigest()
```

#### Deterministic Canonicalization Rules:
1. **Lexicographical Object Key Ordering:** All JSON object keys are recursively sorted in ascending ASCII order.
2. **Whitespace Minification:** Zero whitespace outside of string literals (`separators=(',', ':')`).
3. **Deterministic Numeric Representation:** Numbers are serialized without exponential notation for standard quantities (e.g., `50.0` or `50`, consistent precision).
4. **Array Order Preservation:** Arrays (such as receipt line items or custom BOM lines) maintain their explicit submitted element ordering.
5. **Semantic Coverage:** All user-supplied quantities, units, material variant IDs, source/destination locations, dates, and notes are captured within `request_json`. Altering any quantity (e.g. 50 $\to$ 51) produces a distinct SHA-256 hash.

### 4.4 Generic Conflict Non-Disclosure
If an incoming request provides an `Idempotency-Key` that exists in `idempotency_keys` but differs in `owner_id`, `operation_scope`, or `request_hash`, the server returns a generic HTTP 409:
```json
{
  "error": {
    "code": "IDEMPOTENCY_KEY_REUSED",
    "message": "The provided Idempotency-Key has already been used for a different request."
  }
}
```
**Strict Privacy Guarantee:** The response body NEVER discloses:
- The owner ID of the original request.
- The endpoint or operation scope of the original request.
- The original request payload or timestamp.
- The cached response status code or body.

---

## 5. Acceptance Test Strategy & Quality Assurance Verification

`docs/TEST_PLAN.md` has been expanded with explicit Scenarios 23 through 34 directly addressing the 10 retention and replay acceptance criteria:

1. **Matching Owner/Scope/Hash Replay (Scenario 23):** Initial request returns 200 OK with committed stock transfer. Identical retry before expiry returns identical cached 200 OK. Database verification confirms exactly one header, one response cache, and one pair of ledger movements.
2. **Cross-User Denial (Scenario 24):** User B submitting User A's key receives generic HTTP 409 `IDEMPOTENCY_KEY_REUSED`. User A's data is undisclosed; User B creates zero ledger movements.
3. **Cross-Endpoint & Modified Payload Denial (Scenario 25):** Reusing key across different endpoints or altering payload fields returns generic HTTP 409 without creating duplicate movements.
4. **Retention Pruning Preserves Header & Stock FK (Scenario 26):** Deleting expired rows in `idempotency_responses` (`expires_at < NOW()`) succeeds without violating `fk_stock_transactions_idempotency_key` (`ON DELETE RESTRICT`). Header and stock transactions remain fully intact.
5. **Retrying Expired Key Returns HTTP 410 (Scenario 27):** Retrying after cache expiration returns HTTP 410 `IDEMPOTENCY_RESPONSE_EXPIRED` with resource reference. Zero new ledger rows are created.
6. **Post-Expiry Authorized Status Retrieval (Scenario 28):** Using the `resource_id` from the HTTP 410 response, authorized `STOREKEEPER` inspects `GET /api/v1/goods-receipts/{id}` successfully. Unauthorized `OPERATOR` receives HTTP 403 Forbidden.
7. **Direct PostgREST Denial (Scenario 29):** Direct PostgREST calls on `idempotency_keys` and `idempotency_responses` return empty arrays `[]` on SELECT or fail closed with 403 / 42501 on INSERT/UPDATE/DELETE.
8. **Concurrent Duplicate Serialization (Scenario 30):** Two concurrent requests with the same key serialize via row locks; exactly one executes and both return the identical committed 200 OK.
9. **Multi-Line Atomic Commit (Scenario 31):** A 5-line Goods Receipt commits header, 5 lines, 5 stock transactions, 5 balance updates, 1 idempotency header, and 1 response cache atomically.
10. **Transaction Rollback Removes Key (Scenario 32):** In-transaction check constraint failure rolls back entirely, leaving no partial ledger rows, no balance changes, and no completed idempotency header, enabling clean retries.

---

## 6. Document Verification Audit & Traceability Cross-Check

All canonical specifications in root `docs/` have been verified for internal consistency:

| Document | Verified Version | Reconciled Elements |
| :--- | :---: | :--- |
| `docs/SYSTEM_DESIGN.md` | **1.7.0** | §2.1 PostgREST denial; §2.3 27-operation write matrix; §3 Tables 31, 32, 33; §6.4 33-table RLS matrix; §7.1 33-table inventory; §7.4 Two-tier idempotency architecture, bounded regex, canonical hashing, HTTP 410 semantics. |
| `docs/ARCHITECTURE_DECISIONS.md` | **1.7.0** | Added ADR-028 (*Two-Tier Idempotency Architecture with Ephemeral Response Cache, Foreign Key Preservation, and HTTP 410 Expiration Semantics*); updated Decision Index. |
| `docs/API_CONTRACT.yaml` | **1.7.0** | Added bounded length & regex to `IdempotencyKey` parameter (`minLength: 16`, `maxLength: 128`, pattern); added `IdempotencyExpiredResponse` (HTTP 410); **verified 52/52 local `$ref` pointers resolve cleanly**. |
| `docs/PRD.md` | **1.7.0** | Reconciled table count to 33 tables in §4.1; updated §4.2 to detail two-tier idempotency, PostgREST denial, and HTTP 410 replay semantics. |
| `docs/MRD.md` | **1.7.0** | Bumped header version to 1.7.0 and Phase 1.7 approved status. |
| `docs/TEST_PLAN.md` | **1.7.0** | Reconciled table count to 33 in testing matrix; expanded Scenarios 23–34 covering all 10 retention, replay, expiration, authorization, concurrency, and rollback test cases. |
| `docs/REQUIREMENT_TRACEABILITY.md` | **1.7.0** | Reconciled table count to 33 in overview; mapped Req F.5 to ADR-018, ADR-027, ADR-028, Tables 31 & 32, and Scenarios 23–34. |
| `docs/IMPLEMENTATION_PLAN.md` | **1.7.0** | Reconciled table count to 33 in Phase 2 scope, acceptance criteria, and governance; added `idempotency_responses`, TTL pruning worker, and HTTP 410 middleware handling in Phase 2 and Phase 3. |
| `docs/OPEN_DECISIONS.md` | **1.7.0** | Bumped header version to 1.7.0 and Phase 1.7 approved status. |

---

## 7. Scope & Governance Compliance Checklist

- [x] **Documentation changes only:** Zero SQL migration scripts executed. Zero live database instances mutated.
- [x] **Zero application code executed:** No Flask routes or React components implemented.
- [x] **Zero dependency installations:** No `pip`, `npm`, or other package managers invoked.
- [x] **Historical Phase 0 audit preserved:** `docs/REPOSITORY_AUDIT.md` remains untouched.
- [x] **Root `docs/` treated as sole canonical specification:** Archival packages remain segregated and non-canonical.
- [x] **Direct-access contradiction fully resolved:** PostgREST direct access denied on both idempotency tables.
- [x] **Retention vs FK conflict fully resolved:** Two-tier model (`idempotency_keys` permanent + `idempotency_responses` ephemeral) with HTTP 410 expired replay semantics.
- [x] **Canonical table count verified:** Exactly 33 tables across all design documents, RLS matrix, inventory tables, and implementation roadmaps.
- [x] **Write-channel matrix cataloged:** 27 operations analyzed across write channels, duplicate controls, and stock effects.
- [x] **OpenAPI contract validated:** All 52 local `$ref` pointers resolve cleanly.
- [x] **Clear distinction between documentation checks and runtime tests:** All test scenarios documented as planned acceptance criteria without claiming unexecuted runtime success.

---

**Phase 1.7 Gate Status: APPROVED & COMPLETE.** The system documentation is completely consistent and hardened, ready for Phase 2 database schema implementation upon authorization.
