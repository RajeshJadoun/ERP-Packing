-- =============================================================================
-- Migration 000009: FK Index Coverage and RLS Initplan Optimization
-- Phase 2.1.1 finishing pass
-- =============================================================================

-- Foreign-key child indexes: improve joins and avoid full scans on parent
-- deletes/updates. Every statement is idempotent for safe local replays.
CREATE INDEX IF NOT EXISTS idx_fk_bom_lines_unit_id
    ON public.bom_lines (unit_id);
CREATE INDEX IF NOT EXISTS idx_fk_bom_revision_events_changed_by
    ON public.bom_revision_events (changed_by);
CREATE INDEX IF NOT EXISTS idx_fk_bom_revision_events_previous_bom_id
    ON public.bom_revision_events (previous_bom_id);
CREATE INDEX IF NOT EXISTS idx_fk_boms_created_by
    ON public.boms (created_by);
CREATE INDEX IF NOT EXISTS idx_fk_boms_party_id
    ON public.boms (party_id);
CREATE INDEX IF NOT EXISTS idx_fk_daily_closings_closed_by
    ON public.daily_closings (closed_by);
CREATE INDEX IF NOT EXISTS idx_fk_daily_closings_plan_shift
    ON public.daily_closings (daily_plan_id, shift_code);
CREATE INDEX IF NOT EXISTS idx_fk_daily_closings_reopened_by
    ON public.daily_closings (reopened_by);
CREATE INDEX IF NOT EXISTS idx_fk_daily_plans_created_by
    ON public.daily_plans (created_by);
CREATE INDEX IF NOT EXISTS idx_fk_goods_receipt_lines_canonical_unit_id
    ON public.goods_receipt_lines (canonical_unit_id);
CREATE INDEX IF NOT EXISTS idx_fk_goods_receipt_lines_conversion_rule_id
    ON public.goods_receipt_lines (conversion_rule_id);
CREATE INDEX IF NOT EXISTS idx_fk_goods_receipt_lines_entered_unit_id
    ON public.goods_receipt_lines (entered_unit_id);
CREATE INDEX IF NOT EXISTS idx_fk_goods_receipt_lines_rejected_unit_id
    ON public.goods_receipt_lines (rejected_unit_id);
CREATE INDEX IF NOT EXISTS idx_fk_goods_receipt_lines_rejection_rule_id
    ON public.goods_receipt_lines (rejection_conversion_rule_id);
CREATE INDEX IF NOT EXISTS idx_fk_goods_receipts_destination_location_id
    ON public.goods_receipts (destination_location_id);
CREATE INDEX IF NOT EXISTS idx_fk_goods_receipts_po_id
    ON public.goods_receipts (po_id);
CREATE INDEX IF NOT EXISTS idx_fk_goods_receipts_posted_by
    ON public.goods_receipts (posted_by);
CREATE INDEX IF NOT EXISTS idx_fk_material_consumption_stock_transaction_id
    ON public.material_consumption_records (stock_transaction_id);
CREATE INDEX IF NOT EXISTS idx_fk_material_conversions_created_by
    ON public.material_conversions (created_by);
CREATE INDEX IF NOT EXISTS idx_fk_material_conversions_to_unit_id
    ON public.material_conversions (to_unit_id);
CREATE INDEX IF NOT EXISTS idx_fk_snapshot_lines_canonical_unit_id
    ON public.packing_job_bom_snapshot_lines (canonical_unit_id);
CREATE INDEX IF NOT EXISTS idx_fk_snapshot_lines_conversion_rule_id
    ON public.packing_job_bom_snapshot_lines (conversion_rule_id);
CREATE INDEX IF NOT EXISTS idx_fk_snapshot_lines_unit_id
    ON public.packing_job_bom_snapshot_lines (unit_id);
CREATE INDEX IF NOT EXISTS idx_fk_snapshot_headers_frozen_by
    ON public.packing_job_bom_snapshots (frozen_by);
CREATE INDEX IF NOT EXISTS idx_fk_snapshot_headers_source_bom_id
    ON public.packing_job_bom_snapshots (source_bom_id);
CREATE INDEX IF NOT EXISTS idx_fk_packing_job_events_triggered_by
    ON public.packing_job_events (triggered_by);
CREATE INDEX IF NOT EXISTS idx_fk_packing_job_revisions_revised_by
    ON public.packing_job_revisions (revised_by);
CREATE INDEX IF NOT EXISTS idx_fk_packing_jobs_master_bom_id
    ON public.packing_jobs (master_bom_id);
CREATE INDEX IF NOT EXISTS idx_fk_packing_jobs_party_id
    ON public.packing_jobs (party_id);
CREATE INDEX IF NOT EXISTS idx_fk_packing_jobs_product_id
    ON public.packing_jobs (product_id);
CREATE INDEX IF NOT EXISTS idx_fk_production_completions_recorded_by
    ON public.production_completions (recorded_by);
CREATE INDEX IF NOT EXISTS idx_fk_purchase_order_lines_material_id
    ON public.purchase_order_lines (material_id);
CREATE INDEX IF NOT EXISTS idx_fk_purchase_order_lines_unit_id
    ON public.purchase_order_lines (unit_id);
CREATE INDEX IF NOT EXISTS idx_fk_purchase_orders_created_by
    ON public.purchase_orders (created_by);
CREATE INDEX IF NOT EXISTS idx_fk_stock_adjustments_approved_by
    ON public.stock_adjustments (approved_by);
CREATE INDEX IF NOT EXISTS idx_fk_stock_reservations_canonical_unit_id
    ON public.stock_reservations (canonical_unit_id);
CREATE INDEX IF NOT EXISTS idx_fk_stock_reservations_location_id
    ON public.stock_reservations (location_id);
CREATE INDEX IF NOT EXISTS idx_fk_stock_transactions_conversion_rule_id
    ON public.stock_transactions (conversion_rule_id);
CREATE INDEX IF NOT EXISTS idx_fk_stock_transactions_created_by
    ON public.stock_transactions (created_by);
CREATE INDEX IF NOT EXISTS idx_fk_stock_transactions_destination_location_id
    ON public.stock_transactions (destination_location_id);
CREATE INDEX IF NOT EXISTS idx_fk_stock_transactions_entered_unit_id
    ON public.stock_transactions (entered_unit_id);
CREATE INDEX IF NOT EXISTS idx_fk_stock_transactions_production_completion_id
    ON public.stock_transactions (production_completion_id);
CREATE INDEX IF NOT EXISTS idx_fk_stock_transactions_source_location_id
    ON public.stock_transactions (source_location_id);
CREATE INDEX IF NOT EXISTS idx_fk_stock_transactions_stock_adjustment_id
    ON public.stock_transactions (stock_adjustment_id);
CREATE INDEX IF NOT EXISTS idx_fk_stock_transactions_unit_id
    ON public.stock_transactions (unit_id);
CREATE INDEX IF NOT EXISTS idx_fk_stock_transactions_worker_id
    ON public.stock_transactions (worker_id);

-- Evaluate auth.uid() once per statement instead of once per row.
DROP POLICY IF EXISTS profiles_update_self ON public.profiles;
CREATE POLICY profiles_update_self
    ON public.profiles
    FOR UPDATE
    TO authenticated
    USING ((SELECT auth.uid()) = id)
    WITH CHECK ((SELECT auth.uid()) = id);
