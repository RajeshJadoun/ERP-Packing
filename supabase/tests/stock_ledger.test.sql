-- =============================================================================
-- pgTAP Test Suite: stock_ledger.test.sql
-- Verification of immutable double-entry ledger, signed balance projection,
-- leaf location validation, quarantine isolation, and non-negative stock enforcement
-- =============================================================================

BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(16);

-- 1. Table Structure Verification
SELECT has_table('public', 'stock_transactions', 'Table stock_transactions exists');
SELECT has_table('public', 'material_location_balances', 'Table material_location_balances exists');
DO $$
DECLARE
    v_unit_kg_id uuid;
    v_unit_pcs_id uuid;
    v_cat_id uuid;
BEGIN
    SELECT id INTO v_unit_kg_id FROM public.units WHERE code = 'KG';
    SELECT id INTO v_unit_pcs_id FROM public.units WHERE code = 'PCS';
    SELECT id INTO v_cat_id FROM public.material_categories WHERE code = 'POLY_BAG';

    -- Test user
    INSERT INTO auth.users (id, email) VALUES 
        ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'storekeeper@packing.test')
    ON CONFLICT (id) DO NOTHING;

    INSERT INTO public.profiles (id, full_name, role, is_active) VALUES 
        ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Test Storekeeper', 'STOREKEEPER', true)
    ON CONFLICT (id) DO NOTHING;

    -- Material
    INSERT INTO public.materials (id, material_code, name, category_id, canonical_unit_id)
    VALUES ('mmmmmmmm-mmmm-mmmm-mmmm-mmmmmmmmmmmm', 'MAT-LEDGER-001', 'LDPE Liner Bag', v_cat_id, v_unit_kg_id)
    ON CONFLICT (id) DO NOTHING;

    -- Locations: Parent (not leaf), Shelf (leaf), Buffer (leaf), Quarantine (leaf), Worker Custody (leaf)
    INSERT INTO public.locations (id, location_code, name, location_type, is_leaf, is_active)
    VALUES ('11111111-0000-0000-0000-000000000000', 'LOC-PARENT-MAIN', 'Main Plant Building', 'STORE_SHELF', false, true)
    ON CONFLICT (id) DO NOTHING;

    INSERT INTO public.locations (id, location_code, name, parent_location_id, location_type, is_leaf, is_active)
    VALUES 
        ('11111111-0001-0000-0000-000000000000', 'LOC-LEAF-SHELF1', 'Raw Material Shelf A', '11111111-0000-0000-0000-000000000000', 'STORE_SHELF', true, true),
        ('11111111-0002-0000-0000-000000000000', 'LOC-LEAF-BUFF1', 'Line 1 Buffer Rack', '11111111-0000-0000-0000-000000000000', 'SHOP_FLOOR_BUFFER', true, true),
        ('11111111-0003-0000-0000-000000000000', 'LOC-LEAF-QUAR1', 'Quarantine Segregation Cage', '11111111-0000-0000-0000-000000000000', 'DAMAGE_QUARANTINE', true, true),
        ('11111111-0004-0000-0000-000000000000', 'LOC-LEAF-WRK1', 'Operator Custody Bin 1', '11111111-0000-0000-0000-000000000000', 'WORKER_CUSTODY', true, true)
    ON CONFLICT (id) DO NOTHING;

    -- Worker
    INSERT INTO public.workers (id, worker_code, name, assigned_location_id)
    VALUES ('wwwwwwww-wwww-wwww-wwww-wwwwwwwwwwww', 'WRK-OP-01', 'Ramesh Patel', '11111111-0004-0000-0000-000000000000')
    ON CONFLICT (id) DO NOTHING;
END $$;

-- 2. Test: Non-leaf Parent Location Rejection
SELECT throws_ok(
    $$
    INSERT INTO public.stock_transactions (
        transaction_number, idempotency_key, transaction_sequence, material_id,
        movement_type, source_location_id, destination_location_id, quantity, unit_id,
        entered_quantity, entered_unit_id, measurement_method, movement_reason, created_by
    ) VALUES (
        'TXN-TEST-PARENT', 'test_key_0000000000000001', 1, 'mmmmmmmm-mmmm-mmmm-mmmm-mmmmmmmmmmmm',
        'LOCATION_TRANSFER', '11111111-0000-0000-0000-000000000000', '11111111-0001-0000-0000-000000000000',
        10.0, (SELECT id FROM public.units WHERE code = 'KG'), 10.0, (SELECT id FROM public.units WHERE code = 'KG'),
        'SCALE_WEIGHED', 'Parent transfer attempt', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    )
    $$,
    '23514',
    'Posting against organizational parent location is rejected (is_leaf = false)'
);

-- 3. Test: Identical Source and Destination Location Rejection
SELECT throws_ok(
    $$
    INSERT INTO public.stock_transactions (
        transaction_number, idempotency_key, transaction_sequence, material_id,
        movement_type, source_location_id, destination_location_id, quantity, unit_id,
        entered_quantity, entered_unit_id, measurement_method, movement_reason, created_by
    ) VALUES (
        'TXN-TEST-SELF', 'test_key_0000000000000002', 1, 'mmmmmmmm-mmmm-mmmm-mmmm-mmmmmmmmmmmm',
        'LOCATION_TRANSFER', '11111111-0001-0000-0000-000000000000', '11111111-0001-0000-0000-000000000000',
        10.0, (SELECT id FROM public.units WHERE code = 'KG'), 10.0, (SELECT id FROM public.units WHERE code = 'KG'),
        'SCALE_WEIGHED', 'Self transfer attempt', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    )
    $$,
    'chk_stock_locations_distinct',
    'Identical source and destination locations rejected by check constraint'
);

-- 4. Test: Invalid NULL-Origin Damage Quarantine Rejection (Phase 2.1 Hardening)
SELECT throws_ok(
    $$
    INSERT INTO public.stock_transactions (
        transaction_number, idempotency_key, transaction_sequence, material_id,
        movement_type, source_location_id, destination_location_id, quantity, unit_id,
        entered_quantity, entered_unit_id, measurement_method, movement_reason, created_by
    ) VALUES (
        'TXN-TEST-QUAR-NULL', 'test_key_0000000000000003', 1, 'mmmmmmmm-mmmm-mmmm-mmmm-mmmmmmmmmmmm',
        'DAMAGE_QUARANTINE', NULL, '11111111-0003-0000-0000-000000000000',
        10.0, (SELECT id FROM public.units WHERE code = 'KG'), 10.0, (SELECT id FROM public.units WHERE code = 'KG'),
        'INSPECTION_AUDIT', 'Null source quarantine attempt', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    )
    $$,
    '23514',
    'DAMAGE_QUARANTINE with NULL source is rejected (cannot invent stock in quarantine)'
);

-- 5. Test: Wrong Canonical Unit Rejection
SELECT throws_ok(
    $$
    INSERT INTO public.stock_transactions (
        transaction_number, idempotency_key, transaction_sequence, material_id,
        movement_type, source_location_id, destination_location_id, quantity, unit_id,
        entered_quantity, entered_unit_id, measurement_method, movement_reason, created_by
    ) VALUES (
        'TXN-TEST-WRONG-UNIT', 'test_key_0000000000000004', 1, 'mmmmmmmm-mmmm-mmmm-mmmm-mmmmmmmmmmmm',
        'LOCATION_TRANSFER', '11111111-0001-0000-0000-000000000000', '11111111-0002-0000-0000-000000000000',
        10.0, (SELECT id FROM public.units WHERE code = 'PCS'), 10.0, (SELECT id FROM public.units WHERE code = 'PCS'),
        'SCALE_WEIGHED', 'Wrong unit attempt', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    )
    $$,
    '23514',
    'Ledger posting with non-matching canonical unit is rejected'
);

-- 6. Setup Initial Stock via Stock Adjustment (Gain: 1,000.0 KG on Shelf)
INSERT INTO public.idempotency_keys (idempotency_key, owner_id, operation_scope, request_hash, status)
VALUES ('test_key_0000000000000005', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'POST:/api/v1/stock/adjustments', 'hash5', 'COMPLETED');

INSERT INTO public.stock_adjustments (
    id, adjustment_number, material_id, location_id, counted_quantity, book_quantity, difference_quantity, reason, approved_by
) VALUES (
    'aaaaaaaa-0001-0000-0000-000000000000', 'ADJ-001', 'mmmmmmmm-mmmm-mmmm-mmmm-mmmmmmmmmmmm',
    '11111111-0001-0000-0000-000000000000', 1000.0, 0, 1000.0, 'Initial plant setup', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
);

INSERT INTO public.stock_transactions (
    transaction_number, idempotency_key, transaction_sequence, material_id,
    movement_type, source_location_id, destination_location_id, quantity, unit_id,
    entered_quantity, entered_unit_id, measurement_method, movement_reason, stock_adjustment_id, created_by
) VALUES (
    'TXN-SETUP-001', 'test_key_0000000000000005', 1, 'mmmmmmmm-mmmm-mmmm-mmmm-mmmmmmmmmmmm',
    'STOCK_ADJUSTMENT', NULL, '11111111-0001-0000-0000-000000000000',
    1000.0, (SELECT id FROM public.units WHERE code = 'KG'), 1000.0, (SELECT id FROM public.units WHERE code = 'KG'),
    'INSPECTION_AUDIT', 'Initial plant setup', 'aaaaaaaa-0001-0000-0000-000000000000', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
);

-- Verify shelf projection balance
SELECT is(
    (SELECT on_hand_quantity FROM public.material_location_balances 
     WHERE material_id = 'mmmmmmmm-mmmm-mmmm-mmmm-mmmmmmmmmmmm' AND location_id = '11111111-0001-0000-0000-000000000000'),
    1000.0,
    'Shelf balance projected synchronously to 1000.0 KG'
);

-- 7. Test: Transfer 300.0 KG Shelf -> Buffer Rack (Conserves total inventory)
INSERT INTO public.idempotency_keys (idempotency_key, owner_id, operation_scope, request_hash, status)
VALUES ('test_key_0000000000000006', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'POST:/api/v1/stock/transfer', 'hash6', 'COMPLETED');

INSERT INTO public.stock_transactions (
    transaction_number, idempotency_key, transaction_sequence, material_id,
    movement_type, source_location_id, destination_location_id, quantity, unit_id,
    entered_quantity, entered_unit_id, measurement_method, movement_reason, created_by
) VALUES (
    'TXN-TRANS-001', 'test_key_0000000000000006', 1, 'mmmmmmmm-mmmm-mmmm-mmmm-mmmmmmmmmmmm',
    'LOCATION_TRANSFER', '11111111-0001-0000-0000-000000000000', '11111111-0002-0000-0000-000000000000',
    300.0, (SELECT id FROM public.units WHERE code = 'KG'), 300.0, (SELECT id FROM public.units WHERE code = 'KG'),
    'SCALE_WEIGHED', 'Transfer to Line 1 buffer', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
);

SELECT is(
    (SELECT on_hand_quantity FROM public.material_location_balances 
     WHERE material_id = 'mmmmmmmm-mmmm-mmmm-mmmm-mmmmmmmmmmmm' AND location_id = '11111111-0001-0000-0000-000000000000'),
    700.0,
    'Shelf balance reduced to 700.0 KG after transfer'
);

SELECT is(
    (SELECT on_hand_quantity FROM public.material_location_balances 
     WHERE material_id = 'mmmmmmmm-mmmm-mmmm-mmmm-mmmmmmmmmmmm' AND location_id = '11111111-0002-0000-0000-000000000000'),
    300.0,
    'Buffer balance increased to 300.0 KG after transfer'
);

-- Total physical inventory across plant remains 1000.0 KG
SELECT is(
    (SELECT sum(on_hand_quantity)::numeric FROM public.material_location_balances WHERE material_id = 'mmmmmmmm-mmmm-mmmm-mmmm-mmmmmmmmmmmm'),
    1000.0,
    'Total physical inventory conserved at 1000.0 KG across plant'
);

-- 8. Test: Quarantine 50.0 KG Defective Material from Buffer Rack -> Quarantine Cage
INSERT INTO public.idempotency_keys (idempotency_key, owner_id, operation_scope, request_hash, status)
VALUES ('test_key_0000000000000007', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'POST:/api/v1/stock/damage-quarantine', 'hash7', 'COMPLETED');

INSERT INTO public.stock_transactions (
    transaction_number, idempotency_key, transaction_sequence, material_id,
    movement_type, source_location_id, destination_location_id, quantity, unit_id,
    entered_quantity, entered_unit_id, measurement_method, movement_reason, created_by
) VALUES (
    'TXN-QUAR-001', 'test_key_0000000000000007', 1, 'mmmmmmmm-mmmm-mmmm-mmmm-mmmmmmmmmmmm',
    'DAMAGE_QUARANTINE', '11111111-0002-0000-0000-000000000000', '11111111-0003-0000-0000-000000000000',
    50.0, (SELECT id FROM public.units WHERE code = 'KG'), 50.0, (SELECT id FROM public.units WHERE code = 'KG'),
    'INSPECTION_AUDIT', 'Torn seal batch isolated', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
);

SELECT is(
    (SELECT on_hand_quantity FROM public.material_location_balances 
     WHERE material_id = 'mmmmmmmm-mmmm-mmmm-mmmm-mmmmmmmmmmmm' AND location_id = '11111111-0003-0000-0000-000000000000'),
    50.0,
    'Quarantine balance increased to 50.0 KG'
);

-- Usable stock (Shelf + Buffer) decreased by 50.0 KG, but total stock is still 1000.0 KG
SELECT is(
    (SELECT sum(b.on_hand_quantity)::numeric FROM public.material_location_balances b
     JOIN public.locations l ON l.id = b.location_id
     WHERE b.material_id = 'mmmmmmmm-mmmm-mmmm-mmmm-mmmmmmmmmmmm' AND l.location_type IN ('STORE_SHELF', 'SHOP_FLOOR_BUFFER')),
    950.0,
    'Usable stock decreased to 950.0 KG while total plant stock remains conserved'
);

-- 9. Test: Scrap Disposal of 20.0 KG from Quarantine Cage
INSERT INTO public.idempotency_keys (idempotency_key, owner_id, operation_scope, request_hash, status)
VALUES ('test_key_0000000000000008', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'POST:/api/v1/stock/scrap-disposal', 'hash8', 'COMPLETED');

INSERT INTO public.stock_transactions (
    transaction_number, idempotency_key, transaction_sequence, material_id,
    movement_type, source_location_id, destination_location_id, quantity, unit_id,
    entered_quantity, entered_unit_id, measurement_method, movement_reason, created_by
) VALUES (
    'TXN-SCRAP-001', 'test_key_0000000000000008', 1, 'mmmmmmmm-mmmm-mmmm-mmmm-mmmmmmmmmmmm',
    'SCRAP_DISPOSAL', '11111111-0003-0000-0000-000000000000', NULL,
    20.0, (SELECT id FROM public.units WHERE code = 'KG'), 20.0, (SELECT id FROM public.units WHERE code = 'KG'),
    'INSPECTION_AUDIT', 'Approved disposal batch #88', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
);

SELECT is(
    (SELECT on_hand_quantity FROM public.material_location_balances 
     WHERE material_id = 'mmmmmmmm-mmmm-mmmm-mmmm-mmmmmmmmmmmm' AND location_id = '11111111-0003-0000-0000-000000000000'),
    30.0,
    'Quarantine balance reduced to 30.0 KG after scrap disposal'
);

SELECT is(
    (SELECT sum(on_hand_quantity)::numeric FROM public.material_location_balances WHERE material_id = 'mmmmmmmm-mmmm-mmmm-mmmm-mmmmmmmmmmmm'),
    980.0,
    'Total physical inventory permanently reduced to 980.0 KG by scrap disposal'
);

-- 10. Test: Non-Negative Stock Check (Attempt to transfer 800 KG from shelf with only 700 KG)
SELECT throws_ok(
    $$
    INSERT INTO public.stock_transactions (
        transaction_number, idempotency_key, transaction_sequence, material_id,
        movement_type, source_location_id, destination_location_id, quantity, unit_id,
        entered_quantity, entered_unit_id, measurement_method, movement_reason, created_by
    ) VALUES (
        'TXN-OVERDRAW-001', 'test_key_0000000000000009', 1, 'mmmmmmmm-mmmm-mmmm-mmmm-mmmmmmmmmmmm',
        'LOCATION_TRANSFER', '11111111-0001-0000-0000-000000000000', '11111111-0002-0000-0000-000000000000',
        800.0, (SELECT id FROM public.units WHERE code = 'KG'), 800.0, (SELECT id FROM public.units WHERE code = 'KG'),
        'SCALE_WEIGHED', 'Overdraw attempt', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    )
    $$,
    '23514',
    'Overdrawing shelf balance rejected by check constraint on material_location_balances (on_hand_quantity >= 0)'
);

-- 11. Test: Signed Ledger Aggregation Formula Reconciliation
-- Verify Balance(material, shelf) = sum(dest=shelf) - sum(src=shelf)
SELECT is(
    (SELECT coalesce(sum(CASE WHEN destination_location_id = '11111111-0001-0000-0000-000000000000' THEN quantity ELSE 0 END), 0)
          - coalesce(sum(CASE WHEN source_location_id = '11111111-0001-0000-0000-000000000000' THEN quantity ELSE 0 END), 0)
     FROM public.stock_transactions WHERE material_id = 'mmmmmmmm-mmmm-mmmm-mmmm-mmmmmmmmmmmm'),
    (SELECT on_hand_quantity FROM public.material_location_balances 
     WHERE material_id = 'mmmmmmmm-mmmm-mmmm-mmmm-mmmmmmmmmmmm' AND location_id = '11111111-0001-0000-0000-000000000000'),
    'Signed ledger formula sum(dest) - sum(src) exactly reconciles with projection on shelf'
);

SELECT * FROM finish();
ROLLBACK;
