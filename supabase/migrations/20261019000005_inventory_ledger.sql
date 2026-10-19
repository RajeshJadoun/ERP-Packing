-- =============================================================================
-- Migration 000005: Authoritative Stock Ledger, Balance Projection, and Completions
-- Packing Material Inventory & BOM Management System
-- Database: Supabase PostgreSQL 15+
-- =============================================================================

-- 1. Table 25: production_completions (Finished Goods Completion Batches)
CREATE TABLE public.production_completions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    packing_job_id uuid NOT NULL REFERENCES public.packing_jobs(id) ON DELETE RESTRICT,
    completion_number text NOT NULL UNIQUE,
    completed_units integer NOT NULL CHECK (completed_units > 0),
    completed_by_worker_id uuid NOT NULL REFERENCES public.workers(id) ON DELETE RESTRICT,
    completion_timestamp timestamptz NOT NULL DEFAULT clock_timestamp(),
    idempotency_key text NOT NULL UNIQUE REFERENCES public.idempotency_keys(idempotency_key) ON DELETE RESTRICT,
    remarks text,
    recorded_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX idx_production_completions_job ON public.production_completions(packing_job_id);
CREATE INDEX idx_production_completions_worker ON public.production_completions(completed_by_worker_id);

-- 2. Table 29: stock_adjustments (Formal Physical Count Reconciliations)
-- Single-direction linkage: stock_transactions references stock_adjustments (no circular FK)
CREATE TABLE public.stock_adjustments (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    adjustment_number text NOT NULL UNIQUE,
    material_id uuid NOT NULL REFERENCES public.materials(id) ON DELETE RESTRICT,
    location_id uuid NOT NULL REFERENCES public.locations(id) ON DELETE RESTRICT,
    counted_quantity numeric NOT NULL CHECK (counted_quantity >= 0),
    book_quantity numeric NOT NULL,
    difference_quantity numeric NOT NULL,
    reason text NOT NULL,
    approved_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX idx_stock_adjustments_material ON public.stock_adjustments(material_id);
CREATE INDEX idx_stock_adjustments_location ON public.stock_adjustments(location_id);

-- 3. Table 26: stock_transactions (The Authoritative Immutable Stock Ledger)
CREATE TABLE public.stock_transactions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    transaction_number text NOT NULL UNIQUE,
    idempotency_key text NOT NULL REFERENCES public.idempotency_keys(idempotency_key) ON DELETE RESTRICT,
    transaction_sequence integer NOT NULL DEFAULT 1,
    material_id uuid NOT NULL REFERENCES public.materials(id) ON DELETE RESTRICT,
    movement_type text NOT NULL CHECK (
        movement_type IN (
            'PURCHASE_RECEIPT', 'ISSUE_TO_WORKER', 'RETURN_FROM_WORKER',
            'CONSUMPTION', 'LOCATION_TRANSFER', 'DAMAGE_QUARANTINE',
            'SCRAP_DISPOSAL', 'STOCK_ADJUSTMENT', 'PURCHASE_RETURN'
        )
    ),
    source_location_id uuid REFERENCES public.locations(id) ON DELETE RESTRICT,
    destination_location_id uuid REFERENCES public.locations(id) ON DELETE RESTRICT,
    worker_id uuid REFERENCES public.workers(id) ON DELETE RESTRICT,
    quantity numeric NOT NULL CHECK (quantity > 0),
    unit_id uuid NOT NULL REFERENCES public.units(id) ON DELETE RESTRICT,
    entered_quantity numeric NOT NULL CHECK (entered_quantity > 0),
    entered_unit_id uuid NOT NULL REFERENCES public.units(id) ON DELETE RESTRICT,
    measurement_method text NOT NULL CHECK (
        measurement_method IN (
            'SCALE_WEIGHED', 'SEALED_BUNDLE', 'MANUALLY_COUNTED',
            'AUTO_BOM_BACKFLUSH', 'INSPECTION_AUDIT'
        )
    ),
    conversion_factor_applied numeric NOT NULL DEFAULT 1.0,
    conversion_rule_id uuid REFERENCES public.material_conversions(id) ON DELETE RESTRICT,
    conversion_direction text NOT NULL DEFAULT 'NONE' CHECK (conversion_direction IN ('MULTIPLY', 'DIVIDE', 'NONE')),
    conversion_type_used text NOT NULL DEFAULT 'EXACT' CHECK (conversion_type_used IN ('EXACT', 'ESTIMATED')),
    is_estimated boolean NOT NULL DEFAULT false,
    movement_reason text,
    goods_receipt_id uuid REFERENCES public.goods_receipts(id) ON DELETE RESTRICT,
    goods_receipt_line_id uuid REFERENCES public.goods_receipt_lines(id) ON DELETE RESTRICT,
    packing_job_id uuid REFERENCES public.packing_jobs(id) ON DELETE RESTRICT,
    production_completion_id uuid REFERENCES public.production_completions(id) ON DELETE RESTRICT,
    stock_adjustment_id uuid REFERENCES public.stock_adjustments(id) ON DELETE RESTRICT,
    created_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT chk_stock_locations_distinct CHECK (
        source_location_id IS DISTINCT FROM destination_location_id
    ),
    CONSTRAINT uq_stock_tx_idempotency_seq UNIQUE (idempotency_key, transaction_sequence),
    CONSTRAINT chk_stock_movement_reference_integrity CHECK (
        CASE movement_type
            WHEN 'PURCHASE_RECEIPT' THEN
                goods_receipt_id IS NOT NULL AND goods_receipt_line_id IS NOT NULL AND source_location_id IS NULL AND destination_location_id IS NOT NULL AND packing_job_id IS NULL AND production_completion_id IS NULL AND stock_adjustment_id IS NULL AND worker_id IS NULL AND movement_reason IS NULL
            WHEN 'PURCHASE_RETURN' THEN
                goods_receipt_id IS NOT NULL AND source_location_id IS NOT NULL AND destination_location_id IS NULL AND movement_reason IS NOT NULL AND packing_job_id IS NULL AND production_completion_id IS NULL AND stock_adjustment_id IS NULL AND worker_id IS NULL
            WHEN 'ISSUE_TO_WORKER' THEN
                packing_job_id IS NOT NULL AND worker_id IS NOT NULL AND source_location_id IS NOT NULL AND destination_location_id IS NOT NULL AND goods_receipt_id IS NULL AND goods_receipt_line_id IS NULL AND production_completion_id IS NULL AND stock_adjustment_id IS NULL AND movement_reason IS NULL
            WHEN 'RETURN_FROM_WORKER' THEN
                packing_job_id IS NOT NULL AND worker_id IS NOT NULL AND source_location_id IS NOT NULL AND destination_location_id IS NOT NULL AND goods_receipt_id IS NULL AND goods_receipt_line_id IS NULL AND production_completion_id IS NULL AND stock_adjustment_id IS NULL AND movement_reason IS NULL
            WHEN 'CONSUMPTION' THEN
                packing_job_id IS NOT NULL AND production_completion_id IS NOT NULL AND worker_id IS NOT NULL AND source_location_id IS NOT NULL AND destination_location_id IS NULL AND goods_receipt_id IS NULL AND goods_receipt_line_id IS NULL AND stock_adjustment_id IS NULL AND movement_reason IS NULL
            WHEN 'STOCK_ADJUSTMENT' THEN
                stock_adjustment_id IS NOT NULL AND movement_reason IS NOT NULL AND goods_receipt_id IS NULL AND goods_receipt_line_id IS NULL AND packing_job_id IS NULL AND production_completion_id IS NULL AND worker_id IS NULL
            WHEN 'LOCATION_TRANSFER' THEN
                movement_reason IS NOT NULL AND source_location_id IS NOT NULL AND destination_location_id IS NOT NULL AND goods_receipt_id IS NULL AND goods_receipt_line_id IS NULL AND packing_job_id IS NULL AND production_completion_id IS NULL AND stock_adjustment_id IS NULL AND worker_id IS NULL
            WHEN 'DAMAGE_QUARANTINE' THEN
                movement_reason IS NOT NULL AND source_location_id IS NOT NULL AND destination_location_id IS NOT NULL AND goods_receipt_id IS NULL AND goods_receipt_line_id IS NULL AND production_completion_id IS NULL AND stock_adjustment_id IS NULL AND ((worker_id IS NULL AND packing_job_id IS NULL) OR (worker_id IS NOT NULL AND packing_job_id IS NOT NULL))
            WHEN 'SCRAP_DISPOSAL' THEN
                movement_reason IS NOT NULL AND source_location_id IS NOT NULL AND destination_location_id IS NULL AND goods_receipt_id IS NULL AND goods_receipt_line_id IS NULL AND packing_job_id IS NULL AND production_completion_id IS NULL AND stock_adjustment_id IS NULL AND worker_id IS NULL
            ELSE false
        END
    )
);

CREATE INDEX idx_stock_transactions_material_locations 
ON public.stock_transactions(material_id, source_location_id, destination_location_id, created_at);
CREATE INDEX idx_stock_transactions_movement ON public.stock_transactions(movement_type, created_at);
CREATE INDEX idx_stock_transactions_grn ON public.stock_transactions(goods_receipt_id);
CREATE INDEX idx_stock_transactions_grn_line ON public.stock_transactions(goods_receipt_line_id);
CREATE INDEX idx_stock_transactions_job ON public.stock_transactions(packing_job_id);

COMMENT ON TABLE public.stock_transactions IS 'Authoritative, immutable double-entry stock ledger. Physical inventory balances are computed strictly from this table.';

-- 4. Table 27: material_location_balances (Atomic Read-Model Balance Projection)
CREATE TABLE public.material_location_balances (
    material_id uuid NOT NULL REFERENCES public.materials(id) ON DELETE RESTRICT,
    location_id uuid NOT NULL REFERENCES public.locations(id) ON DELETE RESTRICT,
    on_hand_quantity numeric NOT NULL DEFAULT 0 CHECK (on_hand_quantity >= 0),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (material_id, location_id)
);

CREATE INDEX idx_material_location_balances_location ON public.material_location_balances(location_id);

COMMENT ON TABLE public.material_location_balances IS 'Synchronous read-model projection maintaining live on-hand balance per material and leaf location. Negative balances are physically prevented by check constraint.';

-- 5. Table 28: material_consumption_records (Theoretical vs Confirmed Consumption)
CREATE TABLE public.material_consumption_records (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    production_completion_id uuid NOT NULL REFERENCES public.production_completions(id) ON DELETE RESTRICT,
    material_id uuid NOT NULL REFERENCES public.materials(id) ON DELETE RESTRICT,
    theoretical_quantity numeric NOT NULL CHECK (theoretical_quantity >= 0),
    posted_ledger_quantity numeric NOT NULL CHECK (posted_ledger_quantity >= 0),
    physically_confirmed_quantity numeric CHECK (physically_confirmed_quantity IS NULL OR physically_confirmed_quantity >= 0),
    variance_quantity numeric,
    variance_status text NOT NULL CHECK (variance_status IN ('UNVERIFIED', 'VERIFIED_ZERO', 'VARIANCE_RECORDED')),
    stock_transaction_id uuid NOT NULL REFERENCES public.stock_transactions(id) ON DELETE RESTRICT,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT chk_consumption_variance_unverified CHECK (
        variance_status != 'UNVERIFIED' OR (physically_confirmed_quantity IS NULL AND variance_quantity IS NULL)
    )
);

CREATE INDEX idx_consumption_records_completion ON public.material_consumption_records(production_completion_id);
CREATE INDEX idx_consumption_records_material ON public.material_consumption_records(material_id);

-- 6. Table 30: daily_closings (End-of-Shift Production & Custody Checkpoint)
CREATE TABLE public.daily_closings (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    daily_plan_id uuid NOT NULL,
    shift_code text NOT NULL,
    closing_date date NOT NULL,
    total_planned_units integer NOT NULL,
    total_completed_units integer NOT NULL,
    total_pending_units integer NOT NULL,
    total_cancelled_units integer NOT NULL,
    total_variance_cost numeric NOT NULL DEFAULT 0,
    unresolved_discrepancies_count integer NOT NULL DEFAULT 0,
    override_reason text,
    closed_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    closed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    is_reopened boolean NOT NULL DEFAULT false,
    reopened_by uuid REFERENCES public.profiles(id) ON DELETE RESTRICT,
    reopened_at timestamptz,
    reopen_reason text,
    FOREIGN KEY (daily_plan_id, shift_code) REFERENCES public.daily_plans(id, shift_code) ON DELETE RESTRICT,
    CONSTRAINT uq_daily_closings_plan UNIQUE (daily_plan_id)
);

CREATE INDEX idx_daily_closings_date ON public.daily_closings(closing_date);
