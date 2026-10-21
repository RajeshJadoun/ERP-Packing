-- Extend the append-only audit event allow-list to cover the business workflows
-- already implemented by transactional RPCs. Without these values, the audit
-- insert fails and PostgreSQL rolls back otherwise-valid stock/production work.
ALTER TABLE public.audit_logs
    DROP CONSTRAINT IF EXISTS audit_logs_event_type_check;

ALTER TABLE public.audit_logs
    ADD CONSTRAINT audit_logs_event_type_check
    CHECK (event_type IN (
        'ROLE_CHANGE',
        'OVERRIDE_CLOSING',
        'CYCLE_COUNT_APPROVED',
        'SECURITY_VIOLATION',
        'PROFILE_DEACTIVATED',
        'SYSTEM_CONFIG_CHANGED',
        'DAILY_PLAN_CLOSED',
        'PRODUCTION_COMPLETION_RECORDED',
        'PRODUCTION_CONSUMPTION_VERIFIED',
        'DAILY_CLOSING_REOPENED'
    ));
