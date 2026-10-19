-- =============================================================================
-- Migration 000003: Purchasing, BOM Versioning, and Production Planning
-- Packing Material Inventory & BOM Management System
-- Database: Supabase PostgreSQL 15+
-- =============================================================================

-- 1. Table 11: boms (Versioned Bill of Materials Header)
CREATE TABLE public.boms (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    bom_code text NOT NULL,
    product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
    party_id uuid REFERENCES public.parties(id) ON DELETE RESTRICT,
    packing_variant_name text NOT NULL,
    version_number integer NOT NULL DEFAULT 1,
    status text NOT NULL CHECK (status IN ('DRAFT', 'ACTIVE', 'SUPERSEDED', 'ARCHIVED')),
    notes text,
    created_by uuid REFERENCES public.profiles(id) ON DELETE RESTRICT,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT uq_boms_version UNIQUE NULLS NOT DISTINCT (product_id, party_id, packing_variant_name, version_number)
);

-- Invariant: At most one version per recipe key can be ACTIVE at any time
CREATE UNIQUE INDEX idx_boms_single_active_version 
ON public.boms (product_id, party_id, packing_variant_name) 
NULLS NOT DISTINCT 
WHERE (status = 'ACTIVE');

CREATE INDEX idx_boms_product_status ON public.boms (product_id, status);

-- 2. Table 12: bom_lines (Material Requirements per 1 Finished Good)
CREATE TABLE public.bom_lines (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    bom_id uuid NOT NULL REFERENCES public.boms(id) ON DELETE RESTRICT,
    material_id uuid NOT NULL REFERENCES public.materials(id) ON DELETE RESTRICT,
    quantity_per_unit numeric NOT NULL CHECK (quantity_per_unit > 0),
    unit_id uuid NOT NULL REFERENCES public.units(id) ON DELETE RESTRICT,
    is_optional boolean NOT NULL DEFAULT false,
    notes text,
    CONSTRAINT uq_bom_lines_material UNIQUE (bom_id, material_id)
);

CREATE INDEX idx_bom_lines_bom ON public.bom_lines(bom_id);
CREATE INDEX idx_bom_lines_material ON public.bom_lines(material_id);

-- 3. Table 13: bom_revision_events (BOM Release & Promotion Audit Trail)
CREATE TABLE public.bom_revision_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    bom_id uuid NOT NULL REFERENCES public.boms(id) ON DELETE RESTRICT,
    previous_bom_id uuid REFERENCES public.boms(id) ON DELETE RESTRICT,
    revision_reason text NOT NULL,
    changed_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX idx_bom_revision_events_bom ON public.bom_revision_events(bom_id);

-- 4. Table 14: purchase_orders (Vendor Supply Orders)
CREATE TABLE public.purchase_orders (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    po_number text NOT NULL UNIQUE,
    vendor_id uuid NOT NULL REFERENCES public.vendors(id) ON DELETE RESTRICT,
    order_date date NOT NULL,
    expected_delivery_date date,
    status text NOT NULL CHECK (status IN ('DRAFT', 'APPROVED', 'PARTIALLY_RECEIVED', 'COMPLETED', 'CANCELLED')),
    remarks text,
    created_by uuid REFERENCES public.profiles(id) ON DELETE RESTRICT,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX idx_purchase_orders_vendor_status ON public.purchase_orders(vendor_id, status);

-- 5. Table 15: purchase_order_lines (PO Material Detail Lines)
CREATE TABLE public.purchase_order_lines (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    po_id uuid NOT NULL REFERENCES public.purchase_orders(id) ON DELETE RESTRICT,
    material_id uuid NOT NULL REFERENCES public.materials(id) ON DELETE RESTRICT,
    ordered_quantity numeric NOT NULL CHECK (ordered_quantity > 0),
    unit_id uuid NOT NULL REFERENCES public.units(id) ON DELETE RESTRICT,
    received_quantity numeric NOT NULL DEFAULT 0 CHECK (received_quantity >= 0),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT uq_po_lines_material UNIQUE (po_id, material_id)
);

CREATE INDEX idx_purchase_order_lines_po ON public.purchase_order_lines(po_id);

-- 6. Table 16: goods_receipts (Inward Warehouse Receipts Header)
CREATE TABLE public.goods_receipts (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    grn_number text NOT NULL UNIQUE,
    vendor_id uuid NOT NULL REFERENCES public.vendors(id) ON DELETE RESTRICT,
    po_id uuid REFERENCES public.purchase_orders(id) ON DELETE RESTRICT,
    invoice_number text NOT NULL,
    invoice_date date NOT NULL,
    received_date date NOT NULL,
    destination_location_id uuid NOT NULL REFERENCES public.locations(id) ON DELETE RESTRICT,
    status text NOT NULL CHECK (status IN ('DRAFT', 'POSTED', 'CANCELLED')),
    remarks text,
    posted_by uuid REFERENCES public.profiles(id) ON DELETE RESTRICT,
    posted_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX idx_goods_receipts_vendor_date ON public.goods_receipts(vendor_id, received_date);
CREATE INDEX idx_goods_receipts_status ON public.goods_receipts(status);

-- 7. Table 17: goods_receipt_lines (Inward Receipt Details with Explicit PO Line Linkage)
CREATE TABLE public.goods_receipt_lines (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    grn_id uuid NOT NULL REFERENCES public.goods_receipts(id) ON DELETE RESTRICT,
    purchase_order_line_id uuid REFERENCES public.purchase_order_lines(id) ON DELETE RESTRICT,
    material_id uuid NOT NULL REFERENCES public.materials(id) ON DELETE RESTRICT,
    entered_qty numeric NOT NULL CHECK (entered_qty > 0),
    entered_unit_id uuid NOT NULL REFERENCES public.units(id) ON DELETE RESTRICT,
    rejected_qty numeric NOT NULL DEFAULT 0 CHECK (rejected_qty >= 0),
    rejected_unit_id uuid NOT NULL REFERENCES public.units(id) ON DELETE RESTRICT,
    accepted_qty numeric NOT NULL CHECK (accepted_qty >= 0),
    canonical_quantity numeric NOT NULL CHECK (canonical_quantity >= 0),
    canonical_unit_id uuid NOT NULL REFERENCES public.units(id) ON DELETE RESTRICT,
    box_count integer,
    weight_kg numeric,
    pcs_count numeric,
    conversion_rule_id uuid REFERENCES public.material_conversions(id) ON DELETE RESTRICT,
    conversion_factor_used numeric NOT NULL DEFAULT 1.0,
    conversion_direction text NOT NULL DEFAULT 'NONE' CHECK (conversion_direction IN ('MULTIPLY', 'DIVIDE', 'NONE')),
    conversion_type_used text NOT NULL DEFAULT 'EXACT' CHECK (conversion_type_used IN ('EXACT', 'ESTIMATED')),
    is_estimated_conversion boolean NOT NULL DEFAULT false,
    rejection_conversion_rule_id uuid REFERENCES public.material_conversions(id) ON DELETE RESTRICT,
    rejection_conversion_factor_used numeric NOT NULL DEFAULT 1.0,
    rejection_conversion_direction text NOT NULL DEFAULT 'NONE' CHECK (rejection_conversion_direction IN ('MULTIPLY', 'DIVIDE', 'NONE')),
    rejection_conversion_type_used text NOT NULL DEFAULT 'EXACT' CHECK (rejection_conversion_type_used IN ('EXACT', 'ESTIMATED')),
    batch_lot_number text,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX idx_goods_receipt_lines_grn ON public.goods_receipt_lines(grn_id);
CREATE INDEX idx_goods_receipt_lines_material ON public.goods_receipt_lines(material_id);
CREATE INDEX idx_goods_receipt_lines_po_line ON public.goods_receipt_lines(purchase_order_line_id);

-- 8. Table 18: daily_plans (Shop-Floor Daily Production Schedule)
CREATE TABLE public.daily_plans (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    plan_number text NOT NULL UNIQUE,
    plan_date date NOT NULL,
    shift_code text NOT NULL,
    created_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT uq_daily_plans_date_shift UNIQUE (plan_date, shift_code),
    CONSTRAINT uq_daily_plans_id_shift UNIQUE (id, shift_code)
);

CREATE INDEX idx_daily_plans_date ON public.daily_plans(plan_date);

-- 9. Table 19: packing_jobs (Granular Packing Jobs with 5-Variable Conservation)
CREATE TABLE public.packing_jobs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    daily_plan_id uuid NOT NULL REFERENCES public.daily_plans(id) ON DELETE RESTRICT,
    job_code text NOT NULL UNIQUE,
    party_id uuid NOT NULL REFERENCES public.parties(id) ON DELETE RESTRICT,
    product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
    master_bom_id uuid REFERENCES public.boms(id) ON DELETE RESTRICT,
    original_planned_quantity integer NOT NULL CHECK (original_planned_quantity > 0),
    current_revised_quantity integer NOT NULL CHECK (current_revised_quantity > 0),
    completed_quantity integer NOT NULL DEFAULT 0 CHECK (completed_quantity >= 0),
    pending_quantity integer NOT NULL DEFAULT 0 CHECK (pending_quantity >= 0),
    cancelled_quantity integer NOT NULL DEFAULT 0 CHECK (cancelled_quantity >= 0),
    assigned_worker_id uuid REFERENCES public.workers(id) ON DELETE RESTRICT,
    status text NOT NULL CHECK (status IN ('DRAFT', 'RELEASED', 'IN_PROGRESS', 'PARTIALLY_COMPLETED', 'COMPLETED', 'CANCELLED')),
    priority integer NOT NULL DEFAULT 1,
    cancellation_reason text,
    cancelled_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT chk_packing_jobs_conservation CHECK (
        current_revised_quantity = completed_quantity + pending_quantity + cancelled_quantity
    )
);

CREATE INDEX idx_packing_jobs_plan_party_product ON public.packing_jobs(daily_plan_id, party_id, product_id);
CREATE INDEX idx_packing_jobs_status ON public.packing_jobs(status);
CREATE INDEX idx_packing_jobs_worker ON public.packing_jobs(assigned_worker_id);

-- 10. Table 20: packing_job_bom_snapshots (Immutable BOM Specifications at Release)
CREATE TABLE public.packing_job_bom_snapshots (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    packing_job_id uuid NOT NULL UNIQUE REFERENCES public.packing_jobs(id) ON DELETE RESTRICT,
    source_bom_id uuid REFERENCES public.boms(id) ON DELETE RESTRICT,
    bom_version integer,
    is_customized boolean NOT NULL DEFAULT false,
    customization_notes text,
    frozen_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    frozen_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    CONSTRAINT chk_snapshot_customization CHECK (
        (is_customized = false AND source_bom_id IS NOT NULL AND bom_version IS NOT NULL) OR
        (is_customized = true AND source_bom_id IS NULL AND bom_version IS NULL)
    )
);

-- 11. Table 21: packing_job_bom_snapshot_lines (Frozen Material Requirement Lines)
CREATE TABLE public.packing_job_bom_snapshot_lines (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    snapshot_id uuid NOT NULL REFERENCES public.packing_job_bom_snapshots(id) ON DELETE RESTRICT,
    material_id uuid NOT NULL REFERENCES public.materials(id) ON DELETE RESTRICT,
    quantity_per_unit numeric NOT NULL CHECK (quantity_per_unit > 0),
    unit_id uuid NOT NULL REFERENCES public.units(id) ON DELETE RESTRICT,
    canonical_qty_per_unit numeric NOT NULL CHECK (canonical_qty_per_unit > 0),
    canonical_unit_id uuid NOT NULL REFERENCES public.units(id) ON DELETE RESTRICT,
    conversion_rule_id uuid REFERENCES public.material_conversions(id) ON DELETE RESTRICT,
    conversion_factor_frozen numeric NOT NULL DEFAULT 1.0,
    conversion_direction text NOT NULL DEFAULT 'NONE' CHECK (conversion_direction IN ('MULTIPLY', 'DIVIDE', 'NONE')),
    conversion_type text NOT NULL DEFAULT 'EXACT' CHECK (conversion_type IN ('EXACT', 'ESTIMATED')),
    is_optional boolean NOT NULL DEFAULT false,
    notes text,
    CONSTRAINT uq_snapshot_lines_material UNIQUE (snapshot_id, material_id)
);

CREATE INDEX idx_snapshot_lines_snapshot ON public.packing_job_bom_snapshot_lines(snapshot_id);
CREATE INDEX idx_snapshot_lines_material ON public.packing_job_bom_snapshot_lines(material_id);

-- 12. Table 22: packing_job_revisions (Formal Quantity Revision Audit)
CREATE TABLE public.packing_job_revisions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    packing_job_id uuid NOT NULL REFERENCES public.packing_jobs(id) ON DELETE RESTRICT,
    revision_number integer NOT NULL,
    original_quantity integer NOT NULL,
    revised_quantity integer NOT NULL,
    quantity_difference integer NOT NULL,
    reason text NOT NULL,
    revised_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT uq_packing_job_revisions UNIQUE (packing_job_id, revision_number)
);

CREATE INDEX idx_job_revisions_job ON public.packing_job_revisions(packing_job_id);

-- 13. Table 23: packing_job_events (Job Lifecycle State Transition Log)
CREATE TABLE public.packing_job_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    packing_job_id uuid NOT NULL REFERENCES public.packing_jobs(id) ON DELETE RESTRICT,
    event_type text NOT NULL,
    from_status text NOT NULL,
    to_status text NOT NULL,
    payload jsonb,
    triggered_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX idx_job_events_job ON public.packing_job_events(packing_job_id);

-- 14. Table 24: stock_reservations (Dynamic Soft Allocations for Released Jobs)
CREATE TABLE public.stock_reservations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    packing_job_id uuid NOT NULL REFERENCES public.packing_jobs(id) ON DELETE RESTRICT,
    material_id uuid NOT NULL REFERENCES public.materials(id) ON DELETE RESTRICT,
    location_id uuid NOT NULL REFERENCES public.locations(id) ON DELETE RESTRICT,
    canonical_unit_id uuid NOT NULL REFERENCES public.units(id) ON DELETE RESTRICT,
    reserved_quantity numeric NOT NULL CHECK (reserved_quantity >= 0),
    status text NOT NULL CHECK (status IN ('ACTIVE', 'FULFILLED', 'RELEASED')),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX idx_stock_reservations_material_status ON public.stock_reservations(material_id, status);
CREATE INDEX idx_stock_reservations_job ON public.stock_reservations(packing_job_id);
