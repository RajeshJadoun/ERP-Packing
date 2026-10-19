# Phase 1.5 — Final Pre-Migration Consistency Gate

**Project:** Packing Material Inventory & BOM Management System  
**Phase:** Phase 1.5 — Documentation-only pre-migration consistency gate  
**Document Version:** 1.0.0  
**Date:** 2026-10-14  
**Status:** Documentation design ready for review; Phase 2 remains blocked pending approval  

---

## Scope and verification boundary

This review inspected the actual canonical root `docs/` files and preserved historical review reports and `REPOSITORY_AUDIT.md`. It created no SQL migrations, accessed no live database, implemented no application code, installed no dependencies, and ran no runtime or database-security tests.

## Findings, corrections, and acceptance evidence

| Finding | Selected correction | Files changed | Acceptance evidence |
| :--- | :--- | :--- | :--- |
| GRN requests required client-derived received/accepted/canonical quantities and conversion values. | Request now accepts only original entered/rejected measurements with explicit units plus physical evidence. The trusted posting procedure calculates accepted/canonical quantities, freezes provenance, posts receipt/ledger atomically, and returns calculated results. Optional expected canonical quantity is comparison-only. | `API_CONTRACT.yaml`, `SYSTEM_DESIGN.md`, ADR-023, PRD, UI, Test Plan, RTM, Implementation Plan | Scenario 1 |
| A material canonical unit could be changed despite ledger/projection/reservation/snapshot history. | A database trigger rejects canonical-unit changes after any transaction, reservation, or released snapshot. The approved correction is a replacement material variant; no silent rebase is permitted. | `SYSTEM_DESIGN.md`, ADR-024, PRD, MRD, Open Decisions, Test Plan, RTM, Implementation Plan | Scenario 22 |
| `consumption_records` appeared in a canonical production boundary while the schema uses `material_consumption_records`. | Standardized canonical operational references to `material_consumption_records`. Historical reports retain historical wording where applicable and are not evidence of current schema. | `SYSTEM_DESIGN.md`; audited all listed canonical files | Scenario 2 |
| Location prose implied every active node was inventory-bearing despite leaf-only posting rules. | Distinguished parent organizational containers from active inventory-bearing leaves; added reporting partitions for usable, receiving, custody, quarantine, and dispatch stock. Parent roll-ups are descendant-derived and never double counted. | `SYSTEM_DESIGN.md`, ADR-026, PRD, UI | Scenario 21 |
| Conversion provenance did not always retain a rule-version identifier and complete frozen context. | Versioned rules are append-only. Receipt lines, ledger rows, and snapshot lines retain source/canonical units, rule ID where applicable, factor, direction, exact/estimated classification, and measured/canonical quantities. Direct canonical operations use null rule, factor 1, `NONE`, and `EXACT`. | `SYSTEM_DESIGN.md`, ADR-025, API, MRD, Test Plan, RTM, Implementation Plan | Scenarios 1 and 22 |

## Documentation checks performed

- `SYSTEM_DESIGN.md` contains exactly **32** table sections.
- Canonical documentation search found no remaining `consumption_records`, deprecated derived-GRN request names (`receivedQty`, `acceptedQty`, `conversionFactorUsed`), `INTERNAL_TRANSFER`, or “every active node is inventory-bearing” wording.
- `API_CONTRACT.yaml` parses successfully as OpenAPI **3.0.3**. All **51** local `$ref` pointers resolve with zero errors.
- No installed `redocly`, `spectral`, `swagger-cli`, or `openapi-generator` validator was available. Full semantic OpenAPI validation therefore remains unperformed.

## Phase 2 gate

The documentation design now meets the Phase 1.5 consistency conditions and is ready for human review. It is **not** evidence that migrations, triggers, RLS/RPC grants, stored procedures, API behavior, balance projection behavior, or acceptance tests have executed successfully. Do not start Phase 2 until the revised specifications are explicitly approved.
