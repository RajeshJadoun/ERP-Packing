-- Phase 9: secured operational reporting views.
-- Views use security_invoker so underlying table grants and RLS policies remain authoritative.

CREATE INDEX IF NOT EXISTS idx_reporting_production_completion_timestamp
    ON public.production_completions (completion_timestamp DESC);

CREATE INDEX IF NOT EXISTS idx_reporting_goods_receipt_received_date
    ON public.goods_receipts (received_date DESC, vendor_id);

CREATE INDEX IF NOT EXISTS idx_reporting_consumption_completion
    ON public.material_consumption_records (production_completion_id, variance_status);

CREATE INDEX IF NOT EXISTS idx_reporting_daily_plan_date_shift
    ON public.daily_plans (plan_date DESC, shift_code);

CREATE INDEX IF NOT EXISTS idx_reporting_receipt_lines_grn
    ON public.goods_receipt_lines (grn_id);

CREATE INDEX IF NOT EXISTS idx_reporting_reservations_active_material_location
    ON public.stock_reservations (material_id, location_id)
    WHERE status = 'ACTIVE';

CREATE OR REPLACE VIEW public.vw_stock_by_location
WITH (security_invoker = true)
AS
WITH reservation_totals AS (
    SELECT
        sr.material_id,
        sr.location_id,
        SUM(sr.reserved_quantity)::numeric AS reserved_quantity
    FROM public.stock_reservations AS sr
    WHERE sr.status = 'ACTIVE'
    GROUP BY sr.material_id, sr.location_id
)
SELECT
    b.material_id,
    m.material_code,
    m.name AS material_name,
    m.is_active AS material_is_active,
    m.canonical_unit_id,
    u.code AS canonical_unit_code,
    b.location_id,
    l.location_code,
    l.name AS location_name,
    l.location_type,
    l.is_active AS location_is_active,
    l.is_leaf,
    CASE
        WHEN l.location_type = 'DAMAGE_QUARANTINE' THEN 'QUARANTINE'
        WHEN l.location_type = 'WORKER_CUSTODY' THEN 'WORKER_CUSTODY'
        ELSE 'USABLE'
    END AS inventory_segment,
    b.on_hand_quantity,
    COALESCE(r.reserved_quantity, 0)::numeric AS reserved_quantity,
    CASE
        WHEN l.is_active
         AND l.location_type IN ('STORE_SHELF', 'RECEIVING_BAY', 'SHOP_FLOOR_BUFFER', 'DISPATCH')
        THEN GREATEST(b.on_hand_quantity - COALESCE(r.reserved_quantity, 0), 0)::numeric
        ELSE 0::numeric
    END AS available_quantity
FROM public.material_location_balances AS b
JOIN public.materials AS m ON m.id = b.material_id
JOIN public.units AS u ON u.id = m.canonical_unit_id
JOIN public.locations AS l ON l.id = b.location_id
LEFT JOIN reservation_totals AS r
    ON r.material_id = b.material_id AND r.location_id = b.location_id
WHERE l.is_leaf IS TRUE;

CREATE OR REPLACE VIEW public.vw_worker_custody_balance
WITH (security_invoker = true)
AS
SELECT
    w.id AS worker_id,
    w.worker_code,
    w.name AS worker_name,
    w.is_active AS worker_is_active,
    l.id AS location_id,
    l.location_code,
    b.material_id,
    m.material_code,
    m.name AS material_name,
    m.canonical_unit_id,
    u.code AS canonical_unit_code,
    b.on_hand_quantity,
    b.updated_at AS balance_updated_at
FROM public.material_location_balances AS b
JOIN public.locations AS l
    ON l.id = b.location_id
   AND l.location_type = 'WORKER_CUSTODY'
   AND l.is_leaf IS TRUE
JOIN public.workers AS w ON w.assigned_location_id = l.id
JOIN public.materials AS m ON m.id = b.material_id
JOIN public.units AS u ON u.id = m.canonical_unit_id;

CREATE OR REPLACE VIEW public.vw_material_consumption_variance
WITH (security_invoker = true)
AS
SELECT
    mc.id AS consumption_id,
    pc.id AS production_completion_id,
    pc.completion_number,
    pc.completion_timestamp,
    pc.completion_timestamp::date AS completion_date,
    pc.completed_units,
    pc.completion_policy,
    w.id AS worker_id,
    w.worker_code,
    w.name AS worker_name,
    dp.id AS plan_id,
    dp.plan_number,
    dp.plan_date,
    dp.shift_code,
    dp.status AS plan_status,
    j.id AS job_id,
    j.job_code,
    j.status AS job_status,
    j.party_id,
    party.name AS party_name,
    j.product_id,
    product.name AS product_name,
    mc.material_id,
    m.material_code,
    m.name AS material_name,
    u.code AS canonical_unit_code,
    mc.theoretical_quantity,
    mc.posted_ledger_quantity,
    mc.physically_confirmed_quantity,
    CASE
        WHEN mc.physically_confirmed_quantity IS NULL THEN NULL
        ELSE COALESCE(
            mc.variance_quantity,
            mc.physically_confirmed_quantity - mc.theoretical_quantity
        )
    END AS variance_quantity,
    mc.variance_status,
    mc.stock_transaction_id,
    mc.created_at AS consumption_created_at
FROM public.material_consumption_records AS mc
JOIN public.production_completions AS pc ON pc.id = mc.production_completion_id
JOIN public.packing_jobs AS j ON j.id = pc.packing_job_id
JOIN public.daily_plans AS dp ON dp.id = j.daily_plan_id
JOIN public.materials AS m ON m.id = mc.material_id
JOIN public.units AS u ON u.id = m.canonical_unit_id
LEFT JOIN public.workers AS w ON w.id = pc.completed_by_worker_id
LEFT JOIN public.parties AS party ON party.id = j.party_id
LEFT JOIN public.products AS product ON product.id = j.product_id;

CREATE OR REPLACE VIEW public.vw_vendor_purchase_history
WITH (security_invoker = true)
AS
WITH receipt_stats AS (
    SELECT
        gl.grn_id,
        COUNT(*)::integer AS receipt_line_count,
        COUNT(*) FILTER (WHERE COALESCE(gl.rejected_qty, 0) > 0)::integer AS rejected_line_count
    FROM public.goods_receipt_lines AS gl
    GROUP BY gl.grn_id
)
SELECT
    v.id AS vendor_id,
    v.vendor_code,
    v.name AS vendor_name,
    v.is_active AS vendor_is_active,
    gr.id AS goods_receipt_id,
    gr.grn_number,
    gr.status AS receipt_status,
    gr.invoice_number,
    gr.invoice_date,
    gr.received_date,
    gr.posted_at,
    po.id AS purchase_order_id,
    po.po_number,
    po.order_date,
    po.expected_delivery_date,
    CASE
        WHEN po.order_date IS NULL THEN NULL
        ELSE gr.received_date - po.order_date
    END AS lead_time_days,
    CASE
        WHEN po.expected_delivery_date IS NULL THEN NULL
        ELSE gr.received_date - po.expected_delivery_date
    END AS delivery_variance_days,
    COALESCE(rs.receipt_line_count, 0) AS receipt_line_count,
    COALESCE(rs.rejected_line_count, 0) AS rejected_line_count,
    CASE
        WHEN COALESCE(rs.receipt_line_count, 0) = 0 THEN 0::numeric
        ELSE ROUND(
            rs.rejected_line_count::numeric * 100 / NULLIF(rs.receipt_line_count, 0),
            2
        )
    END AS rejected_line_rate_pct
FROM public.vendors AS v
JOIN public.goods_receipts AS gr ON gr.vendor_id = v.id
LEFT JOIN public.purchase_orders AS po ON po.id = gr.po_id
LEFT JOIN receipt_stats AS rs ON rs.grn_id = gr.id;

CREATE OR REPLACE VIEW public.vw_production_shift_summary
WITH (security_invoker = true)
AS
WITH job_rollup AS (
    SELECT
        j.daily_plan_id,
        COUNT(*)::integer AS job_count,
        COALESCE(SUM(j.original_planned_quantity), 0)::bigint AS original_planned_units,
        COALESCE(SUM(j.current_revised_quantity), 0)::bigint AS authorized_units,
        COALESCE(SUM(j.completed_quantity), 0)::bigint AS completed_units,
        COALESCE(SUM(j.pending_quantity), 0)::bigint AS pending_units,
        COALESCE(SUM(j.cancelled_quantity), 0)::bigint AS cancelled_units
    FROM public.packing_jobs AS j
    GROUP BY j.daily_plan_id
),
completion_rollup AS (
    SELECT
        j.daily_plan_id,
        COUNT(pc.id)::integer AS completion_count,
        COUNT(DISTINCT pc.completed_by_worker_id)::integer AS completion_worker_count
    FROM public.packing_jobs AS j
    LEFT JOIN public.production_completions AS pc ON pc.packing_job_id = j.id
    GROUP BY j.daily_plan_id
)
SELECT
    dp.id AS plan_id,
    dp.plan_number,
    dp.plan_date,
    dp.shift_code,
    dp.status AS plan_status,
    COALESCE(jr.job_count, 0) AS job_count,
    COALESCE(jr.original_planned_units, 0) AS original_planned_units,
    COALESCE(jr.authorized_units, 0) AS authorized_units,
    COALESCE(jr.completed_units, 0) AS completed_units,
    COALESCE(jr.pending_units, 0) AS pending_units,
    COALESCE(jr.cancelled_units, 0) AS cancelled_units,
    COALESCE(cr.completion_count, 0) AS completion_count,
    COALESCE(cr.completion_worker_count, 0) AS completion_worker_count
FROM public.daily_plans AS dp
LEFT JOIN job_rollup AS jr ON jr.daily_plan_id = dp.id
LEFT JOIN completion_rollup AS cr ON cr.daily_plan_id = dp.id;

CREATE OR REPLACE VIEW public.vw_worker_production_output
WITH (security_invoker = true)
AS
SELECT
    dp.id AS plan_id,
    dp.plan_number,
    dp.plan_date,
    dp.shift_code,
    w.id AS worker_id,
    w.worker_code,
    w.name AS worker_name,
    COUNT(pc.id)::integer AS completion_count,
    COUNT(DISTINCT j.id)::integer AS completed_job_count,
    COALESCE(SUM(pc.completed_units), 0)::bigint AS completed_units
FROM public.production_completions AS pc
JOIN public.packing_jobs AS j ON j.id = pc.packing_job_id
JOIN public.daily_plans AS dp ON dp.id = j.daily_plan_id
JOIN public.workers AS w ON w.id = pc.completed_by_worker_id
GROUP BY dp.id, dp.plan_number, dp.plan_date, dp.shift_code, w.id, w.worker_code, w.name;

REVOKE ALL ON public.vw_stock_by_location FROM PUBLIC, anon;
REVOKE ALL ON public.vw_worker_custody_balance FROM PUBLIC, anon;
REVOKE ALL ON public.vw_material_consumption_variance FROM PUBLIC, anon;
REVOKE ALL ON public.vw_vendor_purchase_history FROM PUBLIC, anon;
REVOKE ALL ON public.vw_production_shift_summary FROM PUBLIC, anon;
REVOKE ALL ON public.vw_worker_production_output FROM PUBLIC, anon;

GRANT SELECT ON public.vw_stock_by_location TO authenticated;
GRANT SELECT ON public.vw_worker_custody_balance TO authenticated;
GRANT SELECT ON public.vw_material_consumption_variance TO authenticated;
GRANT SELECT ON public.vw_vendor_purchase_history TO authenticated;
GRANT SELECT ON public.vw_production_shift_summary TO authenticated;
GRANT SELECT ON public.vw_worker_production_output TO authenticated;
