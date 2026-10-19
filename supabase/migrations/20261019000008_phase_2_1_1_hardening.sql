-- Migration 000008: Phase 2.1.1 final security and transactional hardening.
ALTER TABLE public.purchase_order_lines DROP CONSTRAINT IF EXISTS uq_po_lines_material;

-- Enforce end-of-shift quantity conservation at the database boundary.
ALTER TABLE public.daily_closings
    ADD CONSTRAINT chk_daily_closing_conservation
    CHECK (
        total_planned_units >= 0
        AND total_completed_units >= 0
        AND total_pending_units >= 0
        AND total_cancelled_units >= 0
        AND total_planned_units = total_completed_units + total_pending_units + total_cancelled_units
    );
CREATE OR REPLACE FUNCTION public.fn_hash_request(p_scope text,p_payload jsonb)
RETURNS text LANGUAGE sql IMMUTABLE STRICT SET search_path=''
AS $$
SELECT pg_catalog.encode(extensions.digest(pg_catalog.convert_to(p_scope || pg_catalog.chr(10) || p_payload::text,'UTF8'),'sha256'),'hex');
$$;
REVOKE ALL ON FUNCTION public.fn_hash_request(text,jsonb) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.fn_acquire_idempotency(p_key text,p_scope text,p_hash text,p_owner_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $$
DECLARE v_existing public.idempotency_keys; v_cached public.idempotency_responses; v_claimed_key text;
BEGIN
 IF auth.uid() IS NULL OR p_owner_id IS DISTINCT FROM auth.uid() THEN RAISE EXCEPTION 'Idempotency owner must match authenticated actor.' USING ERRCODE='42501'; END IF;
 IF p_key IS NULL OR p_key !~ '^[A-Za-z0-9_.:-]{16,128}$' THEN RAISE EXCEPTION 'Invalid idempotency key format.' USING ERRCODE='22023'; END IF;
 IF p_scope IS NULL OR btrim(p_scope)='' OR p_hash IS NULL OR btrim(p_hash)='' THEN RAISE EXCEPTION 'Scope and request hash are required.' USING ERRCODE='22023'; END IF;
 INSERT INTO public.idempotency_keys(idempotency_key,owner_id,operation_scope,request_hash,status)
 VALUES(p_key,p_owner_id,p_scope,p_hash,'PROCESSING')
 ON CONFLICT(idempotency_key) DO NOTHING RETURNING idempotency_key INTO v_claimed_key;
 IF FOUND THEN RETURN jsonb_build_object('action','PROCEED'); END IF;
 SELECT * INTO v_existing FROM public.idempotency_keys WHERE idempotency_key=p_key FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Idempotency key changed concurrently; retry.' USING ERRCODE='40001'; END IF;
 IF v_existing.owner_id IS DISTINCT FROM p_owner_id OR v_existing.operation_scope IS DISTINCT FROM p_scope OR v_existing.request_hash IS DISTINCT FROM p_hash THEN
   RAISE EXCEPTION 'IDEMPOTENCY_KEY_REUSED: conflicting request.' USING ERRCODE='23505';
 END IF;
 IF v_existing.status='COMPLETED' THEN
   SELECT * INTO v_cached FROM public.idempotency_responses WHERE idempotency_key=p_key;
   IF FOUND AND v_cached.expires_at>clock_timestamp() THEN
     RETURN jsonb_build_object('action','REPLAY','status_code',v_cached.response_status_code,'body',v_cached.response_body);
   END IF;
   RETURN jsonb_build_object('action','EXPIRED','resource_type',v_existing.resource_type,'resource_id',v_existing.resource_id,'operation_completed_at',v_existing.operation_completed_at);
 END IF;
 RAISE EXCEPTION 'IDEMPOTENCY_IN_PROGRESS: request is already processing.' USING ERRCODE='55P03';
END;
$$;
REVOKE ALL ON FUNCTION public.fn_acquire_idempotency(text,text,text,uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.fn_complete_idempotency(p_key text,p_resource_type text,p_resource_id uuid,p_status_code integer,p_body jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $$
DECLARE v_completed_key text;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authenticated actor required.' USING ERRCODE='28000'; END IF;
 IF p_status_code NOT BETWEEN 200 AND 299 OR p_body IS NULL THEN RAISE EXCEPTION 'Valid success response required.' USING ERRCODE='22023'; END IF;
 UPDATE public.idempotency_keys SET status='COMPLETED',resource_type=p_resource_type,resource_id=p_resource_id,operation_completed_at=clock_timestamp()
 WHERE idempotency_key=p_key AND owner_id=auth.uid() AND status='PROCESSING' RETURNING idempotency_key INTO v_completed_key;
 IF NOT FOUND THEN RAISE EXCEPTION 'No owned in-flight idempotency record exists.' USING ERRCODE='42501'; END IF;
 INSERT INTO public.idempotency_responses(idempotency_key,response_status_code,response_body)
 VALUES(p_key,p_status_code,p_body)
 ON CONFLICT(idempotency_key) DO UPDATE SET response_status_code=EXCLUDED.response_status_code,response_body=EXCLUDED.response_body,created_at=clock_timestamp(),expires_at=clock_timestamp()+interval '7 days';
END;
$$;
REVOKE ALL ON FUNCTION public.fn_complete_idempotency(text,text,uuid,integer,jsonb) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.trg_protect_profile_role()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $$
BEGIN
 IF NEW.role IS DISTINCT FROM OLD.role OR NEW.is_active IS DISTINCT FROM OLD.is_active THEN
   IF NOT (session_user IN ('postgres','supabase_admin') AND coalesce(current_setting('role',true),'none') IN ('none','postgres','supabase_admin'))
      AND public.get_current_user_role() IS DISTINCT FROM 'ADMIN' THEN
     RAISE EXCEPTION 'Unauthorized: only active administrators can modify profile access.' USING ERRCODE='42501';
   END IF;
 END IF;
 NEW.updated_at=clock_timestamp();
 RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.trg_protect_profile_role() FROM PUBLIC, anon, authenticated;


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
    v_conv record;
    v_calc_accepted numeric;
    v_calc_canonical numeric;
    v_factor numeric;
    v_dir text;
    v_type text;
    v_is_est boolean;
    v_conversion_rule_id uuid;
    v_po_received_qty numeric;
    v_po_conv record;
    v_po_line record;
    v_response jsonb;
BEGIN
    -- 1. Authentication & Authorization Check
    v_actor_id := auth.uid();
    v_role := public.get_current_user_role();
    IF v_role IS DISTINCT FROM 'ADMIN' AND v_role IS DISTINCT FROM 'STOREKEEPER' THEN
        RAISE EXCEPTION 'Unauthorized: Only storekeepers and administrators can post goods receipts.'
            USING ERRCODE = '42501';
    END IF;

    -- 2. Transactional Idempotency Resolution
    p_request_hash := public.fn_hash_request('POST:/api/v1/goods-receipts/post', jsonb_build_object('grn_id', p_grn_id));
    v_idem := public.fn_acquire_idempotency(p_idempotency_key, 'POST:/api/v1/goods-receipts/post', p_request_hash, v_actor_id);
    IF v_idem->>'action' = 'REPLAY' THEN
        RETURN v_idem->'body';
    ELSIF v_idem->>'action' = 'EXPIRED' THEN
        RAISE EXCEPTION 'IDEMPOTENCY_RESPONSE_EXPIRED: %', v_idem USING ERRCODE = '23514';
    END IF;

    -- 3. Lock and validate Goods Receipt header
    SELECT * INTO v_grn
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

    -- If PO linked, lock and validate PO header
    IF v_grn.po_id IS NOT NULL THEN
        SELECT * INTO v_po FROM public.purchase_orders WHERE id = v_grn.po_id FOR UPDATE;
        IF v_po.vendor_id IS DISTINCT FROM v_grn.vendor_id THEN
            RAISE EXCEPTION 'Vendor mismatch: PO vendor does not match receipt vendor.' USING ERRCODE = '23514';
        END IF;
    END IF;

    -- 4. Process lines with authoritative server-side recalculation
    FOR v_line IN
        SELECT * FROM public.goods_receipt_lines
        WHERE grn_id = p_grn_id
        ORDER BY id
        FOR UPDATE
    LOOP
        -- Fetch active material and canonical unit
        SELECT * INTO v_mat FROM public.materials WHERE id = v_line.material_id AND is_active = true;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Material % is inactive or does not exist.', v_line.material_id USING ERRCODE = '23503';
        END IF;

        -- Validate PO Line Linkage if receipt is tied to a PO
        IF v_grn.po_id IS NOT NULL THEN
            IF v_line.purchase_order_line_id IS NULL THEN
                RAISE EXCEPTION 'Receipt line % missing required purchase_order_line_id for PO receipt.', v_line.id
                    USING ERRCODE = '23514';
            END IF;

            SELECT * INTO v_po_line FROM public.purchase_order_lines 
            WHERE id = v_line.purchase_order_line_id AND po_id = v_grn.po_id
            FOR UPDATE;

            IF NOT FOUND THEN
                RAISE EXCEPTION 'PO Line % does not belong to PO %.', v_line.purchase_order_line_id, v_grn.po_id
                    USING ERRCODE = '23514';
            END IF;

            IF v_po_line.material_id != v_line.material_id THEN
                RAISE EXCEPTION 'PO Line material does not match receipt line material.' USING ERRCODE = '23514';
            END IF;
        END IF;

        -- Validate measurements: entered_qty > 0, rejected_qty >= 0
        IF v_line.entered_qty <= 0 THEN
            RAISE EXCEPTION 'Entered quantity must be positive on line %.', v_line.id USING ERRCODE = '23514';
        END IF;

        IF v_line.rejected_qty < 0 THEN
            RAISE EXCEPTION 'Rejected quantity cannot be negative on line %.', v_line.id USING ERRCODE = '23514';
        END IF;

        IF v_line.rejected_qty > v_line.entered_qty THEN
            RAISE EXCEPTION 'Rejected quantity exceeds entered quantity on line %.', v_line.id USING ERRCODE = '23514';
        END IF;

        -- Authoritative recalculation of accepted quantity
        v_calc_accepted := v_line.entered_qty - v_line.rejected_qty;

        -- Authoritative unit conversion recalculation; ignore draft-supplied rule IDs.
        v_conversion_rule_id := NULL;
        IF v_line.entered_unit_id = v_mat.canonical_unit_id THEN
            v_calc_canonical := v_calc_accepted;
            v_factor := 1.0;
            v_dir := 'NONE';
            v_type := 'EXACT';
            v_is_est := false;
        ELSE
            -- Fetch conversion rule
            SELECT * INTO v_conv FROM public.material_conversions
            WHERE material_id = v_line.material_id
              AND from_unit_id = v_line.entered_unit_id
              AND to_unit_id = v_mat.canonical_unit_id
              AND effective_from <= clock_timestamp()
              AND (effective_to IS NULL OR effective_to > clock_timestamp());

            IF NOT FOUND THEN
                -- Try inverse conversion
                SELECT * INTO v_conv FROM public.material_conversions
                WHERE material_id = v_line.material_id
                  AND from_unit_id = v_mat.canonical_unit_id
                  AND to_unit_id = v_line.entered_unit_id
                  AND effective_from <= clock_timestamp()
                  AND (effective_to IS NULL OR effective_to > clock_timestamp());

                IF NOT FOUND THEN
                    RAISE EXCEPTION 'No valid conversion rule found between % and canonical unit % for material %.',
                        v_line.entered_unit_id, v_mat.canonical_unit_id, v_line.material_id USING ERRCODE = '23514';
                END IF;
                v_dir := 'DIVIDE';
                v_calc_canonical := v_calc_accepted / v_conv.conversion_factor;
                v_conversion_rule_id := v_conv.id;
            ELSE
                v_dir := 'MULTIPLY';
                v_calc_canonical := v_calc_accepted * v_conv.conversion_factor;
                v_conversion_rule_id := v_conv.id;
            END IF;

            v_factor := v_conv.conversion_factor;
            v_type := CASE WHEN v_conv.is_exact THEN 'EXACT' ELSE 'ESTIMATED' END;
            v_is_est := NOT v_conv.is_exact;
        END IF;

        -- Update receipt line with authoritative server-calculated quantities
        UPDATE public.goods_receipt_lines
        SET accepted_qty = v_calc_accepted,
            canonical_quantity = v_calc_canonical,
            canonical_unit_id = v_mat.canonical_unit_id,
            conversion_rule_id = v_conversion_rule_id,
            conversion_factor_used = v_factor,
            conversion_direction = v_dir,
            conversion_type_used = v_type,
            is_estimated_conversion = v_is_est
        WHERE id = v_line.id;

        -- Post stock movement if accepted > 0
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
                p_measurement_method => CASE WHEN v_line.weight_kg IS NOT NULL THEN 'SCALE_WEIGHED' ELSE 'MANUALLY_COUNTED' END,
                p_conversion_factor => v_factor,
                p_conversion_rule_id => v_conversion_rule_id,
                p_conversion_direction => v_dir,
                p_conversion_type => v_type,
                p_is_estimated => v_is_est,
                p_goods_receipt_id => v_grn.id,
                p_goods_receipt_line_id => v_line.id,
                p_created_by => v_actor_id
            );
            v_seq := v_seq + 1;
        END IF;

        -- Credit PO line received quantity unambiguously
        IF v_grn.po_id IS NOT NULL THEN
            -- PO fulfillment is stored in the PO line's unit, converting via canonical units.
            IF v_po_line.unit_id = v_line.entered_unit_id THEN
                v_po_received_qty := v_calc_accepted;
            ELSIF v_po_line.unit_id = v_mat.canonical_unit_id THEN
                v_po_received_qty := v_calc_canonical;
            ELSE
                SELECT * INTO v_po_conv FROM public.material_conversions
                WHERE material_id=v_line.material_id AND from_unit_id=v_po_line.unit_id AND to_unit_id=v_mat.canonical_unit_id
                  AND effective_from<=clock_timestamp() AND (effective_to IS NULL OR effective_to>clock_timestamp())
                ORDER BY effective_from DESC LIMIT 1;
                IF FOUND THEN
                    v_po_received_qty := v_calc_canonical / v_po_conv.conversion_factor;
                ELSE
                    SELECT * INTO v_po_conv FROM public.material_conversions
                    WHERE material_id=v_line.material_id AND from_unit_id=v_mat.canonical_unit_id AND to_unit_id=v_po_line.unit_id
                      AND effective_from<=clock_timestamp() AND (effective_to IS NULL OR effective_to>clock_timestamp())
                    ORDER BY effective_from DESC LIMIT 1;
                    IF NOT FOUND THEN
                        RAISE EXCEPTION 'No active conversion exists between canonical unit and PO unit for material %.',
                            v_line.material_id USING ERRCODE='23514';
                    END IF;
                    v_po_received_qty := v_calc_canonical * v_po_conv.conversion_factor;
                END IF;
            END IF;
            IF v_po_received_qty < 0 THEN RAISE EXCEPTION 'Calculated PO receipt quantity cannot be negative.' USING ERRCODE='23514'; END IF;
            IF v_po_line.received_quantity + v_po_received_qty > v_po_line.ordered_quantity THEN
                RAISE EXCEPTION 'Receipt would exceed ordered quantity for PO line %.',v_po_line.id USING ERRCODE='23514';
            END IF;
            UPDATE public.purchase_order_lines
            SET received_quantity = received_quantity + v_po_received_qty
            WHERE id = v_line.purchase_order_line_id;
        END IF;
    END LOOP;

    -- Update PO status if all lines fulfilled
    IF v_grn.po_id IS NOT NULL THEN
        UPDATE public.purchase_orders
        SET status = CASE 
            WHEN NOT EXISTS (SELECT 1 FROM public.purchase_order_lines WHERE po_id = v_grn.po_id AND received_quantity < ordered_quantity)
            THEN 'COMPLETED'
            ELSE 'PARTIALLY_RECEIVED'
        END,
        updated_at = clock_timestamp()
        WHERE id = v_grn.po_id;
    END IF;

    -- Mark Goods Receipt header as POSTED
    UPDATE public.goods_receipts
    SET status = 'POSTED',
        posted_by = v_actor_id,
        posted_at = clock_timestamp()
    WHERE id = p_grn_id;

    -- Build response payload
    v_response := jsonb_build_object(
        'success', true,
        'grnId', p_grn_id,
        'grnNumber', v_grn.grn_number,
        'status', 'POSTED',
        'linesPosted', v_seq - 1
    );

    -- Store idempotency success response and mark key COMPLETED
    PERFORM public.fn_complete_idempotency(p_idempotency_key, 'GOODS_RECEIPT', p_grn_id, 200, v_response);

    RETURN v_response;
END;
$$;

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
DECLARE
    v_actor_id uuid := auth.uid();
    v_role text := public.get_current_user_role();
    v_worker_loc_id uuid;
    v_tx public.stock_transactions;
    v_idem jsonb;
    v_job public.packing_jobs;
    v_response jsonb;
BEGIN
    IF v_role IS DISTINCT FROM 'ADMIN' AND v_role IS DISTINCT FROM 'STOREKEEPER' THEN
        RAISE EXCEPTION 'Unauthorized: Only storekeepers and admins can issue stock.' USING ERRCODE = '42501';
    END IF;

    p_request_hash := public.fn_hash_request('POST:/api/v1/stock/issue-to-worker', jsonb_build_object('packing_job_id', p_packing_job_id, 'worker_id', p_worker_id, 'material_id', p_material_id, 'source_location_id', p_source_location_id, 'quantity', p_quantity, 'unit_id', p_unit_id));
    v_idem := public.fn_acquire_idempotency(p_idempotency_key, 'POST:/api/v1/stock/issue-to-worker', p_request_hash, v_actor_id);
    IF v_idem->>'action' = 'REPLAY' THEN RETURN v_idem->'body';
    ELSIF v_idem->>'action' = 'EXPIRED' THEN RAISE EXCEPTION 'IDEMPOTENCY_RESPONSE_EXPIRED: %', v_idem USING ERRCODE = '23514'; END IF;

    SELECT * INTO v_job FROM public.packing_jobs WHERE id = p_packing_job_id FOR UPDATE;
    IF v_job.status NOT IN ('RELEASED', 'IN_PROGRESS', 'PARTIALLY_COMPLETED') THEN
        RAISE EXCEPTION 'Cannot issue materials to job in status %.', v_job.status USING ERRCODE = '23514';
    END IF;

    SELECT assigned_location_id INTO v_worker_loc_id FROM public.workers WHERE id = p_worker_id AND is_active = true;
    IF NOT FOUND THEN RAISE EXCEPTION 'Worker % does not exist or is inactive.', p_worker_id USING ERRCODE = '23503'; END IF;

    v_tx := public.fn_post_stock_transaction(
        p_idempotency_key => p_idempotency_key,
        p_transaction_sequence => 1,
        p_material_id => p_material_id,
        p_movement_type => 'ISSUE_TO_WORKER',
        p_source_location_id => p_source_location_id,
        p_destination_location_id => v_worker_loc_id,
        p_worker_id => p_worker_id,
        p_quantity => p_quantity,
        p_unit_id => p_unit_id,
        p_entered_quantity => p_quantity,
        p_entered_unit_id => p_unit_id,
        p_measurement_method => 'SCALE_WEIGHED',
        p_packing_job_id => p_packing_job_id,
        p_created_by => v_actor_id
    );

    v_response := jsonb_build_object(
        'success', true,
        'stockTransactionId', v_tx.id,
        'transactionNumber', v_tx.transaction_number,
        'movementType', v_tx.movement_type,
        'quantity', v_tx.quantity
    );

    PERFORM public.fn_complete_idempotency(p_idempotency_key, 'STOCK_TRANSACTION', v_tx.id, 200, v_response);
    RETURN v_response;
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
    v_worker_loc_id uuid;
    v_tx public.stock_transactions;
    v_idem jsonb;
    v_response jsonb;
BEGIN
    IF v_role IS DISTINCT FROM 'ADMIN' AND v_role IS DISTINCT FROM 'STOREKEEPER' THEN
        RAISE EXCEPTION 'Unauthorized: Only storekeepers and admins can record returns.' USING ERRCODE = '42501';
    END IF;

    p_request_hash := public.fn_hash_request('POST:/api/v1/stock/return-from-worker', jsonb_build_object('packing_job_id', p_packing_job_id, 'worker_id', p_worker_id, 'material_id', p_material_id, 'destination_location_id', p_destination_location_id, 'quantity', p_quantity, 'unit_id', p_unit_id));
    v_idem := public.fn_acquire_idempotency(p_idempotency_key, 'POST:/api/v1/stock/return-from-worker', p_request_hash, v_actor_id);
    IF v_idem->>'action' = 'REPLAY' THEN RETURN v_idem->'body';
    ELSIF v_idem->>'action' = 'EXPIRED' THEN RAISE EXCEPTION 'IDEMPOTENCY_RESPONSE_EXPIRED: %', v_idem USING ERRCODE = '23514'; END IF;

    SELECT assigned_location_id INTO v_worker_loc_id FROM public.workers WHERE id = p_worker_id AND is_active = true;
    IF NOT FOUND THEN RAISE EXCEPTION 'Worker % does not exist or is inactive.', p_worker_id USING ERRCODE = '23503'; END IF;

    v_tx := public.fn_post_stock_transaction(
        p_idempotency_key => p_idempotency_key,
        p_transaction_sequence => 1,
        p_material_id => p_material_id,
        p_movement_type => 'RETURN_FROM_WORKER',
        p_source_location_id => v_worker_loc_id,
        p_destination_location_id => p_destination_location_id,
        p_worker_id => p_worker_id,
        p_quantity => p_quantity,
        p_unit_id => p_unit_id,
        p_entered_quantity => p_quantity,
        p_entered_unit_id => p_unit_id,
        p_measurement_method => 'SCALE_WEIGHED',
        p_packing_job_id => p_packing_job_id,
        p_created_by => v_actor_id
    );

    v_response := jsonb_build_object(
        'success', true,
        'stockTransactionId', v_tx.id,
        'transactionNumber', v_tx.transaction_number,
        'movementType', v_tx.movement_type,
        'quantity', v_tx.quantity
    );

    PERFORM public.fn_complete_idempotency(p_idempotency_key, 'STOCK_TRANSACTION', v_tx.id, 200, v_response);
    RETURN v_response;
END;
$$;

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
    v_tx public.stock_transactions;
    v_idem jsonb;
    v_response jsonb;
BEGIN
    IF v_role IS DISTINCT FROM 'ADMIN' AND v_role IS DISTINCT FROM 'STOREKEEPER' THEN
        RAISE EXCEPTION 'Unauthorized: Only storekeepers and admins can transfer stock.' USING ERRCODE = '42501';
    END IF;

    IF p_reason IS NULL OR trim(p_reason) = '' THEN
        RAISE EXCEPTION 'A non-empty transfer reason is required.' USING ERRCODE = '22023';
    END IF;

    p_request_hash := public.fn_hash_request('POST:/api/v1/stock/transfer', jsonb_build_object('material_id', p_material_id, 'source_location_id', p_source_location_id, 'destination_location_id', p_destination_location_id, 'quantity', p_quantity, 'unit_id', p_unit_id, 'reason', p_reason));
    v_idem := public.fn_acquire_idempotency(p_idempotency_key, 'POST:/api/v1/stock/transfer', p_request_hash, v_actor_id);
    IF v_idem->>'action' = 'REPLAY' THEN RETURN v_idem->'body';
    ELSIF v_idem->>'action' = 'EXPIRED' THEN RAISE EXCEPTION 'IDEMPOTENCY_RESPONSE_EXPIRED: %', v_idem USING ERRCODE = '23514'; END IF;

    v_tx := public.fn_post_stock_transaction(
        p_idempotency_key => p_idempotency_key,
        p_transaction_sequence => 1,
        p_material_id => p_material_id,
        p_movement_type => 'LOCATION_TRANSFER',
        p_source_location_id => p_source_location_id,
        p_destination_location_id => p_destination_location_id,
        p_worker_id => NULL,
        p_quantity => p_quantity,
        p_unit_id => p_unit_id,
        p_entered_quantity => p_quantity,
        p_entered_unit_id => p_unit_id,
        p_measurement_method => 'SCALE_WEIGHED',
        p_movement_reason => p_reason,
        p_created_by => v_actor_id
    );

    v_response := jsonb_build_object(
        'success', true,
        'stockTransactionId', v_tx.id,
        'transactionNumber', v_tx.transaction_number,
        'movementType', v_tx.movement_type,
        'quantity', v_tx.quantity
    );

    PERFORM public.fn_complete_idempotency(p_idempotency_key, 'STOCK_TRANSACTION', v_tx.id, 200, v_response);
    RETURN v_response;
END;
$$;

CREATE OR REPLACE FUNCTION public.rpc_complete_production(
    p_packing_job_id uuid,
    p_completed_units integer,
    p_worker_id uuid,
    p_remarks text,
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
    v_idem jsonb;
    v_job public.packing_jobs;
    v_snap public.packing_job_bom_snapshots;
    v_worker_loc_id uuid;
    v_completion_id uuid := gen_random_uuid();
    v_comp_num text;
    v_line record;
    v_theoretical numeric;
    v_tx public.stock_transactions;
    v_seq integer := 1;
    v_response jsonb;
BEGIN
    IF v_role IS DISTINCT FROM 'ADMIN' AND v_role IS DISTINCT FROM 'OPERATOR' AND v_role IS DISTINCT FROM 'PLANNER' THEN
        RAISE EXCEPTION 'Unauthorized: Only operators, planners, and admins can record production.' USING ERRCODE = '42501';
    END IF;

    IF p_completed_units <= 0 THEN
        RAISE EXCEPTION 'Completed units must be strictly positive.' USING ERRCODE = '23514';
    END IF;

    p_request_hash := public.fn_hash_request('POST:/api/v1/production/completions', jsonb_build_object('packing_job_id', p_packing_job_id, 'completed_units', p_completed_units, 'worker_id', p_worker_id, 'remarks', p_remarks));
    v_idem := public.fn_acquire_idempotency(p_idempotency_key, 'POST:/api/v1/production/completions', p_request_hash, v_actor_id);
    IF v_idem->>'action' = 'REPLAY' THEN RETURN v_idem->'body';
    ELSIF v_idem->>'action' = 'EXPIRED' THEN RAISE EXCEPTION 'IDEMPOTENCY_RESPONSE_EXPIRED: %', v_idem USING ERRCODE = '23514'; END IF;

    -- Lock job and verify status
    SELECT * INTO v_job FROM public.packing_jobs WHERE id = p_packing_job_id FOR UPDATE;
    IF v_job.status NOT IN ('RELEASED', 'IN_PROGRESS', 'PARTIALLY_COMPLETED') THEN
        RAISE EXCEPTION 'Job % cannot receive completions in status %.', p_packing_job_id, v_job.status USING ERRCODE = '23514';
    END IF;

    IF p_completed_units > v_job.pending_quantity THEN
        RAISE EXCEPTION 'Completed units % exceeds pending quantity %.', p_completed_units, v_job.pending_quantity USING ERRCODE = '23514';
    END IF;

    SELECT assigned_location_id INTO v_worker_loc_id FROM public.workers WHERE id = p_worker_id AND is_active = true;
    IF NOT FOUND THEN RAISE EXCEPTION 'Worker % does not exist or is inactive.', p_worker_id USING ERRCODE = '23503'; END IF;

    SELECT * INTO v_snap FROM public.packing_job_bom_snapshots WHERE packing_job_id = p_packing_job_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Job % has no released BOM snapshot.', p_packing_job_id USING ERRCODE = '23514'; END IF;

    -- Update job counters maintaining conservation invariant
    UPDATE public.packing_jobs
    SET completed_quantity = completed_quantity + p_completed_units,
        pending_quantity = pending_quantity - p_completed_units,
        status = CASE WHEN (pending_quantity - p_completed_units) = 0 THEN 'COMPLETED' ELSE 'PARTIALLY_COMPLETED' END,
        updated_at = clock_timestamp()
    WHERE id = p_packing_job_id;

    -- Insert production completion record
    v_comp_num := 'COMP-' || to_char(clock_timestamp(), 'YYYYMMDD') || '-' || substr(md5(random()::text), 1, 6);
    INSERT INTO public.production_completions (
        id, packing_job_id, completion_number, completed_units, completed_by_worker_id,
        idempotency_key, remarks, recorded_by, created_at
    ) VALUES (
        v_completion_id, p_packing_job_id, v_comp_num, p_completed_units, p_worker_id,
        p_idempotency_key, p_remarks, v_actor_id, clock_timestamp()
    );

    -- Iterate frozen BOM snapshot lines to execute backflushed consumption
    FOR v_line IN
        SELECT * FROM public.packing_job_bom_snapshot_lines
        WHERE snapshot_id = v_snap.id
    LOOP
        v_theoretical := p_completed_units * v_line.canonical_qty_per_unit;

        v_tx := public.fn_post_stock_transaction(
            p_idempotency_key => p_idempotency_key,
            p_transaction_sequence => v_seq,
            p_material_id => v_line.material_id,
            p_movement_type => 'CONSUMPTION',
            p_source_location_id => v_worker_loc_id,
            p_destination_location_id => NULL,
            p_worker_id => p_worker_id,
            p_quantity => v_theoretical,
            p_unit_id => v_line.canonical_unit_id,
            p_entered_quantity => v_theoretical,
            p_entered_unit_id => v_line.canonical_unit_id,
            p_measurement_method => 'AUTO_BOM_BACKFLUSH',
            p_packing_job_id => p_packing_job_id,
            p_production_completion_id => v_completion_id,
            p_created_by => v_actor_id
        );
        v_seq := v_seq + 1;

        -- Record material consumption record (UNVERIFIED by default)
        INSERT INTO public.material_consumption_records (
            production_completion_id, material_id, theoretical_quantity, posted_ledger_quantity,
            physically_confirmed_quantity, variance_quantity, variance_status, stock_transaction_id
        ) VALUES (
            v_completion_id, v_line.material_id, v_theoretical, v_theoretical,
            NULL, NULL, 'UNVERIFIED', v_tx.id
        );
    END LOOP;

    v_response := jsonb_build_object(
        'success', true,
        'completionId', v_completion_id,
        'completionNumber', v_comp_num,
        'completedUnits', p_completed_units,
        'remainingPending', v_job.pending_quantity - p_completed_units
    );

    PERFORM public.fn_complete_idempotency(p_idempotency_key, 'PRODUCTION_COMPLETION', v_completion_id, 201, v_response);
    RETURN v_response;
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
    v_tx public.stock_transactions;
    v_idem jsonb;
    v_response jsonb;
BEGIN
    IF v_role IS DISTINCT FROM 'ADMIN' AND v_role IS DISTINCT FROM 'STOREKEEPER' THEN
        RAISE EXCEPTION 'Unauthorized: Only storekeepers and admins can quarantine stock.' USING ERRCODE = '42501';
    END IF;

    IF p_source_location_id IS NULL THEN
        RAISE EXCEPTION 'A valid source inventory location is required for quarantine.' USING ERRCODE = '23514';
    END IF;

    IF p_reason IS NULL OR trim(p_reason) = '' THEN
        RAISE EXCEPTION 'A quarantine reason is required.' USING ERRCODE = '22023';
    END IF;

    p_request_hash := public.fn_hash_request('POST:/api/v1/stock/damage-quarantine', jsonb_build_object('material_id', p_material_id, 'source_location_id', p_source_location_id, 'destination_location_id', p_destination_location_id, 'quantity', p_quantity, 'unit_id', p_unit_id, 'worker_id', p_worker_id, 'packing_job_id', p_packing_job_id, 'reason', p_reason));
    v_idem := public.fn_acquire_idempotency(p_idempotency_key, 'POST:/api/v1/stock/damage-quarantine', p_request_hash, v_actor_id);
    IF v_idem->>'action' = 'REPLAY' THEN RETURN v_idem->'body';
    ELSIF v_idem->>'action' = 'EXPIRED' THEN RAISE EXCEPTION 'IDEMPOTENCY_RESPONSE_EXPIRED: %', v_idem USING ERRCODE = '23514'; END IF;

    v_tx := public.fn_post_stock_transaction(
        p_idempotency_key => p_idempotency_key,
        p_transaction_sequence => 1,
        p_material_id => p_material_id,
        p_movement_type => 'DAMAGE_QUARANTINE',
        p_source_location_id => p_source_location_id,
        p_destination_location_id => p_destination_location_id,
        p_worker_id => p_worker_id,
        p_quantity => p_quantity,
        p_unit_id => p_unit_id,
        p_entered_quantity => p_quantity,
        p_entered_unit_id => p_unit_id,
        p_measurement_method => 'INSPECTION_AUDIT',
        p_movement_reason => p_reason,
        p_packing_job_id => p_packing_job_id,
        p_created_by => v_actor_id
    );

    v_response := jsonb_build_object(
        'success', true,
        'stockTransactionId', v_tx.id,
        'transactionNumber', v_tx.transaction_number,
        'movementType', v_tx.movement_type,
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
    v_tx public.stock_transactions;
    v_idem jsonb;
    v_response jsonb;
BEGIN
    IF v_role IS DISTINCT FROM 'ADMIN' AND v_role IS DISTINCT FROM 'STOREKEEPER' THEN
        RAISE EXCEPTION 'Unauthorized: Only storekeepers and admins can dispose of scrap.' USING ERRCODE = '42501';
    END IF;

    IF p_reason IS NULL OR trim(p_reason) = '' THEN
        RAISE EXCEPTION 'A disposal authorization reason is required.' USING ERRCODE = '22023';
    END IF;

    p_request_hash := public.fn_hash_request('POST:/api/v1/stock/scrap-disposal', jsonb_build_object('material_id', p_material_id, 'source_location_id', p_source_location_id, 'quantity', p_quantity, 'unit_id', p_unit_id, 'reason', p_reason));
    v_idem := public.fn_acquire_idempotency(p_idempotency_key, 'POST:/api/v1/stock/scrap-disposal', p_request_hash, v_actor_id);
    IF v_idem->>'action' = 'REPLAY' THEN RETURN v_idem->'body';
    ELSIF v_idem->>'action' = 'EXPIRED' THEN RAISE EXCEPTION 'IDEMPOTENCY_RESPONSE_EXPIRED: %', v_idem USING ERRCODE = '23514'; END IF;

    v_tx := public.fn_post_stock_transaction(
        p_idempotency_key => p_idempotency_key,
        p_transaction_sequence => 1,
        p_material_id => p_material_id,
        p_movement_type => 'SCRAP_DISPOSAL',
        p_source_location_id => p_source_location_id,
        p_destination_location_id => NULL,
        p_worker_id => NULL,
        p_quantity => p_quantity,
        p_unit_id => p_unit_id,
        p_entered_quantity => p_quantity,
        p_entered_unit_id => p_unit_id,
        p_measurement_method => 'INSPECTION_AUDIT',
        p_movement_reason => p_reason,
        p_created_by => v_actor_id
    );

    v_response := jsonb_build_object(
        'success', true,
        'stockTransactionId', v_tx.id,
        'transactionNumber', v_tx.transaction_number,
        'movementType', v_tx.movement_type,
        'quantity', v_tx.quantity
    );

    PERFORM public.fn_complete_idempotency(p_idempotency_key, 'STOCK_TRANSACTION', v_tx.id, 200, v_response);
    RETURN v_response;
END;
$$;

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
    v_src uuid;
    v_dst uuid;
    v_abs_qty numeric;
    v_tx public.stock_transactions;
    v_idem jsonb;
    v_response jsonb;
BEGIN
    IF v_role IS DISTINCT FROM 'ADMIN' THEN
        RAISE EXCEPTION 'Unauthorized: Only administrators can sign off stock adjustments.' USING ERRCODE = '42501';
    END IF;

    IF p_counted_quantity < 0 THEN
        RAISE EXCEPTION 'Counted quantity cannot be negative.' USING ERRCODE = '23514';
    END IF;

    IF p_reason IS NULL OR trim(p_reason) = '' THEN
        RAISE EXCEPTION 'An adjustment reason is mandatory.' USING ERRCODE = '22023';
    END IF;

    p_request_hash := public.fn_hash_request('POST:/api/v1/stock/adjustments', jsonb_build_object('adjustment_number', p_adjustment_number, 'material_id', p_material_id, 'location_id', p_location_id, 'counted_quantity', p_counted_quantity, 'reason', p_reason));
    v_idem := public.fn_acquire_idempotency(p_idempotency_key, 'POST:/api/v1/stock/adjustments', p_request_hash, v_actor_id);
    IF v_idem->>'action' = 'REPLAY' THEN RETURN v_idem->'body';
    ELSIF v_idem->>'action' = 'EXPIRED' THEN RAISE EXCEPTION 'IDEMPOTENCY_RESPONSE_EXPIRED: %', v_idem USING ERRCODE = '23514'; END IF;

    SELECT * INTO v_mat FROM public.materials WHERE id = p_material_id;

    -- Fetch current book quantity locked
    SELECT coalesce(on_hand_quantity, 0) INTO v_book
    FROM public.material_location_balances
    WHERE material_id = p_material_id AND location_id = p_location_id
    FOR UPDATE;

    v_diff := p_counted_quantity - coalesce(v_book, 0);
    IF v_diff = 0 THEN
        RAISE EXCEPTION 'No adjustment needed: counted quantity equals book quantity.' USING ERRCODE = '23514';
    END IF;

    -- Insert formal stock adjustment record
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

    PERFORM public.fn_complete_idempotency(p_idempotency_key, 'STOCK_ADJUSTMENT', v_adj_id, 201, v_response);
    RETURN v_response;
END;
$$;

DROP FUNCTION IF EXISTS public.rpc_release_packing_job(uuid);
DROP FUNCTION IF EXISTS public.rpc_revise_packing_job(uuid,integer,text);
DROP FUNCTION IF EXISTS public.rpc_cancel_packing_job(uuid,text);

CREATE OR REPLACE FUNCTION public.rpc_release_packing_job(p_packing_job_id uuid,p_idempotency_key text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_actor_id uuid := auth.uid();
    v_role text := public.get_current_user_role();
    v_job public.packing_jobs;
    v_bom public.boms;
    v_line record;
    v_snap_id uuid := gen_random_uuid();
    v_idem jsonb;
    v_request_hash text;
    v_response jsonb;
    v_mat record;
    v_bom_conv record;
    v_canonical_qty numeric;
    v_conv_factor numeric;
    v_conv_direction text;
    v_conv_type text;
    v_conv_rule_id uuid;
BEGIN
    IF v_role IS DISTINCT FROM 'ADMIN' AND v_role IS DISTINCT FROM 'PLANNER' THEN
        RAISE EXCEPTION 'Unauthorized: Only planners and admins can release packing jobs.' USING ERRCODE = '42501';
    END IF;
    IF v_actor_id IS NULL THEN RAISE EXCEPTION 'Authentication is required.' USING ERRCODE='28000'; END IF;
    v_request_hash:=public.fn_hash_request('POST:/api/v1/packing-jobs/release',jsonb_build_object('packing_job_id',p_packing_job_id));
    v_idem:=public.fn_acquire_idempotency(p_idempotency_key,'POST:/api/v1/packing-jobs/release',v_request_hash,v_actor_id);
    IF v_idem->>'action'='REPLAY' THEN RETURN v_idem->'body';
    ELSIF v_idem->>'action'='EXPIRED' THEN RAISE EXCEPTION 'IDEMPOTENCY_RESPONSE_EXPIRED: %',v_idem USING ERRCODE='23514'; END IF;

    SELECT * INTO v_job FROM public.packing_jobs WHERE id = p_packing_job_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Packing job % not found.',p_packing_job_id USING ERRCODE='P0002'; END IF;
    IF v_job.status != 'DRAFT' THEN
        RAISE EXCEPTION 'Job % cannot be released because status is %.', p_packing_job_id, v_job.status USING ERRCODE = '23514';
    END IF;

    -- If job has master BOM, freeze snapshot from master BOM
    IF v_job.master_bom_id IS NOT NULL THEN
        SELECT * INTO v_bom FROM public.boms WHERE id = v_job.master_bom_id;

        INSERT INTO public.packing_job_bom_snapshots (
            id, packing_job_id, source_bom_id, bom_version, is_customized, frozen_by
        ) VALUES (
            v_snap_id, p_packing_job_id, v_bom.id, v_bom.version_number, false, v_actor_id
        );

        FOR v_line IN SELECT * FROM public.bom_lines WHERE bom_id = v_bom.id LOOP
            SELECT canonical_unit_id INTO v_mat FROM public.materials WHERE id=v_line.material_id AND is_active=true;
            IF NOT FOUND THEN RAISE EXCEPTION 'BOM material % is missing or inactive.',v_line.material_id USING ERRCODE='23503'; END IF;
            v_conv_rule_id := NULL;
            IF v_line.unit_id=v_mat.canonical_unit_id THEN
                v_canonical_qty:=v_line.quantity_per_unit; v_conv_factor:=1; v_conv_direction:='NONE'; v_conv_type:='EXACT';
            ELSE
                SELECT * INTO v_bom_conv FROM public.material_conversions
                WHERE material_id=v_line.material_id AND from_unit_id=v_line.unit_id AND to_unit_id=v_mat.canonical_unit_id
                  AND effective_from<=clock_timestamp() AND (effective_to IS NULL OR effective_to>clock_timestamp())
                ORDER BY effective_from DESC LIMIT 1;
                IF FOUND THEN
                    v_canonical_qty:=v_line.quantity_per_unit*v_bom_conv.conversion_factor;
                    v_conv_factor:=v_bom_conv.conversion_factor; v_conv_direction:='MULTIPLY';
                    v_conv_type:=CASE WHEN v_bom_conv.is_exact THEN 'EXACT' ELSE 'ESTIMATED' END; v_conv_rule_id:=v_bom_conv.id;
                ELSE
                    SELECT * INTO v_bom_conv FROM public.material_conversions
                    WHERE material_id=v_line.material_id AND from_unit_id=v_mat.canonical_unit_id AND to_unit_id=v_line.unit_id
                      AND effective_from<=clock_timestamp() AND (effective_to IS NULL OR effective_to>clock_timestamp())
                    ORDER BY effective_from DESC LIMIT 1;
                    IF NOT FOUND THEN
                        RAISE EXCEPTION 'No active BOM conversion for material % from unit % to canonical unit %.',v_line.material_id,v_line.unit_id,v_mat.canonical_unit_id USING ERRCODE='23514';
                    END IF;
                    v_canonical_qty:=v_line.quantity_per_unit/v_bom_conv.conversion_factor;
                    v_conv_factor:=v_bom_conv.conversion_factor; v_conv_direction:='DIVIDE';
                    v_conv_type:=CASE WHEN v_bom_conv.is_exact THEN 'EXACT' ELSE 'ESTIMATED' END; v_conv_rule_id:=v_bom_conv.id;
                END IF;
            END IF;
            INSERT INTO public.packing_job_bom_snapshot_lines (
                snapshot_id,material_id,quantity_per_unit,unit_id,canonical_qty_per_unit,canonical_unit_id,
                conversion_rule_id,conversion_factor_frozen,conversion_direction,conversion_type,is_optional,notes
            ) VALUES (
                v_snap_id,v_line.material_id,v_line.quantity_per_unit,v_line.unit_id,v_canonical_qty,v_mat.canonical_unit_id,
                v_conv_rule_id,v_conv_factor,v_conv_direction,v_conv_type,v_line.is_optional,v_line.notes
            );
        END LOOP;
    ELSE
        -- Customized job: must already have a valid customized snapshot created
        IF NOT EXISTS (SELECT 1 FROM public.packing_job_bom_snapshots WHERE packing_job_id = p_packing_job_id AND is_customized = true) THEN
            RAISE EXCEPTION 'Custom job must have a complete snapshot before release.' USING ERRCODE = '23514';
        END IF;
    END IF;

    -- Update job status to RELEASED
    UPDATE public.packing_jobs
    SET status = 'RELEASED',
        updated_at = clock_timestamp()
    WHERE id = p_packing_job_id;

    v_response:=jsonb_build_object('success',true,'jobId',p_packing_job_id,'status','RELEASED');
    PERFORM public.fn_complete_idempotency(p_idempotency_key,'PACKING_JOB',p_packing_job_id,200,v_response);
    RETURN v_response;
END;
$$;

CREATE OR REPLACE FUNCTION public.rpc_revise_packing_job(
    p_packing_job_id uuid,
    p_revised_quantity integer,
    p_reason text,
    p_idempotency_key text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_actor_id uuid := auth.uid();
    v_role text := public.get_current_user_role();
    v_job public.packing_jobs;
    v_diff integer;
    v_rev_num integer;
    v_idem jsonb;
    v_request_hash text;
    v_response jsonb;
BEGIN
    IF v_role IS DISTINCT FROM 'ADMIN' AND v_role IS DISTINCT FROM 'PLANNER' THEN
        RAISE EXCEPTION 'Unauthorized: Only planners and admins can revise job quantities.' USING ERRCODE = '42501';
    END IF;
    IF v_actor_id IS NULL THEN RAISE EXCEPTION 'Authentication is required.' USING ERRCODE='28000'; END IF;
    IF p_revised_quantity IS NULL OR p_revised_quantity<=0 THEN RAISE EXCEPTION 'Revised quantity must be positive.' USING ERRCODE='22023'; END IF;
    v_request_hash:=public.fn_hash_request('POST:/api/v1/packing-jobs/revise',jsonb_build_object('packing_job_id',p_packing_job_id,'revised_quantity',p_revised_quantity,'reason',p_reason));
    v_idem:=public.fn_acquire_idempotency(p_idempotency_key,'POST:/api/v1/packing-jobs/revise',v_request_hash,v_actor_id);
    IF v_idem->>'action'='REPLAY' THEN RETURN v_idem->'body';
    ELSIF v_idem->>'action'='EXPIRED' THEN RAISE EXCEPTION 'IDEMPOTENCY_RESPONSE_EXPIRED: %',v_idem USING ERRCODE='23514'; END IF;

    IF p_reason IS NULL OR trim(p_reason) = '' THEN
        RAISE EXCEPTION 'A revision reason is mandatory.' USING ERRCODE = '22023';
    END IF;

    SELECT * INTO v_job FROM public.packing_jobs WHERE id = p_packing_job_id FOR UPDATE;

    IF NOT FOUND THEN RAISE EXCEPTION 'Packing job % not found.',p_packing_job_id USING ERRCODE='P0002'; END IF;
    IF v_job.status IN ('COMPLETED','CANCELLED') THEN RAISE EXCEPTION 'Completed/cancelled jobs cannot be revised.' USING ERRCODE='23514'; END IF;
    IF p_revised_quantity < (v_job.completed_quantity + v_job.cancelled_quantity) THEN
        RAISE EXCEPTION 'Cannot revise job quantity to %: below completed quantity %.',
            p_revised_quantity, v_job.completed_quantity USING ERRCODE = '23514';
    END IF;

    v_diff := p_revised_quantity - v_job.current_revised_quantity;
    SELECT coalesce(max(revision_number), 0) + 1 INTO v_rev_num
    FROM public.packing_job_revisions WHERE packing_job_id = p_packing_job_id;

    INSERT INTO public.packing_job_revisions (
        packing_job_id, revision_number, original_quantity, revised_quantity,
        quantity_difference, reason, revised_by, created_at
    ) VALUES (
        p_packing_job_id, v_rev_num, v_job.current_revised_quantity, p_revised_quantity,
        v_diff, p_reason, v_actor_id, clock_timestamp()
    );

    UPDATE public.packing_jobs
    SET current_revised_quantity = p_revised_quantity,
        pending_quantity = p_revised_quantity - completed_quantity - cancelled_quantity,
        updated_at = clock_timestamp()
    WHERE id = p_packing_job_id;

    v_response:=jsonb_build_object('success',true,'jobId',p_packing_job_id,'revisedQuantity',p_revised_quantity,'revisionNumber',v_rev_num);
    PERFORM public.fn_complete_idempotency(p_idempotency_key,'PACKING_JOB',p_packing_job_id,200,v_response);
    RETURN v_response;
END;
$$;

CREATE OR REPLACE FUNCTION public.rpc_cancel_packing_job(
    p_packing_job_id uuid,
    p_reason text,
    p_idempotency_key text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_actor_id uuid := auth.uid();
    v_role text := public.get_current_user_role();
    v_job public.packing_jobs;
    v_canc integer;
    v_idem jsonb;
    v_request_hash text;
    v_response jsonb;
BEGIN
    IF v_role IS DISTINCT FROM 'ADMIN' AND v_role IS DISTINCT FROM 'PLANNER' THEN
        RAISE EXCEPTION 'Unauthorized: Only planners and admins can cancel jobs.' USING ERRCODE = '42501';
    END IF;
    IF v_actor_id IS NULL THEN RAISE EXCEPTION 'Authentication is required.' USING ERRCODE='28000'; END IF;
    v_request_hash:=public.fn_hash_request('POST:/api/v1/packing-jobs/cancel',jsonb_build_object('packing_job_id',p_packing_job_id,'reason',p_reason));
    v_idem:=public.fn_acquire_idempotency(p_idempotency_key,'POST:/api/v1/packing-jobs/cancel',v_request_hash,v_actor_id);
    IF v_idem->>'action'='REPLAY' THEN RETURN v_idem->'body';
    ELSIF v_idem->>'action'='EXPIRED' THEN RAISE EXCEPTION 'IDEMPOTENCY_RESPONSE_EXPIRED: %',v_idem USING ERRCODE='23514'; END IF;

    IF p_reason IS NULL OR trim(p_reason) = '' THEN
        RAISE EXCEPTION 'A cancellation reason is mandatory.' USING ERRCODE = '22023';
    END IF;

    SELECT * INTO v_job FROM public.packing_jobs WHERE id = p_packing_job_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Packing job % not found.',p_packing_job_id USING ERRCODE='P0002'; END IF;
    IF v_job.status = 'CANCELLED' OR v_job.status = 'COMPLETED' THEN
        RAISE EXCEPTION 'Job % is already %.', p_packing_job_id, v_job.status USING ERRCODE = '23514';
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

    -- Release active reservations
    UPDATE public.stock_reservations
    SET status = 'RELEASED', updated_at = clock_timestamp()
    WHERE packing_job_id = p_packing_job_id AND status = 'ACTIVE';

    v_response:=jsonb_build_object('success',true,'jobId',p_packing_job_id,'status','CANCELLED','cancelledQuantity',v_canc,'completedPreserved',v_job.completed_quantity);
    PERFORM public.fn_complete_idempotency(p_idempotency_key,'PACKING_JOB',p_packing_job_id,200,v_response);
    RETURN v_response;
END;
$$;

REVOKE ALL ON FUNCTION public.handle_new_user() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_post_stock_transaction(text,integer,uuid,text,uuid,uuid,uuid,numeric,uuid,numeric,uuid,text,numeric,uuid,text,text,boolean,text,uuid,uuid,uuid,uuid,uuid,uuid) FROM PUBLIC, anon, authenticated;
DO $$
DECLARE v_fn regprocedure;
BEGIN
 FOR v_fn IN
  SELECT p.oid::regprocedure FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname IN ('rpc_post_goods_receipt','rpc_issue_to_worker','rpc_return_from_worker','rpc_transfer_stock','rpc_complete_production','rpc_quarantine_stock','rpc_scrap_disposal','rpc_post_stock_adjustment','rpc_release_packing_job','rpc_revise_packing_job','rpc_cancel_packing_job')
 LOOP
  EXECUTE pg_catalog.format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon',v_fn);
  EXECUTE pg_catalog.format('GRANT EXECUTE ON FUNCTION %s TO authenticated',v_fn);
 END LOOP;
END;
$$;
COMMENT ON FUNCTION public.fn_acquire_idempotency(text,text,text,uuid) IS 'Private atomic idempotency claim/replay helper; owner must match auth.uid().';
COMMENT ON FUNCTION public.fn_complete_idempotency(text,text,uuid,integer,jsonb) IS 'Private owner-bound helper for atomic idempotency response caching.';
