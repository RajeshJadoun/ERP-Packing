-- =============================================================================
-- Migration 000007: Transactional Routines, Balance Synchronization, and Invariants
-- Packing Material Inventory & BOM Management System
-- Database: Supabase PostgreSQL 15+
-- =============================================================================

-- =============================================================================
-- 1. Leaf-Only and Movement-Type Location Validation Trigger
-- =============================================================================
CREATE OR REPLACE FUNCTION public.trg_validate_stock_transaction_locations()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_src_leaf boolean;
    v_src_active boolean;
    v_src_type text;
    v_dst_leaf boolean;
    v_dst_active boolean;
    v_dst_type text;
    v_worker_loc_id uuid;
    v_mat_canonical_unit uuid;
BEGIN
    -- Verify Material exists and is active, and canonical unit matches
    SELECT canonical_unit_id INTO v_mat_canonical_unit
    FROM public.materials
    WHERE id = NEW.material_id AND is_active = true;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Material % does not exist or is inactive.', NEW.material_id
            USING ERRCODE = '23503';
    END IF;

    IF NEW.unit_id IS DISTINCT FROM v_mat_canonical_unit THEN
        RAISE EXCEPTION 'Stock movement canonical unit % does not match material canonical unit %.',
            NEW.unit_id, v_mat_canonical_unit
            USING ERRCODE = '23514';
    END IF;

    -- Validate Source Location if present
    IF NEW.source_location_id IS NOT NULL THEN
        SELECT is_leaf, is_active, location_type 
        INTO v_src_leaf, v_src_active, v_src_type
        FROM public.locations
        WHERE id = NEW.source_location_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Source location % does not exist.', NEW.source_location_id
                USING ERRCODE = '23503';
        END IF;

        IF NOT v_src_active THEN
            RAISE EXCEPTION 'Source location % is inactive.', NEW.source_location_id
                USING ERRCODE = '23514';
        END IF;

        IF NOT v_src_leaf THEN
            RAISE EXCEPTION 'Source location % is an organizational parent node; transactions must target active leaf locations.', NEW.source_location_id
                USING ERRCODE = '23514';
        END IF;
    END IF;

    -- Validate Destination Location if present
    IF NEW.destination_location_id IS NOT NULL THEN
        SELECT is_leaf, is_active, location_type 
        INTO v_dst_leaf, v_dst_active, v_dst_type
        FROM public.locations
        WHERE id = NEW.destination_location_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Destination location % does not exist.', NEW.destination_location_id
                USING ERRCODE = '23503';
        END IF;

        IF NOT v_dst_active THEN
            RAISE EXCEPTION 'Destination location % is inactive.', NEW.destination_location_id
                USING ERRCODE = '23514';
        END IF;

        IF NOT v_dst_leaf THEN
            RAISE EXCEPTION 'Destination location % is an organizational parent node; transactions must target active leaf locations.', NEW.destination_location_id
                USING ERRCODE = '23514';
        END IF;
    END IF;

    -- Validate Worker Location mapping if worker is involved
    IF NEW.worker_id IS NOT NULL THEN
        SELECT assigned_location_id INTO v_worker_loc_id
        FROM public.workers
        WHERE id = NEW.worker_id AND is_active = true;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Worker % does not exist or is inactive.', NEW.worker_id
                USING ERRCODE = '23503';
        END IF;
    END IF;

    -- Movement-Type Specific Direction & Location Type Invariants (Section 4.3 & Phase 2.1 hardening)
    CASE NEW.movement_type
        WHEN 'PURCHASE_RECEIPT' THEN
            IF NEW.source_location_id IS NOT NULL THEN
                RAISE EXCEPTION 'PURCHASE_RECEIPT source location must be NULL.' USING ERRCODE = '23514';
            END IF;
            IF NEW.destination_location_id IS NULL OR v_dst_type NOT IN ('RECEIVING_BAY', 'STORE_SHELF') THEN
                RAISE EXCEPTION 'PURCHASE_RECEIPT destination must be an active leaf of type RECEIVING_BAY or STORE_SHELF.' USING ERRCODE = '23514';
            END IF;
            IF NEW.goods_receipt_id IS NULL OR NEW.goods_receipt_line_id IS NULL THEN
                RAISE EXCEPTION 'PURCHASE_RECEIPT requires both goods_receipt_id and goods_receipt_line_id.' USING ERRCODE = '23514';
            END IF;

        WHEN 'PURCHASE_RETURN' THEN
            IF NEW.destination_location_id IS NOT NULL THEN
                RAISE EXCEPTION 'PURCHASE_RETURN destination location must be NULL.' USING ERRCODE = '23514';
            END IF;
            IF NEW.source_location_id IS NULL OR v_src_type NOT IN ('RECEIVING_BAY', 'STORE_SHELF') THEN
                RAISE EXCEPTION 'PURCHASE_RETURN source must be an active leaf of type RECEIVING_BAY or STORE_SHELF.' USING ERRCODE = '23514';
            END IF;

        WHEN 'ISSUE_TO_WORKER' THEN
            IF NEW.source_location_id IS NULL OR v_src_type NOT IN ('STORE_SHELF', 'SHOP_FLOOR_BUFFER') THEN
                RAISE EXCEPTION 'ISSUE_TO_WORKER source must be STORE_SHELF or SHOP_FLOOR_BUFFER.' USING ERRCODE = '23514';
            END IF;
            IF NEW.destination_location_id IS NULL OR NEW.destination_location_id != v_worker_loc_id THEN
                RAISE EXCEPTION 'ISSUE_TO_WORKER destination must match the assigned custody location of worker %.', NEW.worker_id USING ERRCODE = '23514';
            END IF;

        WHEN 'RETURN_FROM_WORKER' THEN
            IF NEW.source_location_id IS NULL OR NEW.source_location_id != v_worker_loc_id THEN
                RAISE EXCEPTION 'RETURN_FROM_WORKER source must match the assigned custody location of worker %.', NEW.worker_id USING ERRCODE = '23514';
            END IF;
            IF NEW.destination_location_id IS NULL OR v_dst_type NOT IN ('STORE_SHELF', 'SHOP_FLOOR_BUFFER') THEN
                RAISE EXCEPTION 'RETURN_FROM_WORKER destination must be STORE_SHELF or SHOP_FLOOR_BUFFER.' USING ERRCODE = '23514';
            END IF;

        WHEN 'CONSUMPTION' THEN
            IF NEW.source_location_id IS NULL OR NEW.source_location_id != v_worker_loc_id THEN
                RAISE EXCEPTION 'CONSUMPTION source must match the worker custody location of worker %.', NEW.worker_id USING ERRCODE = '23514';
            END IF;
            IF NEW.destination_location_id IS NOT NULL THEN
                RAISE EXCEPTION 'CONSUMPTION destination must be strictly NULL.' USING ERRCODE = '23514';
            END IF;

        WHEN 'LOCATION_TRANSFER' THEN
            IF NEW.source_location_id IS NULL OR NEW.destination_location_id IS NULL THEN
                RAISE EXCEPTION 'LOCATION_TRANSFER requires both source and destination locations.' USING ERRCODE = '23514';
            END IF;
            IF v_src_type NOT IN ('STORE_SHELF', 'SHOP_FLOOR_BUFFER', 'RECEIVING_BAY', 'DISPATCH') OR
               v_dst_type NOT IN ('STORE_SHELF', 'SHOP_FLOOR_BUFFER', 'RECEIVING_BAY', 'DISPATCH') THEN
                RAISE EXCEPTION 'LOCATION_TRANSFER locations must be STORE_SHELF, SHOP_FLOOR_BUFFER, RECEIVING_BAY, or DISPATCH.' USING ERRCODE = '23514';
            END IF;

        WHEN 'DAMAGE_QUARANTINE' THEN
            -- HARDENED: source location must NEVER be null (cannot create inventory in quarantine)
            IF NEW.source_location_id IS NULL THEN
                RAISE EXCEPTION 'DAMAGE_QUARANTINE requires a valid source inventory location.' USING ERRCODE = '23514';
            END IF;
            IF NEW.destination_location_id IS NULL OR v_dst_type != 'DAMAGE_QUARANTINE' THEN
                RAISE EXCEPTION 'DAMAGE_QUARANTINE destination must be a DAMAGE_QUARANTINE leaf node.' USING ERRCODE = '23514';
            END IF;
            IF NEW.worker_id IS NOT NULL THEN
                IF NEW.source_location_id != v_worker_loc_id THEN
                    RAISE EXCEPTION 'DAMAGE_QUARANTINE from worker must originate from worker custody location.' USING ERRCODE = '23514';
                END IF;
            ELSE
                IF v_src_type NOT IN ('STORE_SHELF', 'SHOP_FLOOR_BUFFER', 'RECEIVING_BAY') THEN
                    RAISE EXCEPTION 'DAMAGE_QUARANTINE store origin must be STORE_SHELF, SHOP_FLOOR_BUFFER, or RECEIVING_BAY.' USING ERRCODE = '23514';
                END IF;
            END IF;

        WHEN 'SCRAP_DISPOSAL' THEN
            -- HARDENED: scrap disposal must strictly remove stock from quarantine
            IF NEW.source_location_id IS NULL OR v_src_type != 'DAMAGE_QUARANTINE' THEN
                RAISE EXCEPTION 'SCRAP_DISPOSAL source must be a DAMAGE_QUARANTINE leaf location.' USING ERRCODE = '23514';
            END IF;
            IF NEW.destination_location_id IS NOT NULL THEN
                RAISE EXCEPTION 'SCRAP_DISPOSAL destination must be strictly NULL.' USING ERRCODE = '23514';
            END IF;

        WHEN 'STOCK_ADJUSTMENT' THEN
            IF NEW.source_location_id IS NULL AND NEW.destination_location_id IS NULL THEN
                RAISE EXCEPTION 'STOCK_ADJUSTMENT requires either a source (shrink) or destination (gain) location.' USING ERRCODE = '23514';
            END IF;
            IF NEW.source_location_id IS NOT NULL AND NEW.destination_location_id IS NOT NULL THEN
                RAISE EXCEPTION 'STOCK_ADJUSTMENT cannot have both source and destination locations.' USING ERRCODE = '23514';
            END IF;
    END CASE;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_stock_transaction_locations_before_insert ON public.stock_transactions;
CREATE TRIGGER trg_validate_stock_transaction_locations_before_insert
BEFORE INSERT ON public.stock_transactions
FOR EACH ROW
EXECUTE FUNCTION public.trg_validate_stock_transaction_locations();

-- =============================================================================
-- 2. Synchronous Read-Model Projection Trigger: fn_sync_material_location_balance
-- =============================================================================
CREATE OR REPLACE FUNCTION public.fn_sync_material_location_balance()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    -- 1. Deduct from Source Location if present
    IF NEW.source_location_id IS NOT NULL THEN
        UPDATE public.material_location_balances
        SET on_hand_quantity = on_hand_quantity - NEW.quantity,
            updated_at = clock_timestamp()
        WHERE material_id = NEW.material_id 
          AND location_id = NEW.source_location_id;

        IF NOT FOUND THEN
            -- Row did not exist at all, meaning 0 stock
            RAISE EXCEPTION 'Insufficient stock: Location % holds 0 of material %.', 
                NEW.source_location_id, NEW.material_id
                USING ERRCODE = '23514';
        END IF;
    END IF;

    -- 2. Add to Destination Location if present
    IF NEW.destination_location_id IS NOT NULL THEN
        INSERT INTO public.material_location_balances (
            material_id,
            location_id,
            on_hand_quantity,
            updated_at
        ) VALUES (
            NEW.material_id,
            NEW.destination_location_id,
            NEW.quantity,
            clock_timestamp()
        )
        ON CONFLICT (material_id, location_id)
        DO UPDATE SET
            on_hand_quantity = public.material_location_balances.on_hand_quantity + EXCLUDED.on_hand_quantity,
            updated_at = clock_timestamp();
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_material_location_balance_after_insert ON public.stock_transactions;
CREATE TRIGGER trg_sync_material_location_balance_after_insert
AFTER INSERT ON public.stock_transactions
FOR EACH ROW
EXECUTE FUNCTION public.fn_sync_material_location_balance();

-- =============================================================================
-- 3. Internal Idempotency Helpers (Private, Server/RPC Trust Boundary)
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
    v_cached public.idempotency_responses;
BEGIN
    -- Validate key format
    IF p_key IS NULL OR p_key !~ '^[A-Za-z0-9_\-\.:]{16,128}$' THEN
        RAISE EXCEPTION 'Invalid idempotency key format: %', p_key USING ERRCODE = '22023';
    END IF;

    -- Lock existing key header if present
    SELECT * INTO v_existing
    FROM public.idempotency_keys
    WHERE idempotency_key = p_key
    FOR UPDATE;

    IF FOUND THEN
        -- Verify key ownership, scope, and request hash
        IF v_existing.owner_id != p_owner_id OR 
           v_existing.operation_scope != p_scope OR 
           v_existing.request_hash != p_hash THEN
            -- Generic 409 Conflict: Never disclose existing payload or owner details
            RAISE EXCEPTION 'IDEMPOTENCY_KEY_REUSED: The provided idempotency key has already been used for a conflicting request.'
                USING ERRCODE = '23505';
        END IF;

        IF v_existing.status = 'COMPLETED' THEN
            -- Check Tier 2 ephemeral response cache
            SELECT * INTO v_cached
            FROM public.idempotency_responses
            WHERE idempotency_key = p_key;

            IF FOUND AND v_cached.expires_at > clock_timestamp() THEN
                RETURN jsonb_build_object(
                    'action', 'REPLAY',
                    'status_code', v_cached.response_status_code,
                    'body', v_cached.response_body
                );
            ELSE
                -- HTTP 410 Gone: Cache has expired, return resource reference for direct recovery
                RETURN jsonb_build_object(
                    'action', 'EXPIRED',
                    'resource_type', v_existing.resource_type,
                    'resource_id', v_existing.resource_id,
                    'operation_completed_at', v_existing.operation_completed_at
                );
            END IF;
        ELSE
            -- Concurrency collision: Another request is currently executing with key
            RAISE EXCEPTION 'IDEMPOTENCY_IN_PROGRESS: An identical operation is currently being processed.'
                USING ERRCODE = '55P03';
        END IF;
    ELSE
        -- Insert new processing header
        INSERT INTO public.idempotency_keys (
            idempotency_key, owner_id, operation_scope, request_hash, status
        ) VALUES (
            p_key, p_owner_id, p_scope, p_hash, 'PROCESSING'
        );

        RETURN jsonb_build_object('action', 'PROCEED');
    END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.fn_acquire_idempotency FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.fn_complete_idempotency(
    p_key text,
    p_resource_type text,
    p_resource_id uuid,
    p_status_code integer,
    p_body jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    UPDATE public.idempotency_keys
    SET status = 'COMPLETED',
        resource_type = p_resource_type,
        resource_id = p_resource_id,
        operation_completed_at = clock_timestamp()
    WHERE idempotency_key = p_key;

    INSERT INTO public.idempotency_responses (
        idempotency_key,
        response_status_code,
        response_body
    ) VALUES (
        p_key,
        p_status_code,
        p_body
    )
    ON CONFLICT (idempotency_key) DO UPDATE
    SET response_status_code = EXCLUDED.response_status_code,
        response_body = EXCLUDED.response_body;
END;
$$;

REVOKE ALL ON FUNCTION public.fn_complete_idempotency FROM PUBLIC, anon, authenticated;

-- =============================================================================
-- 4. Stored Transaction Primitive: fn_post_stock_transaction (PRIVATE)
-- =============================================================================
-- SECURITY HARDENING: Revoke all execute from PUBLIC, anon, and authenticated.
-- Only accessible internally by postgres or authorized RPC functions!
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
    -- 1. Validate quantity is strictly positive
    IF p_quantity <= 0 THEN
        RAISE EXCEPTION 'Stock movement canonical quantity must be strictly positive.'
            USING ERRCODE = '23514';
    END IF;

    -- 2. Deterministic Row Locking on material_location_balances to prevent concurrency anomalies
    IF p_source_location_id IS NOT NULL AND p_destination_location_id IS NOT NULL THEN
        IF p_source_location_id < p_destination_location_id THEN
            SELECT on_hand_quantity INTO v_source_lock FROM public.material_location_balances
            WHERE material_id = p_material_id AND location_id = p_source_location_id FOR UPDATE;
            SELECT on_hand_quantity INTO v_dest_lock FROM public.material_location_balances
            WHERE material_id = p_material_id AND location_id = p_destination_location_id FOR UPDATE;
        ELSE
            SELECT on_hand_quantity INTO v_dest_lock FROM public.material_location_balances
            WHERE material_id = p_material_id AND location_id = p_destination_location_id FOR UPDATE;
            SELECT on_hand_quantity INTO v_source_lock FROM public.material_location_balances
            WHERE material_id = p_material_id AND location_id = p_source_location_id FOR UPDATE;
        END IF;
    ELSIF p_source_location_id IS NOT NULL THEN
        SELECT on_hand_quantity INTO v_source_lock FROM public.material_location_balances
        WHERE material_id = p_material_id AND location_id = p_source_location_id FOR UPDATE;
    ELSIF p_destination_location_id IS NOT NULL THEN
        SELECT on_hand_quantity INTO v_dest_lock FROM public.material_location_balances
        WHERE material_id = p_material_id AND location_id = p_destination_location_id FOR UPDATE;
    END IF;

    -- Verify source has sufficient balance while locked
    IF p_source_location_id IS NOT NULL THEN
        IF coalesce(v_source_lock, 0) < p_quantity THEN
            RAISE EXCEPTION 'Insufficient stock: Available % is less than required %.',
                coalesce(v_source_lock, 0), p_quantity
                USING ERRCODE = '23514';
        END IF;
    END IF;

    -- 3. Generate authoritative unique transaction number
    v_tx_number := 'TXN-' || to_char(clock_timestamp(), 'YYYYMMDD-HH24MISS') || '-' || lpad(p_transaction_sequence::text, 3, '0') || '-' || substr(md5(random()::text), 1, 6);

    -- 4. Insert into authoritative ledger
    INSERT INTO public.stock_transactions (
        transaction_number,
        idempotency_key,
        transaction_sequence,
        material_id,
        movement_type,
        source_location_id,
        destination_location_id,
        worker_id,
        quantity,
        unit_id,
        entered_quantity,
        entered_unit_id,
        measurement_method,
        conversion_factor_applied,
        conversion_rule_id,
        conversion_direction,
        conversion_type_used,
        is_estimated,
        movement_reason,
        goods_receipt_id,
        goods_receipt_line_id,
        packing_job_id,
        production_completion_id,
        stock_adjustment_id,
        created_by,
        created_at
    ) VALUES (
        v_tx_number,
        p_idempotency_key,
        p_transaction_sequence,
        p_material_id,
        p_movement_type,
        p_source_location_id,
        p_destination_location_id,
        p_worker_id,
        p_quantity,
        p_unit_id,
        p_entered_quantity,
        p_entered_unit_id,
        p_measurement_method,
        p_conversion_factor,
        p_conversion_rule_id,
        p_conversion_direction,
        p_conversion_type,
        p_is_estimated,
        p_movement_reason,
        p_goods_receipt_id,
        p_goods_receipt_line_id,
        p_packing_job_id,
        p_production_completion_id,
        p_stock_adjustment_id,
        coalesce(p_created_by, auth.uid()),
        clock_timestamp()
    )
    RETURNING * INTO v_inserted_tx;

    RETURN v_inserted_tx;
END;
$$;

-- STRICT ACCESS RESTRICTION: Private internal function only!
REVOKE ALL ON FUNCTION public.fn_post_stock_transaction FROM PUBLIC, anon, authenticated;

-- =============================================================================
-- 5. Secure Operation-Specific RPC: rpc_post_goods_receipt
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
    v_conv record;
    v_calc_accepted numeric;
    v_calc_canonical numeric;
    v_factor numeric;
    v_dir text;
    v_type text;
    v_is_est boolean;
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

        -- Authoritative unit conversion recalculation
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
            ELSE
                v_dir := 'MULTIPLY';
                v_calc_canonical := v_calc_accepted * v_conv.conversion_factor;
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
                p_conversion_rule_id => v_line.conversion_rule_id,
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
            UPDATE public.purchase_order_lines
            SET received_quantity = received_quantity + v_calc_accepted
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

GRANT EXECUTE ON FUNCTION public.rpc_post_goods_receipt TO authenticated;

-- =============================================================================
-- 6. Secure Operation-Specific RPC: rpc_issue_to_worker
-- =============================================================================
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

GRANT EXECUTE ON FUNCTION public.rpc_issue_to_worker TO authenticated;

-- =============================================================================
-- 7. Secure Operation-Specific RPC: rpc_return_from_worker
-- =============================================================================
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

GRANT EXECUTE ON FUNCTION public.rpc_return_from_worker TO authenticated;

-- =============================================================================
-- 8. Secure Operation-Specific RPC: rpc_transfer_stock
-- =============================================================================
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

GRANT EXECUTE ON FUNCTION public.rpc_transfer_stock TO authenticated;

-- =============================================================================
-- 9. Secure Operation-Specific RPC: rpc_complete_production
-- =============================================================================
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

GRANT EXECUTE ON FUNCTION public.rpc_complete_production TO authenticated;

-- =============================================================================
-- 10. Secure Operation-Specific RPC: rpc_quarantine_stock
-- =============================================================================
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

GRANT EXECUTE ON FUNCTION public.rpc_quarantine_stock TO authenticated;

-- =============================================================================
-- 11. Secure Operation-Specific RPC: rpc_scrap_disposal
-- =============================================================================
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

GRANT EXECUTE ON FUNCTION public.rpc_scrap_disposal TO authenticated;

-- =============================================================================
-- 12. Secure Operation-Specific RPC: rpc_post_stock_adjustment
-- =============================================================================
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

GRANT EXECUTE ON FUNCTION public.rpc_post_stock_adjustment TO authenticated;

-- =============================================================================
-- 13. Secure Job Lifecycle Procedures: Release, Revise, Cancel
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
    v_job public.packing_jobs;
    v_bom public.boms;
    v_line record;
    v_snap_id uuid := gen_random_uuid();
BEGIN
    IF v_role IS DISTINCT FROM 'ADMIN' AND v_role IS DISTINCT FROM 'PLANNER' THEN
        RAISE EXCEPTION 'Unauthorized: Only planners and admins can release packing jobs.' USING ERRCODE = '42501';
    END IF;

    SELECT * INTO v_job FROM public.packing_jobs WHERE id = p_packing_job_id FOR UPDATE;
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
            INSERT INTO public.packing_job_bom_snapshot_lines (
                snapshot_id, material_id, quantity_per_unit, unit_id, canonical_qty_per_unit,
                canonical_unit_id, conversion_factor_frozen, is_optional
            ) VALUES (
                v_snap_id, v_line.material_id, v_line.quantity_per_unit, v_line.unit_id,
                v_line.quantity_per_unit, v_line.unit_id, 1.0, v_line.is_optional
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

    RETURN jsonb_build_object('success', true, 'jobId', p_packing_job_id, 'status', 'RELEASED');
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_release_packing_job TO authenticated;

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
    v_job public.packing_jobs;
    v_diff integer;
    v_rev_num integer;
BEGIN
    IF v_role IS DISTINCT FROM 'ADMIN' AND v_role IS DISTINCT FROM 'PLANNER' THEN
        RAISE EXCEPTION 'Unauthorized: Only planners and admins can revise job quantities.' USING ERRCODE = '42501';
    END IF;

    IF p_reason IS NULL OR trim(p_reason) = '' THEN
        RAISE EXCEPTION 'A revision reason is mandatory.' USING ERRCODE = '22023';
    END IF;

    SELECT * INTO v_job FROM public.packing_jobs WHERE id = p_packing_job_id FOR UPDATE;

    IF p_revised_quantity < v_job.completed_quantity THEN
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

    RETURN jsonb_build_object(
        'success', true,
        'jobId', p_packing_job_id,
        'revisedQuantity', p_revised_quantity,
        'revisionNumber', v_rev_num
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_revise_packing_job TO authenticated;

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
    v_job public.packing_jobs;
    v_canc integer;
BEGIN
    IF v_role IS DISTINCT FROM 'ADMIN' AND v_role IS DISTINCT FROM 'PLANNER' THEN
        RAISE EXCEPTION 'Unauthorized: Only planners and admins can cancel jobs.' USING ERRCODE = '42501';
    END IF;

    IF p_reason IS NULL OR trim(p_reason) = '' THEN
        RAISE EXCEPTION 'A cancellation reason is mandatory.' USING ERRCODE = '22023';
    END IF;

    SELECT * INTO v_job FROM public.packing_jobs WHERE id = p_packing_job_id FOR UPDATE;
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

    RETURN jsonb_build_object(
        'success', true,
        'jobId', p_packing_job_id,
        'status', 'CANCELLED',
        'cancelledQuantity', v_canc,
        'completedPreserved', v_job.completed_quantity
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_cancel_packing_job TO authenticated;
