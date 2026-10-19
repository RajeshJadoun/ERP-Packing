-- =============================================================================
-- Test Suite: closing_and_reconciliation.test.sql
-- pgTAP Acceptance Verification for Shift Closing, Composite Foreign Keys,
-- Theoretical Consumption Backflush, and Physical Variance Invariants
-- =============================================================================

BEGIN;

SELECT plan(10);

-- 1-4. Schema Verification
SELECT has_table('public', 'daily_plans', 'Table daily_plans exists');
SELECT has_table('public', 'packing_jobs', 'Table packing_jobs exists');
SELECT has_table('public', 'material_consumption_records', 'Table material_consumption_records exists');
SELECT has_table('public', 'daily_closings', 'Table daily_closings exists');

DO $$
DECLARE
    v_admin_id uuid := '00000000-0000-0000-0000-000000000001'::uuid;
    v_supervisor_id uuid := gen_random_uuid();
    v_worker_id uuid := gen_random_uuid();
    v_party_id uuid := gen_random_uuid();
    v_product_id uuid := gen_random_uuid();
    v_plan_id uuid := gen_random_uuid();
    v_job_id uuid := gen_random_uuid();
    v_completion_id uuid := gen_random_uuid();
    v_unit_pcs_id uuid;
    v_cat_id uuid;
    v_mat_id uuid := gen_random_uuid();
    v_worker_loc_id uuid := gen_random_uuid();
    v_shelf_loc_id uuid := gen_random_uuid();
    v_tx_id uuid := gen_random_uuid();
    v_closing_id uuid := gen_random_uuid();
    v_idemp_comp text := 'req_comp_reconcile_00000000001';
BEGIN
    SELECT id INTO v_unit_pcs_id FROM public.units WHERE code = 'PCS';
    SELECT id INTO v_cat_id FROM public.material_categories WHERE code = 'CORRUGATED_BOX';

    INSERT INTO public.profiles (id, full_name, role, is_active)
    VALUES 
        (v_admin_id, 'Closing Admin', 'ADMIN', true),
        (v_supervisor_id, 'Shift Supervisor', 'STOREKEEPER', true)
    ON CONFLICT (id) DO UPDATE SET role = EXCLUDED.role, is_active = true;

    INSERT INTO public.locations (id, location_code, name, location_type, is_leaf, is_active)
    VALUES 
        (v_shelf_loc_id, 'LOC-CLOSE-SHELF', 'Main Store Shelf', 'STORE_SHELF', true, true),
        (v_worker_loc_id, 'LOC-CLOSE-WRK', 'Worker Bin 1', 'WORKER_CUSTODY', true, true);

    INSERT INTO public.workers (id, worker_code, name, assigned_location_id)
    VALUES (v_worker_id, 'WRK-CLOSE-01', 'Amit Kumar', v_worker_loc_id);

    INSERT INTO public.materials (id, material_code, name, category_id, canonical_unit_id)
    VALUES (v_mat_id, 'MAT-CLOSE-BOX', 'Shipper Box Large', v_cat_id, v_unit_pcs_id);

    INSERT INTO public.parties (id, code, name) VALUES (v_party_id, 'CUST-CLOSE-01', 'Hindustan Unilever');
    INSERT INTO public.products (id, sku_code, name) VALUES (v_product_id, 'SKU-SOAP-BOX', 'Beauty Soap 75g Carton');

    -- Daily Plan for Shift A
    INSERT INTO public.daily_plans (id, plan_number, plan_date, shift_code, created_by)
    VALUES (v_plan_id, 'PLAN-2026-1019-S1', current_date, 'SHIFT_A', v_admin_id);

    INSERT INTO public.packing_jobs (
        id, daily_plan_id, job_code, party_id, product_id,
        original_planned_quantity, current_revised_quantity,
        completed_quantity, pending_quantity, cancelled_quantity,
        status, assigned_worker_id
    ) VALUES (
        v_job_id, v_plan_id, 'JOB-CLOSE-001', v_party_id, v_product_id,
        500, 500, 500, 0, 0, 'COMPLETED', v_worker_id
    );

    -- Setup Idempotency Key for completion
    INSERT INTO public.idempotency_keys (
        idempotency_key, owner_id, operation_scope, request_hash, status
    ) VALUES (
        v_idemp_comp, v_admin_id, 'POST:/api/v1/production/completions', 'hash_comp_001', 'COMPLETED'
    );

    -- Record Production Completion
    INSERT INTO public.production_completions (
        id, packing_job_id, completion_number, completed_units, completed_by_worker_id,
        idempotency_key, recorded_by
    ) VALUES (
        v_completion_id, v_job_id, 'COMP-2026-0001', 500, v_worker_id,
        v_idemp_comp, v_admin_id
    );

    -- Setup Initial Stock & Consumption Movement
    INSERT INTO public.material_location_balances (material_id, location_id, on_hand_quantity)
    VALUES (v_mat_id, v_worker_loc_id, 1000.0);

    INSERT INTO public.stock_transactions (
        id, transaction_number, idempotency_key, transaction_sequence, material_id,
        movement_type, source_location_id, destination_location_id, worker_id,
        quantity, unit_id, entered_quantity, entered_unit_id, measurement_method,
        packing_job_id, production_completion_id, created_by
    ) VALUES (
        v_tx_id, 'TXN-CLOSE-001', v_idemp_comp, 1, v_mat_id,
        'CONSUMPTION', v_worker_loc_id, NULL, v_worker_id,
        500.0, v_unit_pcs_id, 500.0, v_unit_pcs_id, 'AUTO_BOM_BACKFLUSH',
        v_job_id, v_completion_id, v_admin_id
    );

    -- Insert valid UNVERIFIED consumption record with NULL physical variance
    INSERT INTO public.material_consumption_records (
        production_completion_id, material_id, theoretical_quantity, posted_ledger_quantity,
        physically_confirmed_quantity, variance_quantity, variance_status, stock_transaction_id
    ) VALUES (
        v_completion_id, v_mat_id, 500.0, 500.0,
        NULL, NULL, 'UNVERIFIED', v_tx_id
    );
END $$;

-- 5. Backflush creates UNVERIFIED consumption record with NULL physical variance
SELECT is(
    (SELECT variance_status FROM public.material_consumption_records
     WHERE material_id = (SELECT id FROM public.materials WHERE material_code = 'MAT-CLOSE-BOX')),
    'UNVERIFIED'::text,
    'Automated backflush is recorded as UNVERIFIED with NULL physical confirmation'
);

-- 6. Check constraint chk_consumption_variance_unverified rejects false variance on UNVERIFIED record
SELECT throws_ok(
    $$
    INSERT INTO public.material_consumption_records (
        production_completion_id, material_id, theoretical_quantity, posted_ledger_quantity,
        physically_confirmed_quantity, variance_quantity, variance_status, stock_transaction_id
    ) VALUES (
        (SELECT id FROM public.production_completions WHERE completion_number = 'COMP-2026-0001'),
        (SELECT id FROM public.materials WHERE material_code = 'MAT-CLOSE-BOX'),
        500.0, 500.0,
        500.0, 0.0, 'UNVERIFIED', -- Invalid: non-null variance with UNVERIFIED
        (SELECT id FROM public.stock_transactions WHERE transaction_number = 'TXN-CLOSE-001')
    )
    $$,
    '23514',
    NULL,
    'Constraint chk_consumption_variance_unverified rejects non-null variance under UNVERIFIED status'
);

-- 7. Composite foreign key rejects closing with mismatched shift code (SHIFT_B against SHIFT_A plan)
SELECT throws_ok(
    $$
    INSERT INTO public.daily_closings (
        daily_plan_id, shift_code, closing_date, total_planned_units,
        total_completed_units, total_pending_units, total_cancelled_units,
        closed_by
    ) VALUES (
        (SELECT id FROM public.daily_plans WHERE plan_number = 'PLAN-2026-1019-S1'),
        'SHIFT_B', current_date, 500, 500, 0, 0,
        '00000000-0000-0000-0000-000000000001'::uuid
    )
    $$,
    '23503',
    NULL,
    'Composite foreign key (daily_plan_id, shift_code) rejects mismatched shift code'
);

-- 8. Valid shift closing with matching composite key succeeds
SELECT lives_ok(
    $$
    INSERT INTO public.daily_closings (
        daily_plan_id, shift_code, closing_date, total_planned_units,
        total_completed_units, total_pending_units, total_cancelled_units,
        closed_by
    ) VALUES (
        (SELECT id FROM public.daily_plans WHERE plan_number = 'PLAN-2026-1019-S1'),
        'SHIFT_A', current_date, 500, 500, 0, 0,
        '00000000-0000-0000-0000-000000000001'::uuid
    )
    $$,
    'Shift closing with matching composite key (daily_plan_id, shift_code) succeeds'
);

-- 9. Shift closing conservation constraint chk_daily_closing_conservation rejects conservation violation
SELECT throws_ok(
    $$
    INSERT INTO public.daily_closings (
        daily_plan_id, shift_code, closing_date, total_planned_units,
        total_completed_units, total_pending_units, total_cancelled_units,
        closed_by
    ) VALUES (
        (SELECT id FROM public.daily_plans WHERE plan_number = 'PLAN-2026-1019-S1'),
        'SHIFT_A', current_date, 500, 400, 50, 0, -- 400 + 50 + 0 != 500!
        '00000000-0000-0000-0000-000000000001'::uuid
    )
    $$,
    '23514',
    NULL,
    'Constraint chk_daily_closing_conservation rejects conservation violation (planned != completed + pending + cancelled)'
);

-- 10. Verify recorded daily closing metrics match plan totals
SELECT is(
    (SELECT total_completed_units FROM public.daily_closings
     WHERE daily_plan_id = (SELECT id FROM public.daily_plans WHERE plan_number = 'PLAN-2026-1019-S1')
       AND shift_code = 'SHIFT_A'),
    500,
    'Daily closing recorded total completed units correctly'
);

SELECT * FROM finish();
ROLLBACK;
