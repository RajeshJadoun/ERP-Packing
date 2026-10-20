-- =============================================================================
-- Phase 4: transactional purchase-order creation and purchasing boundary hardening
-- =============================================================================
-- API contract requires unitPrice on each PO line; the foundational table was
-- missing persistence for that field. DEFAULT 0 keeps older seed/fixture inserts
-- compatible while all API-created orders provide an explicit price.
ALTER TABLE public.purchase_order_lines
    ADD COLUMN IF NOT EXISTS unit_price numeric NOT NULL DEFAULT 0
    CHECK (unit_price >= 0);

-- Purchasing mutations must go through trusted Flask RPCs. Reads stay available
-- through RLS/PostgREST. Draft receipt headers can still be staged via PostgREST,
-- but clients may not create a forged POSTED receipt directly.
REVOKE INSERT, UPDATE, DELETE ON public.purchase_orders, public.purchase_order_lines
    FROM authenticated;

DROP POLICY IF EXISTS "goods_receipts_insert_storekeeper_admin" ON public.goods_receipts;
CREATE POLICY "goods_receipts_insert_storekeeper_admin" ON public.goods_receipts
FOR INSERT TO authenticated
WITH CHECK (
    public.get_current_user_role() IN ('ADMIN', 'STOREKEEPER')
    AND status = 'DRAFT'
);

-- Atomic PO create. The permanent idempotency header, response cache, PO header,
-- and PO lines all share this same database transaction.
CREATE OR REPLACE FUNCTION public.rpc_create_purchase_order(
    p_po_number text,
    p_vendor_id uuid,
    p_order_date date,
    p_expected_delivery_date date,
    p_remarks text,
    p_lines jsonb,
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
    v_po public.purchase_orders;
    v_line jsonb;
    v_material_id uuid;
    v_unit_id uuid;
    v_canonical_unit_id uuid;
    v_order_qty numeric;
    v_unit_price numeric;
    v_lines jsonb := '[]'::jsonb;
    v_response jsonb;
    v_line_count integer := 0;
BEGIN
    IF v_actor_id IS NULL THEN
        RAISE EXCEPTION 'Valid authentication is required.'
            USING ERRCODE = '42501';
    END IF;

    IF v_role IS DISTINCT FROM 'ADMIN' AND v_role IS DISTINCT FROM 'STOREKEEPER' THEN
        RAISE EXCEPTION 'Unauthorized: Only storekeepers and administrators can create purchase orders.'
            USING ERRCODE = '42501';
    END IF;

    v_idem := public.fn_acquire_idempotency(
        p_idempotency_key,
        'POST:/api/v1/purchase-orders',
        p_request_hash,
        v_actor_id
    );

    IF v_idem->>'action' = 'REPLAY' THEN
        RETURN v_idem->'body';
    ELSIF v_idem->>'action' = 'EXPIRED' THEN
        RAISE EXCEPTION 'IDEMPOTENCY_RESPONSE_EXPIRED: %', v_idem USING ERRCODE = '23514';
    END IF;

    IF p_po_number IS NULL OR length(trim(p_po_number)) < 3 OR length(p_po_number) > 80 THEN
        RAISE EXCEPTION 'PO number must contain between 3 and 80 characters.'
            USING ERRCODE = '22023';
    END IF;

    IF p_vendor_id IS NULL OR p_order_date IS NULL OR p_expected_delivery_date IS NULL THEN
        RAISE EXCEPTION 'Vendor, order date, and expected delivery date are required.'
            USING ERRCODE = '22023';
    END IF;

    IF p_expected_delivery_date < p_order_date THEN
        RAISE EXCEPTION 'Expected delivery date cannot be earlier than the order date.'
            USING ERRCODE = '23514';
    END IF;

    IF jsonb_typeof(p_lines) IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'Purchase order lines must be a JSON array.'
            USING ERRCODE = '22023';
    END IF;
    IF jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'A purchase order must contain at least one material line.'
            USING ERRCODE = '22023';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(p_lines) AS entry(value)
        GROUP BY entry.value->>'materialId'
        HAVING count(*) > 1
    ) THEN
        RAISE EXCEPTION 'A material can appear only once on a purchase order.'
            USING ERRCODE = '23505';
    END IF;

    PERFORM 1
    FROM public.vendors
    WHERE id = p_vendor_id AND is_active = true;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Vendor does not exist or is inactive.'
            USING ERRCODE = '23503';
    END IF;

    INSERT INTO public.purchase_orders (
        po_number, vendor_id, order_date, expected_delivery_date,
        status, remarks, created_by
    ) VALUES (
        trim(p_po_number), p_vendor_id, p_order_date, p_expected_delivery_date,
        'DRAFT', nullif(trim(coalesce(p_remarks, '')), ''), v_actor_id
    )
    RETURNING * INTO v_po;

    FOR v_line IN
        SELECT entry.value FROM jsonb_array_elements(p_lines) AS entry(value)
    LOOP
        IF v_line->>'materialId' IS NULL
           OR v_line->>'orderedQuantity' IS NULL
           OR v_line->>'unitId' IS NULL
           OR v_line->>'unitPrice' IS NULL THEN
            RAISE EXCEPTION 'Each purchase order line requires materialId, orderedQuantity, unitId, and unitPrice.'
                USING ERRCODE = '22023';
        END IF;

        v_material_id := (v_line->>'materialId')::uuid;
        v_unit_id := (v_line->>'unitId')::uuid;
        v_order_qty := (v_line->>'orderedQuantity')::numeric;
        v_unit_price := (v_line->>'unitPrice')::numeric;

        IF v_order_qty <= 0 THEN
            RAISE EXCEPTION 'Ordered quantity must be greater than zero.'
                USING ERRCODE = '23514';
        END IF;
        IF v_unit_price < 0 THEN
            RAISE EXCEPTION 'Unit price cannot be negative.'
                USING ERRCODE = '23514';
        END IF;

        SELECT canonical_unit_id
        INTO v_canonical_unit_id
        FROM public.materials
        WHERE id = v_material_id AND is_active = true;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Material % does not exist or is inactive.', v_material_id
                USING ERRCODE = '23503';
        END IF;

        -- Reject a PO unit that cannot later be authoritatively normalized into
        -- the material's canonical unit during GRN posting.
        PERFORM public.fn_resolve_material_conversion(
            v_material_id,
            v_unit_id,
            v_canonical_unit_id
        );

        PERFORM 1 FROM public.units WHERE id = v_unit_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Unit % does not exist.', v_unit_id
                USING ERRCODE = '23503';
        END IF;

        INSERT INTO public.purchase_order_lines (
            po_id, material_id, ordered_quantity, unit_id, unit_price
        ) VALUES (
            v_po.id, v_material_id, v_order_qty, v_unit_id, v_unit_price
        );
        v_line_count := v_line_count + 1;
    END LOOP;

    SELECT coalesce(
        jsonb_agg(
            jsonb_build_object(
                'id', pol.id,
                'materialId', pol.material_id,
                'orderedQuantity', pol.ordered_quantity,
                'receivedQuantity', pol.received_quantity,
                'unitId', pol.unit_id,
                'unitPrice', pol.unit_price
            ) ORDER BY pol.created_at, pol.id
        ),
        '[]'::jsonb
    )
    INTO v_lines
    FROM public.purchase_order_lines pol
    WHERE pol.po_id = v_po.id;

    v_response := jsonb_build_object(
        'success', true,
        'id', v_po.id,
        'poNumber', v_po.po_number,
        'vendorId', v_po.vendor_id,
        'status', v_po.status,
        'orderDate', v_po.order_date,
        'expectedDeliveryDate', v_po.expected_delivery_date,
        'notes', v_po.remarks,
        'lines', v_lines
    );

    PERFORM public.fn_complete_idempotency(
        p_idempotency_key,
        'PURCHASE_ORDER',
        v_po.id,
        201,
        v_response
    );

    RETURN v_response;
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_create_purchase_order(text, uuid, date, date, text, jsonb, text, text)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_create_purchase_order(text, uuid, date, date, text, jsonb, text, text)
    TO authenticated;


-- GRN header readiness gate. This is intentionally a trigger-level invariant,
-- not just Flask validation: every inbound receipt (including a draft created
-- through PostgREST) must reference a real active vendor and receiving location.
CREATE OR REPLACE FUNCTION public.trg_validate_goods_receipt_header_phase4()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_vendor_active boolean;
    v_location record;
    v_po_vendor_id uuid;
BEGIN
    IF NEW.invoice_date > NEW.received_date THEN
        RAISE EXCEPTION 'Invoice date cannot be later than the goods receipt date.'
            USING ERRCODE = '23514';
    END IF;

    IF NEW.received_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'Goods receipt date cannot be in the future.'
            USING ERRCODE = '23514';
    END IF;

    SELECT is_active
    INTO v_vendor_active
    FROM public.vendors
    WHERE id = NEW.vendor_id;

    IF NOT FOUND OR v_vendor_active IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'Goods receipt vendor does not exist or is inactive.'
            USING ERRCODE = '23503';
    END IF;

    SELECT is_active, is_leaf, location_type
    INTO v_location
    FROM public.locations
    WHERE id = NEW.destination_location_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Goods receipt destination location does not exist.'
            USING ERRCODE = '23503';
    END IF;

    IF v_location.is_active IS DISTINCT FROM true
       OR v_location.is_leaf IS DISTINCT FROM true
       OR v_location.location_type NOT IN ('RECEIVING_BAY', 'STORE_SHELF') THEN
        RAISE EXCEPTION 'Goods receipt destination must be an active leaf receiving bay or store shelf.'
            USING ERRCODE = '23514';
    END IF;

    IF NEW.po_id IS NOT NULL THEN
        SELECT vendor_id
        INTO v_po_vendor_id
        FROM public.purchase_orders
        WHERE id = NEW.po_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Goods receipt purchase order does not exist.'
                USING ERRCODE = '23503';
        END IF;

        IF v_po_vendor_id IS DISTINCT FROM NEW.vendor_id THEN
            RAISE EXCEPTION 'Goods receipt vendor must match the linked purchase order vendor.'
                USING ERRCODE = '23514';
        END IF;
    END IF;

    -- Direct PostgREST writes may stage DRAFT headers, but only the authorized
    -- transactional RPC may transition a draft to POSTED.
    IF TG_OP = 'INSERT' AND NEW.status IS DISTINCT FROM 'DRAFT' THEN
        RAISE EXCEPTION 'Goods receipts must be created in DRAFT status and posted through the transactional API.'
            USING ERRCODE = '42501';
    END IF;

    IF NEW.status = 'POSTED' AND (NEW.posted_at IS NULL OR NEW.posted_by IS NULL) THEN
        RAISE EXCEPTION 'A posted goods receipt requires posted_at and posted_by.'
            USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.trg_validate_goods_receipt_header_phase4()
    FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_validate_goods_receipt_header_phase4 ON public.goods_receipts;
CREATE TRIGGER trg_validate_goods_receipt_header_phase4
BEFORE INSERT OR UPDATE ON public.goods_receipts
FOR EACH ROW
EXECUTE FUNCTION public.trg_validate_goods_receipt_header_phase4();
