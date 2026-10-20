-- =============================================================================
-- pgTAP: Phase 6 BOM versioning, atomic daily planning, snapshots and reservations
-- =============================================================================
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(30);

SELECT has_column('public', 'daily_plans', 'status', 'daily plan lifecycle status exists');
SELECT has_column('public', 'daily_plans', 'released_by', 'daily plan release attribution exists');
SELECT has_function('public', 'rpc_create_bom', 'Atomic BOM creation RPC exists');
SELECT has_function('public', 'rpc_create_bom_version', 'BOM version creation RPC exists');
SELECT has_function('public', 'rpc_activate_bom_version', 'Atomic BOM activation RPC exists');
SELECT has_function('public', 'rpc_create_daily_plan', 'Atomic daily plan and multi-job creation RPC exists');
SELECT has_function('public', 'rpc_release_daily_plan', 'Daily plan release and reservation RPC exists');
SELECT has_function('public', 'rpc_revise_packing_job_api', 'Idempotent job revision API RPC exists');
SELECT has_function('public', 'rpc_cancel_packing_job_api', 'Idempotent job cancellation API RPC exists');
SELECT has_index('public', 'boms', 'idx_boms_single_active_version',
    'Single-active-BOM recipe uniqueness index exists');

SELECT is(
    (SELECT count(*)::integer
     FROM pg_catalog.pg_policies
     WHERE schemaname = 'public'
       AND tablename IN ('boms', 'bom_lines', 'daily_plans', 'packing_jobs')
       AND cmd IN ('INSERT', 'UPDATE', 'DELETE', 'ALL')),
    0,
    'Direct PostgREST writes to BOM and planning entities are closed; writes use transactional RPCs'
);

-- Test-only user, catalog and location setup. All writes are rolled back below.
DO $$
DECLARE
    v_admin uuid := 'a6000000-0000-4000-8000-000000000001';
BEGIN
    INSERT INTO auth.users (id, email)
    VALUES (v_admin, 'phase6_admin@packing.test')
    ON CONFLICT (id) DO NOTHING;

    ALTER TABLE public.profiles DISABLE TRIGGER trg_protect_profile_role_before_update;
    INSERT INTO public.profiles (id, full_name, role, is_active)
    VALUES (v_admin, 'Phase 6 Test Admin', 'ADMIN', true)
    ON CONFLICT (id) DO UPDATE SET role = 'ADMIN', is_active = true;
    ALTER TABLE public.profiles ENABLE TRIGGER trg_protect_profile_role_before_update;

    INSERT INTO public.parties (id, code, name, is_active)
    VALUES ('a6000000-0000-4000-8000-000000000002', 'PTY-PHASE6-TEST', 'Phase 6 Test Party', true)
    ON CONFLICT (id) DO NOTHING;

    INSERT INTO public.products (id, sku_code, name, default_party_id, is_active)
    VALUES ('a6000000-0000-4000-8000-000000000003', 'SKU-PHASE6-TEST', 'Phase 6 Test Product',
            'a6000000-0000-4000-8000-000000000002', true)
    ON CONFLICT (id) DO NOTHING;

    INSERT INTO public.materials (id, material_code, name, category_id, canonical_unit_id, is_active)
    VALUES (
        'a6000000-0000-4000-8000-000000000004',
        'MAT-PHASE6-TEST',
        'Phase 6 Test Carton',
        (SELECT id FROM public.material_categories WHERE code = 'POLY_BAG' LIMIT 1),
        (SELECT id FROM public.units WHERE code = 'PCS' LIMIT 1),
        true
    )
    ON CONFLICT (id) DO NOTHING;

    INSERT INTO public.locations (id, location_code, name, location_type, is_leaf, is_active)
    VALUES ('a6000000-0000-4000-8000-000000000005', 'LOC-PHASE6-TEST', 'Phase 6 Test Shelf',
            'STORE_SHELF', true, true)
    ON CONFLICT (id) DO NOTHING;
END
$$;

SELECT set_config('request.jwt.claim.sub', 'a6000000-0000-4000-8000-000000000001', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

CREATE TEMP TABLE phase6_rpc_results (
    name text PRIMARY KEY,
    body jsonb NOT NULL
) ON COMMIT DROP;

-- Create the first draft version and activate it.
INSERT INTO phase6_rpc_results(name, body)
VALUES (
    'bom_v1',
    public.rpc_create_bom(
        'a6000000-0000-4000-8000-000000000003',
        'a6000000-0000-4000-8000-000000000002',
        'PHASE6_RECIPE',
        'Initial revision',
        jsonb_build_array(jsonb_build_object(
            'materialId', 'a6000000-0000-4000-8000-000000000004',
            'quantityPerUnit', 2,
            'unitId', (SELECT id FROM public.units WHERE code = 'PCS' LIMIT 1),
            'isOptional', false
        )),
        'req_phase6_create_bom_0001',
        'phase6-create-bom-v1-hash'
    )
);

SELECT is((SELECT body->>'status' FROM phase6_rpc_results WHERE name = 'bom_v1'),
          'DRAFT', 'New master BOM is initially created as DRAFT');

INSERT INTO phase6_rpc_results(name, body)
SELECT 'activate_v1',
       public.rpc_activate_bom_version(
           (body->>'id')::uuid,
           'req_phase6_activate_bom_001',
           'phase6-activate-bom-v1-hash'
       )
FROM phase6_rpc_results WHERE name = 'bom_v1';

SELECT is((SELECT body->>'status' FROM phase6_rpc_results WHERE name = 'activate_v1'),
          'ACTIVE', 'First BOM version activates successfully');

-- A new recipe version remains DRAFT until a separate activation transition.
INSERT INTO phase6_rpc_results(name, body)
SELECT 'bom_v2',
       public.rpc_create_bom_version(
           (body->>'id')::uuid,
           'Increase carton quantity per finished unit',
           jsonb_build_array(jsonb_build_object(
               'materialId', 'a6000000-0000-4000-8000-000000000004',
               'quantityPerUnit', 3,
               'unitId', (SELECT id FROM public.units WHERE code = 'PCS' LIMIT 1),
               'isOptional', false
           )),
           'req_phase6_create_bom_v2_001',
           'phase6-create-bom-v2-hash'
       )
FROM phase6_rpc_results WHERE name = 'bom_v1';

SELECT is((SELECT (body->>'versionNumber')::integer FROM phase6_rpc_results WHERE name = 'bom_v2'),
          2, 'New BOM version increments the recipe version number');

INSERT INTO phase6_rpc_results(name, body)
SELECT 'activate_v2',
       public.rpc_activate_bom_version(
           (body->>'id')::uuid,
           'req_phase6_activate_bom_002',
           'phase6-activate-bom-v2-hash'
       )
FROM phase6_rpc_results WHERE name = 'bom_v2';

SELECT is((SELECT status FROM public.boms
           WHERE id = (SELECT (body->>'id')::uuid FROM phase6_rpc_results WHERE name = 'bom_v1')),
          'SUPERSEDED', 'Activating a new version atomically supersedes the previous active BOM');
SELECT is((SELECT status FROM public.boms
           WHERE id = (SELECT (body->>'id')::uuid FROM phase6_rpc_results WHERE name = 'bom_v2')),
          'ACTIVE', 'The newly activated BOM is the active version');

-- Repeated product/party pairs are permitted when a plan explicitly selects a
-- recipe version for each job. A source-less custom job carries its own frozen line.
INSERT INTO phase6_rpc_results(name, body)
VALUES (
    'daily_plan',
    public.rpc_create_daily_plan(
        current_date + 1,
        'PHASE6_TEST',
        'Automated Phase 6 planning test',
        jsonb_build_array(
            jsonb_build_object(
                'partyId', 'a6000000-0000-4000-8000-000000000002',
                'productId', 'a6000000-0000-4000-8000-000000000003',
                'masterBomId', (SELECT (body->>'id')::uuid FROM phase6_rpc_results WHERE name = 'bom_v2'),
                'plannedQuantity', 100
            ),
            jsonb_build_object(
                'partyId', 'a6000000-0000-4000-8000-000000000002',
                'productId', 'a6000000-0000-4000-8000-000000000003',
                'masterBomId', (SELECT (body->>'id')::uuid FROM phase6_rpc_results WHERE name = 'bom_v2'),
                'plannedQuantity', 50
            )
        ),
        jsonb_build_array(
            jsonb_build_object(
                'partyId', 'a6000000-0000-4000-8000-000000000002',
                'productId', 'a6000000-0000-4000-8000-000000000003',
                'plannedQuantity', 20,
                'customizationNotes', 'Custom protective wrap',
                'customBomLines', jsonb_build_array(jsonb_build_object(
                    'materialId', 'a6000000-0000-4000-8000-000000000004',
                    'quantityPerUnit', 2,
                    'unitId', (SELECT id FROM public.units WHERE code = 'PCS' LIMIT 1),
                    'isOptional', false,
                    'applicationNotes', 'Add protective wrap'
                ))
            )
        ),
        'req_phase6_create_plan_0001',
        'phase6-create-plan-hash'
    )
);

SELECT is(jsonb_array_length((SELECT body->'jobs' FROM phase6_rpc_results WHERE name = 'daily_plan')),
          3, 'Daily plan atomically accepts repeated master jobs and one custom job');
SELECT is(
    (SELECT count(*)::integer
     FROM jsonb_array_elements((SELECT body->'jobs' FROM phase6_rpc_results WHERE name = 'daily_plan')) AS job(value)
     WHERE job.value->>'partyId' = 'a6000000-0000-4000-8000-000000000002'
       AND job.value->>'productId' = 'a6000000-0000-4000-8000-000000000003'),
    3,
    'Repeated party/product combinations stay distinct jobs in the schedule'
);

-- Seed authoritative on-hand stock using the transactional adjustment RPC.
INSERT INTO phase6_rpc_results(name, body)
VALUES (
    'stock_adjustment',
    public.rpc_post_stock_adjustment(
        'ADJ-PHASE6-TEST-001',
        'a6000000-0000-4000-8000-000000000004',
        'a6000000-0000-4000-8000-000000000005',
        1000,
        'Phase 6 reservation test seed',
        'req_phase6_stock_adjustment_001',
        'phase6-stock-adjustment-hash'
    )
);

-- Total mandatory demand: 100*3 + 50*3 + 20*2 = 490 PCS.
INSERT INTO phase6_rpc_results(name, body)
SELECT 'released_plan',
       public.rpc_release_daily_plan(
           (body->>'id')::uuid,
           'req_phase6_release_plan_0001',
           'phase6-release-plan-hash'
       )
FROM phase6_rpc_results WHERE name = 'daily_plan';

SELECT is((SELECT body->>'status' FROM phase6_rpc_results WHERE name = 'released_plan'),
          'RELEASED', 'Plan release transitions the plan to RELEASED');

SELECT is((SELECT count(*)::integer FROM public.packing_jobs
           WHERE daily_plan_id = (SELECT (body->>'id')::uuid FROM phase6_rpc_results WHERE name = 'daily_plan')
             AND status = 'RELEASED'),
          3, 'Every draft job is released atomically with the plan');

SELECT is((SELECT coalesce(sum(reserved_quantity), 0) FROM public.stock_reservations
           WHERE packing_job_id IN (
               SELECT id FROM public.packing_jobs
               WHERE daily_plan_id = (SELECT (body->>'id')::uuid FROM phase6_rpc_results WHERE name = 'daily_plan')
           ) AND status = 'ACTIVE'),
          490::numeric, 'Release creates active reservations for all mandatory snapshot lines');

-- Create and activate a later master version after release. The already
-- released jobs must continue using their frozen version-2 snapshot and factor.
INSERT INTO phase6_rpc_results(name, body)
SELECT 'bom_v3',
       public.rpc_create_bom_version(
           (body->>'id')::uuid,
           'Post-release version bump to verify frozen job snapshot',
           jsonb_build_array(jsonb_build_object(
               'materialId', 'a6000000-0000-4000-8000-000000000004',
               'quantityPerUnit', 4,
               'unitId', (SELECT id FROM public.units WHERE code = 'PCS' LIMIT 1),
               'isOptional', false
           )),
           'req_phase6_create_bom_v3_001',
           'phase6-create-bom-v3-hash'
       )
FROM phase6_rpc_results WHERE name = 'bom_v2';

SELECT is((SELECT (body->>'versionNumber')::integer FROM phase6_rpc_results WHERE name = 'bom_v3'),
          3, 'Post-release BOM version bump creates version three');

INSERT INTO phase6_rpc_results(name, body)
SELECT 'activate_v3',
       public.rpc_activate_bom_version(
           (body->>'id')::uuid,
           'req_phase6_activate_bom_v3_001',
           'phase6-activate-bom-v3-hash'
       )
FROM phase6_rpc_results WHERE name = 'bom_v3';

SELECT is((SELECT body->>'status' FROM phase6_rpc_results WHERE name = 'activate_v3'),
          'ACTIVE', 'Version three becomes the active master BOM');

SELECT is(
    (SELECT min(s.bom_version)
     FROM public.packing_jobs pj
     JOIN public.packing_job_bom_snapshots s ON s.packing_job_id = pj.id
     WHERE pj.daily_plan_id = (SELECT (body->>'id')::uuid FROM phase6_rpc_results WHERE name = 'daily_plan')
       AND s.source_bom_id = (SELECT (body->>'id')::uuid FROM phase6_rpc_results WHERE name = 'bom_v2')),
    2,
    'Released master-derived jobs retain their version-two snapshot after version three activates'
);

SELECT is(
    (SELECT min(sl.canonical_qty_per_unit)
     FROM public.packing_jobs pj
     JOIN public.packing_job_bom_snapshots s ON s.packing_job_id = pj.id
     JOIN public.packing_job_bom_snapshot_lines sl ON sl.snapshot_id = s.id
     WHERE pj.daily_plan_id = (SELECT (body->>'id')::uuid FROM phase6_rpc_results WHERE name = 'daily_plan')
       AND s.source_bom_id = (SELECT (body->>'id')::uuid FROM phase6_rpc_results WHERE name = 'bom_v2')),
    3::numeric,
    'Frozen version-two consumption factors do not change after a new master version'
);

-- A planned job reduction must retain completed output and maintain the
-- five-variable conservation identity.
INSERT INTO public.daily_plans (
    id, plan_number, plan_date, shift_code, created_by, status, notes
) VALUES (
    'a6000000-0000-4000-8000-000000000006',
    'PLAN-PHASE6-REVISION',
    current_date + 2,
    'PHASE6_REVISION',
    'a6000000-0000-4000-8000-000000000001',
    'DRAFT',
    'Revision/cancellation test'
);

INSERT INTO public.packing_jobs (
    id, daily_plan_id, job_code, party_id, product_id, master_bom_id,
    original_planned_quantity, current_revised_quantity, completed_quantity,
    pending_quantity, cancelled_quantity, status
) VALUES (
    'a6000000-0000-4000-8000-000000000007',
    'a6000000-0000-4000-8000-000000000006',
    'JOB-PHASE6-REVISION',
    'a6000000-0000-4000-8000-000000000002',
    'a6000000-0000-4000-8000-000000000003',
    (SELECT (body->>'id')::uuid FROM phase6_rpc_results WHERE name = 'bom_v2'),
    520, 520, 100, 420, 0, 'IN_PROGRESS'
);

SELECT throws_ok(
    $$SELECT public.rpc_revise_packing_job_api(
        'a6000000-0000-4000-8000-000000000007',
        99,
        'Invalid below completed output',
        'req_phase6_revision_too_low_001',
        'phase6-invalid-revision-hash'
    )$$,
    '23514',
    NULL,
    'Job revision below the completed quantity is rejected'
);

INSERT INTO phase6_rpc_results(name, body)
VALUES (
    'revised_job',
    public.rpc_revise_packing_job_api(
        'a6000000-0000-4000-8000-000000000007',
        450,
        'Customer demand reduced from 520 to 450',
        'req_phase6_revision_450_0001',
        'phase6-revision-450-hash'
    )
);

SELECT is((SELECT (body->'quantityStatus'->>'pendingQuantity')::integer
           FROM phase6_rpc_results WHERE name = 'revised_job'),
          350, 'Revision to 450 with 100 completed leaves 350 pending');

INSERT INTO phase6_rpc_results(name, body)
VALUES (
    'cancelled_job',
    public.rpc_cancel_packing_job_api(
        'a6000000-0000-4000-8000-000000000007',
        'Remaining customer order cancelled',
        'req_phase6_cancel_job_0001',
        'phase6-cancel-job-hash'
    )
);

SELECT is((SELECT body->>'status' FROM phase6_rpc_results WHERE name = 'cancelled_job'),
          'CANCELLED', 'Packing job cancellation runs through the transactional API');
SELECT ok(
    (SELECT current_revised_quantity = 450
            AND completed_quantity = 100
            AND pending_quantity = 0
            AND cancelled_quantity = 350
            AND current_revised_quantity = completed_quantity + pending_quantity + cancelled_quantity
     FROM public.packing_jobs
     WHERE id = 'a6000000-0000-4000-8000-000000000007'),
    'Cancellation preserves 100 completed units and maintains 450 = 100 + 0 + 350'
);

-- No authenticated caller may invoke low-level helper routines directly.
SELECT ok(
    NOT has_function_privilege('authenticated', 'public.fn_bom_json(uuid)', 'EXECUTE'),
    'Internal BOM JSON helper is not directly executable by authenticated callers'
);

SELECT * FROM finish();
ROLLBACK;
