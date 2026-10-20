-- =============================================================================
-- pgTAP Test Suite: Phase 5 stock engine
-- Conversion provenance, canonical quantities, leaf projections, and retry safety
-- =============================================================================

BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(18);

SELECT has_column(
    'public', 'stock_transactions', 'measurement_evidence',
    'Stock ledger can retain evidence for manual and sealed-bundle measurements'
);
SELECT has_function(
    'public', 'fn_normalize_stock_quantity', ARRAY['uuid', 'numeric', 'uuid'],
    'Private stock quantity normalizer exists'
);

DO $$
DECLARE
    v_category_id uuid;
    v_kg_id uuid;
    v_pcs_id uuid;
    v_user_id uuid := 'f5000000-0000-4000-8000-000000000001';
    v_material_id uuid := 'f5000000-0000-4000-8000-000000000010';
    v_converted_material_id uuid := 'f5000000-0000-4000-8000-000000000011';
    v_parent_id uuid := 'f5000000-0000-4000-8000-000000000020';
    v_shelf_id uuid := 'f5000000-0000-4000-8000-000000000021';
    v_buffer_id uuid := 'f5000000-0000-4000-8000-000000000022';
    v_adjustment_id uuid := 'f5000000-0000-4000-8000-000000000030';
    v_converted_adjustment_id uuid := 'f5000000-0000-4000-8000-000000000031';
BEGIN
    SELECT id INTO v_kg_id FROM public.units WHERE code = 'KG';
    SELECT id INTO v_pcs_id FROM public.units WHERE code = 'PCS';

    IF v_kg_id IS NULL OR v_pcs_id IS NULL THEN
        RAISE EXCEPTION 'Phase 5 test fixture requires KG and PCS standard units.';
    END IF;

    INSERT INTO auth.users (id, email)
    VALUES (v_user_id, 'phase5_storekeeper@packing.test')
    ON CONFLICT (id) DO NOTHING;

    ALTER TABLE public.profiles DISABLE TRIGGER trg_protect_profile_role_before_update;
    INSERT INTO public.profiles (id, full_name, role, is_active)
    VALUES (v_user_id, 'Phase 5 Test Storekeeper', 'STOREKEEPER', true)
    ON CONFLICT (id) DO UPDATE SET role = EXCLUDED.role, is_active = EXCLUDED.is_active;
    ALTER TABLE public.profiles ENABLE TRIGGER trg_protect_profile_role_before_update;

    INSERT INTO public.material_categories (code, name, description)
    VALUES ('PHASE5-TEST-CATEGORY', 'Phase 5 Test Category', 'Temporary pgTAP fixture')
    ON CONFLICT (code) DO NOTHING;
    SELECT id INTO v_category_id
    FROM public.material_categories
    WHERE code = 'PHASE5-TEST-CATEGORY';

    INSERT INTO public.locations (id, location_code, name, location_type, is_leaf, is_active)
    VALUES (v_parent_id, 'P5-ROOT', 'Phase 5 Test Root', 'STORE_SHELF', false, true)
    ON CONFLICT (id) DO NOTHING;
    INSERT INTO public.locations (id, location_code, name, parent_location_id, location_type, is_leaf, is_active)
    VALUES
        (v_shelf_id, 'P5-SHELF', 'Phase 5 Test Shelf', v_parent_id, 'STORE_SHELF', true, true),
        (v_buffer_id, 'P5-BUFFER', 'Phase 5 Test Buffer', v_parent_id, 'SHOP_FLOOR_BUFFER', true, true)
    ON CONFLICT (id) DO NOTHING;

    INSERT INTO public.materials (id, material_code, name, category_id, canonical_unit_id, is_active)
    VALUES
        (v_material_id, 'MAT-PHASE5-STOCK-01', 'Phase 5 Stock Material', v_category_id, v_kg_id, true),
        (v_converted_material_id, 'MAT-PHASE5-CONV-01', 'Phase 5 Converted Material', v_category_id, v_kg_id, true)
    ON CONFLICT (id) DO NOTHING;

    INSERT INTO public.material_conversions (
        material_id, from_unit_id, to_unit_id, conversion_factor, is_exact,
        effective_from, effective_to, notes, created_by
    ) VALUES (
        v_converted_material_id, v_pcs_id, v_kg_id, 0.02, true,
        clock_timestamp() - interval '1 day', NULL,
        'Phase 5 fixture: 50 PCS per KG', v_user_id
    )
    ON CONFLICT DO NOTHING;

    -- Opening stock is represented as a balanced, auditable ledger adjustment.
    INSERT INTO public.idempotency_keys (
        idempotency_key, owner_id, operation_scope, request_hash, status,
        resource_type, resource_id, operation_completed_at
    ) VALUES
        ('req_phase5_opening_000001', v_user_id, 'POST:/api/v1/stock/adjustments',
         'phase5-opening-stock-hash-1', 'COMPLETED', 'STOCK_ADJUSTMENT',
         v_adjustment_id, clock_timestamp()),
        ('req_phase5_opening_000002', v_user_id, 'POST:/api/v1/stock/adjustments',
         'phase5-opening-stock-hash-2', 'COMPLETED', 'STOCK_ADJUSTMENT',
         v_converted_adjustment_id, clock_timestamp())
    ON CONFLICT (idempotency_key) DO NOTHING;

    INSERT INTO public.stock_adjustments (
        id, adjustment_number, material_id, location_id,
        counted_quantity, book_quantity, difference_quantity, reason, approved_by
    ) VALUES
        (v_adjustment_id, 'ADJ-PHASE5-OPEN-01', v_material_id, v_shelf_id,
         100, 0, 100, 'Phase 5 opening fixture', v_user_id),
        (v_converted_adjustment_id, 'ADJ-PHASE5-OPEN-02', v_converted_material_id, v_shelf_id,
         1, 0, 1, 'Phase 5 conversion opening fixture', v_user_id)
    ON CONFLICT (id) DO NOTHING;

    INSERT INTO public.stock_transactions (
        transaction_number, idempotency_key, transaction_sequence, material_id,
        movement_type, source_location_id, destination_location_id, quantity, unit_id,
        entered_quantity, entered_unit_id, measurement_method, movement_reason,
        stock_adjustment_id, created_by
    ) VALUES
        ('TXN-PHASE5-OPEN-01', 'req_phase5_opening_000001', 1, v_material_id,
         'STOCK_ADJUSTMENT', NULL, v_shelf_id, 100, v_kg_id,
         100, v_kg_id, 'INSPECTION_AUDIT', 'Phase 5 opening fixture',
         v_adjustment_id, v_user_id),
        ('TXN-PHASE5-OPEN-02', 'req_phase5_opening_000002', 1, v_converted_material_id,
         'STOCK_ADJUSTMENT', NULL, v_shelf_id, 1, v_kg_id,
         1, v_kg_id, 'INSPECTION_AUDIT', 'Phase 5 conversion opening fixture',
         v_converted_adjustment_id, v_user_id)
    ON CONFLICT (transaction_number) DO NOTHING;
END $$;

SELECT is(
    (public.fn_normalize_stock_quantity(
        'f5000000-0000-4000-8000-000000000010',
        1,
        (SELECT canonical_unit_id FROM public.materials WHERE id = 'f5000000-0000-4000-8000-000000000010')
    )->>'canonical_quantity')::numeric,
    1::numeric,
    'Same-unit movement retains its quantity exactly'
);

SELECT is(
    public.fn_normalize_stock_quantity(
        'f5000000-0000-4000-8000-000000000010',
        1,
        (SELECT canonical_unit_id FROM public.materials WHERE id = 'f5000000-0000-4000-8000-000000000010')
    )->>'conversion_direction',
    'NONE',
    'Same-unit movement records no conversion direction'
);

SELECT is(
    (public.fn_normalize_stock_quantity(
        'f5000000-0000-4000-8000-000000000011',
        10,
        (SELECT id FROM public.units WHERE code = 'PCS')
    )->>'canonical_quantity')::numeric,
    0.20::numeric,
    'Entered quantity is converted into the material canonical unit'
);

SELECT is(
    public.fn_normalize_stock_quantity(
        'f5000000-0000-4000-8000-000000000011',
        10,
        (SELECT id FROM public.units WHERE code = 'PCS')
    )->>'conversion_direction',
    'MULTIPLY',
    'Conversion provenance records the direction of calculation'
);

SELECT is(
    public.fn_normalize_stock_quantity(
        'f5000000-0000-4000-8000-000000000011',
        10,
        (SELECT id FROM public.units WHERE code = 'PCS')
    )->>'conversion_type',
    'EXACT',
    'Exact conversion provenance is retained'
);

SELECT set_config('request.jwt.claim.sub', 'f5000000-0000-4000-8000-000000000001', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT is(
    public.rpc_transfer_stock(
        'f5000000-0000-4000-8000-000000000010',
        'f5000000-0000-4000-8000-000000000021',
        'f5000000-0000-4000-8000-000000000022',
        5,
        (SELECT canonical_unit_id FROM public.materials WHERE id = 'f5000000-0000-4000-8000-000000000010'),
        'Phase 5 test transfer',
        'req_phase5_transfer_000001',
        'phase5-transfer-hash-1'
    )->>'movementType',
    'LOCATION_TRANSFER',
    'Transfer RPC creates an authoritative location-transfer movement'
);

SELECT is(
    (SELECT on_hand_quantity FROM public.material_location_balances
     WHERE material_id = 'f5000000-0000-4000-8000-000000000010'
       AND location_id = 'f5000000-0000-4000-8000-000000000021'),
    95::numeric,
    'Transfer atomically debits the source leaf projection'
);

SELECT is(
    (SELECT on_hand_quantity FROM public.material_location_balances
     WHERE material_id = 'f5000000-0000-4000-8000-000000000010'
       AND location_id = 'f5000000-0000-4000-8000-000000000022'),
    5::numeric,
    'Transfer atomically credits the destination leaf projection'
);

SELECT is(
    (SELECT count(*)::integer FROM public.stock_transactions
     WHERE idempotency_key = 'req_phase5_transfer_000001'),
    1,
    'A transfer creates one immutable ledger transaction'
);

SELECT is(
    public.rpc_transfer_stock(
        'f5000000-0000-4000-8000-000000000010',
        'f5000000-0000-4000-8000-000000000021',
        'f5000000-0000-4000-8000-000000000022',
        5,
        (SELECT canonical_unit_id FROM public.materials WHERE id = 'f5000000-0000-4000-8000-000000000010'),
        'Phase 5 test transfer',
        'req_phase5_transfer_000001',
        'phase5-transfer-hash-1'
    )->>'stockTransactionId',
    (SELECT id::text FROM public.stock_transactions WHERE idempotency_key = 'req_phase5_transfer_000001'),
    'Matching transfer retries replay the original transaction'
);

SELECT is(
    (SELECT count(*)::integer FROM public.stock_transactions
     WHERE idempotency_key = 'req_phase5_transfer_000001'),
    1,
    'Matching idempotency replay never duplicates ledger movements'
);

SELECT is(
    (public.rpc_transfer_stock(
        'f5000000-0000-4000-8000-000000000011',
        'f5000000-0000-4000-8000-000000000021',
        'f5000000-0000-4000-8000-000000000022',
        10,
        (SELECT id FROM public.units WHERE code = 'PCS'),
        'Phase 5 conversion transfer',
        'req_phase5_conv_transfer_000001',
        'phase5-conversion-transfer-hash-1'
    )->>'quantity')::numeric,
    0.20::numeric,
    'Movement RPC posts the authoritative converted canonical quantity'
);

SELECT is(
    (SELECT on_hand_quantity FROM public.material_location_balances
     WHERE material_id = 'f5000000-0000-4000-8000-000000000011'
       AND location_id = 'f5000000-0000-4000-8000-000000000021'),
    0.80::numeric,
    'Converted movement debits the source in the canonical unit'
);

SELECT is(
    (SELECT on_hand_quantity FROM public.material_location_balances
     WHERE material_id = 'f5000000-0000-4000-8000-000000000011'
       AND location_id = 'f5000000-0000-4000-8000-000000000022'),
    0.20::numeric,
    'Converted movement credits the destination in the canonical unit'
);

SELECT is(
    (SELECT measurement_evidence FROM public.stock_transactions
     WHERE idempotency_key = 'req_phase5_conv_transfer_000001'),
    NULL::text,
    'Unmeasured transfer keeps optional measurement evidence empty'
);

SELECT ok(
    NOT has_function_privilege('anon', 'public.fn_normalize_stock_quantity(uuid,numeric,uuid)', 'EXECUTE'),
    'Anonymous callers cannot invoke the private quantity normalizer directly'
);

SELECT * FROM finish();
ROLLBACK;
