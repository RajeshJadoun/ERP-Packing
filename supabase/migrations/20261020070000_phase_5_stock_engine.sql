-- =============================================================================
-- Phase 5: canonical stock quantities, custody movement audit provenance
-- =============================================================================
-- This migration keeps stock mutation authoritative in PostgreSQL. Values
-- supplied in an entry unit are converted into the material's canonical unit
-- inside the transactional RPC before the stock ledger/projection is changed.
-- No client-side quantity conversion is trusted.

ALTER TABLE public.stock_transactions
    ADD COLUMN IF NOT EXISTS measurement_evidence text;

-- Private quantity normalizer used by stock movement RPCs. The conversion
-- factor and direction are resolved from effective database rules, not payload
-- claims. The helper is intentionally not exposed as a PostgREST RPC.
CREATE OR REPLACE FUNCTION public.fn_normalize_stock_quantity(
    p_material_id uuid,
    p_quantity numeric,
    p_unit_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_material public.materials;
    v_conversion jsonb;
    v_factor numeric;
    v_direction text;
    v_canonical_quantity numeric;
BEGIN
    IF p_quantity IS NULL
       OR p_quantity::text IN ('NaN', 'Infinity', '-Infinity')
       OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Movement quantity must be a finite number greater than zero.'
            USING ERRCODE = '23514';
    END IF;

    IF p_unit_id IS NULL THEN
        RAISE EXCEPTION 'Movement unit is required.'
            USING ERRCODE = '22023';
    END IF;

    SELECT *
    INTO v_material
    FROM public.materials
    WHERE id = p_material_id
      AND is_active = true;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Material % does not exist or is inactive.', p_material_id
            USING ERRCODE = '23503';
    END IF;

    v_conversion := public.fn_resolve_material_conversion(
        p_material_id,
        p_unit_id,
        v_material.canonical_unit_id
    );
    v_factor := (v_conversion->>'factor')::numeric;
    v_direction := v_conversion->>'direction';

    v_canonical_quantity := CASE v_direction
        WHEN 'MULTIPLY' THEN p_quantity * v_factor
        WHEN 'DIVIDE' THEN p_quantity / v_factor
        ELSE p_quantity
    END;

    IF v_canonical_quantity IS NULL
       OR v_canonical_quantity::text IN ('NaN', 'Infinity', '-Infinity')
       OR v_canonical_quantity <= 0 THEN
        RAISE EXCEPTION 'Resolved canonical quantity must be finite and greater than zero.'
            USING ERRCODE = '23514';
    END IF;

    RETURN jsonb_build_object(
        'canonical_quantity', v_canonical_quantity,
        'canonical_unit_id', v_material.canonical_unit_id,
        'conversion_factor', v_factor,
        'conversion_rule_id', v_conversion->'rule_id',
        'conversion_direction', v_direction,
        'conversion_type', v_conversion->>'conversion_type',
        'is_estimated', coalesce((v_conversion->>'is_estimated')::boolean, false)
    );
END;
$$;

REVOKE ALL ON FUNCTION public.fn_normalize_stock_quantity(uuid, numeric, uuid)
    FROM PUBLIC, anon, authenticated;

-- Overload the private posting helper with persisted evidence. The older
-- signature remains for unrelated existing DB callers during the migration.
CREATE OR REPLACE FUNCTION public.fn_post_stock_transaction(
    p_idempotency_key text,
    p_transaction_sequence integer,
    p_material_id uuid,
    p_movement_type text,
    p_source_location_id uuid,
    p_destination_location_id uuid,
    p_worker_id uuid,
    p_quantity numeric,
    p_unit_id uuid,
    p_entered_quantity numeric,
    p_entered_unit_id uuid,
    p_measurement_method text,
    p_measurement_evidence text,
    p_conversion_factor numeric DEFAULT 1.0,
    p_conversion_rule_id uuid DEFAULT NULL,
    p_conversion_direction text DEFAULT 'NONE',
    p_conversion_type text DEFAULT 'EXACT',
    p_is_estimated boolean DEFAULT false,
    p_movement_reason text DEFAULT NULL,
    p_goods_receipt_id uuid DEFAULT NULL,
    p_goods_receipt_line_id uuid DEFAULT NULL,
    p_packing_job_id uuid DEFAULT NULL,
    p_production_completion_id uuid DEFAULT NULL,
    p_stock_adjustment_id uuid DEFAULT NULL,
    p_created_by uuid DEFAULT NULL
)
RETURNS public.stock_transactions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_tx_number text;
    v_inserted_tx public.stock_transactions;
    v_source_lock numeric;
    v_dest_lock numeric;
BEGIN
    IF p_quantity IS NULL
       OR p_quantity::text IN ('NaN', 'Infinity', '-Infinity')
       OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Stock movement canonical quantity must be finite and strictly positive.'
            USING ERRCODE = '23514';
    END IF;

    -- Transaction-scoped advisory locks also cover a balance row that does not
    -- exist yet. All movements lock location keys in UUID order, making first-row
    -- insert races deterministic per material/location.
    IF p_source_location_id IS NOT NULL AND p_destination_location_id IS NOT NULL THEN
        IF p_source_location_id < p_destination_location_id THEN
            PERFORM pg_catalog.pg_advisory_xact_lock(
                pg_catalog.hashtextextended(p_material_id::text || ':' || p_source_location_id::text, 0)
            );
            PERFORM pg_catalog.pg_advisory_xact_lock(
                pg_catalog.hashtextextended(p_material_id::text || ':' || p_destination_location_id::text, 0)
            );
        ELSE
            PERFORM pg_catalog.pg_advisory_xact_lock(
                pg_catalog.hashtextextended(p_material_id::text || ':' || p_destination_location_id::text, 0)
            );
            PERFORM pg_catalog.pg_advisory_xact_lock(
                pg_catalog.hashtextextended(p_material_id::text || ':' || p_source_location_id::text, 0)
            );
        END IF;
    ELSIF p_source_location_id IS NOT NULL THEN
        PERFORM pg_catalog.pg_advisory_xact_lock(
            pg_catalog.hashtextextended(p_material_id::text || ':' || p_source_location_id::text, 0)
        );
    ELSIF p_destination_location_id IS NOT NULL THEN
        PERFORM pg_catalog.pg_advisory_xact_lock(
            pg_catalog.hashtextextended(p_material_id::text || ':' || p_destination_location_id::text, 0)
        );
    END IF;

    -- Deterministic lock ordering prevents two transfers from locking balances
    -- in opposite orders. The availability check happens while the source row
    -- is locked, and the balance trigger updates are part of this transaction.
    IF p_source_location_id IS NOT NULL AND p_destination_location_id IS NOT NULL THEN
        IF p_source_location_id < p_destination_location_id THEN
            SELECT on_hand_quantity INTO v_source_lock
            FROM public.material_location_balances
            WHERE material_id = p_material_id AND location_id = p_source_location_id
            FOR UPDATE;
            SELECT on_hand_quantity INTO v_dest_lock
            FROM public.material_location_balances
            WHERE material_id = p_material_id AND location_id = p_destination_location_id
            FOR UPDATE;
        ELSE
            SELECT on_hand_quantity INTO v_dest_lock
            FROM public.material_location_balances
            WHERE material_id = p_material_id AND location_id = p_destination_location_id
            FOR UPDATE;
            SELECT on_hand_quantity INTO v_source_lock
            FROM public.material_location_balances
            WHERE material_id = p_material_id AND location_id = p_source_location_id
            FOR UPDATE;
        END IF;
    ELSIF p_source_location_id IS NOT NULL THEN
        SELECT on_hand_quantity INTO v_source_lock
        FROM public.material_location_balances
        WHERE material_id = p_material_id AND location_id = p_source_location_id
        FOR UPDATE;
    ELSIF p_destination_location_id IS NOT NULL THEN
        SELECT on_hand_quantity INTO v_dest_lock
        FROM public.material_location_balances
        WHERE material_id = p_material_id AND location_id = p_destination_location_id
        FOR UPDATE;
    END IF;

    IF p_source_location_id IS NOT NULL AND coalesce(v_source_lock, 0) < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock: Available % is less than required %.',
            coalesce(v_source_lock, 0), p_quantity
            USING ERRCODE = '23514';
    END IF;

    v_tx_number := 'TXN-' || to_char(clock_timestamp(), 'YYYYMMDD-HH24MISS')
        || '-' || lpad(p_transaction_sequence::text, 3, '0')
        || '-' || substr(md5(random()::text), 1, 6);

    INSERT INTO public.stock_transactions (
        transaction_number, idempotency_key, transaction_sequence,
        material_id, movement_type, source_location_id, destination_location_id,
        worker_id, quantity, unit_id, entered_quantity, entered_unit_id,
        measurement_method, measurement_evidence, conversion_factor_applied,
        conversion_rule_id, conversion_direction, conversion_type_used, is_estimated,
        movement_reason, goods_receipt_id, goods_receipt_line_id, packing_job_id,
        production_completion_id, stock_adjustment_id, created_by, created_at
    ) VALUES (
        v_tx_number, p_idempotency_key, p_transaction_sequence,
        p_material_id, p_movement_type, p_source_location_id, p_destination_location_id,
        p_worker_id, p_quantity, p_unit_id, p_entered_quantity, p_entered_unit_id,
        p_measurement_method, nullif(trim(coalesce(p_measurement_evidence, '')), ''),
        p_conversion_factor, p_conversion_rule_id, p_conversion_direction,
        p_conversion_type, p_is_estimated, p_movement_reason, p_goods_receipt_id,
        p_goods_receipt_line_id, p_packing_job_id, p_production_completion_id,
        p_stock_adjustment_id, coalesce(p_created_by, auth.uid()), clock_timestamp()
    )
    RETURNING * INTO v_inserted_tx;

    RETURN v_inserted_tx;
END;
$$;

REVOKE ALL ON FUNCTION public.fn_post_stock_transaction(
    text, integer, uuid, text, uuid, uuid, uuid, numeric, uuid, numeric, uuid,
    text, text, numeric, uuid, text, text, boolean, text, uuid, uuid, uuid, uuid, uuid, uuid
) FROM PUBLIC, anon, authenticated;

-- Transactional internal transfer. The DB converts the entered quantity first,
-- then the immutable canonical quantity drives both the ledger and projection.
CREATE OR REPLACE FUNCTION public.rpc_transfer_stock(
    p_material_id uuid,
    p_source_location_id uuid,
    p_destination_location_id uuid,
    p_quantity numeric,
    p_unit_id uuid,
    p_reason text,
    p_idempotency_key text,
    p_request_hash text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_actor_id uuid := auth.uid();
    v_role text := public.get_current_user_role();
    v_norm jsonb;
    v_tx public.stock_transactions;
    v_idem jsonb;
    v_response jsonb;
BEGIN
    IF v_role IS DISTINCT FROM 'ADMIN' AND v_role IS DISTINCT FROM 'STOREKEEPER' THEN
        RAISE EXCEPTION 'Unauthorized: Only storekeepers and administrators can transfer stock.'
            USING ERRCODE = '42501';
    END IF;
    IF p_reason IS NULL OR trim(p_reason) = '' THEN
        RAISE EXCEPTION 'A non-empty transfer reason is required.' USING ERRCODE = '22023';
    END IF;

    v_idem := public.fn_acquire_idempotency(
        p_idempotency_key, 'POST:/api/v1/stock/transfer', p_request_hash, v_actor_id
    );
    IF v_idem->>'action' = 'REPLAY' THEN RETURN v_idem->'body';
    ELSIF v_idem->>'action' = 'EXPIRED' THEN
        RAISE EXCEPTION 'IDEMPOTENCY_RESPONSE_EXPIRED: %', v_idem USING ERRCODE = '23514';
    END IF;

    v_norm := public.fn_normalize_stock_quantity(p_material_id, p_quantity, p_unit_id);
    v_tx := public.fn_post_stock_transaction(
        p_idempotency_key => p_idempotency_key,
        p_transaction_sequence => 1,
        p_material_id => p_material_id,
        p_movement_type => 'LOCATION_TRANSFER',
        p_source_location_id => p_source_location_id,
        p_destination_location_id => p_destination_location_id,
        p_worker_id => NULL,
        p_quantity => (v_norm->>'canonical_quantity')::numeric,
        p_unit_id => (v_norm->>'canonical_unit_id')::uuid,
        p_entered_quantity => p_quantity,
        p_entered_unit_id => p_unit_id,
        p_measurement_method => 'SCALE_WEIGHED',
        p_measurement_evidence => NULL,
        p_conversion_factor => (v_norm->>'conversion_factor')::numeric,
        p_conversion_rule_id => nullif(v_norm->>'conversion_rule_id', 'null')::uuid,
        p_conversion_direction => v_norm->>'conversion_direction',
        p_conversion_type => v_norm->>'conversion_type',
        p_is_estimated => (v_norm->>'is_estimated')::boolean,
        p_movement_reason => p_reason,
        p_created_by => v_actor_id
    );

    v_response := jsonb_build_object(
        'success', true, 'stockTransactionId', v_tx.id,
        'transactionNumber', v_tx.transaction_number, 'movementType', v_tx.movement_type,
        'quantity', v_tx.quantity
    );
    PERFORM public.fn_complete_idempotency(p_idempotency_key, 'STOCK_TRANSACTION', v_tx.id, 200, v_response);
    RETURN v_response;
END;
$$;

-- New overloads expose auditable measurement selection for worker custody moves.
-- Legacy signatures below delegate to SCALE_WEIGHED for compatibility.
CREATE OR REPLACE FUNCTION public.rpc_issue_to_worker(
    p_packing_job_id uuid,
    p_worker_id uuid,
    p_material_id uuid,
    p_source_location_id uuid,
    p_quantity numeric,
    p_unit_id uuid,
    p_idempotency_key text,
    p_request_hash text,
    p_measurement_method text,
    p_measurement_evidence text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_actor_id uuid := auth.uid();
    v_role text := public.get_current_user_role();
    v_worker_loc_id uuid;
    v_norm jsonb;
    v_tx public.stock_transactions;
    v_idem jsonb;
    v_job public.packing_jobs;
    v_response jsonb;
BEGIN
    IF v_role NOT IN ('ADMIN', 'STOREKEEPER', 'PLANNER') THEN
        RAISE EXCEPTION 'Unauthorized: role cannot issue stock to a worker.' USING ERRCODE = '42501';
    END IF;
    IF p_measurement_method NOT IN ('SCALE_WEIGHED', 'SEALED_BUNDLE', 'MANUALLY_COUNTED') THEN
        RAISE EXCEPTION 'Unsupported measurement method.' USING ERRCODE = '22023';
    END IF;
    IF p_measurement_method IN ('SEALED_BUNDLE', 'MANUALLY_COUNTED')
       AND nullif(trim(coalesce(p_measurement_evidence, '')), '') IS NULL THEN
        RAISE EXCEPTION 'Measurement evidence is required for bundle or manual counts.'
            USING ERRCODE = '22023';
    END IF;

    v_idem := public.fn_acquire_idempotency(
        p_idempotency_key, 'POST:/api/v1/stock/issue-to-worker', p_request_hash, v_actor_id
    );
    IF v_idem->>'action' = 'REPLAY' THEN RETURN v_idem->'body';
    ELSIF v_idem->>'action' = 'EXPIRED' THEN
        RAISE EXCEPTION 'IDEMPOTENCY_RESPONSE_EXPIRED: %', v_idem USING ERRCODE = '23514';
    END IF;

    SELECT * INTO v_job FROM public.packing_jobs WHERE id = p_packing_job_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Packing job % was not found.', p_packing_job_id USING ERRCODE = '23503';
    END IF;
    IF v_job.status NOT IN ('RELEASED', 'IN_PROGRESS', 'PARTIALLY_COMPLETED') THEN
        RAISE EXCEPTION 'Cannot issue materials to job in status %.', v_job.status USING ERRCODE = '23514';
    END IF;

    SELECT assigned_location_id INTO v_worker_loc_id
    FROM public.workers WHERE id = p_worker_id AND is_active = true;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Worker % does not exist or is inactive.', p_worker_id USING ERRCODE = '23503';
    END IF;

    v_norm := public.fn_normalize_stock_quantity(p_material_id, p_quantity, p_unit_id);
    v_tx := public.fn_post_stock_transaction(
        p_idempotency_key => p_idempotency_key,
        p_transaction_sequence => 1,
        p_material_id => p_material_id,
        p_movement_type => 'ISSUE_TO_WORKER',
        p_source_location_id => p_source_location_id,
        p_destination_location_id => v_worker_loc_id,
        p_worker_id => p_worker_id,
        p_quantity => (v_norm->>'canonical_quantity')::numeric,
        p_unit_id => (v_norm->>'canonical_unit_id')::uuid,
        p_entered_quantity => p_quantity,
        p_entered_unit_id => p_unit_id,
        p_measurement_method => p_measurement_method,
        p_measurement_evidence => p_measurement_evidence,
        p_conversion_factor => (v_norm->>'conversion_factor')::numeric,
        p_conversion_rule_id => nullif(v_norm->>'conversion_rule_id', 'null')::uuid,
        p_conversion_direction => v_norm->>'conversion_direction',
        p_conversion_type => v_norm->>'conversion_type',
        p_is_estimated => (v_norm->>'is_estimated')::boolean,
        p_packing_job_id => p_packing_job_id,
        p_created_by => v_actor_id
    );

    v_response := jsonb_build_object(
        'success', true, 'stockTransactionId', v_tx.id,
        'transactionNumber', v_tx.transaction_number, 'movementType', v_tx.movement_type,
        'quantity', v_tx.quantity
    );
    PERFORM public.fn_complete_idempotency(p_idempotency_key, 'STOCK_TRANSACTION', v_tx.id, 200, v_response);
    RETURN v_response;
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_issue_to_worker(uuid, uuid, uuid, uuid, numeric, uuid, text, text, text, text)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_issue_to_worker(uuid, uuid, uuid, uuid, numeric, uuid, text, text, text, text)
    TO authenticated;

CREATE OR REPLACE FUNCTION public.rpc_issue_to_worker(
    p_packing_job_id uuid,
    p_worker_id uuid,
    p_material_id uuid,
    p_source_location_id uuid,
    p_quantity numeric,
    p_unit_id uuid,
    p_idempotency_key text,
    p_request_hash text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    RETURN public.rpc_issue_to_worker(
        p_packing_job_id, p_worker_id, p_material_id, p_source_location_id,
        p_quantity, p_unit_id, p_idempotency_key, p_request_hash, 'SCALE_WEIGHED', NULL
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.rpc_return_from_worker(
    p_packing_job_id uuid,
    p_worker_id uuid,
    p_material_id uuid,
    p_destination_location_id uuid,
    p_quantity numeric,
    p_unit_id uuid,
    p_idempotency_key text,
    p_request_hash text,
    p_measurement_method text,
    p_measurement_evidence text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_actor_id uuid := auth.uid();
    v_role text := public.get_current_user_role();
    v_worker_loc_id uuid;
    v_norm jsonb;
    v_tx public.stock_transactions;
    v_idem jsonb;
    v_job public.packing_jobs;
    v_response jsonb;
BEGIN
    IF v_role NOT IN ('ADMIN', 'STOREKEEPER', 'OPERATOR') THEN
        RAISE EXCEPTION 'Unauthorized: role cannot return stock from worker custody.' USING ERRCODE = '42501';
    END IF;
    IF p_measurement_method NOT IN ('SCALE_WEIGHED', 'SEALED_BUNDLE', 'MANUALLY_COUNTED') THEN
        RAISE EXCEPTION 'Unsupported measurement method.' USING ERRCODE = '22023';
    END IF;
    IF p_measurement_method IN ('SEALED_BUNDLE', 'MANUALLY_COUNTED')
       AND nullif(trim(coalesce(p_measurement_evidence, '')), '') IS NULL THEN
        RAISE EXCEPTION 'Measurement evidence is required for bundle or manual counts.'
            USING ERRCODE = '22023';
    END IF;

    v_idem := public.fn_acquire_idempotency(
        p_idempotency_key, 'POST:/api/v1/stock/return-from-worker', p_request_hash, v_actor_id
    );
    IF v_idem->>'action' = 'REPLAY' THEN RETURN v_idem->'body';
    ELSIF v_idem->>'action' = 'EXPIRED' THEN
        RAISE EXCEPTION 'IDEMPOTENCY_RESPONSE_EXPIRED: %', v_idem USING ERRCODE = '23514';
    END IF;

    SELECT * INTO v_job FROM public.packing_jobs WHERE id = p_packing_job_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Packing job % was not found.', p_packing_job_id USING ERRCODE = '23503';
    END IF;
    SELECT assigned_location_id INTO v_worker_loc_id
    FROM public.workers WHERE id = p_worker_id AND is_active = true;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Worker % does not exist or is inactive.', p_worker_id USING ERRCODE = '23503';
    END IF;

    v_norm := public.fn_normalize_stock_quantity(p_material_id, p_quantity, p_unit_id);
    v_tx := public.fn_post_stock_transaction(
        p_idempotency_key => p_idempotency_key,
        p_transaction_sequence => 1,
        p_material_id => p_material_id,
        p_movement_type => 'RETURN_FROM_WORKER',
        p_source_location_id => v_worker_loc_id,
        p_destination_location_id => p_destination_location_id,
        p_worker_id => p_worker_id,
        p_quantity => (v_norm->>'canonical_quantity')::numeric,
        p_unit_id => (v_norm->>'canonical_unit_id')::uuid,
        p_entered_quantity => p_quantity,
        p_entered_unit_id => p_unit_id,
        p_measurement_method => p_measurement_method,
        p_measurement_evidence => p_measurement_evidence,
        p_conversion_factor => (v_norm->>'conversion_factor')::numeric,
        p_conversion_rule_id => nullif(v_norm->>'conversion_rule_id', 'null')::uuid,
        p_conversion_direction => v_norm->>'conversion_direction',
        p_conversion_type => v_norm->>'conversion_type',
        p_is_estimated => (v_norm->>'is_estimated')::boolean,
        p_packing_job_id => p_packing_job_id,
        p_created_by => v_actor_id
    );

    v_response := jsonb_build_object(
        'success', true, 'stockTransactionId', v_tx.id,
        'transactionNumber', v_tx.transaction_number, 'movementType', v_tx.movement_type,
        'quantity', v_tx.quantity
    );
    PERFORM public.fn_complete_idempotency(p_idempotency_key, 'STOCK_TRANSACTION', v_tx.id, 200, v_response);
    RETURN v_response;
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_return_from_worker(uuid, uuid, uuid, uuid, numeric, uuid, text, text, text, text)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_return_from_worker(uuid, uuid, uuid, uuid, numeric, uuid, text, text, text, text)
    TO authenticated;

CREATE OR REPLACE FUNCTION public.rpc_return_from_worker(
    p_packing_job_id uuid,
    p_worker_id uuid,
    p_material_id uuid,
    p_destination_location_id uuid,
    p_quantity numeric,
    p_unit_id uuid,
    p_idempotency_key text,
    p_request_hash text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    RETURN public.rpc_return_from_worker(
        p_packing_job_id, p_worker_id, p_material_id, p_destination_location_id,
        p_quantity, p_unit_id, p_idempotency_key, p_request_hash, 'SCALE_WEIGHED', NULL
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.rpc_quarantine_stock(
    p_material_id uuid,
    p_source_location_id uuid,
    p_destination_location_id uuid,
    p_quantity numeric,
    p_unit_id uuid,
    p_worker_id uuid,
    p_packing_job_id uuid,
    p_reason text,
    p_idempotency_key text,
    p_request_hash text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_actor_id uuid := auth.uid();
    v_role text := public.get_current_user_role();
    v_norm jsonb;
    v_tx public.stock_transactions;
    v_idem jsonb;
    v_response jsonb;
BEGIN
    IF v_role NOT IN ('ADMIN', 'STOREKEEPER') THEN
        RAISE EXCEPTION 'Unauthorized: role cannot quarantine stock.' USING ERRCODE = '42501';
    END IF;
    IF p_source_location_id IS NULL THEN
        RAISE EXCEPTION 'A valid source inventory location is required for quarantine.'
            USING ERRCODE = '23514';
    END IF;
    IF p_reason IS NULL OR trim(p_reason) = '' THEN
        RAISE EXCEPTION 'A quarantine reason is required.' USING ERRCODE = '22023';
    END IF;

    v_idem := public.fn_acquire_idempotency(
        p_idempotency_key, 'POST:/api/v1/stock/damage-quarantine', p_request_hash, v_actor_id
    );
    IF v_idem->>'action' = 'REPLAY' THEN RETURN v_idem->'body';
    ELSIF v_idem->>'action' = 'EXPIRED' THEN
        RAISE EXCEPTION 'IDEMPOTENCY_RESPONSE_EXPIRED: %', v_idem USING ERRCODE = '23514';
    END IF;

    v_norm := public.fn_normalize_stock_quantity(p_material_id, p_quantity, p_unit_id);
    v_tx := public.fn_post_stock_transaction(
        p_idempotency_key => p_idempotency_key,
        p_transaction_sequence => 1,
        p_material_id => p_material_id,
        p_movement_type => 'DAMAGE_QUARANTINE',
        p_source_location_id => p_source_location_id,
        p_destination_location_id => p_destination_location_id,
        p_worker_id => p_worker_id,
        p_quantity => (v_norm->>'canonical_quantity')::numeric,
        p_unit_id => (v_norm->>'canonical_unit_id')::uuid,
        p_entered_quantity => p_quantity,
        p_entered_unit_id => p_unit_id,
        p_measurement_method => 'INSPECTION_AUDIT',
        p_measurement_evidence => p_reason,
        p_conversion_factor => (v_norm->>'conversion_factor')::numeric,
        p_conversion_rule_id => nullif(v_norm->>'conversion_rule_id', 'null')::uuid,
        p_conversion_direction => v_norm->>'conversion_direction',
        p_conversion_type => v_norm->>'conversion_type',
        p_is_estimated => (v_norm->>'is_estimated')::boolean,
        p_movement_reason => p_reason,
        p_packing_job_id => p_packing_job_id,
        p_created_by => v_actor_id
    );

    v_response := jsonb_build_object(
        'success', true, 'stockTransactionId', v_tx.id,
        'transactionNumber', v_tx.transaction_number, 'movementType', v_tx.movement_type,
        'quantity', v_tx.quantity
    );
    PERFORM public.fn_complete_idempotency(p_idempotency_key, 'STOCK_TRANSACTION', v_tx.id, 200, v_response);
    RETURN v_response;
END;
$$;

CREATE OR REPLACE FUNCTION public.rpc_scrap_disposal(
    p_material_id uuid,
    p_source_location_id uuid,
    p_quantity numeric,
    p_unit_id uuid,
    p_reason text,
    p_idempotency_key text,
    p_request_hash text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_actor_id uuid := auth.uid();
    v_role text := public.get_current_user_role();
    v_norm jsonb;
    v_tx public.stock_transactions;
    v_idem jsonb;
    v_response jsonb;
BEGIN
    IF v_role IS DISTINCT FROM 'ADMIN' THEN
        RAISE EXCEPTION 'Unauthorized: only administrators can dispose of scrapped inventory.'
            USING ERRCODE = '42501';
    END IF;
    IF p_reason IS NULL OR trim(p_reason) = '' THEN
        RAISE EXCEPTION 'A disposal authorization reason is required.' USING ERRCODE = '22023';
    END IF;

    v_idem := public.fn_acquire_idempotency(
        p_idempotency_key, 'POST:/api/v1/stock/scrap-disposal', p_request_hash, v_actor_id
    );
    IF v_idem->>'action' = 'REPLAY' THEN RETURN v_idem->'body';
    ELSIF v_idem->>'action' = 'EXPIRED' THEN
        RAISE EXCEPTION 'IDEMPOTENCY_RESPONSE_EXPIRED: %', v_idem USING ERRCODE = '23514';
    END IF;

    v_norm := public.fn_normalize_stock_quantity(p_material_id, p_quantity, p_unit_id);
    v_tx := public.fn_post_stock_transaction(
        p_idempotency_key => p_idempotency_key,
        p_transaction_sequence => 1,
        p_material_id => p_material_id,
        p_movement_type => 'SCRAP_DISPOSAL',
        p_source_location_id => p_source_location_id,
        p_destination_location_id => NULL,
        p_worker_id => NULL,
        p_quantity => (v_norm->>'canonical_quantity')::numeric,
        p_unit_id => (v_norm->>'canonical_unit_id')::uuid,
        p_entered_quantity => p_quantity,
        p_entered_unit_id => p_unit_id,
        p_measurement_method => 'INSPECTION_AUDIT',
        p_measurement_evidence => p_reason,
        p_conversion_factor => (v_norm->>'conversion_factor')::numeric,
        p_conversion_rule_id => nullif(v_norm->>'conversion_rule_id', 'null')::uuid,
        p_conversion_direction => v_norm->>'conversion_direction',
        p_conversion_type => v_norm->>'conversion_type',
        p_is_estimated => (v_norm->>'is_estimated')::boolean,
        p_movement_reason => p_reason,
        p_created_by => v_actor_id
    );

    v_response := jsonb_build_object(
        'success', true, 'stockTransactionId', v_tx.id,
        'transactionNumber', v_tx.transaction_number, 'movementType', v_tx.movement_type,
        'quantity', v_tx.quantity
    );
    PERFORM public.fn_complete_idempotency(p_idempotency_key, 'STOCK_TRANSACTION', v_tx.id, 200, v_response);
    RETURN v_response;
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_scrap_disposal(uuid, uuid, numeric, uuid, text, text, text)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_scrap_disposal(uuid, uuid, numeric, uuid, text, text, text)
    TO authenticated;

-- Serialize cycle-count adjustments even when no projection row exists yet.
-- The advisory lock key matches the one used by fn_post_stock_transaction.
CREATE OR REPLACE FUNCTION public.rpc_post_stock_adjustment(
    p_adjustment_number text,
    p_material_id uuid,
    p_location_id uuid,
    p_counted_quantity numeric,
    p_reason text,
    p_idempotency_key text,
    p_request_hash text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_actor_id uuid := auth.uid();
    v_role text := public.get_current_user_role();
    v_book numeric := 0;
    v_diff numeric;
    v_adj_id uuid := gen_random_uuid();
    v_mat public.materials;
    v_loc public.locations;
    v_src uuid;
    v_dst uuid;
    v_abs_qty numeric;
    v_tx public.stock_transactions;
    v_idem jsonb;
    v_response jsonb;
BEGIN
    IF v_role IS DISTINCT FROM 'ADMIN' THEN
        RAISE EXCEPTION 'Unauthorized: Only administrators can sign off stock adjustments.'
            USING ERRCODE = '42501';
    END IF;
    IF p_adjustment_number IS NULL OR trim(p_adjustment_number) = '' THEN
        RAISE EXCEPTION 'An adjustment number is required.' USING ERRCODE = '22023';
    END IF;
    IF p_counted_quantity IS NULL
       OR p_counted_quantity::text IN ('NaN', 'Infinity', '-Infinity')
       OR p_counted_quantity < 0 THEN
        RAISE EXCEPTION 'Counted quantity must be finite and non-negative.'
            USING ERRCODE = '23514';
    END IF;
    IF p_reason IS NULL OR trim(p_reason) = '' THEN
        RAISE EXCEPTION 'An adjustment reason is mandatory.' USING ERRCODE = '22023';
    END IF;

    v_idem := public.fn_acquire_idempotency(
        p_idempotency_key, 'POST:/api/v1/stock/adjustments', p_request_hash, v_actor_id
    );
    IF v_idem->>'action' = 'REPLAY' THEN RETURN v_idem->'body';
    ELSIF v_idem->>'action' = 'EXPIRED' THEN
        RAISE EXCEPTION 'IDEMPOTENCY_RESPONSE_EXPIRED: %', v_idem USING ERRCODE = '23514';
    END IF;

    SELECT * INTO v_mat
    FROM public.materials
    WHERE id = p_material_id AND is_active = true;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Material % does not exist or is inactive.', p_material_id
            USING ERRCODE = '23503';
    END IF;

    SELECT * INTO v_loc
    FROM public.locations
    WHERE id = p_location_id AND is_active = true AND is_leaf = true;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Stock adjustment requires an active leaf location.'
            USING ERRCODE = '23514';
    END IF;

    PERFORM pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended(p_material_id::text || ':' || p_location_id::text, 0)
    );

    INSERT INTO public.material_location_balances (
        material_id, location_id, on_hand_quantity, updated_at
    ) VALUES (
        p_material_id, p_location_id, 0, clock_timestamp()
    )
    ON CONFLICT (material_id, location_id) DO NOTHING;

    SELECT on_hand_quantity
    INTO v_book
    FROM public.material_location_balances
    WHERE material_id = p_material_id AND location_id = p_location_id
    FOR UPDATE;

    v_diff := p_counted_quantity - coalesce(v_book, 0);
    IF v_diff = 0 THEN
        RAISE EXCEPTION 'No adjustment needed: counted quantity equals book quantity.'
            USING ERRCODE = '23514';
    END IF;

    INSERT INTO public.stock_adjustments (
        id, adjustment_number, material_id, location_id, counted_quantity,
        book_quantity, difference_quantity, reason, approved_by, created_at
    ) VALUES (
        v_adj_id, p_adjustment_number, p_material_id, p_location_id, p_counted_quantity,
        coalesce(v_book, 0), v_diff, p_reason, v_actor_id, clock_timestamp()
    );

    IF v_diff > 0 THEN
        v_src := NULL;
        v_dst := p_location_id;
        v_abs_qty := v_diff;
    ELSE
        v_src := p_location_id;
        v_dst := NULL;
        v_abs_qty := abs(v_diff);
    END IF;

    v_tx := public.fn_post_stock_transaction(
        p_idempotency_key => p_idempotency_key,
        p_transaction_sequence => 1,
        p_material_id => p_material_id,
        p_movement_type => 'STOCK_ADJUSTMENT',
        p_source_location_id => v_src,
        p_destination_location_id => v_dst,
        p_worker_id => NULL,
        p_quantity => v_abs_qty,
        p_unit_id => v_mat.canonical_unit_id,
        p_entered_quantity => v_abs_qty,
        p_entered_unit_id => v_mat.canonical_unit_id,
        p_measurement_method => 'INSPECTION_AUDIT',
        p_measurement_evidence => p_reason,
        p_movement_reason => p_reason,
        p_stock_adjustment_id => v_adj_id,
        p_created_by => v_actor_id
    );

    v_response := jsonb_build_object(
        'success', true,
        'stockAdjustmentId', v_adj_id,
        'adjustmentNumber', p_adjustment_number,
        'stockTransactionId', v_tx.id,
        'differenceQuantity', v_diff
    );
    PERFORM public.fn_complete_idempotency(
        p_idempotency_key, 'STOCK_ADJUSTMENT', v_adj_id, 200, v_response
    );
    RETURN v_response;
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_post_stock_adjustment(text, uuid, uuid, numeric, text, text, text)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_post_stock_adjustment(text, uuid, uuid, numeric, text, text, text)
    TO authenticated;

NOTIFY pgrst, 'reload schema';
