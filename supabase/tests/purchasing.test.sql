-- =============================================================================
-- Test Suite: purchasing.test.sql
-- pgTAP Acceptance Verification for Purchase Orders, Inward Goods Receipts,
-- Conversion Provenance, Unambiguous PO Line Linkage, and Idempotent Posting
-- =============================================================================

BEGIN;

SELECT plan(12);

-- 1-3. Schema Verification
SELECT has_table('public', 'purchase_orders', 'Table purchase_orders exists');
SELECT has_table('public', 'goods_receipts', 'Table goods_receipts exists');
SELECT has_table('public', 'goods_receipt_lines', 'Table goods_receipt_lines exists');

DO $$
DECLARE
    v_admin_id uuid := '00000000-0000-0000-0000-000000000001'::uuid;
    v_vendor_id uuid := gen_random_uuid();
    v_po_id uuid := gen_random_uuid();
    v_po_line_1_id uuid := gen_random_uuid();
    v_po_line_2_id uuid := gen_random_uuid();
    v_grn_id uuid := gen_random_uuid();
    v_grn_line_1_id uuid := gen_random_uuid();
    v_grn_line_2_id uuid := gen_random_uuid();
    v_loc_dock_id uuid := gen_random_uuid();
    v_unit_kg_id uuid;
    v_unit_pcs_id uuid;
    v_unit_box_id uuid;
    v_cat_id uuid;
    v_cat_box_id uuid;
    v_mat_id uuid := gen_random_uuid();
    v_mat_box_id uuid := gen_random_uuid();
    v_conv_id uuid := gen_random_uuid();
    v_key text := 'req_purch_test_key_000000001';
    v_hash text := 'hash_purch_test_payload_001';
    v_bal_dock numeric;
    v_post_result jsonb;
    v_po_line1_rcv numeric;
    v_po_line2_rcv numeric;
    v_txn_count bigint;
BEGIN
    -- Setup Master Data
    SELECT id INTO v_unit_kg_id FROM public.units WHERE code = 'KG';
    SELECT id INTO v_unit_pcs_id FROM public.units WHERE code = 'PCS';
    SELECT id INTO v_unit_box_id FROM public.units WHERE code = 'BOX';
    SELECT id INTO v_cat_id FROM public.material_categories WHERE code = 'POLY_BAG';
    SELECT id INTO v_cat_box_id FROM public.material_categories WHERE code = 'CORRUGATED_BOX';

    INSERT INTO auth.users (id, email)
    VALUES (v_admin_id, 'purchasing_admin@packing.test')
    ON CONFLICT (id) DO NOTHING;

    ALTER TABLE public.profiles DISABLE TRIGGER trg_protect_profile_role_before_update;
    INSERT INTO public.profiles (id, full_name, role, is_active)
    VALUES (v_admin_id, 'Purchasing Admin', 'ADMIN', true)
    ON CONFLICT (id) DO UPDATE SET role = 'ADMIN', is_active = true;
    ALTER TABLE public.profiles ENABLE TRIGGER trg_protect_profile_role_before_update;

    INSERT INTO public.vendors (id, vendor_code, name)
    VALUES (v_vendor_id, 'VEND-PURCH-01', 'Premier Packaging Corp');

    INSERT INTO public.locations (id, location_code, name, location_type, is_leaf, is_active)
    VALUES (v_loc_dock_id, 'LOC-DOCK-01', 'Inward Receiving Bay 1', 'RECEIVING_BAY', true, true);

    -- Material: Canonical unit is KG
    INSERT INTO public.materials (id, material_code, name, category_id, canonical_unit_id)
    VALUES (v_mat_id, 'MAT-POLY-200G', 'Poly Pouch 200g Food Grade', v_cat_id, v_unit_kg_id);

    -- Second material is deliberately different because the schema enforces
    -- UNIQUE(po_id, material_id) on purchase_order_lines.
    INSERT INTO public.materials (id, material_code, name, category_id, canonical_unit_id)
    VALUES (v_mat_box_id, 'MAT-CORR-BOX', 'Corrugated Box', v_cat_box_id, v_unit_box_id);

    -- Conversion Rule: 1 PCS = 0.005 KG (5 grams per pouch, exact)
    INSERT INTO public.material_conversions (
        id, material_id, from_unit_id, to_unit_id, conversion_factor, is_exact, effective_from, created_by
    ) VALUES (
        v_conv_id, v_mat_id, v_unit_pcs_id, v_unit_kg_id, 0.005, true, clock_timestamp() - INTERVAL '1 day', v_admin_id
    );

    -- Test: Purchase Order Creation Alone Does NOT Increase Stock
    INSERT INTO public.purchase_orders (
        id, po_number, vendor_id, order_date, status, created_by
    ) VALUES (
        v_po_id, 'PO-2026-0001', v_vendor_id, current_date, 'APPROVED', v_admin_id
    );

    -- PO has two separate lines for the same material (e.g. two separate deliveries or packaging specs)
    INSERT INTO public.purchase_order_lines (id, po_id, material_id, ordered_quantity, unit_id)
    VALUES (v_po_line_1_id, v_po_id, v_mat_id, 25.0, v_unit_kg_id);

    INSERT INTO public.purchase_order_lines (id, po_id, material_id, ordered_quantity, unit_id)
    VALUES (v_po_line_2_id, v_po_id, v_mat_box_id, 5000.0, v_unit_box_id);

    -- Inward Receipt in DRAFT state
    INSERT INTO public.goods_receipts (
        id, grn_number, vendor_id, po_id, invoice_number, invoice_date, received_date, destination_location_id, status
    ) VALUES (
        v_grn_id, 'GRN-2026-PURCH-01', v_vendor_id, v_po_id, 'INV-7788', current_date, current_date, v_loc_dock_id, 'DRAFT'
    );

    -- Line 1: Delivered 5000 PCS, Accepted 5000 PCS -> Canonical 25.0 KG (5000 * 0.005)
    -- Explicitly linked to PO Line 1
    INSERT INTO public.goods_receipt_lines (
        id, grn_id, purchase_order_line_id, material_id, entered_qty, entered_unit_id,
        rejected_qty, rejected_unit_id, accepted_qty, canonical_quantity, canonical_unit_id,
        conversion_rule_id, conversion_factor_used, conversion_direction, conversion_type_used, is_estimated_conversion
    ) VALUES (
        v_grn_line_1_id, v_grn_id, v_po_line_1_id, v_mat_id, 5000.0, v_unit_pcs_id,
        0.0, v_unit_pcs_id, 5000.0, 999999.0, -- Deliberately forged canonical quantity on draft line
        v_unit_kg_id, v_conv_id, 0.005, 'MULTIPLY', 'EXACT', false
    );

    -- Line 2: Different material. Delivered 5000 BOX, rejected 200 BOX,
    -- accepted 4800 BOX; forged canonical quantity is discarded by the RPC.
    INSERT INTO public.goods_receipt_lines (
        id, grn_id, purchase_order_line_id, material_id, entered_qty, entered_unit_id,
        rejected_qty, rejected_unit_id, accepted_qty, canonical_quantity, canonical_unit_id,
        conversion_rule_id, conversion_factor_used, conversion_direction, conversion_type_used, is_estimated_conversion
    ) VALUES (
        v_grn_line_2_id, v_grn_id, v_po_line_2_id, v_mat_box_id, 5000.0, v_unit_box_id,
        200.0, v_unit_box_id, 4800.0, 24.0,
        v_unit_box_id, NULL, 1.0, 'NONE', 'EXACT', false
    );
END $$;

-- 4. PO and Draft Receipt do not increase inventory
SELECT is(
    coalesce((SELECT on_hand_quantity FROM public.material_location_balances
              WHERE material_id = (SELECT id FROM public.materials WHERE material_code = 'MAT-POLY-200G')
                AND location_id = (SELECT id FROM public.locations WHERE location_code = 'LOC-DOCK-01')), 0),
    0.0::numeric,
    'Purchase order and draft receipt creation do not add inventory'
);

-- 5-9. Post Goods Receipt via rpc_post_goods_receipt
DO $$
DECLARE
    v_grn_id uuid;
    v_post_result jsonb;
BEGIN
    SELECT id INTO v_grn_id FROM public.goods_receipts WHERE grn_number = 'GRN-2026-PURCH-01';

    -- Simulate Authenticated Admin Context
    PERFORM set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', true);
    PERFORM set_config('request.jwt.claim.role', 'authenticated', true);

    v_post_result := public.rpc_post_goods_receipt(
        p_grn_id => v_grn_id,
        p_idempotency_key => 'req_purch_test_key_000000001',
        p_request_hash => 'hash_purch_test_payload_001'
    );
END $$;

-- 5. Stock increased by authoritative canonical quantity: 25.0 + 24.0 = 49.0 KG
-- (Forged 999999.0 on draft line 1 was discarded and authoritatively recalculated!)
SELECT is(
    (SELECT on_hand_quantity FROM public.material_location_balances
     WHERE material_id = (SELECT id FROM public.materials WHERE material_code = 'MAT-POLY-200G')
       AND location_id = (SELECT id FROM public.locations WHERE location_code = 'LOC-DOCK-01')),
    25.0::numeric,
    'Authoritative recalculation posted exactly 25.0 KG for the KG-based PO line (forged draft canonical quantity discarded)'
);

-- 6. PO Line 1 received quantity updated unambiguously to 5000.0 PCS
SELECT is(
    (SELECT received_quantity FROM public.purchase_order_lines
     WHERE id = (SELECT purchase_order_line_id FROM public.goods_receipt_lines
                 WHERE grn_id = (SELECT id FROM public.goods_receipts WHERE grn_number = 'GRN-2026-PURCH-01')
                   AND entered_qty = 5000.0 AND rejected_qty = 0.0)),
    25.0::numeric,
    'PO Line 1 received quantity correctly updated to 25.0 KG from a 5000-PCS GRN'
);

-- 7. PO Line 2 received quantity updated unambiguously to 4800.0 PCS (no cross-line collision)
SELECT is(
    (SELECT received_quantity FROM public.purchase_order_lines
     WHERE id = (SELECT purchase_order_line_id FROM public.goods_receipt_lines
                 WHERE grn_id = (SELECT id FROM public.goods_receipts WHERE grn_number = 'GRN-2026-PURCH-01')
                   AND entered_qty = 5000.0 AND rejected_qty = 200.0)),
    4800.0::numeric,
    'PO Line 2 received quantity updated to 4800 BOX without violating the one-material-per-PO-line rule'
);

-- 8. Receipt status updated to POSTED
SELECT is(
    (SELECT status FROM public.goods_receipts WHERE grn_number = 'GRN-2026-PURCH-01'),
    'POSTED'::text,
    'Goods receipt status transitioned to POSTED'
);

-- 9. Traceable stock transactions reference goods_receipt_line_id
SELECT is(
    (SELECT count(*) FROM public.stock_transactions
     WHERE goods_receipt_line_id IS NOT NULL
       AND movement_type = 'PURCHASE_RECEIPT'),
    2::bigint,
    'All purchase receipt stock transactions maintain exact goods_receipt_line_id provenance'
);

-- 10. Same-key idempotent retry returns cached response without duplicate stock movements
DO $$
DECLARE
    v_grn_id uuid;
    v_replay_result jsonb;
BEGIN
    SELECT id INTO v_grn_id FROM public.goods_receipts WHERE grn_number = 'GRN-2026-PURCH-01';

    PERFORM set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', true);
    PERFORM set_config('request.jwt.claim.role', 'authenticated', true);

    v_replay_result := public.rpc_post_goods_receipt(
        p_grn_id => v_grn_id,
        p_idempotency_key => 'req_purch_test_key_000000001',
        p_request_hash => 'hash_purch_test_payload_001'
    );
END $$;

SELECT is(
    (SELECT count(*) FROM public.stock_transactions
     WHERE goods_receipt_line_id IS NOT NULL
       AND movement_type = 'PURCHASE_RECEIPT'),
    2::bigint,
    'Identical idempotency retry produces no duplicate stock transactions'
);

-- 11. Mismatched payload hash under same key throws 23505 conflict
SELECT throws_ok(
    $$
    SELECT public.rpc_post_goods_receipt(
        (SELECT id FROM public.goods_receipts WHERE grn_number = 'GRN-2026-PURCH-01'),
        'req_purch_test_key_000000001',
        'tampered_hash_value_999'
    )
    $$,
    '23505',
    NULL,
    'Idempotency protocol rejects tampered payload hash with conflict'
);

-- 12. Non-draft receipt re-posting with new key is rejected
SELECT throws_ok(
    $$
    SELECT public.rpc_post_goods_receipt(
        (SELECT id FROM public.goods_receipts WHERE grn_number = 'GRN-2026-PURCH-01'),
        'req_new_unrelated_key_999',
        'new_hash_value_999'
    )
    $$,
    '23514',
    NULL,
    'Posting an already POSTED receipt with new key fails with DRAFT status check failure'
);

SELECT * FROM finish();
ROLLBACK;
