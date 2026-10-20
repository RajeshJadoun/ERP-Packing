-- =============================================================================
-- pgTAP Test Suite: security_rls.test.sql
-- Verification of Row Level Security, fail-closed role resolution, and trigger protections
-- =============================================================================

BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(15);

-- 1. Verify RLS is enabled on all 33 tables
SELECT is(
    (SELECT count(*)::integer FROM pg_class c
     JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' 
       AND c.relname IN (
        'profiles', 'material_categories', 'parties', 'products', 'vendors',
        'units', 'materials', 'material_conversions', 'locations', 'workers',
        'boms', 'bom_lines', 'bom_revision_events', 'purchase_orders',
        'purchase_order_lines', 'goods_receipts', 'goods_receipt_lines',
        'daily_plans', 'packing_jobs', 'packing_job_bom_snapshots',
        'packing_job_bom_snapshot_lines', 'packing_job_revisions',
        'packing_job_events', 'stock_reservations', 'production_completions',
        'stock_transactions', 'material_location_balances',
        'material_consumption_records', 'stock_adjustments', 'daily_closings',
        'idempotency_keys', 'idempotency_responses', 'audit_logs'
       ) AND c.relrowsecurity = true),
    33,
    'Row Level Security is enabled on all 33 canonical tables'
);

-- 2. Verify FORCE ROW LEVEL SECURITY on all 33 tables
SELECT is(
    (SELECT count(*)::integer FROM pg_class c
     JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' 
       AND c.relname IN (
        'profiles', 'material_categories', 'parties', 'products', 'vendors',
        'units', 'materials', 'material_conversions', 'locations', 'workers',
        'boms', 'bom_lines', 'bom_revision_events', 'purchase_orders',
        'purchase_order_lines', 'goods_receipts', 'goods_receipt_lines',
        'daily_plans', 'packing_jobs', 'packing_job_bom_snapshots',
        'packing_job_bom_snapshot_lines', 'packing_job_revisions',
        'packing_job_events', 'stock_reservations', 'production_completions',
        'stock_transactions', 'material_location_balances',
        'material_consumption_records', 'stock_adjustments', 'daily_closings',
        'idempotency_keys', 'idempotency_responses', 'audit_logs'
       ) AND c.relforcerowsecurity = true),
    33,
    'FORCE ROW LEVEL SECURITY is enforced on all 33 canonical tables'
);

-- 3. Fail-Closed Role Check for Unauthenticated Caller
SELECT is(
    public.get_current_user_role(),
    NULL,
    'get_current_user_role() returns NULL for unauthenticated callers'
);

SELECT ok(
    (public.get_current_user_role() IS DISTINCT FROM 'ADMIN'),
    'Unauthenticated role fails closed against ADMIN check (NULL IS DISTINCT FROM ADMIN evaluates to TRUE)'
);

-- 4. Setup Test User Profiles in Database
INSERT INTO auth.users (id, email) VALUES 
    ('11111111-1111-1111-1111-111111111111', 'admin@packing.test'),
    ('22222222-2222-2222-2222-222222222222', 'operator@packing.test')
ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.profiles DISABLE TRIGGER trg_protect_profile_role_before_update;
INSERT INTO public.profiles (id, full_name, role, is_active) VALUES
    ('11111111-1111-1111-1111-111111111111', 'Test Admin User', 'ADMIN', true),
    ('22222222-2222-2222-2222-222222222222', 'Test Shopfloor Operator', 'OPERATOR', true)
ON CONFLICT (id) DO UPDATE SET role = EXCLUDED.role, is_active = EXCLUDED.is_active;
ALTER TABLE public.profiles ENABLE TRIGGER trg_protect_profile_role_before_update;

-- 5. Test Profile Self-Protection: Operator cannot escalate role
SELECT throws_ok(
    $$UPDATE public.profiles SET role = 'ADMIN' WHERE id = '22222222-2222-2222-2222-222222222222'$$,
    '42501',
    'trg_protect_profile_role blocks unprivileged role elevation'
);

-- 6. Test Profile Self-Protection: Operator cannot modify active status
SELECT throws_ok(
    $$UPDATE public.profiles SET is_active = false WHERE id = '22222222-2222-2222-2222-222222222222'$$,
    '42501',
    'trg_protect_profile_role blocks unprivileged active status modification'
);

-- 7. Verify Generic Stock Primitive is NOT directly executable by authenticated
SELECT ok(
    NOT has_function_privilege('authenticated', 'public.fn_post_stock_transaction(text,integer,uuid,text,uuid,uuid,uuid,numeric,uuid,numeric,uuid,text,numeric,uuid,text,text,boolean,text,uuid,uuid,uuid,uuid,uuid,uuid)', 'EXECUTE'),
    'fn_post_stock_transaction has NO direct execute privilege granted to authenticated'
);

-- 8. Verify Strict Isolation of Idempotency Tables (Zero direct PostgREST policies)
SELECT is(
    (SELECT count(*)::integer FROM pg_policies WHERE schemaname = 'public' AND tablename = 'idempotency_keys'),
    0,
    'idempotency_keys has zero policies (strict default deny for direct PostgREST)'
);

SELECT is(
    (SELECT count(*)::integer FROM pg_policies WHERE schemaname = 'public' AND tablename = 'idempotency_responses'),
    0,
    'idempotency_responses has zero policies (strict default deny for direct PostgREST)'
);

-- 9. Admin Profile RPC Access Control
-- Calling admin_update_profile_access without admin JWT context throws 42501 or 28000
SELECT throws_ok(
    $$SELECT public.admin_update_profile_access('22222222-2222-2222-2222-222222222222', 'STOREKEEPER', true, 'Promoted')$$,
    '28000',
    'admin_update_profile_access rejects unauthenticated execution (SQLSTATE 28000)'
);

-- 10. Verify Deactivated User Fails Closed. Use the seeded administrator context.
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
UPDATE public.profiles SET is_active = false WHERE id = '22222222-2222-2222-2222-222222222222';
SELECT set_config('request.jwt.claim.sub', '', true);
SELECT is(
    (SELECT role FROM public.profiles WHERE id = '22222222-2222-2222-2222-222222222222' AND is_active = true),
    NULL,
    'Inactive user resolves to NULL active role'
);

-- 11. Verify User Provisioning Function Exists
SELECT has_function('public', 'handle_new_user', 'User provisioning function handle_new_user exists');

-- 12. Verify RLS Draft-Only Update on Packing Jobs Policy Exists
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE schemaname = 'public' 
          AND tablename = 'packing_jobs' 
          AND policyname = 'packing_jobs_update_draft_planner_admin'
    ),
    'packing_jobs has draft-only direct update policy packing_jobs_update_draft_planner_admin'
);

-- 13. Audit Log Access Restricted to Admin
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE schemaname = 'public' 
          AND tablename = 'audit_logs' 
          AND policyname = 'audit_logs_select_admin_only'
    ),
    'audit_logs has admin-only select policy'
);

-- 14. Verify RLS Update on Daily Plans Policy Exists
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE schemaname = 'public' 
          AND tablename = 'daily_plans' 
          AND policyname = 'daily_plans_update_planner_admin'
    ),
    'daily_plans has direct update policy daily_plans_update_planner_admin'
);

SELECT * FROM finish();
ROLLBACK;
