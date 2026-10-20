-- =============================================================================
-- pgTAP: Phase 7 production completion, physical consumption and shift closing
-- =============================================================================
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(21);

SELECT has_column(
    'public', 'production_completions', 'completion_policy',
    'Production completion persists the original physical/theoretical entry policy'
);
SELECT has_column(
    'public', 'material_consumption_records', 'physically_confirmed_unit_id',
    'Physical verification persists the canonical unit used by the operator'
);
SELECT has_column(
    'public', 'material_consumption_records', 'physical_measurement_method',
    'Physical verification records how quantities were measured'
);
SELECT has_column(
    'public', 'material_consumption_records', 'physical_measurement_evidence',
    'Optional physical count evidence is retained'
);
SELECT has_column(
    'public', 'daily_closings', 'pending_dispositions',
    'Shift closing records carry-forward, reschedule and cancellation dispositions'
);
SELECT has_column(
    'public', 'daily_closings', 'discrepancy_details',
    'Shift closing persists its material/custody discrepancy checklist'
);

SELECT has_function('public', 'rpc_complete_production',
    'Atomic production completion RPC exists');
SELECT has_function('public', 'rpc_verify_production_consumption',
    'Atomic physical consumption verification RPC exists');
SELECT has_function('public', 'rpc_close_daily_plan',
    'Atomic shift closing RPC exists');
SELECT has_function('public', 'rpc_reopen_daily_closing',
    'Admin-only daily closing reopen RPC exists');
SELECT has_function('public', 'fn_production_consumptions_json',
    'Internal consumption detail read model exists');

SELECT ok(
    NOT has_function_privilege(
        'anon',
        'public.rpc_complete_production(uuid,integer,uuid,text,text,text,text,jsonb)',
        'EXECUTE'
    ),
    'Anonymous callers cannot execute production completion'
);
SELECT ok(
    NOT has_function_privilege(
        'anon',
        'public.rpc_verify_production_consumption(uuid,jsonb,text,text)',
        'EXECUTE'
    ),
    'Anonymous callers cannot execute physical consumption verification'
);
SELECT ok(
    NOT has_function_privilege(
        'anon',
        'public.rpc_close_daily_plan(uuid,text,boolean,text,jsonb,text,text)',
        'EXECUTE'
    ),
    'Anonymous callers cannot execute shift closing'
);
SELECT ok(
    NOT has_function_privilege(
        'anon',
        'public.rpc_reopen_daily_closing(uuid,text,text,text)',
        'EXECUTE'
    ),
    'Anonymous callers cannot reopen shift closings'
);
SELECT ok(
    NOT has_function_privilege(
        'authenticated',
        'public.fn_production_consumptions_json(uuid)',
        'EXECUTE'
    ),
    'Authenticated clients cannot execute the private consumption read-model helper'
);

SELECT ok(
    has_function_privilege(
        'authenticated',
        'public.rpc_complete_production(uuid,integer,uuid,text,text,text,text,jsonb)',
        'EXECUTE'
    ),
    'Authenticated application requests can invoke the role-checked production completion RPC'
);
SELECT ok(
    has_function_privilege(
        'authenticated',
        'public.rpc_verify_production_consumption(uuid,jsonb,text,text)',
        'EXECUTE'
    ),
    'Authenticated application requests can invoke the role-checked physical verification RPC'
);
SELECT ok(
    has_function_privilege(
        'authenticated',
        'public.rpc_close_daily_plan(uuid,text,boolean,text,jsonb,text,text)',
        'EXECUTE'
    ),
    'Authenticated application requests can invoke the role-checked closing RPC'
);
SELECT ok(
    has_function_privilege(
        'authenticated',
        'public.rpc_reopen_daily_closing(uuid,text,text,text)',
        'EXECUTE'
    ),
    'Authenticated application requests can invoke the RPC whose body requires ADMIN'
);

SELECT is(
    (
        SELECT count(*)::integer
        FROM pg_catalog.pg_class c
        WHERE c.oid IN (
            'public.material_consumption_records'::regclass,
            'public.daily_closings'::regclass
        )
          AND c.relrowsecurity
    ),
    2,
    'Row-level security remains enabled on both production verification and closing records'
);

ROLLBACK;
