-- =============================================================================
-- pgTAP Test Suite: database_schema.test.sql
-- Verification of canonical 33-table schema, extensions, PKs, FKs, and anti-cascade rules
-- =============================================================================

BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(75);

-- 1. Required Extensions
SELECT has_extension('uuid-ossp', 'Extension uuid-ossp must be installed');
SELECT has_extension('pgcrypto', 'Extension pgcrypto must be installed');

-- 2. Verify all 33 Canonical Tables Exist
SELECT has_table('public', 'profiles', 'Table 1: profiles exists');
SELECT has_table('public', 'material_categories', 'Table 2: material_categories exists');
SELECT has_table('public', 'parties', 'Table 3: parties exists');
SELECT has_table('public', 'products', 'Table 4: products exists');
SELECT has_table('public', 'vendors', 'Table 5: vendors exists');
SELECT has_table('public', 'units', 'Table 6: units exists');
SELECT has_table('public', 'materials', 'Table 7: materials exists');
SELECT has_table('public', 'material_conversions', 'Table 8: material_conversions exists');
SELECT has_table('public', 'locations', 'Table 9: locations exists');
SELECT has_table('public', 'workers', 'Table 10: workers exists');
SELECT has_table('public', 'boms', 'Table 11: boms exists');
SELECT has_table('public', 'bom_lines', 'Table 12: bom_lines exists');
SELECT has_table('public', 'bom_revision_events', 'Table 13: bom_revision_events exists');
SELECT has_table('public', 'purchase_orders', 'Table 14: purchase_orders exists');
SELECT has_table('public', 'purchase_order_lines', 'Table 15: purchase_order_lines exists');
SELECT has_table('public', 'goods_receipts', 'Table 16: goods_receipts exists');
SELECT has_table('public', 'goods_receipt_lines', 'Table 17: goods_receipt_lines exists');
SELECT has_table('public', 'daily_plans', 'Table 18: daily_plans exists');
SELECT has_table('public', 'packing_jobs', 'Table 19: packing_jobs exists');
SELECT has_table('public', 'packing_job_bom_snapshots', 'Table 20: packing_job_bom_snapshots exists');
SELECT has_table('public', 'packing_job_bom_snapshot_lines', 'Table 21: packing_job_bom_snapshot_lines exists');
SELECT has_table('public', 'packing_job_revisions', 'Table 22: packing_job_revisions exists');
SELECT has_table('public', 'packing_job_events', 'Table 23: packing_job_events exists');
SELECT has_table('public', 'stock_reservations', 'Table 24: stock_reservations exists');
SELECT has_table('public', 'production_completions', 'Table 25: production_completions exists');
SELECT has_table('public', 'stock_transactions', 'Table 26: stock_transactions exists');
SELECT has_table('public', 'material_location_balances', 'Table 27: material_location_balances exists');
SELECT has_table('public', 'material_consumption_records', 'Table 28: material_consumption_records exists');
SELECT has_table('public', 'stock_adjustments', 'Table 29: stock_adjustments exists');
SELECT has_table('public', 'daily_closings', 'Table 30: daily_closings exists');
SELECT has_table('public', 'idempotency_keys', 'Table 31: idempotency_keys exists');
SELECT has_table('public', 'idempotency_responses', 'Table 32: idempotency_responses exists');
SELECT has_table('public', 'audit_logs', 'Table 33: audit_logs exists');

-- 3. Verify Primary Keys on All 33 Tables
SELECT has_pk('public', 'profiles', 'profiles has a primary key');
SELECT has_pk('public', 'material_categories', 'material_categories has a primary key');
SELECT has_pk('public', 'parties', 'parties has a primary key');
SELECT has_pk('public', 'products', 'products has a primary key');
SELECT has_pk('public', 'vendors', 'vendors has a primary key');
SELECT has_pk('public', 'units', 'units has a primary key');
SELECT has_pk('public', 'materials', 'materials has a primary key');
SELECT has_pk('public', 'material_conversions', 'material_conversions has a primary key');
SELECT has_pk('public', 'locations', 'locations has a primary key');
SELECT has_pk('public', 'workers', 'workers has a primary key');
SELECT has_pk('public', 'boms', 'boms has a primary key');
SELECT has_pk('public', 'bom_lines', 'bom_lines has a primary key');
SELECT has_pk('public', 'bom_revision_events', 'bom_revision_events has a primary key');
SELECT has_pk('public', 'purchase_orders', 'purchase_orders has a primary key');
SELECT has_pk('public', 'purchase_order_lines', 'purchase_order_lines has a primary key');
SELECT has_pk('public', 'goods_receipts', 'goods_receipts has a primary key');
SELECT has_pk('public', 'goods_receipt_lines', 'goods_receipt_lines has a primary key');
SELECT has_pk('public', 'daily_plans', 'daily_plans has a primary key');
SELECT has_pk('public', 'packing_jobs', 'packing_jobs has a primary key');
SELECT has_pk('public', 'packing_job_bom_snapshots', 'packing_job_bom_snapshots has a primary key');
SELECT has_pk('public', 'packing_job_bom_snapshot_lines', 'packing_job_bom_snapshot_lines has a primary key');
SELECT has_pk('public', 'packing_job_revisions', 'packing_job_revisions has a primary key');
SELECT has_pk('public', 'packing_job_events', 'packing_job_events has a primary key');
SELECT has_pk('public', 'stock_reservations', 'stock_reservations has a primary key');
SELECT has_pk('public', 'production_completions', 'production_completions has a primary key');
SELECT has_pk('public', 'stock_transactions', 'stock_transactions has a primary key');
SELECT has_pk('public', 'material_location_balances', 'material_location_balances has a primary key');
SELECT has_pk('public', 'material_consumption_records', 'material_consumption_records has a primary key');
SELECT has_pk('public', 'stock_adjustments', 'stock_adjustments has a primary key');
SELECT has_pk('public', 'daily_closings', 'daily_closings has a primary key');
SELECT has_pk('public', 'idempotency_keys', 'idempotency_keys has a primary key');
SELECT has_pk('public', 'idempotency_responses', 'idempotency_responses has a primary key');
SELECT has_pk('public', 'audit_logs', 'audit_logs has a primary key');

-- 4. Verify Phase 2.1 Specific Columns & Relationships
SELECT has_column('public', 'goods_receipt_lines', 'purchase_order_line_id', 'goods_receipt_lines has purchase_order_line_id');
SELECT has_column('public', 'stock_transactions', 'goods_receipt_line_id', 'stock_transactions has goods_receipt_line_id');

-- 5. Verify Anti-Cascade Rule: Zero unauthorized CASCADE delete foreign keys
SELECT is(
    (SELECT count(*)::integer FROM information_schema.referential_constraints rc
     JOIN information_schema.table_constraints tc ON rc.constraint_name = tc.constraint_name
     WHERE tc.table_schema = 'public' AND rc.delete_rule = 'CASCADE' AND tc.table_name != 'idempotency_responses'),
    0,
    'Zero unauthorized ON DELETE CASCADE foreign keys exist across historical domain records'
);

-- 6. Verify Partial Unique Index on BOMs
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_indexes 
        WHERE schemaname = 'public' 
          AND tablename = 'boms' 
          AND indexname = 'idx_boms_single_active_version'
    ),
    'Partial unique index idx_boms_single_active_version exists on boms'
);

-- 7. Verify Composite Unique Constraints
SELECT ok(
    EXISTS (
        SELECT 1 FROM information_schema.table_constraints
        WHERE table_schema = 'public' AND table_name = 'daily_plans' AND constraint_name = 'uq_daily_plans_id_shift'
    ),
    'Composite unique constraint (id, shift_code) exists on daily_plans'
);

-- 8. Verify Critical Functions Exist
SELECT has_function('public', 'handle_new_user', 'User provisioning function handle_new_user exists');
SELECT has_function('public', 'fn_post_stock_transaction', 'Private primitive fn_post_stock_transaction exists');

SELECT * FROM finish();
ROLLBACK;
