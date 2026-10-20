-- =============================================================================
-- Migration 000008: Phase 2.1.1 Final Transactional & Security Hardening
-- Packing Material Inventory & BOM Management System
-- =============================================================================
--
-- Scope:
--   1) Close the idempotency first-insert race with INSERT..ON CONFLICT.
--   2) Add one authoritative material-unit conversion resolver.
--   3) Rebuild goods-receipt posting to normalize rejected quantities,
--      persist authoritative conversion provenance, and credit PO lines
--      in the PO line's own unit with over-receipt protection.
--   4) Make packing-job release/revise/cancel retry-safe.
--   5) Explicitly revoke PUBLIC/anon execution on privileged RPCs.
--
-- This migration is additive/replace-in-place and preserves the 2.1 API
-- signatures for backward compatibility.
-- =============================================================================

-- =============================================================================
-- 1. Race-safe idempotency acquisition
-- =============================================================================
CREATE OR REPLACE FUNCTION public.fn_acquire_idempotency(
    p_key text,
    p_scope text,
    p_hash text,
    p_owner_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_existing public.idempotency_keys;
    v_inserted public.idempotency_keys;
    v_cached public.idempotency_responses;
    v_now timestamptz := clock_timestamp();
BEGIN
    IF p_key IS NULL OR p_key !~ '^[A-Za-z0-9_\-\.:]{16,128}$' THEN
        RAISE EXCEPTION 'Invalid idempotency key format: %', p_key USING ERRCODE = '22023';
    END IF;

    -- The unique-key insert is the mutex. Under concurrency, PostgreSQL
    -- waits on the conflicting insert and only one caller can return PROCEED.
    INSERT INTO public.idempotency_keys (
        idempotency_key, owner_id, operation_scope, request_hash, status, locked_at
    ) VALUES (
        p_key, p_owner_id, p_scope, p_hash, 'PROCESSING', v_now
    )
    ON CONFLICT (idempotency_key) DO NOTHING
    RETURNING * INTO v_inserted;

    IF FOUND THEN
        RETURN jsonb_build_object('action', 'PROCEED');
    END IF;

    -- The losing concurrent caller now locks and inspects the committed row.
    SELECT *
    INTO v_existing
    FROM public.idempotency_keys
    WHERE idempotency_key = p_key
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Idempotency state could not be resolved for key %.', p_key
            USING ERRCODE = '55P03';
    END IF;

    IF v_existing.owner_id IS DISTINCT FROM p_owner_id
       OR v_existing.operation_scope IS DISTINCT FROM p_scope
       OR v_existing.request_hash IS DISTINCT FROM p_hash THEN
        RAISE EXCEPTION 'IDEMPOTENCY_KEY_REUSED: The provided idempotency key has already been used for a conflicting request.'
            USING ERRCODE = '23505';
    END IF;

    IF v_existing.status = 'COMPLETED' THEN
        SELECT *
        INTO v_cached
        FROM public.idempotency_responses
        WHERE idempotency_key = p_key;

        IF FOUND AND v_cached.expires_at > v_now THEN
            RETURN jsonb_build_object(
                'action', 'REPLAY',
                'status_code', v_cached.response_status_code,
                'body', v_cached.response_body
            );
        END IF;

        RETURN jsonb_build_object(
            'action', 'EXPIRED',
            'resource_type', v_existing.resource_type,
            'resource_id', v_existing.resource_id,
            'operation_completed_at', v_existing.operation_completed_at
        );
    END IF;

    RAISE EXCEPTION 'IDEMPOTENCY_IN_PROGRESS: An identical operation is currently being processed.'
        USING ERRCODE = '55P03';
END;
$$;

REVOKE ALL ON FUNCTION public.fn_acquire_idempotency FROM PUBLIC, anon, authenticated;

-- =============================================================================
-- 2. Authoritative material-unit conversion resolver
-- =============================================================================
CREATE OR REPLACE FUNCTION public.fn_resolve_material_conversion(
    p_material_id uuid,
    p_from_unit_id uuid,
    p_to_unit_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_rule public.material_conversions;
    v_canonical_unit_id uuid;
    v_now timestamptz := clock_timestamp();
BEGIN
    SELECT canonical_unit_id
    INTO v_canonical_unit_id
    FROM public.materials
    WHERE id = p_material_id
      AND is_active = true;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Material % does not exist or is inactive.', p_material_id
            USING ERRCODE = '23503';
    END IF;

    IF p_from_unit_id IS NULL OR p_to_unit_id IS NULL THEN
        RAISE EXCEPTION 'Material conversion requires both source and target units.'
            USING ERRCODE = '22023';
    END IF;

    IF p_from_unit_id = p_to_unit_id THEN
        RETURN jsonb_build_object(
            'rule_id', NULL,
            'factor', 1.0,
            'direction', 'NONE',
            'conversion_type', 'EXACT',
            'is_estimated', false,
            'from_unit_id', p_from_unit_id,
            'to_unit_id', p_to_unit_id
        );
    END IF;

    -- Prefer the newest effective direct rule when historical windows overlap.
    SELECT *
    INTO v_rule
    FROM public.material_conversions
    WHERE material_id = p_material_id
      AND from_unit_id = p_from_unit_id
      AND to_unit_id = p_to_unit_id
      AND effective_from <= v_now
      AND (effective_to IS NULL OR effective_to > v_now)
    ORDER BY effective_from DESC, created_at DESC, id DESC
    LIMIT 1;

    IF FOUND THEN
        RETURN jsonb_build_object(
            'rule_id', v_rule.id,
            'factor', v_rule.conversion_factor,
            'direction', 'MULTIPLY',
            'conversion_type', CASE WHEN v_rule.is_exact THEN 'EXACT' ELSE 'ESTIMATED' END,
            'is_estimated', NOT v_rule.is_exact,
            'from_unit_id', p_from_unit_id,
            'to_unit_id', p_to_unit_id
        );
    END IF;

    -- Otherwise use the newest inverse rule and divide by its factor.
    SELECT *
    INTO v_rule
    FROM public.material_conversions
    WHERE material_id = p_material_id
      AND from_unit_id = p_to_unit_id
      AND to_unit_id = p_from_unit_id
      AND effective_from <= v_now
      AND (effective_to IS NULL OR effective_to > v_now)
    ORDER BY effective_from DESC, created_at DESC, id DESC
    LIMIT 1;

    IF FOUND THEN
        RETURN jsonb_build_object(
            'rule_id', v_rule.id,
            'factor', v_rule.conversion_factor,
            'direction', 'DIVIDE',
            'conversion_type', CASE WHEN v_rule.is_exact THEN 'EXACT' ELSE 'ESTIMATED' END,
            'is_estimated', NOT v_rule.is_exact,
            'from_unit_id', p_from_unit_id,
            'to_unit_id', p_to_unit_id
        );
    END IF;

    RAISE EXCEPTION 'No valid conversion rule found for material % from unit % to unit %.',
        p_material_id, p_from_unit_id, p_to_unit_id
        USING ERRCODE = '23514';
END;
$$;

REVOKE ALL ON FUNCTION public.fn_resolve_material_conversion FROM PUBLIC, anon, authenticated;

-- =============================================================================
-- 3. Hardened Goods Receipt Posting
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_post_goods_receipt(
    p_grn_id uuid,
    p_idempotency_key text,
    p_request_hash text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_actor_id uuid;
    v_role text;
    v_idem jsonb;
    v_grn public.goods_receipts;
    v_po public.purchase_orders;
    v_line record;
    v_seq integer := 1;
    v_tx public.stock_transactions;
    v_mat record;
    v_accept_conversion jsonb;
    v_reject_conversion jsonb;
    v_po_conversion jsonb;
    v_calc_accepted numeric;
    v_calc_canonical numeric;
    v_norm_rejected numeric;
    v_po_credit numeric;
    v_response jsonb;
    v_now timestamptz;
BEGIN
    v_actor_id := auth.uid();
    v_role := public.get_current_user_role();

    IF v_role IS DISTINCT FROM 'ADMIN' AND v_role IS DISTINCT FROM 'STOREKEEPER' THEN
        RAISE EXCEPTION 'Unauthorized: Only storekeepers and administrators can post goods receipts.'
            USING ERRCODE = '42501';
    END IF;

    v_idem := public.fn_acquire_idempotency(
        p_idempotency_key,
        'POST:/api/v1/goods-receipts/post',
        p_request_hash,
        v_actor_id
    );

    IF v_idem->>'action' = 'REPLAY' THEN
        RETURN v_idem->'body';
    ELSIF v_idem->>'action' = 'EXPIRED' THEN
        RAISE EXCEPTION 'IDEMPOTENCY_RESPONSE_EXPIRED: %', v_idem USING ERRCODE = '23514';
    END IF;

    SELECT *
    INTO v_grn
    FROM public.goods_receipts
    WHERE id = p_grn_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Goods receipt % not found.', p_grn_id USING ERRCODE = 'P0002';
    END IF;

    IF v_grn.status != 'DRAFT' THEN
        RAISE EXCEPTION 'Goods receipt % cannot be posted because status is %.', p_grn_id, v_grn.status
            USING ERRCODE = '23514';
    END IF;

    IF v_grn.po_id IS NOT NULL THEN
        SELECT *
        INTO v_po
        FROM public.purchase_orders
        WHERE id = v_grn.po_id
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Purchase order % not found.', v_grn.po_id USING ERRCODE = 'P0002';
        END IF;

        IF v_po.vendor_id IS DISTINCT FROM v_grn.vendor_id THEN
            RAISE EXCEPTION 'Vendor mismatch: PO vendor does not match receipt vendor.'
                USING ERRCODE = '23514';
        END IF;
    END IF;

    FOR v_line IN
        SELECT *
        FROM public.goods_receipt_lines
        WHERE grn_id = p_grn_id
        ORDER BY id
        FOR UPDATE
    LOOP
        SELECT *
        INTO v_mat
        FROM public.materials
        WHERE id = v_line.material_id
          AND is_active = true;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Material % is inactive or does not exist.', v_line.material_id
                USING ERRCODE = '23503';
        END IF;

        IF v_line.entered_qty <= 0 THEN
            RAISE EXCEPTION 'Entered quantity must be positive on line %.', v_line.id
                USING ERRCODE = '23514';
        END IF;

        IF v_line.rejected_qty < 0 THEN
            RAISE EXCEPTION 'Rejected quantity cannot be negative on line %.', v_line.id
                USING ERRCODE = '23514';
        END IF;

        -- Normalize rejected quantity into the receipt's entered unit.
        IF v_line.rejected_qty = 0 THEN
            v_reject_conversion := jsonb_build_object(
                'rule_id', NULL,
                'factor', 1.0,
                'direction', 'NONE',
                'conversion_type', 'EXACT',
                'is_estimated', false
            );
            v_norm_rejected := 0;
        ELSE
            v_reject_conversion := public.fn_resolve_material_conversion(
                v_line.material_id,
                v_line.rejected_unit_id,
                v_line.entered_unit_id
            );

            v_norm_rejected :=
                CASE v_reject_conversion->>'direction'
                    WHEN 'MULTIPLY' THEN
                        v_line.rejected_qty * (v_reject_conversion->>'factor')::numeric
                    WHEN 'DIVIDE' THEN
                        v_line.rejected_qty / (v_reject_conversion->>'factor')::numeric
                    ELSE
                        v_line.rejected_qty
                END;
        END IF;

        IF v_norm_rejected > v_line.entered_qty THEN
            RAISE EXCEPTION 'Rejected quantity exceeds entered quantity after unit normalization on line %.',
                v_line.id
                USING ERRCODE = '23514';
        END IF;

        v_calc_accepted := v_line.entered_qty - v_norm_rejected;

        -- Always resolve the accepted-to-canonical rule so the posted ledger
        -- contains immutable, authoritative provenance.
        v_accept_conversion := public.fn_resolve_material_conversion(
            v_line.material_id,
            v_line.entered_unit_id,
            v_mat.canonical_unit_id
        );

        v_calc_canonical :=
            CASE v_accept_conversion->>'direction'
                WHEN 'MULTIPLY' THEN
                    v_calc_accepted * (v_accept_conversion->>'factor')::numeric
                WHEN 'DIVIDE' THEN
                    v_calc_accepted / (v_accept_conversion->>'factor')::numeric
                ELSE
                    v_calc_accepted
            END;

        IF v_grn.po_id IS NOT NULL THEN
            IF v_line.purchase_order_line_id IS NULL THEN
                RAISE EXCEPTION 'Receipt line % missing required purchase_order_line_id for PO receipt.',
                    v_line.id
                    USING ERRCODE = '23514';
            END IF;

            SELECT *
            INTO v_po_line
            FROM public.purchase_order_lines
            WHERE id = v_line.purchase_order_line_id
              AND po_id = v_grn.po_id
            FOR UPDATE;

            IF NOT FOUND THEN
                RAISE EXCEPTION 'PO Line % does not belong to PO %.',
                    v_line.purchase_order_line_id, v_grn.po_id
                    USING ERRCODE = '23514';
            END IF;

            IF v_po_line.material_id != v_line.material_id THEN
                RAISE EXCEPTION 'PO Line material does not match receipt line material.'
                    USING ERRCODE = '23514';
            END IF;

            -- received_quantity is stored in the PO line's own unit.
            IF v_calc_accepted = 0 THEN
                v_po_credit := 0;
                v_po_conversion := jsonb_build_object(
                    'rule_id', NULL,
                    'factor', 1.0,
                    'direction', 'NONE',
                    'conversion_type', 'EXACT',
                    'is_estimated', false
                );
            ELSE
                v_po_conversion := public.fn_resolve_material_conversion(
                    v_line.material_id,
                    v_line.entered_unit_id,
                    v_po_line.unit_id
                );

                v_po_credit :=
                    CASE v_po_conversion->>'direction'
                        WHEN 'MULTIPLY' THEN
                            v_calc_accepted * (v_po_conversion->>'factor')::numeric
                        WHEN 'DIVIDE' THEN
                            v_calc_accepted / (v_po_conversion->>'factor')::numeric
                        ELSE
                            v_calc_accepted
                    END;
            END IF;

            IF v_po_line.received_quantity + v_po_credit > v_po_line.ordered_quantity THEN
                RAISE EXCEPTION
                    'PO line % would be over-received: current %, incoming %, ordered %.',
                    v_po_line.id,
                    v_po_line.received_quantity,
                    v_po_credit,
                    v_po_line.ordered_quantity
                    USING ERRCODE = '23514';
            END IF;

            UPDATE public.purchase_order_lines
            SET received_quantity = received_quantity + v_po_credit
            WHERE id = v_po_line.id;
        ELSE
            v_po_conversion := NULL;
        END IF;

        UPDATE public.goods_receipt_lines
        SET accepted_qty = v_calc_accepted,
            canonical_quantity = v_calc_canonical,
            canonical_unit_id = v_mat.canonical_unit_id,
            conversion_rule_id = (v_accept_conversion->>'rule_id')::uuid,
            conversion_factor_used = (v_accept_conversion->>'factor')::numeric,
            conversion_direction = v_accept_conversion->>'direction',
            conversion_type_used = v_accept_conversion->>'conversion_type',
            is_estimated_conversion = (v_accept_conversion->>'is_estimated')::boolean,
            rejection_conversion_rule_id = (v_reject_conversion->>'rule_id')::uuid,
            rejection_conversion_factor_used = (v_reject_conversion->>'factor')::numeric,
            rejection_conversion_direction = v_reject_conversion->>'direction',
            rejection_conversion_type_used = v_reject_conversion->>'conversion_type',
            is_estimated_conversion = (v_accept_conversion->>'is_estimated')::boolean
        WHERE id = v_line.id;

        IF v_calc_accepted > 0 AND v_calc_canonical > 0 THEN
            v_tx := public.fn_post_stock_transaction(
                p_idempotency_key => p_idempotency_key,
                p_transaction_sequence => v_seq,
                p_material_id => v_line.material_id,
                p_movement_type => 'PURCHASE_RECEIPT',
                p_source_location_id => NULL,
                p_destination_location_id => v_grn.destination_location_id,
                p_worker_id => NULL,
                p_quantity => v_calc_canonical,
                p_unit_id => v_mat.canonical_unit_id,
                p_entered_quantity => v_line.entered_qty,
                p_entered_unit_id => v_line.entered_unit_id,
                p_measurement_method => CASE
                    WHEN v_line.weight_kg IS NOT NULL THEN 'SCALE_WEIGHED'
                    ELSE 'MANUALLY_COUNTED'
                END,
                p_conversion_factor => (v_accept_conversion->>'factor')::numeric,
                p_conversion_rule_id => (v_accept_conversion->>'rule_id')::uuid,
                p_conversion_direction => v_accept_conversion->>'direction',
                p_conversion_type => v_accept_conversion->>'conversion_type',
                p_is_estimated => (v_accept_conversion->>'is_estimated')::boolean,
                p_goods_receipt_id => v_grn.id,
                p_goods_receipt_line_id => v_line.id,
                p_created_by => v_actor_id
            );
            v_seq := v_seq + 1;
        END IF;
    END LOOP;

    IF v_grn.po_id IS NOT NULL THEN
        UPDATE public.purchase_orders
        SET status = CASE
                WHEN NOT EXISTS (
                    SELECT 1
                    FROM public.purchase_order_lines
                    WHERE po_id = v_grn.po_id
                      AND received_quantity < ordered_quantity
                )
                THEN 'COMPLETED'
                ELSE 'PARTIALLY_RECEIVED'
            END,
            updated_at = clock_timestamp()
        WHERE id = v_grn.po_id;
    END IF;

    UPDATE public.goods_receipts
    SET status = 'POSTED',
        posted_by = v_actor_id,
        posted_at = clock_timestamp()
    WHERE id = p_grn_id;

    v_response := jsonb_build_object(
        'success', true,
        'grnId', p_grn_id,
        'grnNumber', v_grn.grn_number,
        'status', 'POSTED',
        'linesPosted', v_seq - 1
    );

    PERFORM public.fn_complete_idempotency(
        p_idempotency_key,
        'GOODS_RECEIPT',
        p_grn_id,
        200,
        v_response
    );

    RETURN v_response;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_post_goods_receipt TO authenticated;
REVOKE EXECUTE ON FUNCTION public.rpc_post_goods_receipt(uuid, text, text) FROM PUBLIC, anon;

-- =============================================================================
-- 4. Retry-safe packing job release
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_release_packing_job(p_packing_job_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_actor_id uuid := auth.uid();
    v_role text := public.get_current_user_role();
    v_idem jsonb;
    v_idem_key text := 'release_job:' || p_packing_job_id::text;
    v_request_hash text := md5('release|' || p_packing_job_id::text);
    v_job public.packing_jobs;
    v_bom public.boms;
    v_line record;
    v_snap_id uuid := gen_random_uuid();
    v_line_count integer := 0;
    v_canonical_unit_id uuid;
    v_conversion jsonb;
    v_canonical_qty numeric;
    v_response jsonb;
BEGIN
    IF v_role IS DISTINCT FROM 'ADMIN' AND v_role IS DISTINCT FROM 'PLANNER' THEN
        RAISE EXCEPTION 'Unauthorized: Only planners and admins can release packing jobs.'
            USING ERRCODE = '42501';
    END IF;

    v_idem := public.fn_acquire_idempotency(
        v_idem_key,
        'POST:/api/v1/packing-jobs/{id}/release',
        v_request_hash,
        v_actor_id
    );

    IF v_idem->>'action' = 'REPLAY' THEN
        RETURN v_idem->'body';
    ELSIF v_idem->>'action' = 'EXPIRED' THEN
        RAISE EXCEPTION 'IDEMPOTENCY_RESPONSE_EXPIRED: %', v_idem USING ERRCODE = '23514';
    END IF;

    SELECT *
    INTO v_job
    FROM public.packing_jobs
    WHERE id = p_packing_job_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Packing job % not found.', p_packing_job_id USING ERRCODE = 'P0002';
    END IF;

    -- A job previously released by the pre-2.1.1 implementation is treated
    -- as already-completed work rather than duplicated.
    IF v_job.status = 'RELEASED' THEN
        v_response := jsonb_build_object(
            'success', true,
            'jobId', p_packing_job_id,
            'status', 'RELEASED'
        );
        PERFORM public.fn_complete_idempotency(
            v_idem_key, 'PACKING_JOB', p_packing_job_id, 200, v_response
        );
        RETURN v_response;
    END IF;

    IF v_job.status != 'DRAFT' THEN
        RAISE EXCEPTION 'Job % cannot be released because status is %.',
            p_packing_job_id, v_job.status
            USING ERRCODE = '23514';
    END IF;

    IF v_job.master_bom_id IS NOT NULL THEN
        SELECT *
        INTO v_bom
        FROM public.boms
        WHERE id = v_job.master_bom_id
        FOR SHARE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Master BOM % not found.', v_job.master_bom_id
                USING ERRCODE = 'P0002';
        END IF;

        IF v_bom.status != 'ACTIVE' THEN
            RAISE EXCEPTION 'Master BOM % must be ACTIVE before release.',
                v_bom.id
                USING ERRCODE = '23514';
        END IF;

        INSERT INTO public.packing_job_bom_snapshots (
            id, packing_job_id, source_bom_id, bom_version, is_customized, frozen_by
        ) VALUES (
            v_snap_id, p_packing_job_id, v_bom.id, v_bom.version_number, false, v_actor_id
        );

        FOR v_line IN
            SELECT *
            FROM public.bom_lines
            WHERE bom_id = v_bom.id
            ORDER BY id
        LOOP
            SELECT canonical_unit_id
            INTO v_canonical_unit_id
            FROM public.materials
            WHERE id = v_line.material_id
              AND is_active = true
            FOR SHARE;

            IF NOT FOUND THEN
                RAISE EXCEPTION 'BOM material % is inactive or missing.', v_line.material_id
                    USING ERRCODE = '23503';
            END IF;

            v_conversion := public.fn_resolve_material_conversion(
                v_line.material_id,
                v_line.unit_id,
                v_canonical_unit_id
            );

            v_canonical_qty :=
                CASE v_conversion->>'direction'
                    WHEN 'MULTIPLY' THEN
                        v_line.quantity_per_unit * (v_conversion->>'factor')::numeric
                    WHEN 'DIVIDE' THEN
                        v_line.quantity_per_unit / (v_conversion->>'factor')::numeric
                    ELSE
                        v_line.quantity_per_unit
                END;

            INSERT INTO public.packing_job_bom_snapshot_lines (
                snapshot_id,
                material_id,
                quantity_per_unit,
                unit_id,
                canonical_qty_per_unit,
                canonical_unit_id,
                conversion_rule_id,
                conversion_factor_frozen,
                conversion_direction,
                conversion_type,
                is_optional
            ) VALUES (
                v_snap_id,
                v_line.material_id,
                v_line.quantity_per_unit,
                v_line.unit_id,
                v_canonical_qty,
                v_canonical_unit_id,
                (v_conversion->>'rule_id')::uuid,
                (v_conversion->>'factor')::numeric,
                v_conversion->>'direction',
                v_conversion->>'conversion_type',
                v_line.is_optional
            );

            v_line_count := v_line_count + 1;
        END LOOP;

        IF v_line_count = 0 THEN
            RAISE EXCEPTION 'Packing job % cannot be released because its master BOM has no lines.',
                p_packing_job_id USING ERRCODE = '23514';
        END IF;
    ELSE
        IF NOT EXISTS (
            SELECT 1
            FROM public.packing_job_bom_snapshots
            WHERE packing_job_id = p_packing_job_id
              AND is_customized = true
        ) THEN
            RAISE EXCEPTION 'Custom job must have a complete snapshot before release.'
                USING ERRCODE = '23514';
        END IF;

        IF NOT EXISTS (
            SELECT 1
            FROM public.packing_job_bom_snapshot_lines sl
            JOIN public.packing_job_bom_snapshots s ON s.id = sl.snapshot_id
            WHERE s.packing_job_id = p_packing_job_id
        ) THEN
            RAISE EXCEPTION 'Custom job snapshot must contain at least one material line.'
                USING ERRCODE = '23514';
        END IF;
    END IF;

    UPDATE public.packing_jobs
    SET status = 'RELEASED',
        updated_at = clock_timestamp()
    WHERE id = p_packing_job_id;

    v_response := jsonb_build_object(
        'success', true,
        'jobId', p_packing_job_id,
        'status', 'RELEASED'
    );

    PERFORM public.fn_complete_idempotency(
        v_idem_key, 'PACKING_JOB', p_packing_job_id, 200, v_response
    );

    RETURN v_response;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_release_packing_job(uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.rpc_release_packing_job(uuid) FROM PUBLIC, anon;

-- =============================================================================
-- 5. Retry-safe packing job revision
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_revise_packing_job(
    p_packing_job_id uuid,
    p_revised_quantity integer,
    p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_actor_id uuid := auth.uid();
    v_role text := public.get_current_user_role();
    v_idem jsonb;
    v_idem_key text;
    v_request_hash text;
    v_job public.packing_jobs;
    v_latest_revision public.packing_job_revisions;
    v_diff integer;
    v_rev_num integer;
    v_response jsonb;
BEGIN
    IF v_role IS DISTINCT FROM 'ADMIN' AND v_role IS DISTINCT FROM 'PLANNER' THEN
        RAISE EXCEPTION 'Unauthorized: Only planners and admins can revise job quantities.'
            USING ERRCODE = '42501';
    END IF;

    IF p_revised_quantity <= 0 THEN
        RAISE EXCEPTION 'Revised quantity must be strictly positive.'
            USING ERRCODE = '23514';
    END IF;

    IF p_reason IS NULL OR trim(p_reason) = '' THEN
        RAISE EXCEPTION 'A revision reason is mandatory.' USING ERRCODE = '22023';
    END IF;

    v_idem_key :=
        'revise_job:' ||
        p_packing_job_id::text ||
        ':' ||
        substr(md5(p_revised_quantity::text || '|' || p_reason), 1, 32);

    v_request_hash := md5(
        p_packing_job_id::text || '|' || p_revised_quantity::text || '|' || p_reason
    );

    v_idem := public.fn_acquire_idempotency(
        v_idem_key,
        'POST:/api/v1/packing-jobs/{id}/revise-quantity',
        v_request_hash,
        v_actor_id
    );

    IF v_idem->>'action' = 'REPLAY' THEN
        RETURN v_idem->'body';
    ELSIF v_idem->>'action' = 'EXPIRED' THEN
        RAISE EXCEPTION 'IDEMPOTENCY_RESPONSE_EXPIRED: %', v_idem USING ERRCODE = '23514';
    END IF;

    SELECT *
    INTO v_job
    FROM public.packing_jobs
    WHERE id = p_packing_job_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Packing job % not found.', p_packing_job_id USING ERRCODE = 'P0002';
    END IF;

    IF p_revised_quantity < v_job.completed_quantity THEN
        RAISE EXCEPTION 'Cannot revise job quantity to %: below completed quantity %.',
            p_revised_quantity, v_job.completed_quantity
            USING ERRCODE = '23514';
    END IF;

    SELECT *
    INTO v_latest_revision
    FROM public.packing_job_revisions
    WHERE packing_job_id = p_packing_job_id
    ORDER BY revision_number DESC
    LIMIT 1;

    -- Backward-compatible replay detection for a revision committed before
    -- Phase 2.1.1 introduced the derived idempotency key.
    IF FOUND
       AND v_latest_revision.revised_quantity = p_revised_quantity
       AND v_latest_revision.reason = p_reason THEN
        v_response := jsonb_build_object(
            'success', true,
            'jobId', p_packing_job_id,
            'revisedQuantity', p_revised_quantity,
            'revisionNumber', v_latest_revision.revision_number
        );

        PERFORM public.fn_complete_idempotency(
            v_idem_key,
            'PACKING_JOB',
            p_packing_job_id,
            200,
            v_response
        );

        RETURN v_response;
    END IF;

    v_diff := p_revised_quantity - v_job.current_revised_quantity;

    SELECT COALESCE(max(revision_number), 0) + 1
    INTO v_rev_num
    FROM public.packing_job_revisions
    WHERE packing_job_id = p_packing_job_id;

    INSERT INTO public.packing_job_revisions (
        packing_job_id,
        revision_number,
        original_quantity,
        revised_quantity,
        quantity_difference,
        reason,
        revised_by,
        created_at
    ) VALUES (
        p_packing_job_id,
        v_rev_num,
        v_job.current_revised_quantity,
        p_revised_quantity,
        v_diff,
        p_reason,
        v_actor_id,
        clock_timestamp()
    );

    UPDATE public.packing_jobs
    SET current_revised_quantity = p_revised_quantity,
        pending_quantity = p_revised_quantity - completed_quantity - cancelled_quantity,
        updated_at = clock_timestamp()
    WHERE id = p_packing_job_id;

    v_response := jsonb_build_object(
        'success', true,
        'jobId', p_packing_job_id,
        'revisedQuantity', p_revised_quantity,
        'revisionNumber', v_rev_num
    );

    PERFORM public.fn_complete_idempotency(
        v_idem_key,
        'PACKING_JOB',
        p_packing_job_id,
        200,
        v_response
    );

    RETURN v_response;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_revise_packing_job(uuid, integer, text) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.rpc_revise_packing_job(uuid, integer, text) FROM PUBLIC, anon;

-- =============================================================================
-- 6. Retry-safe packing job cancellation
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_cancel_packing_job(
    p_packing_job_id uuid,
    p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_actor_id uuid := auth.uid();
    v_role text := public.get_current_user_role();
    v_idem jsonb;
    v_idem_key text := 'cancel_job:' || p_packing_job_id::text;
    v_request_hash text := md5('cancel|' || p_packing_job_id::text || '|' || p_reason);
    v_job public.packing_jobs;
    v_canc integer;
    v_response jsonb;
BEGIN
    IF v_role IS DISTINCT FROM 'ADMIN' AND v_role IS DISTINCT FROM 'PLANNER' THEN
        RAISE EXCEPTION 'Unauthorized: Only planners and admins can cancel jobs.'
            USING ERRCODE = '42501';
    END IF;

    IF p_reason IS NULL OR trim(p_reason) = '' THEN
        RAISE EXCEPTION 'A cancellation reason is mandatory.' USING ERRCODE = '22023';
    END IF;

    v_idem := public.fn_acquire_idempotency(
        v_idem_key,
        'POST:/api/v1/packing-jobs/{id}/cancel',
        v_request_hash,
        v_actor_id
    );

    IF v_idem->>'action' = 'REPLAY' THEN
        RETURN v_idem->'body';
    ELSIF v_idem->>'action' = 'EXPIRED' THEN
        RAISE EXCEPTION 'IDEMPOTENCY_RESPONSE_EXPIRED: %', v_idem USING ERRCODE = '23514';
    END IF;

    SELECT *
    INTO v_job
    FROM public.packing_jobs
    WHERE id = p_packing_job_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Packing job % not found.', p_packing_job_id USING ERRCODE = 'P0002';
    END IF;

    IF v_job.status = 'CANCELLED' THEN
        IF v_job.cancellation_reason IS DISTINCT FROM p_reason THEN
            RAISE EXCEPTION 'CANCELLED_JOB_REQUEST_CONFLICT: The job is already cancelled with a different reason.'
                USING ERRCODE = '23505';
        END IF;

        v_response := jsonb_build_object(
            'success', true,
            'jobId', p_packing_job_id,
            'status', 'CANCELLED',
            'cancelledQuantity', v_job.cancelled_quantity,
            'completedPreserved', v_job.completed_quantity
        );

        PERFORM public.fn_complete_idempotency(
            v_idem_key,
            'PACKING_JOB',
            p_packing_job_id,
            200,
            v_response
        );

        RETURN v_response;
    END IF;

    IF v_job.status = 'COMPLETED' THEN
        RAISE EXCEPTION 'Job % is already COMPLETED.', p_packing_job_id
            USING ERRCODE = '23514';
    END IF;

    v_canc := v_job.pending_quantity;

    UPDATE public.packing_jobs
    SET cancelled_quantity = cancelled_quantity + v_canc,
        pending_quantity = 0,
        status = 'CANCELLED',
        cancellation_reason = p_reason,
        cancelled_at = clock_timestamp(),
        updated_at = clock_timestamp()
    WHERE id = p_packing_job_id;

    UPDATE public.stock_reservations
    SET status = 'RELEASED',
        updated_at = clock_timestamp()
    WHERE packing_job_id = p_packing_job_id
      AND status = 'ACTIVE';

    v_response := jsonb_build_object(
        'success', true,
        'jobId', p_packing_job_id,
        'status', 'CANCELLED',
        'cancelledQuantity', v_canc,
        'completedPreserved', v_job.completed_quantity
    );

    PERFORM public.fn_complete_idempotency(
        v_idem_key,
        'PACKING_JOB',
        p_packing_job_id,
        200,
        v_response
    );

    RETURN v_response;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_cancel_packing_job(uuid, text) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.rpc_cancel_packing_job(uuid, text) FROM PUBLIC, anon;

-- =============================================================================
-- 7. Explicitly close privileged RPCs to PUBLIC/anon
-- =============================================================================
REVOKE EXECUTE ON FUNCTION public.rpc_issue_to_worker(uuid, uuid, uuid, uuid, numeric, uuid, text, text)
    FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.rpc_return_from_worker(uuid, uuid, uuid, uuid, numeric, uuid, text, text)
    FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.rpc_transfer_stock(uuid, uuid, uuid, numeric, uuid, text, text, text)
    FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.rpc_complete_production(uuid, integer, uuid, text, text, text)
    FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.rpc_quarantine_stock(uuid, uuid, uuid, numeric, uuid, uuid, uuid, text, text, text)
    FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.rpc_scrap_disposal(uuid, uuid, numeric, uuid, text, text, text)
    FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.rpc_post_stock_adjustment(text, uuid, uuid, numeric, text, text, text)
    FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.rpc_issue_to_worker(uuid, uuid, uuid, uuid, numeric, uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_return_from_worker(uuid, uuid, uuid, uuid, numeric, uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_transfer_stock(uuid, uuid, uuid, numeric, uuid, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_complete_production(uuid, integer, uuid, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_quarantine_stock(uuid, uuid, uuid, numeric, uuid, uuid, uuid, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_scrap_disposal(uuid, uuid, numeric, uuid, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_post_stock_adjustment(text, uuid, uuid, numeric, text, text, text) TO authenticated;
