# Phase 1.6 — Idempotency Ownership, Replay Security and Failure Semantics

**Project:** Packing Material Inventory & BOM Management System  
**Phase:** Phase 1.6 — Documentation-only transaction-security correction  
**Document Version:** 1.0.0  
**Date:** 2026-10-14  
**Status:** Documentation design ready for review; Phase 2 remains blocked pending approval  

---

## Original gap

The prior idempotency model stored key, endpoint, request hash, creator, and cached response but allowed the replay description to match only key/hash. It did not require the verified caller or normalized operation to match, exposed a self PostgREST cache-read policy, and left failure behavior ambiguous between rollback and a retained `FAILED` record.

## Selected solution

The opaque key remains globally unique. Each header is bound to a verified JWT-derived `owner_id`, a server-normalized `operation_scope`, and canonical request hash. An existing-key lookup compares key + owner + scope + hash before status/body access. Any mismatch produces generic HTTP 409 `IDEMPOTENCY_KEY_REUSED` with no cached body, record IDs, endpoint details, or owner data.

The single selected failure strategy is **rollback removes the key**. Header creation, domain changes, every generated ledger/projection row, and cached successful response occur in one PostgreSQL transaction. Any in-transaction failure rolls all of them back, including the `PROCESSING` header. `FAILED` is not a persisted state. A completed commit followed by a lost client response is recovered only by a matching owner/scope/hash retry, which replays the committed success without creating another movement.

## Files changed and acceptance evidence

| File | Correction | Planned acceptance tests |
| :--- | :--- | :--- |
| `SYSTEM_DESIGN.md` | Owner/scope/hash schema, global-key lookup rule, direct-cache RLS denial, and complete transaction/retry semantics. | 23–32 |
| `ARCHITECTURE_DECISIONS.md` | ADR-027 records the security and rollback decision. | 23–32 |
| `API_CONTRACT.yaml` | Idempotency header and conflict response document generic non-disclosing replay behavior. | 23–26, 30 |
| `TEST_PLAN.md` | Added ten owner/replay/concurrency/rollback/cache-access scenarios with setup, HTTP, and database outcomes. | 23–32 |
| `REQUIREMENT_TRACEABILITY.md` | Maps owner-bound idempotency to the new scenarios and ADR. | 7, 23–32 |
| `IMPLEMENTATION_PLAN.md` | Specifies procedure, RLS, canonicalization, and rollback-removes-key implementation/testing work. | 23–32 |

## Verification and limitations

- `SYSTEM_DESIGN.md` contains exactly **32** table sections.
- `API_CONTRACT.yaml` parses as OpenAPI **3.0.3**; all **51** local `$ref` pointers resolve with zero errors.
- No installed OpenAPI semantic validator was used or installed; full semantic validation remains unperformed.
- No migration, database access, runtime test, concurrency test, RLS test, or security test was run. Acceptance scenarios are planned only.

## Phase 2 gate

The documentation now defines owner-bound replay authorization, multi-row association, and unambiguous rollback/retry behavior. It is ready for review, not proof of implementation. Do not start Phase 2 until these revisions are explicitly approved.
