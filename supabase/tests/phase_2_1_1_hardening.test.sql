-- =============================================================================
-- pgTAP Test Suite: Phase 2.1.1 transactional and security hardening
-- All assertions are top-level pgTAP SELECT statements so pg_prove can see
-- and sequence every planned assertion. Fixture/setup DO blocks contain no
-- pgTAP calls.
-- =============================================================================

BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(31);

-- Shared fixtures. Everything in this test is rolled back at the end.
DO $$
DECLARE
    v_user uuid := '88888888-8888-4888-8888-888888888888';
    v_base_material uuid := '88888888-8888-4888-8888-888888888001';
    v_material uuid := '88888888-8888-4888-8888-888888888002';
    v_rule uuid := '88888888-8888-4888-8888-888888888003';
    v_kg uuid;
    v_g uuid;
    v_category uuid;
BEGIN
    INSERT INTO auth.users (id, email)
    VALUES (v_user, 'phase_2_1_1@packing.test')
    ON CONFLICT (id) DO NOTHING;

    SELECT id INTO v_kg FROM public.units WHERE code = 'KG' LIMIT 1;
    SELECT id INTO v_g FROM public.units WHERE code = 'G' LIMIT 1;
    SELECT id INTO v_category FROM public.material_categories WHERE code = 'POLY_BAG' LIMIT 1;

    ALTER TABLE public.profiles DISABLE TRIGGER trg_protect_profile_role_before_update;
    INSERT INTO public.profiles(id, full_name, role, is_active)
    VALUES (v_user, 'Phase 2.1.1 Admin', 'ADMIN', true)
    ON CONFLICT (id) DO UPDATE SET role = 'ADMIN', is_active = true;
    ALTER TABLE public.profiles ENABLE TRIGGER trg_protect_profile_role_before_update;

    INSERT INTO public.materials(id, material_code, name, category_id, canonical_unit_id)
    VALUES
      (v_base_material, 'MAT-HARD-BASE', 'Hardening Baseline Material', v_category, v_kg),
      (v_material, 'MAT-HARD-8', 'Hardening Conversion Material', v_category, v_kg)
    ON CONFLICT DO NOTHING;

    INSERT INTO public.material_conversions(
        id, material_id, from_unit_id, to_unit_id, conversion_factor,
        is_exact, effective_from, created_by
    ) VALUES (
        v_rule, v_material, v_kg, v_g, 1000, true,
        clock_timestamp() - interval '1 day', v_user
    )
    ON CONFLICT (id) DO NOTHING;
END $$;

-- 1-6: API surface and idempotency guardrails.
SELECT has_function('public', 'fn_resolve_material_conversion',
    'Authoritative material conversion resolver exists');

SELECT ok(
    position('ON CONFLICT (idempotency_key) DO NOTHING' IN pg_get_functiondef(
        'public.fn_acquire_idempotency(text,text,text,uuid)'::regprocedure
    )) > 0,
    'Idempotency acquisition uses an atomic conflict-safe insert'
);

SELECT has_function('public', 'rpc_cancel_packing_job',
    'Retry-safe packing-job cancellation RPC exists');

SELECT ok(
    NOT has_function_privilege('anon', 'public.rpc_post_goods_receipt(uuid,text,text)', 'EXECUTE'),
    'anon cannot execute goods-receipt posting'
);

SELECT ok(
    NOT has_function_privilege('anon', 'public.rpc_cancel_packing_job(uuid,text)', 'EXECUTE'),
    'anon cannot execute packing-job cancellation'
);

SELECT ok(
    has_function_privilege('authenticated', 'public.rpc_cancel_packing_job_api(uuid,text,text,text)', 'EXECUTE'),
    'authenticated role can call the authorized idempotent cancellation API wrapper'
);

-- 7-8: Same-unit conversion is a no-op with an exact factor of one.
SELECT is(
    public.fn_resolve_material_conversion(
        (SELECT id FROM public.materials WHERE material_code = 'MAT-HARD-BASE'),
        (SELECT id FROM public.units WHERE code = 'KG'),
        (SELECT id FROM public.units WHERE code = 'KG')
    )->>'direction',
    'NONE',
    'Same-unit conversion uses NONE direction'
);

SELECT is(
    (public.fn_resolve_material_conversion(
        (SELECT id FROM public.materials WHERE material_code = 'MAT-HARD-BASE'),
        (SELECT id FROM public.units WHERE code = 'KG'),
        (SELECT id FROM public.units WHERE code = 'KG')
    )->>'factor')::numeric,
    1.0::numeric,
    'Same-unit conversion factor is one'
);

-- 9-10: Direct conversion uses the current effective rule.
SELECT is(
    public.fn_resolve_material_conversion(
        (SELECT id FROM public.materials WHERE material_code = 'MAT-HARD-8'),
        (SELECT id FROM public.units WHERE code = 'KG'),
        (SELECT id FROM public.units WHERE code = 'G')
    )->>'direction',
    'MULTIPLY',
    'Direct conversion uses MULTIPLY direction'
);

SELECT is(
    (public.fn_resolve_material_conversion(
        (SELECT id FROM public.materials WHERE material_code = 'MAT-HARD-8'),
        (SELECT id FROM public.units WHERE code = 'KG'),
        (SELECT id FROM public.units WHERE code = 'G')
    )->>'rule_id')::uuid,
    (SELECT id FROM public.material_conversions
     WHERE material_id = (SELECT id FROM public.materials WHERE material_code = 'MAT-HARD-8')
       AND from_unit_id = (SELECT id FROM public.units WHERE code = 'KG')
       AND to_unit_id = (SELECT id FROM public.units WHERE code = 'G')
     ORDER BY effective_from DESC LIMIT 1),
    'Direct conversion returns its authoritative rule id'
);

-- 11-12: Inverse conversion retains original-rule provenance and divides.
SELECT is(
    public.fn_resolve_material_conversion(
        (SELECT id FROM public.materials WHERE material_code = 'MAT-HARD-8'),
        (SELECT id FROM public.units WHERE code = 'G'),
        (SELECT id FROM public.units WHERE code = 'KG')
    )->>'direction',
    'DIVIDE',
    'Inverse conversion uses DIVIDE direction'
);

SELECT is(
    (public.fn_resolve_material_conversion(
        (SELECT id FROM public.materials WHERE material_code = 'MAT-HARD-8'),
        (SELECT id FROM public.units WHERE code = 'G'),
        (SELECT id FROM public.units WHERE code = 'KG')
    )->>'rule_id')::uuid,
    (SELECT id FROM public.material_conversions
     WHERE material_id = (SELECT id FROM public.materials WHERE material_code = 'MAT-HARD-8')
       AND from_unit_id = (SELECT id FROM public.units WHERE code = 'KG')
       AND to_unit_id = (SELECT id FROM public.units WHERE code = 'G')
     ORDER BY effective_from DESC LIMIT 1),
    'Inverse conversion points to the original conversion rule'
);

-- 13: Missing material-specific conversion fails closed.
SELECT throws_ok(
    $$
    SELECT public.fn_resolve_material_conversion(
        (SELECT id FROM public.materials WHERE material_code = 'MAT-HARD-8'),
        (SELECT id FROM public.units WHERE code = 'G'),
        (SELECT id FROM public.units WHERE code = 'BOX')
    )
    $$,
    '23514',
    NULL,
    'Missing material conversion rule is rejected'
);

-- Set authenticated admin context for the operational RPC tests.
SELECT set_config('request.jwt.claim.sub', '88888888-8888-4888-8888-888888888888', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

-- GRN fixture deliberately supplies forged accepted/canonical values. The
-- posting RPC must compute accepted quantity, canonical units and PO credit.
DO $$
DECLARE
    v_user uuid := '88888888-8888-4888-8888-888888888888';
    v_vendor uuid := '88888888-8888-4888-8888-888888888010';
    v_location uuid := '88888888-8888-4888-8888-888888888011';
    v_po uuid := '88888888-8888-4888-8888-888888888012';
    v_po_line uuid := '88888888-8888-4888-8888-888888888013';
    v_grn uuid := '88888888-8888-4888-8888-888888888014';
    v_grn_line uuid := '88888888-8888-4888-8888-888888888015';
    v_material uuid := (SELECT id FROM public.materials WHERE material_code = 'MAT-HARD-8');
    v_kg uuid := (SELECT id FROM public.units WHERE code = 'KG');
    v_g uuid := (SELECT id FROM public.units WHERE code = 'G');
    v_box uuid := (SELECT id FROM public.units WHERE code = 'BOX');
BEGIN
    INSERT INTO public.vendors(id, vendor_code, name)
    VALUES (v_vendor, 'VEND-HARD-01', 'Hardening Vendor');

    INSERT INTO public.locations(id, location_code, name, location_type, is_leaf, is_active)
    VALUES (v_location, 'LOC-HARD-01', 'Hardening Receiving', 'RECEIVING_BAY', true, true);

    INSERT INTO public.purchase_orders(id, po_number, vendor_id, order_date, status, created_by)
    VALUES (v_po, 'PO-HARD-01', v_vendor, current_date, 'APPROVED', v_user);

    INSERT INTO public.purchase_order_lines(id, po_id, material_id, ordered_quantity, unit_id)
    VALUES (v_po_line, v_po, v_material, 4.0, v_kg);

    INSERT INTO public.goods_receipts(
        id, grn_number, vendor_id, po_id, invoice_number, invoice_date,
        received_date, destination_location_id, status
    ) VALUES (
        v_grn, 'GRN-HARD-01', v_vendor, v_po, 'INV-HARD-01', current_date,
        current_date, v_location, 'DRAFT'
    );

    -- Entered 5,000 G; rejected 1 KG = 1,000 G; accepted quantity must be 4,000 G = 4 KG.
    INSERT INTO public.goods_receipt_lines(
        id, grn_id, purchase_order_line_id, material_id,
        entered_qty, entered_unit_id, rejected_qty, rejected_unit_id,
        accepted_qty, canonical_quantity, canonical_unit_id,
        conversion_rule_id, conversion_factor_used, conversion_direction,
        conversion_type_used, is_estimated_conversion,
        rejection_conversion_rule_id, rejection_conversion_factor_used,
        rejection_conversion_direction, rejection_conversion_type_used
    ) VALUES (
        v_grn_line, v_grn, v_po_line, v_material,
        5000, v_g, 1, v_kg,
        999999, 999999, v_box,
        NULL, 1, 'NONE', 'EXACT', false,
        NULL, 1, 'NONE', 'EXACT'
    );
END $$;

-- 14: Posting succeeds and returns the committed operation response.
SELECT is(
    public.rpc_post_goods_receipt(
        '88888888-8888-4888-8888-888888888014',
        'req_hardening_grn_000000001',
        'hash_hardening_grn_000000001'
    )->>'status',
    'POSTED',
    'Hardened goods receipt posts successfully'
);

-- 15-19: Receipt, PO and stock ledger quantities/provenance reconcile.
SELECT is(
    (SELECT accepted_qty FROM public.goods_receipt_lines
     WHERE id = '88888888-8888-4888-8888-888888888015'),
    4000::numeric,
    'Rejected quantity is normalized into entered units before accepted quantity is calculated'
);

SELECT is(
    (SELECT canonical_quantity FROM public.goods_receipt_lines
     WHERE id = '88888888-8888-4888-8888-888888888015'),
    4::numeric,
    'Canonical quantity is recalculated from authoritative conversion provenance'
);

SELECT is(
    (SELECT rejection_conversion_rule_id FROM public.goods_receipt_lines
     WHERE id = '88888888-8888-4888-8888-888888888015'),
    (SELECT id FROM public.material_conversions
     WHERE material_id = (SELECT id FROM public.materials WHERE material_code = 'MAT-HARD-8')
       AND from_unit_id = (SELECT id FROM public.units WHERE code = 'KG')
       AND to_unit_id = (SELECT id FROM public.units WHERE code = 'G')
     ORDER BY effective_from DESC LIMIT 1),
    'Rejected-unit conversion rule provenance is persisted'
);

SELECT is(
    (SELECT received_quantity FROM public.purchase_order_lines
     WHERE id = '88888888-8888-4888-8888-888888888013'),
    4::numeric,
    'PO received quantity is credited in the PO line unit, not the GRN entered unit'
);

SELECT is(
    (SELECT conversion_rule_id FROM public.stock_transactions
     WHERE goods_receipt_line_id = '88888888-8888-4888-8888-888888888015'
     LIMIT 1),
    (SELECT id FROM public.material_conversions
     WHERE material_id = (SELECT id FROM public.materials WHERE material_code = 'MAT-HARD-8')
       AND from_unit_id = (SELECT id FROM public.units WHERE code = 'KG')
       AND to_unit_id = (SELECT id FROM public.units WHERE code = 'G')
     ORDER BY effective_from DESC LIMIT 1),
    'Stock ledger preserves the authoritative inverse conversion rule id'
);

-- 20-21: Exact retries replay the stored response without duplicate ledger rows.
SELECT is(
    public.rpc_post_goods_receipt(
        '88888888-8888-4888-8888-888888888014',
        'req_hardening_grn_000000001',
        'hash_hardening_grn_000000001'
    )->>'status',
    'POSTED',
    'Exact goods-receipt retry replays the stored POSTED response'
);

SELECT is(
    (SELECT count(*)::integer FROM public.stock_transactions
     WHERE goods_receipt_line_id = '88888888-8888-4888-8888-888888888015'),
    1,
    'Exact goods-receipt retry leaves exactly one purchase-receipt ledger row'
);

-- 22-25: Revision RPC is retry safe.
DO $$
DECLARE
    v_user uuid := '88888888-8888-4888-8888-888888888888';
    v_party uuid := '88888888-8888-4888-8888-888888888020';
    v_product uuid := '88888888-8888-4888-8888-888888888021';
    v_plan uuid := '88888888-8888-4888-8888-888888888022';
    v_job uuid := '88888888-8888-4888-8888-888888888023';
BEGIN
    INSERT INTO public.parties(id, code, name)
    VALUES (v_party, 'PART-HARD-01', 'Hardening Party');

    INSERT INTO public.products(id, sku_code, name)
    VALUES (v_product, 'SKU-HARD-01', 'Hardening Product');

    INSERT INTO public.daily_plans(id, plan_number, plan_date, shift_code, created_by)
    VALUES (v_plan, 'PLAN-HARD-01', current_date, 'A', v_user);

    INSERT INTO public.packing_jobs(
        id, daily_plan_id, job_code, party_id, product_id,
        original_planned_quantity, current_revised_quantity,
        completed_quantity, pending_quantity, cancelled_quantity, status, priority
    ) VALUES (
        v_job, v_plan, 'JOB-HARD-REV-01', v_party, v_product,
        10, 10, 0, 10, 0, 'RELEASED', 1
    );
END $$;

SELECT lives_ok(
    $$SELECT public.rpc_revise_packing_job(
        '88888888-8888-4888-8888-888888888023', 12, 'Increase by customer request')$$,
    'First revision call succeeds'
);

SELECT lives_ok(
    $$SELECT public.rpc_revise_packing_job(
        '88888888-8888-4888-8888-888888888023', 12, 'Increase by customer request')$$,
    'Identical revision retry succeeds without duplicate work'
);

SELECT is(
    (SELECT current_revised_quantity FROM public.packing_jobs
     WHERE id = '88888888-8888-4888-8888-888888888023'),
    12,
    'Revision retry leaves the requested revised quantity at 12'
);

SELECT is(
    (SELECT count(*)::integer FROM public.packing_job_revisions
     WHERE packing_job_id = '88888888-8888-4888-8888-888888888023'),
    1,
    'Identical revision retry creates one revision row'
);

-- 26-30: Cancellation applies once and the stored response is replayed.
DO $$
DECLARE
    v_user uuid := '88888888-8888-4888-8888-888888888888';
    v_party uuid := '88888888-8888-4888-8888-888888888030';
    v_product uuid := '88888888-8888-4888-8888-888888888031';
    v_plan uuid := '88888888-8888-4888-8888-888888888032';
    v_job uuid := '88888888-8888-4888-8888-888888888033';
BEGIN
    INSERT INTO public.parties(id, code, name)
    VALUES (v_party, 'PART-HARD-02', 'Hardening Party 2');

    INSERT INTO public.products(id, sku_code, name)
    VALUES (v_product, 'SKU-HARD-02', 'Hardening Product 2');

    INSERT INTO public.daily_plans(id, plan_number, plan_date, shift_code, created_by)
    VALUES (v_plan, 'PLAN-HARD-02', current_date + 1, 'B', v_user);

    INSERT INTO public.packing_jobs(
        id, daily_plan_id, job_code, party_id, product_id,
        original_planned_quantity, current_revised_quantity,
        completed_quantity, pending_quantity, cancelled_quantity, status, priority
    ) VALUES (
        v_job, v_plan, 'JOB-HARD-CAN-01', v_party, v_product,
        10, 10, 0, 10, 0, 'RELEASED', 1
    );
END $$;

SELECT lives_ok(
    $$SELECT public.rpc_cancel_packing_job(
        '88888888-8888-4888-8888-888888888033', 'Customer order cancelled')$$,
    'First cancellation call succeeds'
);

SELECT lives_ok(
    $$SELECT public.rpc_cancel_packing_job(
        '88888888-8888-4888-8888-888888888033', 'Customer order cancelled')$$,
    'Identical cancellation retry succeeds without duplicate work'
);

SELECT is(
    (SELECT status FROM public.packing_jobs
     WHERE id = '88888888-8888-4888-8888-888888888033'),
    'CANCELLED',
    'Retry-safe cancellation leaves the job cancelled'
);

SELECT is(
    (SELECT cancelled_quantity FROM public.packing_jobs
     WHERE id = '88888888-8888-4888-8888-888888888033'),
    10,
    'Cancellation quantity is applied exactly once'
);

SELECT is(
    (SELECT count(*)::integer FROM public.idempotency_keys
     WHERE idempotency_key = 'cancel_job:88888888-8888-4888-8888-888888888033'),
    1,
    'Cancellation retry uses one permanent idempotency header'
);

-- 31: Phase 6 disables direct updates; the API routes now write through
-- atomic SECURITY DEFINER RPCs so job creation/release remains all-or-nothing.
SELECT ok(
    NOT EXISTS (
        SELECT 1
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = 'daily_plans'
          AND policyname = 'daily_plans_update_draft_planner_admin'
    ),
    'Direct daily-plan update policy is removed in favor of transactional RPCs'
);

SELECT * FROM finish();
ROLLBACK;
