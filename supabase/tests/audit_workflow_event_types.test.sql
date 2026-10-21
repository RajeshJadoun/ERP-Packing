-- pgTAP regression checks for workflow audit event types.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(4);

SELECT ok(
    (SELECT pg_get_constraintdef(oid) LIKE '%DAILY_PLAN_CLOSED%'
     FROM pg_constraint
     WHERE conrelid = 'public.audit_logs'::regclass
       AND conname = 'audit_logs_event_type_check'),
    'Audit constraint permits the normal daily-plan closing event'
);

SELECT ok(
    (SELECT pg_get_constraintdef(oid) LIKE '%PRODUCTION_COMPLETION_RECORDED%'
     FROM pg_constraint
     WHERE conrelid = 'public.audit_logs'::regclass
       AND conname = 'audit_logs_event_type_check'),
    'Audit constraint permits production completion'
);

SELECT ok(
    (SELECT pg_get_constraintdef(oid) LIKE '%PRODUCTION_CONSUMPTION_VERIFIED%'
     FROM pg_constraint
     WHERE conrelid = 'public.audit_logs'::regclass
       AND conname = 'audit_logs_event_type_check'),
    'Audit constraint permits physical consumption verification'
);

SELECT ok(
    (SELECT pg_get_constraintdef(oid) LIKE '%DAILY_CLOSING_REOPENED%'
     FROM pg_constraint
     WHERE conrelid = 'public.audit_logs'::regclass
       AND conname = 'audit_logs_event_type_check'),
    'Audit constraint permits admin reopening of a closing'
);

SELECT * FROM finish();
ROLLBACK;
