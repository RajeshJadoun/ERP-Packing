# Phase 1.4 — Final Database Specification Corrections

**Project:** Packing Material Inventory & BOM Management System  
**Phase:** Phase 1.4 — Documentation-only consistency correction  
**Document Version:** 1.0.0  
**Date:** 2026-10-14  
**Status:** Complete documentation correction; implementation approval remains required  

---

## Scope and evidence

This review inspected the canonical root `docs/` specifications and preserved `REPOSITORY_AUDIT.md` unchanged. No migration was created or executed, no database/data was accessed, and no application code or dependency was changed. Phase 1.3 completion statements were treated as historical claims, not evidence.

## Findings and corrections

| Finding | Correction | Canonical documents / acceptance evidence |
| :--- | :--- | :--- |
| `packing_jobs.master_bom_id` was NOT NULL although the API admitted customized jobs with nullable `masterBomId`. | The job FK is nullable only for source-less custom jobs. Release is gated by one immutable, non-empty, complete snapshot; custom snapshots require null source and version while master-derived snapshots require both. | `SYSTEM_DESIGN`, ADR-019, API `MasterDerivedJobInput`/`CustomJobInput`, PRD, MRD, Open Decisions, UI; Scenario 19. |
| The stock reference CHECK did not reject all unrelated FKs and did not require job linkage for returns/consumption. | Added an exhaustive nine-movement row matrix and CHECK semantics. Consumption requires job, completion, and worker; table-dependent links are validated by the posting trigger/procedure. | `SYSTEM_DESIGN`, ADR-020, Implementation Plan; Scenarios 17 and 21. |
| Leaf/location rules were described as though a CHECK could inspect `locations`. | Assigned same-row null/difference facts to CHECKs and active leaf/type/origin facts to triggers/procedures. Added unsafe location topology transition protections and atomic ledger/projection procedure requirements. | `SYSTEM_DESIGN`, ADR-020, Implementation Plan; Scenario 21. |
| The trusted role path ambiguously mixed service-role execution with `auth.uid()` identity. | Selected actual-administrator JWT forwarding to narrowly scoped `admin_update_profile_access` RPC. It derives actor from `auth.uid()`, verifies active ADMIN status, has narrow EXECUTE grants, denies direct target updates, and audits atomically. | `SYSTEM_DESIGN`, ADR-021, API, PRD, RTM, Implementation Plan; Scenario 20. |
| YAML declared 3.0.3 while Phase 1.3 described 3.1.0. | Retained OpenAPI 3.0.3 because the document uses 3.0 `nullable: true`, updated API version to 1.4.0, and amended the Phase 1.3 historical report. | `API_CONTRACT.yaml`, ADR-022, `PHASE_1_3_REVIEW.md`; structural validation below. |
| A revision below already-completed output was not consistently specified. | Revision procedures and API reject `revisedQuantity < completed_quantity` with HTTP 422; UI explains that completed production is not rewritten and any overproduction requires a separate audited exception. | `SYSTEM_DESIGN`, ADR-022, API, PRD, MRD, UI, Implementation Plan; Scenarios 4, 15, and 4A UI walkthrough. |

## OpenAPI structural verification

The contract uses `openapi: 3.0.3`; its nullable fields use valid OpenAPI 3.0 representation (`nullable: true`), not 3.1 JSON Schema union types. Phase 1.4 parsed the YAML successfully and resolved all **48** local `$ref` JSON pointers (zero errors; zero non-local references). This is a structural check, not a claim of complete OpenAPI compliance. No installed `redocly`, `spectral`, `swagger-cli`, or `openapi-generator` validator was available, and none was installed; external semantic validation remains an implementation/review task.

## Current implementation gate

The canonical documentation is internally reconciled for the corrected items. Before Phase 2, reviewers must approve these specifications. Phase 2 must implement and test the stated constraints, triggers, RPC grants/RLS, and procedures; this report does **not** claim migration, runtime, database-security, or acceptance tests passed.
