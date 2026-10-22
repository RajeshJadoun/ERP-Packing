-- Packing ERP operational invariant audit
-- READ ONLY: run in the Supabase SQL Editor for production or staging.
-- This query performs SELECTs only; it does not create, update, or delete records.

WITH
job_conservation AS (
  SELECT count(*)::integer AS violations
  FROM public.packing_jobs
  WHERE current_revised_quantity <> completed_quantity + pending_quantity + cancelled_quantity
),
ledger_projection AS (
  SELECT count(*)::integer AS violations
  FROM (
    SELECT
      keys.material_id,
      keys.location_id,
      coalesce(balance.on_hand_quantity, 0)::numeric AS projected_quantity,
      coalesce(ledger.on_hand_quantity, 0)::numeric AS ledger_quantity
    FROM (
      SELECT material_id, location_id
      FROM public.material_location_balances
      UNION
      SELECT material_id, source_location_id
      FROM public.stock_transactions
      WHERE source_location_id IS NOT NULL
      UNION
      SELECT material_id, destination_location_id
      FROM public.stock_transactions
      WHERE destination_location_id IS NOT NULL
    ) AS keys
    LEFT JOIN public.material_location_balances AS balance
      ON balance.material_id = keys.material_id
     AND balance.location_id = keys.location_id
    LEFT JOIN (
      SELECT material_id, location_id, sum(delta)::numeric AS on_hand_quantity
      FROM (
        SELECT material_id, destination_location_id AS location_id, quantity AS delta
        FROM public.stock_transactions
        WHERE destination_location_id IS NOT NULL
        UNION ALL
        SELECT material_id, source_location_id AS location_id, -quantity AS delta
        FROM public.stock_transactions
        WHERE source_location_id IS NOT NULL
      ) AS movements
      GROUP BY material_id, location_id
    ) AS ledger
      ON ledger.material_id = keys.material_id
     AND ledger.location_id = keys.location_id
    WHERE abs(
      coalesce(balance.on_hand_quantity, 0)::numeric
      - coalesce(ledger.on_hand_quantity, 0)::numeric
    ) > 0.00000001
  ) AS mismatches
),
consumption_status AS (
  SELECT count(*)::integer AS violations
  FROM public.material_consumption_records
  WHERE
    (variance_status = 'UNVERIFIED'
      AND (physically_confirmed_quantity IS NOT NULL OR variance_quantity IS NOT NULL))
    OR
    (variance_status = 'VERIFIED_ZERO'
      AND (physically_confirmed_quantity IS NULL OR variance_quantity IS DISTINCT FROM 0))
    OR
    (variance_status = 'VARIANCE_RECORDED'
      AND (physically_confirmed_quantity IS NULL OR variance_quantity IS NULL OR variance_quantity = 0))
),
active_bom_uniqueness AS (
  SELECT count(*)::integer AS violations
  FROM (
    SELECT product_id, party_id, packing_variant_name
    FROM public.boms
    WHERE status = 'ACTIVE'
    GROUP BY product_id, party_id, packing_variant_name
    HAVING count(*) > 1
  ) AS duplicate_variants
),
purchase_order_receipts AS (
  SELECT count(*)::integer AS violations
  FROM public.purchase_order_lines
  WHERE received_quantity > ordered_quantity
),
daily_closing_conservation AS (
  SELECT count(*)::integer AS violations
  FROM public.daily_closings
  WHERE total_planned_units <> total_completed_units + total_pending_units + total_cancelled_units
),
canonical_tables AS (
  SELECT unnest(ARRAY[
    'profiles', 'material_categories', 'parties', 'products', 'vendors',
    'units', 'materials', 'material_conversions', 'locations', 'workers',
    'boms', 'bom_lines', 'bom_revision_events', 'purchase_orders',
    'purchase_order_lines', 'goods_receipts', 'goods_receipt_lines',
    'daily_plans', 'packing_jobs', 'packing_job_bom_snapshots',
    'packing_job_bom_snapshot_lines', 'packing_job_revisions',
    'packing_job_events', 'stock_reservations', 'production_completions',
    'stock_transactions', 'material_location_balances',
    'material_consumption_records', 'stock_adjustments', 'daily_closings',
    'idempotency_keys', 'idempotency_responses', 'audit_logs'
  ]) AS table_name
),
rls_coverage AS (
  SELECT count(*)::integer AS violations
  FROM canonical_tables AS expected
  LEFT JOIN (
    SELECT c.relname, c.relrowsecurity, c.relforcerowsecurity
    FROM pg_class AS c
    JOIN pg_namespace AS n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind = 'r'
  ) AS actual ON actual.relname = expected.table_name
  WHERE actual.relname IS NULL
     OR NOT actual.relrowsecurity
     OR NOT actual.relforcerowsecurity
),
results AS (
  SELECT 'active_bom_uniqueness'::text AS check_name, violations FROM active_bom_uniqueness
  UNION ALL SELECT 'consumption_variance_state_consistency', violations FROM consumption_status
  UNION ALL SELECT 'daily_closing_quantity_conservation', violations FROM daily_closing_conservation
  UNION ALL SELECT 'packing_job_quantity_conservation', violations FROM job_conservation
  UNION ALL SELECT 'purchase_order_over_receipt', violations FROM purchase_order_receipts
  UNION ALL SELECT 'rls_enabled_and_forced_on_33_tables', violations FROM rls_coverage
  UNION ALL SELECT 'stock_ledger_vs_balance_projection', violations FROM ledger_projection
)
SELECT
  check_name,
  violations,
  CASE WHEN violations = 0 THEN 'PASS' ELSE 'INVESTIGATE' END AS status
FROM results
ORDER BY check_name;
