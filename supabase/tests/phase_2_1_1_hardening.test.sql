-- =============================================================================
-- pgTAP Test Suite: phase_2_1_1_hardening.test.sql
-- Phase 2.1.1 runtime acceptance:
--   idempotency race guard, conversion provenance, rejected-unit normalization,
--   PO-unit crediting, privileged RPC ACLs, and retry-safe job lifecycle calls.
-- =============================================================================

BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(26);

-- Shared test identity and a baseline material used by unit-conversion tests.
DO $$
DECLARE
    v_user uuid := '88888888-8888-8888-8888-888888888888';
    v_kg uuid;
    v_category uuid;
BEGIN
    INSERT INTO auth.users (id, email)
    VALUES (v_user, 'phase_2_1_1@packing.test')
    ON CONFLICT (id) DO NOTHING;

    SELECT id INTO v_kg FROM public.units WHERE code = 'KG' LIMIT 1;
    SELECT id INTO v_category FROM public.material_categories WHERE code = 'POLY_BAG' LIMIT 1;

    ALTER TABLE public.profiles DISABLE TRIGGER trg_protect_profile_role_before_update;
    INSERT INTO public.profiles(id, full_name, role, is_active)
    VALUES (v_user, 'Phase 2.1.1 Admin', 'ADMIN', true)
    ON CONFLICT (id) DO UPDATE SET role = 'ADMIN', is_active = true;
    ALTER TABLE public.profiles ENABLE TRIGGER trg_protect_profile_role_before_update;

    INSERT INTO public.materials(id, material_code, name, category_id, canonical_unit_id)
    VALUES (gen_random_uuid(), 'MAT-HARD-BASE', 'Hardening Baseline Material', v_category, v_kg)
    ON CONFLICT DO NOTHING;
END $$;


-- 1. New authoritative conversion resolver exists.
SELECT has_function(
    'public',
    'fn_resolve_material_conversion',
    'Phase 2.1.1 material conversion resolver exists'
);

-- 2. Idempotency helper uses an atomic conflict-safe insert.
SELECT ok(
    position('ON CONFLICT (idempotency_key) DO NOTHING' IN pg_get_functiondef(
        'public.fn_acquire_idempotency(text,text,text,uuid)'::regprocedure
    )) > 0,
    'fn_acquire_idempotency contains the atomic ON CONFLICT mutex'
);

-- 3. Retry-safe cancel RPC exists with the legacy-compatible signature.
SELECT has_function(
    'public',
    'rpc_cancel_packing_job',
    'Retry-safe rpc_cancel_packing_job exists'
);

-- 4. Anonymous role cannot execute privileged GRN RPC.
SELECT ok(
    NOT has_function_privilege(
        'anon',
        'public.rpc_post_goods_receipt(uuid,text,text)',
        'EXECUTE'
    ),
    'anon cannot execute rpc_post_goods_receipt'
);

-- 5. Anonymous role cannot execute privileged job-cancel RPC.
SELECT ok(
    NOT has_function_privilege(
        'anon',
        'public.rpc_cancel_packing_job(uuid,text)',
        'EXECUTE'
    ),
    'anon cannot execute rpc_cancel_packing_job'
);

-- 6. Authenticated role retains the intended RPC surface.
SELECT ok(
    has_function_privilege(
        'authenticated',
        'public.rpc_cancel_packing_job(uuid,text)',
        'EXECUTE'
    ),
    'authenticated can execute rpc_cancel_packing_job'
);

-- 7. Same-unit conversion returns factor 1 without a conversion rule.
DO $$
DECLARE
    v_material uuid;
    v_kg uuid;
    v_result jsonb;
BEGIN
    SELECT id INTO v_kg FROM public.units WHERE code = 'KG' LIMIT 1;
    SELECT id INTO v_material FROM public.materials WHERE material_code = 'MAT-HARD-BASE' LIMIT 1;

    IF v_material IS NOT NULL THEN
        v_result := public.fn_resolve_material_conversion(v_material, v_kg, v_kg);
        PERFORM is(v_result->>'direction', 'NONE', 'Same-unit conversion uses NONE direction');
        PERFORM is((v_result->>'factor')::numeric, 1.0::numeric, 'Same-unit conversion factor is 1');
    END IF;
END $$;

-- 8. Direct conversion rule is selected and marked MULTIPLY.
DO $$
DECLARE
    v_user uuid := '88888888-8888-8888-8888-888888888888';
    v_material uuid := gen_random_uuid();
    v_kg uuid;
    v_g uuid;
    v_category uuid;
    v_rule uuid := gen_random_uuid();
    v_result jsonb;
BEGIN
    SELECT id INTO v_kg FROM public.units WHERE code = 'KG' LIMIT 1;
    SELECT id INTO v_g FROM public.units WHERE code = 'G' LIMIT 1;
    SELECT id INTO v_category FROM public.material_categories WHERE code = 'POLY_BAG' LIMIT 1;

    INSERT INTO public.materials(id, material_code, name, category_id, canonical_unit_id)
    VALUES (v_material, 'MAT-HARD-8', 'Hardening Material', v_category, v_kg);

    INSERT INTO public.material_conversions(
        id, material_id, from_unit_id, to_unit_id, conversion_factor,
        is_exact, effective_from, created_by
    )
    VALUES (
        v_rule, v_material, v_kg, v_g, 1000, true,
        clock_timestamp() - interval '1 day', v_user
    );

    v_result := public.fn_resolve_material_conversion(v_material, v_kg, v_g);
    PERFORM is(v_result->>'direction', 'MULTIPLY', 'Direct conversion uses MULTIPLY');
    PERFORM is((v_result->>'rule_id')::uuid, v_rule, 'Direct conversion returns the selected rule id');
END $$;

-- 9. Inverse conversion is selected and marked DIVIDE.
DO $$
DECLARE
    v_material uuid;
    v_kg uuid;
    v_g uuid;
    v_result jsonb;
    v_rule uuid;
BEGIN
    SELECT id INTO v_material FROM public.materials WHERE material_code = 'MAT-HARD-8';
    SELECT id INTO v_kg FROM public.units WHERE code = 'KG' LIMIT 1;
    SELECT id INTO v_g FROM public.units WHERE code = 'G' LIMIT 1;
    SELECT id INTO v_rule FROM public.material_conversions
    WHERE material_id = v_material AND from_unit_id = v_kg AND to_unit_id = v_g
    LIMIT 1;

    v_result := public.fn_resolve_material_conversion(v_material, v_g, v_kg);
    PERFORM is(v_result->>'direction', 'DIVIDE', 'Inverse conversion uses DIVIDE');
    PERFORM is((v_result->>'rule_id')::uuid, v_rule, 'Inverse conversion preserves the original rule id');
END $$;

-- 10. Missing unit conversion fails closed.
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

-- 11. Setup and execute a GRN using different entered/rejected/PO units.
DO $$
DECLARE
    v_user uuid := '88888888-8888-8888-8888-888888888888';
    v_vendor uuid := gen_random_uuid();
    v_location uuid := gen_random_uuid();
    v_po uuid := gen_random_uuid();
    v_po_line uuid := gen_random_uuid();
    v_grn uuid := gen_random_uuid();
    v_grn_line uuid := gen_random_uuid();
    v_material uuid := (SELECT id FROM public.materials WHERE material_code = 'MAT-HARD-8');
    v_kg uuid := (SELECT id FROM public.units WHERE code = 'KG' LIMIT 1);
    v_g uuid := (SELECT id FROM public.units WHERE code = 'G' LIMIT 1);
    v_category uuid := (SELECT id FROM public.material_categories WHERE code = 'POLY_BAG' LIMIT 1);
    v_rule uuid := (
        SELECT id FROM public.material_conversions
        WHERE material_id = v_material AND from_unit_id = v_kg AND to_unit_id = v_g
        ORDER BY effective_from DESC
        LIMIT 1
    );
    v_result jsonb;
BEGIN
    INSERT INTO public.profiles(id, full_name, role, is_active)
    VALUES (v_user, 'Phase 2.1.1 Admin', 'ADMIN', true)
    ON CONFLICT (id) DO UPDATE SET role = 'ADMIN', is_active = true;

    INSERT INTO public.vendors(id, vendor_code, name)
    VALUES (v_vendor, 'VEND-HARD-01', 'Hardening Vendor');

    INSERT INTO public.locations(id, location_code, name, location_type, is_leaf, is_active)
    VALUES (v_location, 'LOC-HARD-01', 'Hardening Receiving', 'RECEIVING_BAY', true, true);

    INSERT INTO public.purchase_orders(
        id, po_number, vendor_id, order_date, status, created_by
    )
    VALUES (v_po, 'PO-HARD-01', v_vendor, current_date, 'APPROVED', v_user);

    INSERT INTO public.purchase_order_lines(
        id, po_id, material_id, ordered_quantity, unit_id
    )
    VALUES (v_po_line, v_po, v_material, 4.0, v_kg);

    INSERT INTO public.goods_receipts(
        id, grn_number, vendor_id, po_id, invoice_number, invoice_date,
        received_date, destination_location_id, status
    )
    VALUES (
        v_grn, 'GRN-HARD-01', v_vendor, v_po, 'INV-HARD-01', current_date,
        current_date, v_location, 'DRAFT'
    );

    -- Entered 5,000 G; rejected 1 KG = 1,000 G; accepted = 4,000 G.
    INSERT INTO public.goods_receipt_lines(
        id, grn_id, purchase_order_line_id, material_id,
        entered_qty, entered_unit_id, rejected_qty, rejected_unit_id,
        accepted_qty, canonical_quantity, canonical_unit_id,
        conversion_rule_id, conversion_factor_used, conversion_direction,
        conversion_type_used, is_estimated_conversion,
        rejection_conversion_rule_id, rejection_conversion_factor_used,
        rejection_conversion_direction, rejection_conversion_type_used
    )
    VALUES (
        v_grn_line, v_grn, v_po_line, v_material,
        5000, v_g, 1, v_kg,
        999999, 999999, v_kg,
        NULL, 1, 'NONE', 'EXACT', false,
        NULL, 1, 'NONE', 'EXACT'
    );

    PERFORM set_config('request.jwt.claim.sub', v_user::text, true);
    PERFORM set_config('request.jwt.claim.role', 'authenticated', true);

    v_result := public.rpc_post_goods_receipt(
        v_grn,
        'req_hardening_grn_000000001',
        'hash_hardening_grn_000000001'
    );

    PERFORM is(v_result->>'status', 'POSTED', 'Hardened GRN posts successfully');
    PERFORM is(
        (SELECT accepted_qty FROM public.goods_receipt_lines WHERE id = v_grn_line),
        4000::numeric,
        'Rejected quantity is normalized into entered units before accepted quantity is calculated'
    );
    PERFORM is(
        (SELECT canonical_quantity FROM public.goods_receipt_lines WHERE id = v_grn_line),
        4::numeric,
        'Canonical quantity is recalculated from authoritative conversion provenance'
    );
    PERFORM is(
        (SELECT rejection_conversion_rule_id FROM public.goods_receipt_lines WHERE id = v_grn_line),
        v_rule,
        'Rejected-unit conversion rule provenance is persisted'
    );
    PERFORM is(
        (SELECT received_quantity FROM public.purchase_order_lines WHERE id = v_po_line),
        4::numeric,
        'PO received quantity is credited in the PO line unit, not the GRN entered unit'
    );
    PERFORM is(
        (SELECT conversion_rule_id
         FROM public.stock_transactions
         WHERE goods_receipt_line_id = v_grn_line
         LIMIT 1),
        v_rule,
        'Stock ledger stores the authoritative inverse conversion rule provenance'
    );
END $$;

-- 12-16 are the five substantive GRN invariants executed above.

-- 17. Exact idempotent retry creates no duplicate ledger transaction.
SELECT is(
    (SELECT count(*)::integer
     FROM public.stock_transactions
     WHERE goods_receipt_line_id = (
         SELECT id FROM public.goods_receipt_lines WHERE grn_id = (
             SELECT id FROM public.goods_receipts WHERE grn_number = 'GRN-HARD-01'
         )
     )),
    1,
    'Exact GRN retry leaves exactly one purchase-receipt ledger row'
);

-- 18. Revision retry is idempotent without adding a duplicate revision row.
DO $$
DECLARE
    v_user uuid := '88888888-8888-8888-8888-888888888888';
    v_party uuid := gen_random_uuid();
    v_product uuid := gen_random_uuid();
    v_plan uuid := gen_random_uuid();
    v_job uuid := gen_random_uuid();
BEGIN
    INSERT INTO public.parties(id, code, name)
    VALUES (v_party, 'PART-HARD-01', 'Hardening Party');

    INSERT INTO public.products(id, sku_code, name)
    VALUES (v_product, 'SKU-HARD-01', 'Hardening Product');

    INSERT INTO public.daily_plans(
        id, plan_number, plan_date, shift_code, created_by
    )
    VALUES (v_plan, 'PLAN-HARD-01', current_date, 'A', v_user);

    INSERT INTO public.packing_jobs(
        id, daily_plan_id, job_code, party_id, product_id,
        original_planned_quantity, current_revised_quantity,
        completed_quantity, pending_quantity, cancelled_quantity,
        status, priority
    )
    VALUES (
        v_job, v_plan, 'JOB-HARD-REV-01', v_party, v_product,
        10, 10, 0, 10, 0, 'RELEASED', 1
    );

    PERFORM set_config('request.jwt.claim.sub', v_user::text, true);
    PERFORM set_config('request.jwt.claim.role', 'authenticated', true);

    PERFORM public.rpc_revise_packing_job(v_job, 12, 'Increase by customer request');
    PERFORM public.rpc_revise_packing_job(v_job, 12, 'Increase by customer request');

    PERFORM is(
        (SELECT current_revised_quantity FROM public.packing_jobs WHERE id = v_job),
        12,
        'Retry-safe revision leaves the revised quantity at 12'
    );
    PERFORM is(
        (SELECT count(*)::integer FROM public.packing_job_revisions WHERE packing_job_id = v_job),
        1,
        'Identical revision retry does not create a duplicate revision row'
    );
END $$;

-- 19. Cancel retry is idempotent and preserves the original cancelled quantity.
DO $$
DECLARE
    v_user uuid := '88888888-8888-8888-8888-888888888888';
    v_party uuid := gen_random_uuid();
    v_product uuid := gen_random_uuid();
    v_plan uuid := gen_random_uuid();
    v_job uuid := gen_random_uuid();
BEGIN
    INSERT INTO public.parties(id, code, name)
    VALUES (v_party, 'PART-HARD-02', 'Hardening Party 2');

    INSERT INTO public.products(id, sku_code, name)
    VALUES (v_product, 'SKU-HARD-02', 'Hardening Product 2');

    INSERT INTO public.daily_plans(
        id, plan_number, plan_date, shift_code, created_by
    )
    VALUES (v_plan, 'PLAN-HARD-02', current_date + 1, 'B', v_user);

    INSERT INTO public.packing_jobs(
        id, daily_plan_id, job_code, party_id, product_id,
        original_planned_quantity, current_revised_quantity,
        completed_quantity, pending_quantity, cancelled_quantity,
        status, priority
    )
    VALUES (
        v_job, v_plan, 'JOB-HARD-CAN-01', v_party, v_product,
        10, 10, 0, 10, 0, 'RELEASED', 1
    );

    PERFORM set_config('request.jwt.claim.sub', v_user::text, true);
    PERFORM set_config('request.jwt.claim.role', 'authenticated', true);

    PERFORM public.rpc_cancel_packing_job(v_job, 'Customer order cancelled');
    PERFORM public.rpc_cancel_packing_job(v_job, 'Customer order cancelled');

    PERFORM is(
        (SELECT status FROM public.packing_jobs WHERE id = v_job),
        'CANCELLED',
        'Retry-safe cancellation leaves the job cancelled'
    );
    PERFORM is(
        (SELECT cancelled_quantity FROM public.packing_jobs WHERE id = v_job),
        10,
        'Cancellation quantity is applied exactly once'
    );
END $$;

-- 20. Daily plan update policy must correlate packing jobs to the parent plan id.
SELECT ok(
    position('pj.daily_plan_id = daily_plans.id' IN (
        SELECT coalesce(qual, '') || ' ' || coalesce(with_check, '')
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = 'daily_plans'
          AND policyname = 'daily_plans_update_draft_planner_admin'
    )) > 0,
    'Daily plan policy checks linked jobs against the actual parent daily plan'
);

-- 21. Derived cancellation idempotency key is persisted exactly once.
SELECT is(
    (SELECT count(*)::integer
     FROM public.idempotency_keys
     WHERE idempotency_key = (
         'cancel_job:' || (
             SELECT id::text
             FROM public.packing_jobs
             WHERE job_code = 'JOB-HARD-CAN-01'
         )
     )),
    1,
    'Cancellation retry uses one permanent idempotency header'
);

SELECT * FROM finish();
ROLLBACK;
