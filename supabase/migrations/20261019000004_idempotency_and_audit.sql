-- =============================================================================
-- Migration 000004: Transactional Idempotency Infrastructure and Security Audit
-- Packing Material Inventory & BOM Management System
-- Database: Supabase PostgreSQL 15+
-- =============================================================================

-- 1. Table 31: idempotency_keys (Permanent Request Identity & Audit Header)
CREATE TABLE public.idempotency_keys (
    idempotency_key text PRIMARY KEY,
    owner_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    operation_scope text NOT NULL,
    request_hash text NOT NULL,
    status text NOT NULL DEFAULT 'PROCESSING' CHECK (status IN ('PROCESSING', 'COMPLETED')),
    resource_type text,
    resource_id uuid,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    locked_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    operation_completed_at timestamptz,
    CONSTRAINT chk_idempotency_key_format CHECK (
        idempotency_key ~ '^[A-Za-z0-9_\-\.:]{16,128}$'
    ),
    CONSTRAINT chk_idempotency_keys_resource_type CHECK (
        resource_type IS NULL OR resource_type IN (
            'GOODS_RECEIPT', 'PRODUCTION_COMPLETION', 'STOCK_TRANSACTION',
            'STOCK_ADJUSTMENT', 'PURCHASE_ORDER', 'DAILY_PLAN',
            'PACKING_JOB', 'DAILY_CLOSING', 'BOM', 'PROFILE'
        )
    )
);

CREATE INDEX idx_idempotency_keys_owner ON public.idempotency_keys(owner_id, created_at);
CREATE INDEX idx_idempotency_keys_lookup ON public.idempotency_keys(owner_id, operation_scope, request_hash);

COMMENT ON TABLE public.idempotency_keys IS 'Permanent request-identity header guaranteeing transactional idempotency without historical ledger loss.';
COMMENT ON COLUMN public.idempotency_keys.idempotency_key IS 'Client-supplied opaque token (16-128 chars). Used as authoritative primary key.';
COMMENT ON COLUMN public.idempotency_keys.owner_id IS 'Verified caller identity derived strictly from authenticated JWT sub.';
COMMENT ON COLUMN public.idempotency_keys.operation_scope IS 'Server-normalized route scope, e.g., POST:/api/v1/goods-receipts/post.';
COMMENT ON COLUMN public.idempotency_keys.resource_type IS 'Enumerated type of the root business entity created or updated.';
COMMENT ON COLUMN public.idempotency_keys.operation_completed_at IS 'Physical transaction completion timestamp used for HTTP 410 resource recovery.';

-- 2. Table 32: idempotency_responses (Ephemeral Response Cache Tier)
CREATE TABLE public.idempotency_responses (
    idempotency_key text PRIMARY KEY REFERENCES public.idempotency_keys(idempotency_key) ON DELETE CASCADE,
    response_status_code integer NOT NULL CHECK (response_status_code BETWEEN 200 AND 299),
    response_body jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    expires_at timestamptz NOT NULL DEFAULT (clock_timestamp() + INTERVAL '7 days')
);

CREATE INDEX idx_idempotency_responses_expiry ON public.idempotency_responses(expires_at);

COMMENT ON TABLE public.idempotency_responses IS 'Ephemeral cache storing serialized HTTP response payload. Can be safely pruned by background workers without foreign key violations.';

-- 3. Table 33: audit_logs (Security and Compliance Event Log)
CREATE TABLE public.audit_logs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    event_type text NOT NULL CHECK (event_type IN ('ROLE_CHANGE', 'OVERRIDE_CLOSING', 'CYCLE_COUNT_APPROVED', 'SECURITY_VIOLATION', 'PROFILE_DEACTIVATED', 'SYSTEM_CONFIG_CHANGED')),
    actor_id uuid REFERENCES public.profiles(id) ON DELETE RESTRICT,
    target_entity_type text NOT NULL,
    target_entity_id uuid,
    old_state jsonb,
    new_state jsonb,
    ip_address text,
    user_agent text,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX idx_audit_logs_event_created ON public.audit_logs(event_type, created_at);
CREATE INDEX idx_audit_logs_actor ON public.audit_logs(actor_id);
CREATE INDEX idx_audit_logs_target ON public.audit_logs(target_entity_type, target_entity_id);

COMMENT ON TABLE public.audit_logs IS 'Append-only system-wide security, privilege escalation, and supervisor override compliance trail.';
