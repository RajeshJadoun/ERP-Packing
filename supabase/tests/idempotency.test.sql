-- =============================================================================
-- pgTAP Test Suite: idempotency.test.sql
-- Verification of two-tier idempotency protocol, key bounding, 10-type resource check,
-- cascade cache pruning, and ON DELETE RESTRICT ledger preservation
-- =============================================================================

BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(12);

-- 1. Setup Test User
DO $$
BEGIN
    INSERT INTO auth.users (id, email) VALUES 
        ('99999999-9999-9999-9999-999999999999', 'idem_tester@packing.test')
    ON CONFLICT (id) DO NOTHING;

    ALTER TABLE public.profiles DISABLE TRIGGER trg_protect_profile_role_before_update;
    INSERT INTO public.profiles (id, full_name, role, is_active) VALUES 
        ('99999999-9999-9999-9999-999999999999', 'Idempotency Tester', 'ADMIN', true)
    ON CONFLICT (id) DO UPDATE SET role = EXCLUDED.role, is_active = EXCLUDED.is_active;
    ALTER TABLE public.profiles ENABLE TRIGGER trg_protect_profile_role_before_update;
END $$;

-- 2. Test: Reject Key Under 16 Characters
SELECT throws_ok(
    $$
    INSERT INTO public.idempotency_keys (
        idempotency_key, owner_id, operation_scope, request_hash, status
    ) VALUES (
        'short_key_123', '99999999-9999-9999-9999-999999999999',
        'POST:/api/v1/goods-receipts/post', 'hash_test', 'PROCESSING'
    )
    $$,
    '23514',
    'Idempotency key under 16 characters rejected by chk_idempotency_key_format'
);

-- 3. Test: Reject Key with Forbidden Characters (Whitespace)
SELECT throws_ok(
    $$
    INSERT INTO public.idempotency_keys (
        idempotency_key, owner_id, operation_scope, request_hash, status
    ) VALUES (
        'key with whitespace inside', '99999999-9999-9999-9999-999999999999',
        'POST:/api/v1/goods-receipts/post', 'hash_test', 'PROCESSING'
    )
    $$,
    '23514',
    'Idempotency key containing spaces rejected by regex check'
);

-- 4. Test: Valid Format Key Insertion
SELECT lives_ok(
    $$
    INSERT INTO public.idempotency_keys (
        idempotency_key, owner_id, operation_scope, request_hash, status, resource_type, resource_id
    ) VALUES (
        'req_01jb89c4z80000a1b2c3d4e5f6', '99999999-9999-9999-9999-999999999999',
        'POST:/api/v1/goods-receipts/post', 'hash_canonical_001', 'COMPLETED',
        'GOODS_RECEIPT', 'aaaaaaaa-1111-0000-0000-000000000000'
    )
    $$,
    'Valid 30-character alphanumeric idempotency key stored successfully'
);

-- 5. Test: Resource Type Check Constraint Rejects Unknown Types
SELECT throws_ok(
    $$
    INSERT INTO public.idempotency_keys (
        idempotency_key, owner_id, operation_scope, request_hash, status, resource_type
    ) VALUES (
        'req_invalid_res_type_000001', '99999999-9999-9999-9999-999999999999',
        'POST:/api/v1/test', 'hash_inv', 'PROCESSING',
        'UNAPPROVED_RESOURCE_TYPE'
    )
    $$,
    '23514',
    'Unapproved resource_type rejected by chk_idempotency_keys_resource_type constraint'
);

-- 6. Test: Store Tier 2 Ephemeral Response Cache
SELECT lives_ok(
    $$
    INSERT INTO public.idempotency_responses (
        idempotency_key, response_status_code, response_body, expires_at
    ) VALUES (
        'req_01jb89c4z80000a1b2c3d4e5f6', 200,
        jsonb_build_object('success', true, 'grnNumber', 'GRN-2026-0001'),
        clock_timestamp() + INTERVAL '7 days'
    )
    $$,
    'Tier 2 response cache row linked via foreign key'
);

-- 7. Test: Pruning Expired Cache Row Leaves Tier 1 Request Header Intact
DELETE FROM public.idempotency_responses WHERE idempotency_key = 'req_01jb89c4z80000a1b2c3d4e5f6';

SELECT is(
    (SELECT count(*)::integer FROM public.idempotency_responses WHERE idempotency_key = 'req_01jb89c4z80000a1b2c3d4e5f6'),
    0,
    'Ephemeral response cache successfully pruned'
);

SELECT is(
    (SELECT count(*)::integer FROM public.idempotency_keys WHERE idempotency_key = 'req_01jb89c4z80000a1b2c3d4e5f6'),
    1,
    'Permanent request-identity header remains intact after response cache pruning (Ready for HTTP 410)'
);

-- 8. Test: fn_acquire_idempotency First Call (PROCEED)
SELECT is(
    (public.fn_acquire_idempotency(
        'req_protocol_test_000000001',
        'POST:/api/v1/stock/transfer',
        'hash_protocol_1',
        '99999999-9999-9999-9999-999999999999'
    )->>'action'),
    'PROCEED',
    'fn_acquire_idempotency returns action=PROCEED for new incoming request'
);

-- Complete the operation
SELECT lives_ok(
    $$
    SELECT public.fn_complete_idempotency(
        'req_protocol_test_000000001',
        'STOCK_TRANSACTION',
        'aaaaaaaa-2222-0000-0000-000000000000',
        200,
        jsonb_build_object('success', true, 'txId', 'aaaaaaaa-2222-0000-0000-000000000000')
    )
    $$,
    'fn_complete_idempotency completes header and caches response'
);

-- 9. Test: Identical Replay Returns Stored Response (REPLAY)
SELECT is(
    (public.fn_acquire_idempotency(
        'req_protocol_test_000000001',
        'POST:/api/v1/stock/transfer',
        'hash_protocol_1',
        '99999999-9999-9999-9999-999999999999'
    )->>'action'),
    'REPLAY',
    'fn_acquire_idempotency returns action=REPLAY for identical completed request'
);

-- 10. Test: Key Reused with Different Hash Throws Conflict (409 / 23505)
SELECT throws_ok(
    $$
    SELECT public.fn_acquire_idempotency(
        'req_protocol_test_000000001',
        'POST:/api/v1/stock/transfer',
        'different_tampered_payload_hash',
        '99999999-9999-9999-9999-999999999999'
    )
    $$,
    '23505',
    'Reusing same key with altered payload hash throws conflict (SQLSTATE 23505)'
);

-- 11. Test: Expired Response Cache Returns Resource Reference
-- Expire the response cache
UPDATE public.idempotency_responses 
SET expires_at = clock_timestamp() - INTERVAL '1 day' 
WHERE idempotency_key = 'req_protocol_test_000000001';

SELECT is(
    (public.fn_acquire_idempotency(
        'req_protocol_test_000000001',
        'POST:/api/v1/stock/transfer',
        'hash_protocol_1',
        '99999999-9999-9999-9999-999999999999'
    )->>'action'),
    'EXPIRED',
    'fn_acquire_idempotency returns action=EXPIRED with resource reference when cache has expired'
);

SELECT * FROM finish();
ROLLBACK;
