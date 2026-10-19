-- =============================================================================
-- Migration 000006: Row Level Security (RLS) and Role-Based Authorization
-- Packing Material Inventory & BOM Management System
-- Database: Supabase PostgreSQL 15+
-- =============================================================================

-- 1. Grant Schema Usage to Data API Roles
GRANT USAGE ON SCHEMA public TO anon, authenticated;

-- 2. Enforce Row Level Security and Table Defaults across all 33 Tables
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.profiles FORCE ROW LEVEL SECURITY;

ALTER TABLE public.material_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.material_categories FORCE ROW LEVEL SECURITY;

ALTER TABLE public.parties ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.parties FORCE ROW LEVEL SECURITY;

ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.products FORCE ROW LEVEL SECURITY;

ALTER TABLE public.vendors ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vendors FORCE ROW LEVEL SECURITY;

ALTER TABLE public.units ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.units FORCE ROW LEVEL SECURITY;

ALTER TABLE public.materials ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.materials FORCE ROW LEVEL SECURITY;

ALTER TABLE public.material_conversions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.material_conversions FORCE ROW LEVEL SECURITY;

ALTER TABLE public.locations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.locations FORCE ROW LEVEL SECURITY;

ALTER TABLE public.workers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.workers FORCE ROW LEVEL SECURITY;

ALTER TABLE public.boms ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.boms FORCE ROW LEVEL SECURITY;

ALTER TABLE public.bom_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bom_lines FORCE ROW LEVEL SECURITY;

ALTER TABLE public.bom_revision_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bom_revision_events FORCE ROW LEVEL SECURITY;

ALTER TABLE public.purchase_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_orders FORCE ROW LEVEL SECURITY;

ALTER TABLE public.purchase_order_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_order_lines FORCE ROW LEVEL SECURITY;

ALTER TABLE public.goods_receipts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.goods_receipts FORCE ROW LEVEL SECURITY;

ALTER TABLE public.goods_receipt_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.goods_receipt_lines FORCE ROW LEVEL SECURITY;

ALTER TABLE public.daily_plans ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.daily_plans FORCE ROW LEVEL SECURITY;

ALTER TABLE public.packing_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.packing_jobs FORCE ROW LEVEL SECURITY;

ALTER TABLE public.packing_job_bom_snapshots ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.packing_job_bom_snapshots FORCE ROW LEVEL SECURITY;

ALTER TABLE public.packing_job_bom_snapshot_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.packing_job_bom_snapshot_lines FORCE ROW LEVEL SECURITY;

ALTER TABLE public.packing_job_revisions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.packing_job_revisions FORCE ROW LEVEL SECURITY;

ALTER TABLE public.packing_job_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.packing_job_events FORCE ROW LEVEL SECURITY;

ALTER TABLE public.stock_reservations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_reservations FORCE ROW LEVEL SECURITY;

ALTER TABLE public.production_completions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.production_completions FORCE ROW LEVEL SECURITY;

ALTER TABLE public.stock_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_transactions FORCE ROW LEVEL SECURITY;

ALTER TABLE public.material_location_balances ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.material_location_balances FORCE ROW LEVEL SECURITY;

ALTER TABLE public.material_consumption_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.material_consumption_records FORCE ROW LEVEL SECURITY;

ALTER TABLE public.stock_adjustments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_adjustments FORCE ROW LEVEL SECURITY;

ALTER TABLE public.daily_closings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.daily_closings FORCE ROW LEVEL SECURITY;

ALTER TABLE public.idempotency_keys ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.idempotency_keys FORCE ROW LEVEL SECURITY;

ALTER TABLE public.idempotency_responses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.idempotency_responses FORCE ROW LEVEL SECURITY;

ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_logs FORCE ROW LEVEL SECURITY;

-- 3. Grant Explicit Table Permissions to Authenticated Role
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;

-- =============================================================================
-- 4. Table-by-Table Row Level Security Policies
-- =============================================================================

-- Table 1: profiles
CREATE POLICY "profiles_select_authenticated" ON public.profiles
FOR SELECT TO authenticated USING (true);

CREATE POLICY "profiles_update_self" ON public.profiles
FOR UPDATE TO authenticated 
USING (id = auth.uid()) 
WITH CHECK (id = auth.uid());

-- Table 2: material_categories
CREATE POLICY "material_categories_select_authenticated" ON public.material_categories
FOR SELECT TO authenticated USING (true);

CREATE POLICY "material_categories_insert_admin" ON public.material_categories
FOR INSERT TO authenticated 
WITH CHECK (public.get_current_user_role() = 'ADMIN');

CREATE POLICY "material_categories_update_admin" ON public.material_categories
FOR UPDATE TO authenticated 
USING (public.get_current_user_role() = 'ADMIN')
WITH CHECK (public.get_current_user_role() = 'ADMIN');

-- Table 3: parties
CREATE POLICY "parties_select_authenticated" ON public.parties
FOR SELECT TO authenticated USING (true);

CREATE POLICY "parties_insert_planner_admin" ON public.parties
FOR INSERT TO authenticated 
WITH CHECK (public.get_current_user_role() IN ('ADMIN', 'PLANNER'));

CREATE POLICY "parties_update_planner_admin" ON public.parties
FOR UPDATE TO authenticated 
USING (public.get_current_user_role() IN ('ADMIN', 'PLANNER'))
WITH CHECK (public.get_current_user_role() IN ('ADMIN', 'PLANNER'));

-- Table 4: products
CREATE POLICY "products_select_authenticated" ON public.products
FOR SELECT TO authenticated USING (true);

CREATE POLICY "products_insert_planner_admin" ON public.products
FOR INSERT TO authenticated 
WITH CHECK (public.get_current_user_role() IN ('ADMIN', 'PLANNER'));

CREATE POLICY "products_update_planner_admin" ON public.products
FOR UPDATE TO authenticated 
USING (public.get_current_user_role() IN ('ADMIN', 'PLANNER'))
WITH CHECK (public.get_current_user_role() IN ('ADMIN', 'PLANNER'));

-- Table 5: vendors
CREATE POLICY "vendors_select_authenticated" ON public.vendors
FOR SELECT TO authenticated USING (true);

CREATE POLICY "vendors_insert_storekeeper_admin" ON public.vendors
FOR INSERT TO authenticated 
WITH CHECK (public.get_current_user_role() IN ('ADMIN', 'STOREKEEPER'));

CREATE POLICY "vendors_update_storekeeper_admin" ON public.vendors
FOR UPDATE TO authenticated 
USING (public.get_current_user_role() IN ('ADMIN', 'STOREKEEPER'))
WITH CHECK (public.get_current_user_role() IN ('ADMIN', 'STOREKEEPER'));

-- Table 6: units
CREATE POLICY "units_select_authenticated" ON public.units
FOR SELECT TO authenticated USING (true);

CREATE POLICY "units_insert_admin" ON public.units
FOR INSERT TO authenticated 
WITH CHECK (public.get_current_user_role() = 'ADMIN');

CREATE POLICY "units_update_admin" ON public.units
FOR UPDATE TO authenticated 
USING (public.get_current_user_role() = 'ADMIN')
WITH CHECK (public.get_current_user_role() = 'ADMIN');

-- Table 7: materials
CREATE POLICY "materials_select_authenticated" ON public.materials
FOR SELECT TO authenticated USING (true);

CREATE POLICY "materials_insert_storekeeper_admin" ON public.materials
FOR INSERT TO authenticated 
WITH CHECK (public.get_current_user_role() IN ('ADMIN', 'STOREKEEPER'));

CREATE POLICY "materials_update_storekeeper_admin" ON public.materials
FOR UPDATE TO authenticated 
USING (public.get_current_user_role() IN ('ADMIN', 'STOREKEEPER'))
WITH CHECK (public.get_current_user_role() IN ('ADMIN', 'STOREKEEPER'));

-- Table 8: material_conversions
CREATE POLICY "material_conversions_select_authenticated" ON public.material_conversions
FOR SELECT TO authenticated USING (true);

CREATE POLICY "material_conversions_insert_storekeeper_admin" ON public.material_conversions
FOR INSERT TO authenticated 
WITH CHECK (public.get_current_user_role() IN ('ADMIN', 'STOREKEEPER'));

-- Table 9: locations
CREATE POLICY "locations_select_authenticated" ON public.locations
FOR SELECT TO authenticated USING (true);

CREATE POLICY "locations_insert_storekeeper_admin" ON public.locations
FOR INSERT TO authenticated 
WITH CHECK (public.get_current_user_role() IN ('ADMIN', 'STOREKEEPER'));

CREATE POLICY "locations_update_storekeeper_admin" ON public.locations
FOR UPDATE TO authenticated 
USING (public.get_current_user_role() IN ('ADMIN', 'STOREKEEPER'))
WITH CHECK (public.get_current_user_role() IN ('ADMIN', 'STOREKEEPER'));

-- Table 10: workers
CREATE POLICY "workers_select_authenticated" ON public.workers
FOR SELECT TO authenticated USING (true);

CREATE POLICY "workers_insert_planner_admin" ON public.workers
FOR INSERT TO authenticated 
WITH CHECK (public.get_current_user_role() IN ('ADMIN', 'PLANNER'));

CREATE POLICY "workers_update_planner_admin" ON public.workers
FOR UPDATE TO authenticated 
USING (public.get_current_user_role() IN ('ADMIN', 'PLANNER'))
WITH CHECK (public.get_current_user_role() IN ('ADMIN', 'PLANNER'));

-- Table 11: boms
CREATE POLICY "boms_select_authenticated" ON public.boms
FOR SELECT TO authenticated USING (true);

CREATE POLICY "boms_insert_planner_admin" ON public.boms
FOR INSERT TO authenticated 
WITH CHECK (public.get_current_user_role() IN ('ADMIN', 'PLANNER'));

CREATE POLICY "boms_update_draft_planner_admin" ON public.boms
FOR UPDATE TO authenticated 
USING (public.get_current_user_role() IN ('ADMIN', 'PLANNER') AND status = 'DRAFT')
WITH CHECK (public.get_current_user_role() IN ('ADMIN', 'PLANNER') AND status = 'DRAFT');

CREATE POLICY "boms_delete_draft_planner_admin" ON public.boms
FOR DELETE TO authenticated 
USING (public.get_current_user_role() IN ('ADMIN', 'PLANNER') AND status = 'DRAFT');

-- Table 12: bom_lines
CREATE POLICY "bom_lines_select_authenticated" ON public.bom_lines
FOR SELECT TO authenticated USING (true);

CREATE POLICY "bom_lines_insert_draft_planner_admin" ON public.bom_lines
FOR INSERT TO authenticated 
WITH CHECK (
    public.get_current_user_role() IN ('ADMIN', 'PLANNER') 
    AND EXISTS (SELECT 1 FROM public.boms b WHERE b.id = bom_id AND b.status = 'DRAFT')
);

CREATE POLICY "bom_lines_update_draft_planner_admin" ON public.bom_lines
FOR UPDATE TO authenticated 
USING (
    public.get_current_user_role() IN ('ADMIN', 'PLANNER') 
    AND EXISTS (SELECT 1 FROM public.boms b WHERE b.id = bom_id AND b.status = 'DRAFT')
)
WITH CHECK (
    public.get_current_user_role() IN ('ADMIN', 'PLANNER') 
    AND EXISTS (SELECT 1 FROM public.boms b WHERE b.id = bom_id AND b.status = 'DRAFT')
);

CREATE POLICY "bom_lines_delete_draft_planner_admin" ON public.bom_lines
FOR DELETE TO authenticated 
USING (
    public.get_current_user_role() IN ('ADMIN', 'PLANNER') 
    AND EXISTS (SELECT 1 FROM public.boms b WHERE b.id = bom_id AND b.status = 'DRAFT')
);

-- Table 13: bom_revision_events
CREATE POLICY "bom_revision_events_select_authenticated" ON public.bom_revision_events
FOR SELECT TO authenticated USING (true);

-- Table 14: purchase_orders
CREATE POLICY "purchase_orders_select_authenticated" ON public.purchase_orders
FOR SELECT TO authenticated USING (true);

CREATE POLICY "purchase_orders_insert_storekeeper_admin" ON public.purchase_orders
FOR INSERT TO authenticated 
WITH CHECK (public.get_current_user_role() IN ('ADMIN', 'STOREKEEPER'));

CREATE POLICY "purchase_orders_update_draft_storekeeper_admin" ON public.purchase_orders
FOR UPDATE TO authenticated 
USING (public.get_current_user_role() IN ('ADMIN', 'STOREKEEPER') AND status = 'DRAFT')
WITH CHECK (public.get_current_user_role() IN ('ADMIN', 'STOREKEEPER') AND status = 'DRAFT');

CREATE POLICY "purchase_orders_delete_draft_storekeeper_admin" ON public.purchase_orders
FOR DELETE TO authenticated 
USING (public.get_current_user_role() IN ('ADMIN', 'STOREKEEPER') AND status = 'DRAFT');

-- Table 15: purchase_order_lines
CREATE POLICY "purchase_order_lines_select_authenticated" ON public.purchase_order_lines
FOR SELECT TO authenticated USING (true);

CREATE POLICY "purchase_order_lines_insert_draft_storekeeper_admin" ON public.purchase_order_lines
FOR INSERT TO authenticated 
WITH CHECK (
    public.get_current_user_role() IN ('ADMIN', 'STOREKEEPER') 
    AND EXISTS (SELECT 1 FROM public.purchase_orders po WHERE po.id = po_id AND po.status = 'DRAFT')
);

CREATE POLICY "purchase_order_lines_update_draft_storekeeper_admin" ON public.purchase_order_lines
FOR UPDATE TO authenticated 
USING (
    public.get_current_user_role() IN ('ADMIN', 'STOREKEEPER') 
    AND EXISTS (SELECT 1 FROM public.purchase_orders po WHERE po.id = po_id AND po.status = 'DRAFT')
)
WITH CHECK (
    public.get_current_user_role() IN ('ADMIN', 'STOREKEEPER') 
    AND EXISTS (SELECT 1 FROM public.purchase_orders po WHERE po.id = po_id AND po.status = 'DRAFT')
);

CREATE POLICY "purchase_order_lines_delete_draft_storekeeper_admin" ON public.purchase_order_lines
FOR DELETE TO authenticated 
USING (
    public.get_current_user_role() IN ('ADMIN', 'STOREKEEPER') 
    AND EXISTS (SELECT 1 FROM public.purchase_orders po WHERE po.id = po_id AND po.status = 'DRAFT')
);

-- Table 16: goods_receipts
CREATE POLICY "goods_receipts_select_authenticated" ON public.goods_receipts
FOR SELECT TO authenticated USING (true);

CREATE POLICY "goods_receipts_insert_storekeeper_admin" ON public.goods_receipts
FOR INSERT TO authenticated 
WITH CHECK (public.get_current_user_role() IN ('ADMIN', 'STOREKEEPER'));

CREATE POLICY "goods_receipts_update_draft_storekeeper_admin" ON public.goods_receipts
FOR UPDATE TO authenticated 
USING (public.get_current_user_role() IN ('ADMIN', 'STOREKEEPER') AND status = 'DRAFT')
WITH CHECK (public.get_current_user_role() IN ('ADMIN', 'STOREKEEPER') AND status = 'DRAFT');

CREATE POLICY "goods_receipts_delete_draft_storekeeper_admin" ON public.goods_receipts
FOR DELETE TO authenticated 
USING (public.get_current_user_role() IN ('ADMIN', 'STOREKEEPER') AND status = 'DRAFT');

-- Table 17: goods_receipt_lines
CREATE POLICY "goods_receipt_lines_select_authenticated" ON public.goods_receipt_lines
FOR SELECT TO authenticated USING (true);

CREATE POLICY "goods_receipt_lines_insert_draft_storekeeper_admin" ON public.goods_receipt_lines
FOR INSERT TO authenticated 
WITH CHECK (
    public.get_current_user_role() IN ('ADMIN', 'STOREKEEPER') 
    AND EXISTS (SELECT 1 FROM public.goods_receipts gr WHERE gr.id = grn_id AND gr.status = 'DRAFT')
);

CREATE POLICY "goods_receipt_lines_update_draft_storekeeper_admin" ON public.goods_receipt_lines
FOR UPDATE TO authenticated 
USING (
    public.get_current_user_role() IN ('ADMIN', 'STOREKEEPER') 
    AND EXISTS (SELECT 1 FROM public.goods_receipts gr WHERE gr.id = grn_id AND gr.status = 'DRAFT')
)
WITH CHECK (
    public.get_current_user_role() IN ('ADMIN', 'STOREKEEPER') 
    AND EXISTS (SELECT 1 FROM public.goods_receipts gr WHERE gr.id = grn_id AND gr.status = 'DRAFT')
);

CREATE POLICY "goods_receipt_lines_delete_draft_storekeeper_admin" ON public.goods_receipt_lines
FOR DELETE TO authenticated 
USING (
    public.get_current_user_role() IN ('ADMIN', 'STOREKEEPER') 
    AND EXISTS (SELECT 1 FROM public.goods_receipts gr WHERE gr.id = grn_id AND gr.status = 'DRAFT')
);

-- Table 18: daily_plans (Direct update allowed only when plan contains no non-draft jobs)
CREATE POLICY "daily_plans_select_authenticated" ON public.daily_plans
FOR SELECT TO authenticated USING (true);

CREATE POLICY "daily_plans_insert_planner_admin" ON public.daily_plans
FOR INSERT TO authenticated 
WITH CHECK (public.get_current_user_role() IN ('ADMIN', 'PLANNER'));

CREATE POLICY "daily_plans_update_draft_planner_admin" ON public.daily_plans
FOR UPDATE TO authenticated 
USING (
    public.get_current_user_role() IN ('ADMIN', 'PLANNER') 
    AND NOT EXISTS (
        SELECT 1 FROM public.packing_jobs pj 
        WHERE pj.daily_plan_id = id AND pj.status != 'DRAFT'
    )
)
WITH CHECK (
    public.get_current_user_role() IN ('ADMIN', 'PLANNER')
);

-- Table 19: packing_jobs (Draft-only direct update; released jobs updated strictly via controlled RPCs)
CREATE POLICY "packing_jobs_select_authenticated" ON public.packing_jobs
FOR SELECT TO authenticated USING (true);

CREATE POLICY "packing_jobs_insert_planner_admin" ON public.packing_jobs
FOR INSERT TO authenticated 
WITH CHECK (public.get_current_user_role() IN ('ADMIN', 'PLANNER'));

CREATE POLICY "packing_jobs_update_draft_planner_admin" ON public.packing_jobs
FOR UPDATE TO authenticated 
USING (public.get_current_user_role() IN ('ADMIN', 'PLANNER') AND status = 'DRAFT')
WITH CHECK (public.get_current_user_role() IN ('ADMIN', 'PLANNER') AND status = 'DRAFT');

CREATE POLICY "packing_jobs_delete_draft_planner_admin" ON public.packing_jobs
FOR DELETE TO authenticated 
USING (public.get_current_user_role() IN ('ADMIN', 'PLANNER') AND status = 'DRAFT');

-- Tables 20-28, 29-30: Protected Operational & Ledger Tables
-- Direct PostgREST write is completely denied by default (zero write policies)
CREATE POLICY "packing_job_bom_snapshots_select_authenticated" ON public.packing_job_bom_snapshots
FOR SELECT TO authenticated USING (true);

CREATE POLICY "packing_job_bom_snapshot_lines_select_authenticated" ON public.packing_job_bom_snapshot_lines
FOR SELECT TO authenticated USING (true);

CREATE POLICY "packing_job_revisions_select_authenticated" ON public.packing_job_revisions
FOR SELECT TO authenticated USING (true);

CREATE POLICY "packing_job_events_select_authenticated" ON public.packing_job_events
FOR SELECT TO authenticated USING (true);

CREATE POLICY "stock_reservations_select_authenticated" ON public.stock_reservations
FOR SELECT TO authenticated USING (true);

CREATE POLICY "production_completions_select_authenticated" ON public.production_completions
FOR SELECT TO authenticated USING (true);

CREATE POLICY "stock_transactions_select_authenticated" ON public.stock_transactions
FOR SELECT TO authenticated USING (true);

CREATE POLICY "material_location_balances_select_authenticated" ON public.material_location_balances
FOR SELECT TO authenticated USING (true);

CREATE POLICY "material_consumption_records_select_authenticated" ON public.material_consumption_records
FOR SELECT TO authenticated USING (true);

CREATE POLICY "stock_adjustments_select_authenticated" ON public.stock_adjustments
FOR SELECT TO authenticated USING (true);

CREATE POLICY "daily_closings_select_authenticated" ON public.daily_closings
FOR SELECT TO authenticated USING (true);

-- Tables 31 & 32: idempotency_keys & idempotency_responses
-- ZERO policies defined: Denied completely to all direct PostgREST calls (SELECT, INSERT, UPDATE, DELETE)

-- Table 33: audit_logs
-- Only active administrators can view audit logs. Direct write is denied.
CREATE POLICY "audit_logs_select_admin_only" ON public.audit_logs
FOR SELECT TO authenticated 
USING (public.get_current_user_role() = 'ADMIN');

-- =============================================================================
-- 5. Trusted Administrator Role-Update RPC
-- =============================================================================
CREATE OR REPLACE FUNCTION public.admin_update_profile_access(
    target_id uuid,
    new_role text,
    new_is_active boolean,
    reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_actor_id uuid;
    v_actor_role text;
    v_target_old_role text;
    v_target_old_active boolean;
    v_active_admin_count integer;
BEGIN
    -- 1. Validate caller identity from verified JWT sub
    v_actor_id := auth.uid();
    IF v_actor_id IS NULL THEN
        RAISE EXCEPTION 'Unauthenticated request: missing caller identity.'
            USING ERRCODE = '28000';
    END IF;

    -- 2. Verify actor has active ADMIN profile (lock actor profile row)
    SELECT role INTO v_actor_role
    FROM public.profiles
    WHERE id = v_actor_id AND is_active = true
    FOR UPDATE;

    IF v_actor_role IS DISTINCT FROM 'ADMIN' THEN
        RAISE EXCEPTION 'Unauthorized: Only active administrators can execute access updates.'
            USING ERRCODE = '42501';
    END IF;

    -- 3. Validate arguments
    IF new_role NOT IN ('ADMIN', 'STOREKEEPER', 'PLANNER', 'OPERATOR', 'VIEWER') THEN
        RAISE EXCEPTION 'Invalid role specified: %', new_role
            USING ERRCODE = '22023';
    END IF;

    IF reason IS NULL OR trim(reason) = '' THEN
        RAISE EXCEPTION 'A non-empty reason is required for profile access modifications.'
            USING ERRCODE = '22023';
    END IF;

    -- 4. Lock target profile and fetch existing state
    SELECT role, is_active INTO v_target_old_role, v_target_old_active
    FROM public.profiles
    WHERE id = target_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Target profile not found: %', target_id
            USING ERRCODE = 'P0002';
    END IF;

    -- 5. Invariant: Prevent removing or deactivating the last active administrator
    IF (v_target_old_role = 'ADMIN' AND v_target_old_active = true) AND 
       (new_role IS DISTINCT FROM 'ADMIN' OR new_is_active = false) THEN
        SELECT count(*) INTO v_active_admin_count
        FROM public.profiles
        WHERE role = 'ADMIN' AND is_active = true;

        IF v_active_admin_count <= 1 THEN
            RAISE EXCEPTION 'Cannot remove or deactivate the last active administrator.'
                USING ERRCODE = '23514';
        END IF;
    END IF;

    -- 6. Perform profile update
    UPDATE public.profiles
    SET role = new_role,
        is_active = new_is_active,
        updated_at = clock_timestamp()
    WHERE id = target_id;

    -- 7. Record immutable security audit log entry
    INSERT INTO public.audit_logs (
        event_type,
        actor_id,
        target_entity_type,
        target_entity_id,
        old_state,
        new_state
    ) VALUES (
        CASE WHEN new_is_active = false AND v_target_old_active = true THEN 'PROFILE_DEACTIVATED' ELSE 'ROLE_CHANGE' END,
        v_actor_id,
        'PROFILE',
        target_id,
        jsonb_build_object('role', v_target_old_role, 'is_active', v_target_old_active),
        jsonb_build_object('role', new_role, 'is_active', new_is_active, 'reason', reason)
    );

    RETURN jsonb_build_object(
        'success', true,
        'target_id', target_id,
        'new_role', new_role,
        'new_is_active', new_is_active
    );
END;
$$;

-- Revoke execute from PUBLIC and anon; grant exclusively to authenticated
REVOKE ALL ON FUNCTION public.admin_update_profile_access(uuid, text, boolean, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_update_profile_access(uuid, text, boolean, text) TO authenticated;
