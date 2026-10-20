-- =============================================================================
-- Phase 4 acceptance tests: atomic purchase order creation and purchasing RLS
-- =============================================================================
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap;
SELECT plan(16);

SELECT has_column(
    'public', 'purchase_order_lines', 'unit_price',
    'Purchase order line unit price is persisted'
);
SELECT has_function(
    'public', 'rpc_create_purchase_order',
    'Transactional purchase order creation RPC exists'
);
SELECT has_function(
    'public', 'trg_validate_goods_receipt_header_phase4',
    'GRN header validation trigger exists'
);
SELECT ok(
    NOT has_table_privilege('authenticated', 'public.purchase_orders', 'INSERT'),
    'Authenticated users cannot bypass PO creation through direct table inserts'
);
SELECT ok(
    NOT has_table_privilege('authenticated', 'public.purchase_order_lines', 'INSERT'),
    'Authenticated users cannot bypass atomic PO line creation through direct table inserts'
);

DO $$
DECLARE
    v_admin_id uuid := '00000000-0000-0000-0000-000000000041'::uuid;
    v_operator_id uuid := '00000000-0000-0000-0000-000000000042'::uuid;
    v_vendor_id uuid := gen_random_uuid();
    v_material_id uuid := gen_random_uuid();
    v_location_id uuid := gen_random_uuid();
    v_inactive_location_id uuid := gen_random_uuid();
    v_unit_id uuid;
    v_category_id uuid;
BEGIN
    SELECT id INTO v_unit_id FROM public.units WHERE code = 'KG';
    SELECT id INTO v_category_id FROM public.material_categories WHERE code = 'POLY_BAG';

    INSERT INTO auth.users (id, email)
    VALUES
      (v_admin_id, 'phase4-po-admin@packing.test'),
      (v_operator_id, 'phase4-po-operator@packing.test')
    ON CONFLICT (id) DO NOTHING;

    ALTER TABLE public.profiles DISABLE TRIGGER trg_protect_profile_role_before_update;
    INSERT INTO public.profiles (id, full_name, role, is_active)
    VALUES
      (v_admin_id, 'Phase 4 PO Admin', 'ADMIN', true),
      (v_operator_id, 'Phase 4 PO Operator', 'OPERATOR', true)
    ON CONFLICT (id) DO UPDATE
    SET role = EXCLUDED.role, is_active = EXCLUDED.is_active;
    ALTER TABLE public.profiles ENABLE TRIGGER trg_protect_profile_role_before_update;

    INSERT INTO public.vendors (id, vendor_code, name, is_active)
    VALUES (v_vendor_id, 'VEND-PHASE4-PO-01', 'Phase 4 PO Test Vendor', true);

    INSERT INTO public.materials (id, material_code, name, category_id, canonical_unit_id, is_active)
    VALUES (v_material_id, 'MAT-PHASE4-PO-01', 'Phase 4 PO Test Material', v_category_id, v_unit_id, true);

    INSERT INTO public.locations (id, location_code, name, location_type, is_leaf, is_active)
    VALUES
      (v_location_id, 'LOC-PHASE4-PO-01', 'Phase 4 Test Receiving Bay', 'RECEIVING_BAY', true, true),
      (v_inactive_location_id, 'LOC-PHASE4-PO-02', 'Phase 4 Inactive Receiving Bay', 'RECEIVING_BAY', true, false);
END $$;

SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000041', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT throws_ok(
    $$
    INSERT INTO public.goods_receipts (
        grn_number, vendor_id, invoice_number, invoice_date, received_date,
        destination_location_id, status
    ) VALUES (
        'GRN-PHASE4-BAD-DATE-01',
        (SELECT id FROM public.vendors WHERE vendor_code = 'VEND-PHASE4-PO-01'),
        'INV-PHASE4-BAD-DATE-01',
        current_date + 1,
        current_date,
        (SELECT id FROM public.locations WHERE location_code = 'LOC-PHASE4-PO-01'),
        'DRAFT'
    )
    $$,
    '23514',
    NULL,
    'GRN invoice date later than receipt date is rejected'
);

SELECT throws_ok(
    $$
    INSERT INTO public.goods_receipts (
        grn_number, vendor_id, invoice_number, invoice_date, received_date,
        destination_location_id, status
    ) VALUES (
        'GRN-PHASE4-BAD-LOCATION-01',
        (SELECT id FROM public.vendors WHERE vendor_code = 'VEND-PHASE4-PO-01'),
        'INV-PHASE4-BAD-LOCATION-01',
        current_date,
        current_date,
        (SELECT id FROM public.locations WHERE location_code = 'LOC-PHASE4-PO-02'),
        'DRAFT'
    )
    $$,
    '23514',
    NULL,
    'GRN cannot target an inactive receiving location'
);

SELECT is(
    public.rpc_create_purchase_order(
        'PO-PHASE4-TEST-001',
        (SELECT id FROM public.vendors WHERE vendor_code = 'VEND-PHASE4-PO-01'),
        current_date,
        current_date + 7,
        'Phase 4 transactional test',
        jsonb_build_array(jsonb_build_object(
            'materialId', (SELECT id FROM public.materials WHERE material_code = 'MAT-PHASE4-PO-01'),
            'orderedQuantity', 12.5,
            'unitId', (SELECT id FROM public.units WHERE code = 'KG'),
            'unitPrice', 8.75
        )),
        'req_phase4_po_create_000001',
        'phase4-po-request-hash-001'
    )->>'poNumber',
    'PO-PHASE4-TEST-001',
    'PO RPC creates a purchase order with the supplied number'
);

SELECT is(
    (SELECT status FROM public.purchase_orders WHERE po_number = 'PO-PHASE4-TEST-001'),
    'DRAFT'::text,
    'New purchase orders begin in DRAFT status'
);

SELECT is(
    (SELECT unit_price FROM public.purchase_order_lines
     WHERE po_id = (SELECT id FROM public.purchase_orders WHERE po_number = 'PO-PHASE4-TEST-001')),
    8.75::numeric,
    'Unit price is persisted on the purchase order line'
);

SELECT is(
    public.rpc_create_purchase_order(
        'PO-PHASE4-TEST-001',
        (SELECT id FROM public.vendors WHERE vendor_code = 'VEND-PHASE4-PO-01'),
        current_date,
        current_date + 7,
        'Phase 4 transactional test',
        jsonb_build_array(jsonb_build_object(
            'materialId', (SELECT id FROM public.materials WHERE material_code = 'MAT-PHASE4-PO-01'),
            'orderedQuantity', 12.5,
            'unitId', (SELECT id FROM public.units WHERE code = 'KG'),
            'unitPrice', 8.75
        )),
        'req_phase4_po_create_000001',
        'phase4-po-request-hash-001'
    )->>'id',
    (SELECT id::text FROM public.purchase_orders WHERE po_number = 'PO-PHASE4-TEST-001'),
    'Same idempotency key and hash replay the original purchase order'
);

SELECT is(
    (SELECT count(*)::integer FROM public.purchase_orders WHERE po_number = 'PO-PHASE4-TEST-001'),
    1,
    'Idempotent replay does not duplicate purchase order headers'
);

SELECT is(
    coalesce((
        SELECT sum(on_hand_quantity)
        FROM public.material_location_balances
        WHERE material_id = (SELECT id FROM public.materials WHERE material_code = 'MAT-PHASE4-PO-01')
    ), 0::numeric),
    0::numeric,
    'Purchase order creation does not increase physical stock'
);

-- Dynamic categories remain data-driven: a new ADMIN-created category requires
-- no application code changes and uses the existing authenticated RLS policy.
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000041', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SET LOCAL ROLE authenticated;
INSERT INTO public.material_categories (code, name, description)
VALUES (
    'PHASE4_DYNAMIC_CATEGORY_ACCEPTANCE',
    'Phase 4 Dynamic Category',
    'Created through the authenticated master-data path without code changes'
);
RESET ROLE;

SELECT is(
    (SELECT count(*)::integer FROM public.material_categories
     WHERE code = 'PHASE4_DYNAMIC_CATEGORY_ACCEPTANCE'),
    1,
    'Dynamic material category can be created through authenticated PostgREST-compatible RLS'
);

SELECT throws_ok(
    $$
    SELECT public.rpc_create_purchase_order(
        'PO-PHASE4-TEST-001',
        (SELECT id FROM public.vendors WHERE vendor_code = 'VEND-PHASE4-PO-01'),
        current_date,
        current_date + 7,
        'Phase 4 transactional test',
        jsonb_build_array(jsonb_build_object(
            'materialId', (SELECT id FROM public.materials WHERE material_code = 'MAT-PHASE4-PO-01'),
            'orderedQuantity', 12.5,
            'unitId', (SELECT id FROM public.units WHERE code = 'KG'),
            'unitPrice', 8.75
        )),
        'req_phase4_po_create_000001',
        'tampered-po-hash-999'
    )
    $$,
    '23505',
    NULL,
    'Reusing a PO idempotency key with a different hash is rejected'
);

SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000042', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT throws_ok(
    $$
    SELECT public.rpc_create_purchase_order(
        'PO-PHASE4-OPERATOR-001',
        (SELECT id FROM public.vendors WHERE vendor_code = 'VEND-PHASE4-PO-01'),
        current_date,
        current_date + 7,
        NULL,
        jsonb_build_array(jsonb_build_object(
            'materialId', (SELECT id FROM public.materials WHERE material_code = 'MAT-PHASE4-PO-01'),
            'orderedQuantity', 1,
            'unitId', (SELECT id FROM public.units WHERE code = 'KG'),
            'unitPrice', 1
        )),
        'req_phase4_po_operator_001',
        'operator-po-hash-001'
    )
    $$,
    '42501',
    NULL,
    'Operator role cannot create purchase orders'
);

SELECT * FROM finish();
ROLLBACK;
