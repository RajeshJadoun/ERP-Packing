-- =============================================================================
-- pgTAP: Phase 9 secured operational reporting views
-- =============================================================================
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(30);

SELECT has_view('public', 'vw_stock_by_location', 'Stock location report view exists');
SELECT has_view('public', 'vw_worker_custody_balance', 'Worker custody report view exists');
SELECT has_view('public', 'vw_material_consumption_variance', 'Consumption variance report view exists');
SELECT has_view('public', 'vw_vendor_purchase_history', 'Vendor purchase history report view exists');
SELECT has_view('public', 'vw_production_shift_summary', 'Production shift summary view exists');
SELECT has_view('public', 'vw_worker_production_output', 'Worker output report view exists');

SELECT ok(
    (SELECT COALESCE('security_invoker=true' = ANY(c.reloptions), false)
     FROM pg_class AS c JOIN pg_namespace AS n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname = 'vw_stock_by_location'),
    'Stock report executes with invoker privileges'
);
SELECT ok(
    (SELECT COALESCE('security_invoker=true' = ANY(c.reloptions), false)
     FROM pg_class AS c JOIN pg_namespace AS n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname = 'vw_worker_custody_balance'),
    'Worker custody report executes with invoker privileges'
);
SELECT ok(
    (SELECT COALESCE('security_invoker=true' = ANY(c.reloptions), false)
     FROM pg_class AS c JOIN pg_namespace AS n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname = 'vw_material_consumption_variance'),
    'Consumption variance report executes with invoker privileges'
);
SELECT ok(
    (SELECT COALESCE('security_invoker=true' = ANY(c.reloptions), false)
     FROM pg_class AS c JOIN pg_namespace AS n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname = 'vw_vendor_purchase_history'),
    'Vendor history report executes with invoker privileges'
);
SELECT ok(
    (SELECT COALESCE('security_invoker=true' = ANY(c.reloptions), false)
     FROM pg_class AS c JOIN pg_namespace AS n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname = 'vw_production_shift_summary'),
    'Production shift report executes with invoker privileges'
);
SELECT ok(
    (SELECT COALESCE('security_invoker=true' = ANY(c.reloptions), false)
     FROM pg_class AS c JOIN pg_namespace AS n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname = 'vw_worker_production_output'),
    'Worker output report executes with invoker privileges'
);

SELECT has_column('public', 'vw_stock_by_location', 'available_quantity', 'Stock report returns available quantity');
SELECT has_column('public', 'vw_worker_custody_balance', 'worker_id', 'Custody report identifies its worker');
SELECT has_column('public', 'vw_material_consumption_variance', 'variance_status', 'Consumption report preserves verification state');
SELECT has_column('public', 'vw_vendor_purchase_history', 'rejected_line_rate_pct', 'Vendor report returns rejection rate');
SELECT has_column('public', 'vw_production_shift_summary', 'completed_units', 'Shift report returns completed output');
SELECT has_column('public', 'vw_worker_production_output', 'completed_units', 'Worker report returns completed output');

SELECT ok(NOT has_table_privilege('anon', 'public.vw_stock_by_location', 'SELECT'), 'Anon cannot select stock analytics');
SELECT ok(NOT has_table_privilege('anon', 'public.vw_worker_custody_balance', 'SELECT'), 'Anon cannot select worker custody analytics');
SELECT ok(NOT has_table_privilege('anon', 'public.vw_material_consumption_variance', 'SELECT'), 'Anon cannot select consumption analytics');
SELECT ok(NOT has_table_privilege('anon', 'public.vw_vendor_purchase_history', 'SELECT'), 'Anon cannot select vendor analytics');
SELECT ok(NOT has_table_privilege('anon', 'public.vw_production_shift_summary', 'SELECT'), 'Anon cannot select shift analytics');
SELECT ok(NOT has_table_privilege('anon', 'public.vw_worker_production_output', 'SELECT'), 'Anon cannot select worker output analytics');

SELECT ok(has_table_privilege('authenticated', 'public.vw_stock_by_location', 'SELECT'), 'Authenticated callers can select stock analytics subject to underlying RLS');
SELECT ok(has_table_privilege('authenticated', 'public.vw_worker_custody_balance', 'SELECT'), 'Authenticated callers can select custody analytics subject to underlying RLS');
SELECT ok(has_table_privilege('authenticated', 'public.vw_material_consumption_variance', 'SELECT'), 'Authenticated callers can select consumption analytics subject to underlying RLS');
SELECT ok(has_table_privilege('authenticated', 'public.vw_vendor_purchase_history', 'SELECT'), 'Authenticated callers can select vendor analytics subject to underlying RLS');
SELECT ok(has_table_privilege('authenticated', 'public.vw_production_shift_summary', 'SELECT'), 'Authenticated callers can select shift analytics subject to underlying RLS');
SELECT ok(has_table_privilege('authenticated', 'public.vw_worker_production_output', 'SELECT'), 'Authenticated callers can select worker output analytics subject to underlying RLS');

SELECT * FROM finish();
ROLLBACK;
