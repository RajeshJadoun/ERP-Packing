-- =============================================================================
-- pgTAP Test Suite: bom_and_planning.test.sql
-- Verification of BOM versioning, partial unique index (NULLS NOT DISTINCT),
-- customized snapshots, and packing job 5-variable quantity conservation lifecycle
-- =============================================================================

BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(13);

-- 1. Setup Master Reference Data
DO $$
DECLARE
    v_unit_pcs_id uuid;
    v_cat_id uuid;
BEGIN
    SELECT id INTO v_unit_pcs_id FROM public.units WHERE code = 'PCS';
    SELECT id INTO v_cat_id FROM public.material_categories WHERE code = 'CORRUGATED_BOX';

    INSERT INTO auth.users (id, email) VALUES 
        ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'planner@packing.test')
    ON CONFLICT (id) DO NOTHING;

    ALTER TABLE public.profiles DISABLE TRIGGER trg_protect_profile_role_before_update;
    INSERT INTO public.profiles (id, full_name, role, is_active) VALUES 
        ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Test Planner', 'PLANNER', true)
    ON CONFLICT (id) DO UPDATE SET role = EXCLUDED.role, is_active = EXCLUDED.is_active;
    ALTER TABLE public.profiles ENABLE TRIGGER trg_protect_profile_role_before_update;

    INSERT INTO public.parties (id, code, name)
    VALUES ('cccccccc-0001-0000-0000-000000000000', 'CUST-TATA', 'Tata Consumer Products')
    ON CONFLICT (id) DO NOTHING;

    INSERT INTO public.products (id, sku_code, name, default_party_id)
    VALUES ('dddddddd-0001-0000-0000-000000000000', 'SKU-TEA-250G', 'Premium Green Tea 250g', 'cccccccc-0001-0000-0000-000000000000')
    ON CONFLICT (id) DO NOTHING;

    INSERT INTO public.materials (id, material_code, name, category_id, canonical_unit_id)
    VALUES ('eeeeeeee-0001-0000-0000-000000000000', 'MAT-BOX-SHIPPER', 'Shipper Carton 24x250g', v_cat_id, v_unit_pcs_id)
    ON CONFLICT (id) DO NOTHING;
END $$;

-- 2. Test: Insert First Active Party-Specific BOM
SELECT lives_ok(
    $$
    INSERT INTO public.boms (
        id, bom_code, product_id, party_id, packing_variant_name, version_number, status, created_by
    ) VALUES (
        '11111111-b001-0000-0000-000000000000', 'BOM-TEA-V1',
        'dddddddd-0001-0000-0000-000000000000', 'cccccccc-0001-0000-0000-000000000000',
        'STANDARD_EXPORT', 1, 'ACTIVE', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
    )
    $$,
    'First active BOM for recipe key created successfully'
);

-- 3. Test: Reject Second Active BOM for Same Recipe Key (idx_boms_single_active_version)
SELECT throws_ok(
    $$
    INSERT INTO public.boms (
        id, bom_code, product_id, party_id, packing_variant_name, version_number, status, created_by
    ) VALUES (
        '11111111-b002-0000-0000-000000000000', 'BOM-TEA-V2',
        'dddddddd-0001-0000-0000-000000000000', 'cccccccc-0001-0000-0000-000000000000',
        'STANDARD_EXPORT', 2, 'ACTIVE', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
    )
    $$,
    '23505',
    NULL,
    'Second active BOM rejected by idx_boms_single_active_version (duplicate active version)'
);

-- 4. Test: Superseding V1 Permits Promoting V2 to ACTIVE
UPDATE public.boms SET status = 'SUPERSEDED' WHERE id = '11111111-b001-0000-0000-000000000000';

SELECT lives_ok(
    $$
    INSERT INTO public.boms (
        id, bom_code, product_id, party_id, packing_variant_name, version_number, status, created_by
    ) VALUES (
        '11111111-b002-0000-0000-000000000000', 'BOM-TEA-V2',
        'dddddddd-0001-0000-0000-000000000000', 'cccccccc-0001-0000-0000-000000000000',
        'STANDARD_EXPORT', 2, 'ACTIVE', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
    )
    $$,
    'V2 successfully promoted to ACTIVE after V1 is SUPERSEDED'
);

-- 5. Test: Generic BOM with NULL party_id enforces single active version (NULLS NOT DISTINCT)
INSERT INTO public.boms (
    id, bom_code, product_id, party_id, packing_variant_name, version_number, status, created_by
) VALUES (
    '11111111-b003-0000-0000-000000000000', 'BOM-GEN-V1',
    'dddddddd-0001-0000-0000-000000000000', NULL,
    'GENERIC_LOCAL', 1, 'ACTIVE', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
);

SELECT throws_ok(
    $$
    INSERT INTO public.boms (
        id, bom_code, product_id, party_id, packing_variant_name, version_number, status, created_by
    ) VALUES (
        '11111111-b004-0000-0000-000000000000', 'BOM-GEN-V2',
        'dddddddd-0001-0000-0000-000000000000', NULL,
        'GENERIC_LOCAL', 2, 'ACTIVE', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
    )
    $$,
    '23505',
    NULL,
    'Second active generic BOM with NULL party_id rejected (NULLS NOT DISTINCT treated equal)'
);

-- 6. Setup Daily Plan and Packing Job for 5-Variable Conservation Lifecycle
INSERT INTO public.daily_plans (id, plan_number, plan_date, shift_code, created_by)
VALUES ('ffffffff-0001-0000-0000-000000000000', 'PLAN-2026-1019-B1', current_date, 'SHIFT_A', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');

-- Initial Release: Planned 1000 (1000 = 0 + 1000 + 0)
INSERT INTO public.packing_jobs (
    id, daily_plan_id, job_code, party_id, product_id, master_bom_id,
    original_planned_quantity, current_revised_quantity,
    completed_quantity, pending_quantity, cancelled_quantity, status
) VALUES (
    '22222222-a001-4000-8000-000000000000', 'ffffffff-0001-0000-0000-000000000000', 'JOB-TEST-001',
    'cccccccc-0001-0000-0000-000000000000', 'dddddddd-0001-0000-0000-000000000000',
    '11111111-b002-0000-0000-000000000000',
    1000, 1000, 0, 1000, 0, 'RELEASED'
);

SELECT is(
    (SELECT current_revised_quantity FROM public.packing_jobs WHERE id = '22222222-a001-4000-8000-000000000000'),
    (SELECT completed_quantity + pending_quantity + cancelled_quantity FROM public.packing_jobs WHERE id = '22222222-a001-4000-8000-000000000000'),
    'Conservation check verified at release: 1000 = 0 + 1000 + 0'
);

-- 7. Test: Partial Completion: 530 units packed -> completed=530, pending=470
UPDATE public.packing_jobs
SET completed_quantity = 530,
    pending_quantity = 470,
    status = 'PARTIALLY_COMPLETED',
    updated_at = clock_timestamp()
WHERE id = '22222222-a001-4000-8000-000000000000';

SELECT is(
    (SELECT pending_quantity FROM public.packing_jobs WHERE id = '22222222-a001-4000-8000-000000000000'),
    470,
    'Pending quantity exactly equals 470 after completing 530 units'
);

-- 8. Test: Reject Invalid Conservation Update (e.g. Broken Equality)
SELECT throws_ok(
    $$
    UPDATE public.packing_jobs
    SET completed_quantity = 600
    WHERE id = '22222222-a001-4000-8000-000000000000'
    $$,
    '23514',
    NULL,
    'Imbalanced update rejected by chk_packing_jobs_conservation constraint'
);

-- 9. Test: Revision below completed production must be rejected by RPC
SELECT set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT throws_ok(
    $$
    SELECT public.rpc_revise_packing_job('22222222-a001-4000-8000-000000000000', 500, 'Invalid reduction below completed')
    $$,
    '23514',
    NULL,
    'Revision procedure rejects revising total planned quantity below completed production (500 < 530)'
);

-- 10. Test: Cancellation of remaining pending units (470 cancelled, pending=0, completed=530 preserved)
SELECT is(
    (SELECT (public.rpc_cancel_packing_job('22222222-a001-4000-8000-000000000000', 'Customer order cancelled'))->>'status'),
    'CANCELLED',
    'Job cancelled successfully via rpc_cancel_packing_job'
);

SELECT is(
    (SELECT completed_quantity FROM public.packing_jobs WHERE id = '22222222-a001-4000-8000-000000000000'),
    530,
    'Completed production permanently preserved at 530 units after cancellation'
);

SELECT is(
    (SELECT cancelled_quantity FROM public.packing_jobs WHERE id = '22222222-a001-4000-8000-000000000000'),
    470,
    'Cancelled quantity recorded at 470 units'
);

-- 11. Test: Customized Snapshot Validation
SELECT lives_ok(
    $$
    INSERT INTO public.packing_jobs (
        id, daily_plan_id, job_code, party_id, product_id, master_bom_id,
        original_planned_quantity, current_revised_quantity,
        completed_quantity, pending_quantity, cancelled_quantity, status
    ) VALUES (
        '22222222-a002-4000-8000-000000000000', 'ffffffff-0001-0000-0000-000000000000', 'JOB-CUSTOM-002',
        'cccccccc-0001-0000-0000-000000000000', 'dddddddd-0001-0000-0000-000000000000',
        NULL, 200, 200, 0, 200, 0, 'DRAFT'
    );
    INSERT INTO public.packing_job_bom_snapshots (
        id, packing_job_id, source_bom_id, bom_version, is_customized, customization_notes, frozen_by
    ) VALUES (
        '33333333-a002-4000-8000-000000000000', '22222222-a002-4000-8000-000000000000',
        NULL, NULL, true, 'Ad-hoc customized packing specifications', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
    );
    $$,
    'Customized job snapshot with NULL source_bom_id and is_customized=true created successfully'
);

-- 12. Test: Inconsistent Customization Metadata Rejected
SELECT throws_ok(
    $$
    INSERT INTO public.packing_job_bom_snapshots (
        id, packing_job_id, source_bom_id, bom_version, is_customized, frozen_by
    ) VALUES (
        '33333333-a003-4000-8000-000000000000', '22222222-a002-4000-8000-000000000000',
        NULL, NULL, false, 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
    )
    $$,
    '23514',
    NULL,
    'Snapshot with is_customized=false and NULL source_bom_id rejected by check constraint'
);

SELECT * FROM finish();
ROLLBACK;
