-- =============================================================================
-- Phase 6: BOM versioning, daily planning, immutable snapshots and reservations
-- =============================================================================
-- All business mutations remain transactional, caller-JWT authorized RPCs.
-- Read access remains caller-scoped PostgREST/RLS. No service-role secret is
-- introduced into the Flask application.
-- =============================================================================

-- The original foundation created daily_plans before its lifecycle metadata was
-- finalized. Add the contract fields here without rewriting historical rows.
ALTER TABLE public.daily_plans
    ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'DRAFT',
    ADD COLUMN IF NOT EXISTS notes text,
    ADD COLUMN IF NOT EXISTS released_at timestamptz,
    ADD COLUMN IF NOT EXISTS released_by uuid REFERENCES public.profiles(id) ON DELETE RESTRICT;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_constraint
        WHERE conrelid = 'public.daily_plans'::regclass
          AND conname = 'chk_daily_plans_status'
    ) THEN
        ALTER TABLE public.daily_plans
            ADD CONSTRAINT chk_daily_plans_status
            CHECK (status IN ('DRAFT', 'RELEASED', 'CLOSED', 'ARCHIVED'));
    END IF;
END
$$;

CREATE INDEX IF NOT EXISTS idx_daily_plans_status_date
    ON public.daily_plans(status, plan_date);

-- BOM/plan/job writes must go through RPCs so their audit rows, immutable
-- snapshots, quantity conservation and idempotency entries commit together.
DROP POLICY IF EXISTS "boms_insert_planner_admin" ON public.boms;
DROP POLICY IF EXISTS "boms_update_draft_planner_admin" ON public.boms;
DROP POLICY IF EXISTS "boms_delete_draft_planner_admin" ON public.boms;
DROP POLICY IF EXISTS "bom_lines_insert_draft_planner_admin" ON public.bom_lines;
DROP POLICY IF EXISTS "bom_lines_update_draft_planner_admin" ON public.bom_lines;
DROP POLICY IF EXISTS "bom_lines_delete_draft_planner_admin" ON public.bom_lines;
DROP POLICY IF EXISTS "daily_plans_insert_planner_admin" ON public.daily_plans;
DROP POLICY IF EXISTS "daily_plans_update_draft_planner_admin" ON public.daily_plans;
DROP POLICY IF EXISTS "packing_jobs_insert_planner_admin" ON public.packing_jobs;
DROP POLICY IF EXISTS "packing_jobs_update_draft_planner_admin" ON public.packing_jobs;
DROP POLICY IF EXISTS "packing_jobs_delete_draft_planner_admin" ON public.packing_jobs;

-- A shared recipe-key lock prevents two simultaneous version bumps or
-- activations from racing the partial unique ACTIVE index.
CREATE OR REPLACE FUNCTION public.fn_lock_bom_recipe(
    p_product_id uuid,
    p_party_id uuid,
    p_packing_variant_name text
)
RETURNS void
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
    PERFORM pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended(
            p_product_id::text || '|' ||
            coalesce(p_party_id::text, '<UNIVERSAL>') || '|' ||
            lower(trim(p_packing_variant_name)),
            0
        )
    );
END;
$$;
REVOKE ALL ON FUNCTION public.fn_lock_bom_recipe(uuid, uuid, text)
    FROM PUBLIC, anon, authenticated;

-- Canonical BOM response builder used inside atomic RPCs. Recipe quantities
-- remain in their entered units; conversion provenance is frozen at release.
CREATE OR REPLACE FUNCTION public.fn_bom_json(p_bom_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
    v_bom public.boms;
    v_lines jsonb;
BEGIN
    SELECT * INTO v_bom
    FROM public.boms
    WHERE id = p_bom_id;

    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    SELECT coalesce(
        jsonb_agg(
            jsonb_build_object(
                'materialId', bl.material_id,
                'quantityPerUnit', bl.quantity_per_unit,
                'unitId', bl.unit_id,
                'isOptional', bl.is_optional,
                'applicationNotes', bl.notes
            ) ORDER BY bl.material_id
        ),
        '[]'::jsonb
    )
    INTO v_lines
    FROM public.bom_lines bl
    WHERE bl.bom_id = p_bom_id;

    RETURN jsonb_build_object(
        'id', v_bom.id,
        'bomCode', v_bom.bom_code,
        'productId', v_bom.product_id,
        'partyId', v_bom.party_id,
        'packingVariantName', v_bom.packing_variant_name,
        'versionNumber', v_bom.version_number,
        'status', v_bom.status,
        'versionNotes', v_bom.notes,
        'lines', v_lines
    );
END;
$$;
REVOKE ALL ON FUNCTION public.fn_bom_json(uuid) FROM PUBLIC, anon, authenticated;

-- Validates and inserts a non-empty, duplicate-free recipe. It deliberately
-- checks active material/unit conversion now; authoritative factor provenance
-- is resolved again and frozen when a job is released.
CREATE OR REPLACE FUNCTION public.fn_insert_bom_lines(
    p_bom_id uuid,
    p_lines jsonb
)
RETURNS integer
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
    v_line jsonb;
    v_material_id uuid;
    v_unit_id uuid;
    v_canonical_unit_id uuid;
    v_quantity numeric;
    v_optional boolean;
    v_note text;
    v_count integer := 0;
BEGIN
    IF jsonb_typeof(p_lines) IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'BOM lines must be a JSON array.' USING ERRCODE = '22023';
    END IF;
    IF jsonb_array_length(p_lines) < 1 OR jsonb_array_length(p_lines) > 250 THEN
        RAISE EXCEPTION 'A BOM must contain between 1 and 250 lines.' USING ERRCODE = '22023';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(p_lines) AS item(value)
        GROUP BY item.value->>'materialId'
        HAVING count(*) > 1
    ) THEN
        RAISE EXCEPTION 'A material may appear only once in a BOM.' USING ERRCODE = '23505';
    END IF;

    FOR v_line IN
        SELECT item.value
        FROM jsonb_array_elements(p_lines) AS item(value)
    LOOP
        IF nullif(v_line->>'materialId', '') IS NULL
           OR nullif(v_line->>'quantityPerUnit', '') IS NULL
           OR nullif(v_line->>'unitId', '') IS NULL THEN
            RAISE EXCEPTION 'Each BOM line requires materialId, quantityPerUnit and unitId.'
                USING ERRCODE = '22023';
        END IF;

        v_material_id := (v_line->>'materialId')::uuid;
        v_unit_id := (v_line->>'unitId')::uuid;
        v_quantity := (v_line->>'quantityPerUnit')::numeric;
        v_optional := coalesce((v_line->>'isOptional')::boolean, false);
        v_note := nullif(trim(coalesce(v_line->>'applicationNotes', '')), '');

        IF v_quantity IS NULL OR v_quantity::text IN ('NaN', 'Infinity', '-Infinity')
           OR v_quantity <= 0 THEN
            RAISE EXCEPTION 'BOM quantityPerUnit must be finite and greater than zero.'
                USING ERRCODE = '23514';
        END IF;
        IF length(coalesce(v_note, '')) > 2000 THEN
            RAISE EXCEPTION 'BOM line notes exceed 2000 characters.' USING ERRCODE = '22023';
        END IF;

        SELECT m.canonical_unit_id
        INTO v_canonical_unit_id
        FROM public.materials m
        WHERE m.id = v_material_id
          AND m.is_active = true;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'BOM material does not exist or is inactive.'
                USING ERRCODE = '23503';
        END IF;

        PERFORM 1 FROM public.units u WHERE u.id = v_unit_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'BOM unit does not exist.' USING ERRCODE = '23503';
        END IF;

        PERFORM public.fn_resolve_material_conversion(
            v_material_id, v_unit_id, v_canonical_unit_id
        );

        INSERT INTO public.bom_lines (
            bom_id, material_id, quantity_per_unit, unit_id, is_optional, notes
        ) VALUES (
            p_bom_id, v_material_id, v_quantity, v_unit_id, v_optional, v_note
        );
        v_count := v_count + 1;
    END LOOP;

    RETURN v_count;
END;
$$;
REVOKE ALL ON FUNCTION public.fn_insert_bom_lines(uuid, jsonb)
    FROM PUBLIC, anon, authenticated;

-- Insert a custom recipe directly into its job's immutable specification
-- snapshot. A custom recipe has no source BOM/version and must never be
-- silently represented as master-derived.
CREATE OR REPLACE FUNCTION public.fn_insert_custom_snapshot_lines(
    p_snapshot_id uuid,
    p_lines jsonb
)
RETURNS integer
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
    v_line jsonb;
    v_material_id uuid;
    v_unit_id uuid;
    v_canonical_unit_id uuid;
    v_quantity numeric;
    v_optional boolean;
    v_note text;
    v_conversion jsonb;
    v_factor numeric;
    v_direction text;
    v_canonical_quantity numeric;
    v_count integer := 0;
BEGIN
    IF jsonb_typeof(p_lines) IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'Custom BOM lines must be a JSON array.' USING ERRCODE = '22023';
    END IF;
    IF jsonb_array_length(p_lines) < 1 OR jsonb_array_length(p_lines) > 250 THEN
        RAISE EXCEPTION 'A custom BOM must contain between 1 and 250 lines.' USING ERRCODE = '22023';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(p_lines) AS item(value)
        GROUP BY item.value->>'materialId'
        HAVING count(*) > 1
    ) THEN
        RAISE EXCEPTION 'A material may appear only once in a custom BOM.' USING ERRCODE = '23505';
    END IF;

    FOR v_line IN
        SELECT item.value
        FROM jsonb_array_elements(p_lines) AS item(value)
    LOOP
        IF nullif(v_line->>'materialId', '') IS NULL
           OR nullif(v_line->>'quantityPerUnit', '') IS NULL
           OR nullif(v_line->>'unitId', '') IS NULL THEN
            RAISE EXCEPTION 'Each custom BOM line requires materialId, quantityPerUnit and unitId.'
                USING ERRCODE = '22023';
        END IF;

        v_material_id := (v_line->>'materialId')::uuid;
        v_unit_id := (v_line->>'unitId')::uuid;
        v_quantity := (v_line->>'quantityPerUnit')::numeric;
        v_optional := coalesce((v_line->>'isOptional')::boolean, false);
        v_note := nullif(trim(coalesce(v_line->>'applicationNotes', '')), '');

        IF v_quantity IS NULL OR v_quantity::text IN ('NaN', 'Infinity', '-Infinity')
           OR v_quantity <= 0 THEN
            RAISE EXCEPTION 'Custom BOM quantityPerUnit must be finite and greater than zero.'
                USING ERRCODE = '23514';
        END IF;
        IF length(coalesce(v_note, '')) > 2000 THEN
            RAISE EXCEPTION 'Custom BOM line notes exceed 2000 characters.' USING ERRCODE = '22023';
        END IF;

        SELECT m.canonical_unit_id
        INTO v_canonical_unit_id
        FROM public.materials m
        WHERE m.id = v_material_id
          AND m.is_active = true;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Custom BOM material does not exist or is inactive.'
                USING ERRCODE = '23503';
        END IF;
        PERFORM 1 FROM public.units u WHERE u.id = v_unit_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Custom BOM unit does not exist.' USING ERRCODE = '23503';
        END IF;

        v_conversion := public.fn_resolve_material_conversion(
            v_material_id, v_unit_id, v_canonical_unit_id
        );
        v_factor := (v_conversion->>'factor')::numeric;
        v_direction := v_conversion->>'direction';
        v_canonical_quantity := CASE v_direction
            WHEN 'MULTIPLY' THEN v_quantity * v_factor
            WHEN 'DIVIDE' THEN v_quantity / v_factor
            ELSE v_quantity
        END;
        IF v_canonical_quantity IS NULL OR v_canonical_quantity <= 0
           OR v_canonical_quantity::text IN ('NaN', 'Infinity', '-Infinity') THEN
            RAISE EXCEPTION 'Custom BOM normalized quantity is invalid.' USING ERRCODE = '23514';
        END IF;

        INSERT INTO public.packing_job_bom_snapshot_lines (
            snapshot_id, material_id, quantity_per_unit, unit_id,
            canonical_qty_per_unit, canonical_unit_id,
            conversion_rule_id, conversion_factor_frozen, conversion_direction,
            conversion_type, is_optional, notes
        ) VALUES (
            p_snapshot_id, v_material_id, v_quantity, v_unit_id,
            v_canonical_quantity, v_canonical_unit_id,
            nullif(v_conversion->>'rule_id', 'null')::uuid,
            v_factor, v_direction, v_conversion->>'conversion_type',
            v_optional, v_note
        );
        v_count := v_count + 1;
    END LOOP;

    RETURN v_count;
END;
$$;
REVOKE ALL ON FUNCTION public.fn_insert_custom_snapshot_lines(uuid, jsonb)
    FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.fn_packing_job_json(p_job_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
    v_job public.packing_jobs;
    v_snapshot public.packing_job_bom_snapshots;
    v_snapshot_lines jsonb := '[]'::jsonb;
    v_snapshot_json jsonb;
BEGIN
    SELECT * INTO v_job FROM public.packing_jobs WHERE id = p_job_id;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    SELECT * INTO v_snapshot
    FROM public.packing_job_bom_snapshots
    WHERE packing_job_id = p_job_id;

    IF FOUND THEN
        SELECT coalesce(
            jsonb_agg(
                jsonb_build_object(
                    'materialId', sl.material_id,
                    'quantityPerUnit', sl.quantity_per_unit,
                    'unitId', sl.unit_id,
                    'canonicalQuantityPerUnit', sl.canonical_qty_per_unit,
                    'canonicalUnitId', sl.canonical_unit_id,
                    'conversionRuleId', sl.conversion_rule_id,
                    'conversionFactorFrozen', sl.conversion_factor_frozen,
                    'conversionDirection', sl.conversion_direction,
                    'conversionClassification', sl.conversion_type,
                    'isOptional', sl.is_optional,
                    'applicationNotes', sl.notes
                ) ORDER BY sl.material_id
            ),
            '[]'::jsonb
        )
        INTO v_snapshot_lines
        FROM public.packing_job_bom_snapshot_lines sl
        WHERE sl.snapshot_id = v_snapshot.id;

        v_snapshot_json := jsonb_build_object(
            'id', v_snapshot.id,
            'sourceBomId', v_snapshot.source_bom_id,
            'bomVersion', v_snapshot.bom_version,
            'isCustomized', v_snapshot.is_customized,
            'customizationNotes', v_snapshot.customization_notes,
            'frozenAt', v_snapshot.frozen_at,
            'lines', v_snapshot_lines
        );
    ELSE
        v_snapshot_json := NULL;
    END IF;

    RETURN jsonb_build_object(
        'id', v_job.id,
        'jobCode', v_job.job_code,
        'dailyPlanId', v_job.daily_plan_id,
        'partyId', v_job.party_id,
        'productId', v_job.product_id,
        'masterBomId', v_job.master_bom_id,
        'isCustomized', v_job.master_bom_id IS NULL,
        'assignedWorkerId', v_job.assigned_worker_id,
        'status', v_job.status,
        'priority', v_job.priority,
        'quantityStatus', jsonb_build_object(
            'originalPlannedQuantity', v_job.original_planned_quantity,
            'currentRevisedQuantity', v_job.current_revised_quantity,
            'completedQuantity', v_job.completed_quantity,
            'pendingQuantity', v_job.pending_quantity,
            'cancelledQuantity', v_job.cancelled_quantity
        ),
        'snapshot', v_snapshot_json
    );
END;
$$;
REVOKE ALL ON FUNCTION public.fn_packing_job_json(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.fn_daily_plan_json(p_plan_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
    v_plan public.daily_plans;
    v_jobs jsonb;
BEGIN
    SELECT * INTO v_plan FROM public.daily_plans WHERE id = p_plan_id;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    SELECT coalesce(
        jsonb_agg(public.fn_packing_job_json(pj.id) ORDER BY pj.priority, pj.created_at, pj.id),
        '[]'::jsonb
    )
    INTO v_jobs
    FROM public.packing_jobs pj
    WHERE pj.daily_plan_id = p_plan_id;

    RETURN jsonb_build_object(
        'id', v_plan.id,
        'planNumber', v_plan.plan_number,
        'planDate', v_plan.plan_date,
        'shiftCode', v_plan.shift_code,
        'status', v_plan.status,
        'notes', v_plan.notes,
        'releasedAt', v_plan.released_at,
        'jobs', v_jobs
    );
END;
$$;
REVOKE ALL ON FUNCTION public.fn_daily_plan_json(uuid) FROM PUBLIC, anon, authenticated;

-- =============================================================================
-- 1. Create initial master BOM
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_create_bom(
    p_product_id uuid,
    p_party_id uuid,
    p_packing_variant_name text,
    p_version_notes text,
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
    v_bom public.boms;
    v_response jsonb;
BEGIN
    IF v_actor_id IS NULL THEN
        RAISE EXCEPTION 'Valid authentication is required.' USING ERRCODE = '42501';
    END IF;
    IF v_role NOT IN ('ADMIN', 'PLANNER') THEN
        RAISE EXCEPTION 'Only planners and administrators can create BOMs.' USING ERRCODE = '42501';
    END IF;
    IF p_product_id IS NULL OR length(trim(coalesce(p_packing_variant_name, ''))) = 0
       OR length(trim(p_packing_variant_name)) > 120 THEN
        RAISE EXCEPTION 'Product and a packing variant name of 1-120 characters are required.'
            USING ERRCODE = '22023';
    END IF;
    IF length(coalesce(p_version_notes, '')) > 2000 THEN
        RAISE EXCEPTION 'BOM version notes exceed 2000 characters.' USING ERRCODE = '22023';
    END IF;
    PERFORM 1 FROM public.products WHERE id = p_product_id AND is_active = true;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'BOM product does not exist or is inactive.' USING ERRCODE = '23503';
    END IF;
    IF p_party_id IS NOT NULL THEN
        PERFORM 1 FROM public.parties WHERE id = p_party_id AND is_active = true;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'BOM party does not exist or is inactive.' USING ERRCODE = '23503';
        END IF;
    END IF;

    PERFORM public.fn_lock_bom_recipe(p_product_id, p_party_id, p_packing_variant_name);

    IF EXISTS (
        SELECT 1 FROM public.boms b
        WHERE b.product_id = p_product_id
          AND b.party_id IS NOT DISTINCT FROM p_party_id
          AND lower(b.packing_variant_name) = lower(trim(p_packing_variant_name))
    ) THEN
        RAISE EXCEPTION 'This BOM recipe already has a version. Use the new-version operation.'
            USING ERRCODE = '23505';
    END IF;

    PERFORM public.fn_acquire_idempotency(
        p_idempotency_key, 'POST:/api/v1/boms', p_request_hash, v_actor_id
    ) INTO v_response;
    IF v_response->>'action' = 'REPLAY' THEN
        RETURN v_response->'body';
    ELSIF v_response->>'action' = 'EXPIRED' THEN
        RAISE EXCEPTION 'IDEMPOTENCY_RESPONSE_EXPIRED: %', v_response USING ERRCODE = '23514';
    END IF;

    INSERT INTO public.boms (
        bom_code, product_id, party_id, packing_variant_name,
        version_number, status, notes, created_by
    ) VALUES (
        'BOM-' || to_char(CURRENT_DATE, 'YYYYMMDD') || '-' || upper(substr(gen_random_uuid()::text, 1, 8)),
        p_product_id, p_party_id, trim(p_packing_variant_name),
        1, 'DRAFT', nullif(trim(coalesce(p_version_notes, '')), ''), v_actor_id
    )
    RETURNING * INTO v_bom;

    PERFORM public.fn_insert_bom_lines(v_bom.id, p_lines);

    v_response := public.fn_bom_json(v_bom.id);
    PERFORM public.fn_complete_idempotency(p_idempotency_key, 'BOM', v_bom.id, 201, v_response);
    RETURN v_response;
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_create_bom(uuid, uuid, text, text, jsonb, text, text)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_create_bom(uuid, uuid, text, text, jsonb, text, text)
    TO authenticated;

-- =============================================================================
-- 2. Create a draft version of an existing BOM recipe
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_create_bom_version(
    p_source_bom_id uuid,
    p_revision_reason text,
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
    v_source public.boms;
    v_bom public.boms;
    v_next_version integer;
    v_response jsonb;
BEGIN
    IF v_actor_id IS NULL THEN
        RAISE EXCEPTION 'Valid authentication is required.' USING ERRCODE = '42501';
    END IF;
    IF v_role NOT IN ('ADMIN', 'PLANNER') THEN
        RAISE EXCEPTION 'Only planners and administrators can create BOM versions.' USING ERRCODE = '42501';
    END IF;
    IF p_revision_reason IS NULL OR length(trim(p_revision_reason)) < 3
       OR length(trim(p_revision_reason)) > 2000 THEN
        RAISE EXCEPTION 'A revision reason of 3-2000 characters is required.' USING ERRCODE = '22023';
    END IF;

    SELECT * INTO v_source FROM public.boms WHERE id = p_source_bom_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Source BOM was not found.' USING ERRCODE = 'P0002';
    END IF;

    PERFORM public.fn_lock_bom_recipe(
        v_source.product_id, v_source.party_id, v_source.packing_variant_name
    );
    SELECT * INTO v_source FROM public.boms WHERE id = p_source_bom_id FOR UPDATE;
    IF NOT FOUND OR v_source.status = 'ARCHIVED' THEN
        RAISE EXCEPTION 'Source BOM is missing or archived.' USING ERRCODE = '23514';
    END IF;

    v_response := public.fn_acquire_idempotency(
        p_idempotency_key,
        'POST:/api/v1/boms/<bom_id>/new-version',
        p_request_hash,
        v_actor_id
    );
    IF v_response->>'action' = 'REPLAY' THEN
        RETURN v_response->'body';
    ELSIF v_response->>'action' = 'EXPIRED' THEN
        RAISE EXCEPTION 'IDEMPOTENCY_RESPONSE_EXPIRED: %', v_response USING ERRCODE = '23514';
    END IF;

    SELECT coalesce(max(b.version_number), 0) + 1
    INTO v_next_version
    FROM public.boms b
    WHERE b.product_id = v_source.product_id
      AND b.party_id IS NOT DISTINCT FROM v_source.party_id
      AND lower(b.packing_variant_name) = lower(v_source.packing_variant_name);

    INSERT INTO public.boms (
        bom_code, product_id, party_id, packing_variant_name,
        version_number, status, notes, created_by
    ) VALUES (
        'BOM-' || to_char(CURRENT_DATE, 'YYYYMMDD') || '-' || upper(substr(gen_random_uuid()::text, 1, 8)),
        v_source.product_id, v_source.party_id, v_source.packing_variant_name,
        v_next_version, 'DRAFT', trim(p_revision_reason), v_actor_id
    )
    RETURNING * INTO v_bom;

    PERFORM public.fn_insert_bom_lines(v_bom.id, p_lines);

    INSERT INTO public.bom_revision_events (
        bom_id, previous_bom_id, revision_reason, changed_by
    ) VALUES (
        v_bom.id, v_source.id, trim(p_revision_reason), v_actor_id
    );

    v_response := public.fn_bom_json(v_bom.id);
    PERFORM public.fn_complete_idempotency(p_idempotency_key, 'BOM', v_bom.id, 201, v_response);
    RETURN v_response;
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_create_bom_version(uuid, text, jsonb, text, text)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_create_bom_version(uuid, text, jsonb, text, text)
    TO authenticated;

-- =============================================================================
-- 3. Atomically promote a BOM and supersede the previous active version
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_activate_bom_version(
    p_bom_id uuid,
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
    v_bom public.boms;
    v_previous_id uuid;
    v_response jsonb;
BEGIN
    IF v_actor_id IS NULL THEN
        RAISE EXCEPTION 'Valid authentication is required.' USING ERRCODE = '42501';
    END IF;
    IF v_role NOT IN ('ADMIN', 'PLANNER') THEN
        RAISE EXCEPTION 'Only planners and administrators can activate BOM versions.' USING ERRCODE = '42501';
    END IF;

    SELECT * INTO v_bom FROM public.boms WHERE id = p_bom_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'BOM version was not found.' USING ERRCODE = 'P0002';
    END IF;
    PERFORM public.fn_lock_bom_recipe(v_bom.product_id, v_bom.party_id, v_bom.packing_variant_name);

    v_response := public.fn_acquire_idempotency(
        p_idempotency_key,
        'POST:/api/v1/boms/<bom_id>/activate',
        p_request_hash,
        v_actor_id
    );
    IF v_response->>'action' = 'REPLAY' THEN
        RETURN v_response->'body';
    ELSIF v_response->>'action' = 'EXPIRED' THEN
        RAISE EXCEPTION 'IDEMPOTENCY_RESPONSE_EXPIRED: %', v_response USING ERRCODE = '23514';
    END IF;

    SELECT * INTO v_bom FROM public.boms WHERE id = p_bom_id FOR UPDATE;
    IF v_bom.status <> 'DRAFT' THEN
        RAISE EXCEPTION 'Only a draft BOM version can be activated.'
            USING ERRCODE = '23514';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.bom_lines WHERE bom_id = p_bom_id) THEN
        RAISE EXCEPTION 'A BOM requires at least one recipe line before activation.'
            USING ERRCODE = '23514';
    END IF;

    SELECT b.id INTO v_previous_id
    FROM public.boms b
    WHERE b.product_id = v_bom.product_id
      AND b.party_id IS NOT DISTINCT FROM v_bom.party_id
      AND lower(b.packing_variant_name) = lower(v_bom.packing_variant_name)
      AND b.status = 'ACTIVE'
      AND b.id <> p_bom_id
    FOR UPDATE;

    IF v_previous_id IS NOT NULL THEN
        UPDATE public.boms
        SET status = 'SUPERSEDED', updated_at = clock_timestamp()
        WHERE id = v_previous_id;
    END IF;

    UPDATE public.boms
    SET status = 'ACTIVE', updated_at = clock_timestamp()
    WHERE id = p_bom_id;

    INSERT INTO public.bom_revision_events (
        bom_id, previous_bom_id, revision_reason, changed_by
    ) VALUES (
        p_bom_id, v_previous_id,
        CASE WHEN v_previous_id IS NULL
            THEN 'Initial activation'
            ELSE 'Activated version ' || v_bom.version_number::text
        END,
        v_actor_id
    );

    v_response := public.fn_bom_json(p_bom_id);
    PERFORM public.fn_complete_idempotency(p_idempotency_key, 'BOM', p_bom_id, 200, v_response);
    RETURN v_response;
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_activate_bom_version(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_activate_bom_version(uuid, text, text) TO authenticated;

-- =============================================================================
-- 4. Create a daily plan and any number of master-derived/custom jobs atomically
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_create_daily_plan(
    p_plan_date date,
    p_shift_code text,
    p_notes text,
    p_master_derived_jobs jsonb,
    p_custom_jobs jsonb,
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
    v_plan public.daily_plans;
    v_item jsonb;
    v_job public.packing_jobs;
    v_product_id uuid;
    v_party_id uuid;
    v_bom_id uuid;
    v_quantity integer;
    v_job_index integer := 0;
    v_total_jobs integer;
    v_snapshot_id uuid;
    v_snapshot_lines_count integer;
    v_response jsonb;
BEGIN
    IF v_actor_id IS NULL THEN
        RAISE EXCEPTION 'Valid authentication is required.' USING ERRCODE = '42501';
    END IF;
    IF v_role NOT IN ('ADMIN', 'PLANNER') THEN
        RAISE EXCEPTION 'Only planners and administrators can create daily plans.' USING ERRCODE = '42501';
    END IF;
    IF p_plan_date IS NULL OR length(trim(coalesce(p_shift_code, ''))) = 0
       OR length(trim(p_shift_code)) > 30
       OR trim(p_shift_code) !~ '^[A-Za-z0-9_-]+$' THEN
        RAISE EXCEPTION 'Plan date and a shift code using letters, digits, underscore or hyphen are required.'
            USING ERRCODE = '22023';
    END IF;
    IF length(coalesce(p_notes, '')) > 2000 THEN
        RAISE EXCEPTION 'Daily plan notes exceed 2000 characters.' USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(coalesce(p_master_derived_jobs, '[]'::jsonb)) IS DISTINCT FROM 'array'
       OR jsonb_typeof(coalesce(p_custom_jobs, '[]'::jsonb)) IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'Master-derived and custom jobs must both be JSON arrays.' USING ERRCODE = '22023';
    END IF;
    v_total_jobs := jsonb_array_length(coalesce(p_master_derived_jobs, '[]'::jsonb))
        + jsonb_array_length(coalesce(p_custom_jobs, '[]'::jsonb));
    IF v_total_jobs < 1 OR v_total_jobs > 100 THEN
        RAISE EXCEPTION 'A daily plan must contain between 1 and 100 jobs.' USING ERRCODE = '22023';
    END IF;

    PERFORM pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended(
            'phase6:plan:' || p_plan_date::text || '|' || upper(trim(p_shift_code)),
            0
        )
    );

    v_response := public.fn_acquire_idempotency(
        p_idempotency_key, 'POST:/api/v1/daily-plans', p_request_hash, v_actor_id
    );
    IF v_response->>'action' = 'REPLAY' THEN
        RETURN v_response->'body';
    ELSIF v_response->>'action' = 'EXPIRED' THEN
        RAISE EXCEPTION 'IDEMPOTENCY_RESPONSE_EXPIRED: %', v_response USING ERRCODE = '23514';
    END IF;

    INSERT INTO public.daily_plans (
        plan_number, plan_date, shift_code, status, notes, created_by
    ) VALUES (
        'PLAN-' || to_char(p_plan_date, 'YYYYMMDD') || '-' ||
            upper(trim(p_shift_code)) || '-' || upper(substr(gen_random_uuid()::text, 1, 8)),
        p_plan_date, upper(trim(p_shift_code)), 'DRAFT',
        nullif(trim(coalesce(p_notes, '')), ''), v_actor_id
    )
    RETURNING * INTO v_plan;

    -- Master-derived jobs can repeat product/party combinations: each row binds
    -- an explicit masterBomId, so party-specific overrides remain deterministic.
    FOR v_item IN
        SELECT item.value
        FROM jsonb_array_elements(coalesce(p_master_derived_jobs, '[]'::jsonb)) AS item(value)
    LOOP
        IF nullif(v_item->>'partyId', '') IS NULL
           OR nullif(v_item->>'productId', '') IS NULL
           OR nullif(v_item->>'masterBomId', '') IS NULL
           OR nullif(v_item->>'plannedQuantity', '') IS NULL THEN
            RAISE EXCEPTION 'Master-derived jobs require partyId, productId, masterBomId and plannedQuantity.'
                USING ERRCODE = '22023';
        END IF;
        v_party_id := (v_item->>'partyId')::uuid;
        v_product_id := (v_item->>'productId')::uuid;
        v_bom_id := (v_item->>'masterBomId')::uuid;
        v_quantity := (v_item->>'plannedQuantity')::integer;
        IF v_quantity <= 0 THEN
            RAISE EXCEPTION 'Planned quantity must be a positive integer.' USING ERRCODE = '23514';
        END IF;

        PERFORM 1 FROM public.parties WHERE id = v_party_id AND is_active = true;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Daily plan party does not exist or is inactive.' USING ERRCODE = '23503';
        END IF;
        PERFORM 1 FROM public.products WHERE id = v_product_id AND is_active = true;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Daily plan product does not exist or is inactive.' USING ERRCODE = '23503';
        END IF;
        PERFORM 1
        FROM public.boms b
        WHERE b.id = v_bom_id
          AND b.product_id = v_product_id
          AND (b.party_id IS NULL OR b.party_id = v_party_id)
          AND b.status = 'ACTIVE';
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Selected master BOM is not active for the requested product and party.'
                USING ERRCODE = '23514';
        END IF;

        v_job_index := v_job_index + 1;
        INSERT INTO public.packing_jobs (
            daily_plan_id, job_code, party_id, product_id, master_bom_id,
            original_planned_quantity, current_revised_quantity, completed_quantity,
            pending_quantity, cancelled_quantity, status, priority
        ) VALUES (
            v_plan.id,
            'JOB-' || to_char(p_plan_date, 'YYYYMMDD') || '-' ||
                upper(substr(gen_random_uuid()::text, 1, 8)),
            v_party_id, v_product_id, v_bom_id,
            v_quantity, v_quantity, 0, v_quantity, 0, 'DRAFT', v_job_index
        )
        RETURNING * INTO v_job;

        INSERT INTO public.packing_job_events (
            packing_job_id, event_type, from_status, to_status, payload, triggered_by
        ) VALUES (
            v_job.id, 'JOB_CREATED', 'DRAFT', 'DRAFT',
            jsonb_build_object('origin', 'MASTER_BOM', 'masterBomId', v_bom_id), v_actor_id
        );
    END LOOP;

    -- Custom recipes are saved as source-less snapshots. Their original and
    -- canonical units plus exact/estimated conversion provenance are frozen
    -- together so a later master BOM change can never alter this job.
    FOR v_item IN
        SELECT item.value
        FROM jsonb_array_elements(coalesce(p_custom_jobs, '[]'::jsonb)) AS item(value)
    LOOP
        IF nullif(v_item->>'partyId', '') IS NULL
           OR nullif(v_item->>'productId', '') IS NULL
           OR nullif(v_item->>'plannedQuantity', '') IS NULL
           OR jsonb_typeof(v_item->'customBomLines') IS DISTINCT FROM 'array' THEN
            RAISE EXCEPTION 'Custom jobs require partyId, productId, plannedQuantity and customBomLines.'
                USING ERRCODE = '22023';
        END IF;
        v_party_id := (v_item->>'partyId')::uuid;
        v_product_id := (v_item->>'productId')::uuid;
        v_quantity := (v_item->>'plannedQuantity')::integer;
        IF v_quantity <= 0 THEN
            RAISE EXCEPTION 'Planned quantity must be a positive integer.' USING ERRCODE = '23514';
        END IF;
        PERFORM 1 FROM public.parties WHERE id = v_party_id AND is_active = true;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Custom job party does not exist or is inactive.' USING ERRCODE = '23503';
        END IF;
        PERFORM 1 FROM public.products WHERE id = v_product_id AND is_active = true;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Custom job product does not exist or is inactive.' USING ERRCODE = '23503';
        END IF;

        v_job_index := v_job_index + 1;
        INSERT INTO public.packing_jobs (
            daily_plan_id, job_code, party_id, product_id, master_bom_id,
            original_planned_quantity, current_revised_quantity, completed_quantity,
            pending_quantity, cancelled_quantity, status, priority
        ) VALUES (
            v_plan.id,
            'JOB-' || to_char(p_plan_date, 'YYYYMMDD') || '-' ||
                upper(substr(gen_random_uuid()::text, 1, 8)),
            v_party_id, v_product_id, NULL,
            v_quantity, v_quantity, 0, v_quantity, 0, 'DRAFT', v_job_index
        )
        RETURNING * INTO v_job;

        INSERT INTO public.packing_job_bom_snapshots (
            packing_job_id, source_bom_id, bom_version, is_customized,
            customization_notes, frozen_by
        ) VALUES (
            v_job.id, NULL, NULL, true,
            nullif(trim(coalesce(v_item->>'customizationNotes', '')), ''),
            v_actor_id
        )
        RETURNING id INTO v_snapshot_id;

        v_snapshot_lines_count := public.fn_insert_custom_snapshot_lines(
            v_snapshot_id, v_item->'customBomLines'
        );
        IF v_snapshot_lines_count < 1 THEN
            RAISE EXCEPTION 'Custom jobs must contain at least one frozen BOM line.' USING ERRCODE = '23514';
        END IF;

        INSERT INTO public.packing_job_events (
            packing_job_id, event_type, from_status, to_status, payload, triggered_by
        ) VALUES (
            v_job.id, 'JOB_CREATED', 'DRAFT', 'DRAFT',
            jsonb_build_object('origin', 'CUSTOM_BOM', 'snapshotId', v_snapshot_id), v_actor_id
        );
    END LOOP;

    v_response := public.fn_daily_plan_json(v_plan.id);
    PERFORM public.fn_complete_idempotency(p_idempotency_key, 'DAILY_PLAN', v_plan.id, 201, v_response);
    RETURN v_response;
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_create_daily_plan(date, text, text, jsonb, jsonb, text, text)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_create_daily_plan(date, text, text, jsonb, jsonb, text, text)
    TO authenticated;

-- =============================================================================
-- 5. Release a daily plan: freeze master BOMs and reserve all required stock
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_release_daily_plan(
    p_daily_plan_id uuid,
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
    v_plan public.daily_plans;
    v_job public.packing_jobs;
    v_bom public.boms;
    v_bom_line record;
    v_snapshot public.packing_job_bom_snapshots;
    v_snapshot_id uuid;
    v_conversion jsonb;
    v_factor numeric;
    v_direction text;
    v_canonical_quantity numeric;
    v_req record;
    v_lock record;
    v_balance record;
    v_need numeric;
    v_take numeric;
    v_remaining numeric;
    v_response jsonb;
BEGIN
    IF v_actor_id IS NULL THEN
        RAISE EXCEPTION 'Valid authentication is required.' USING ERRCODE = '42501';
    END IF;
    IF v_role NOT IN ('ADMIN', 'PLANNER') THEN
        RAISE EXCEPTION 'Only planners and administrators can release daily plans.' USING ERRCODE = '42501';
    END IF;

    v_response := public.fn_acquire_idempotency(
        p_idempotency_key,
        'POST:/api/v1/daily-plans/<plan_id>/release',
        p_request_hash,
        v_actor_id
    );
    IF v_response->>'action' = 'REPLAY' THEN
        RETURN v_response->'body';
    ELSIF v_response->>'action' = 'EXPIRED' THEN
        RAISE EXCEPTION 'IDEMPOTENCY_RESPONSE_EXPIRED: %', v_response USING ERRCODE = '23514';
    END IF;

    SELECT * INTO v_plan FROM public.daily_plans
    WHERE id = p_daily_plan_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Daily plan was not found.' USING ERRCODE = 'P0002';
    END IF;
    IF v_plan.status <> 'DRAFT' THEN
        RAISE EXCEPTION 'Only a draft daily plan can be released.' USING ERRCODE = '23514';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.packing_jobs pj
        WHERE pj.daily_plan_id = p_daily_plan_id AND pj.status = 'DRAFT'
    ) THEN
        RAISE EXCEPTION 'A daily plan requires at least one draft job before release.'
            USING ERRCODE = '23514';
    END IF;

    -- Build immutable snapshots for master-derived jobs. Custom job snapshots
    -- were persisted when the draft plan was created and are validated below.
    FOR v_job IN
        SELECT pj.*
        FROM public.packing_jobs pj
        WHERE pj.daily_plan_id = p_daily_plan_id AND pj.status = 'DRAFT'
        ORDER BY pj.job_code, pj.id
        FOR UPDATE
    LOOP
        SELECT * INTO v_snapshot
        FROM public.packing_job_bom_snapshots
        WHERE packing_job_id = v_job.id;
        IF FOUND THEN
            IF v_job.master_bom_id IS NOT NULL OR v_snapshot.is_customized IS DISTINCT FROM true THEN
                RAISE EXCEPTION 'Job has an inconsistent existing BOM snapshot.'
                    USING ERRCODE = '23514';
            END IF;
            IF NOT EXISTS (
                SELECT 1 FROM public.packing_job_bom_snapshot_lines sl
                WHERE sl.snapshot_id = v_snapshot.id
            ) THEN
                RAISE EXCEPTION 'Custom job has no frozen recipe lines.' USING ERRCODE = '23514';
            END IF;
            CONTINUE;
        END IF;

        IF v_job.master_bom_id IS NULL THEN
            RAISE EXCEPTION 'A source-less custom job requires a frozen custom BOM snapshot.'
                USING ERRCODE = '23514';
        END IF;

        SELECT * INTO v_bom
        FROM public.boms b
        WHERE b.id = v_job.master_bom_id
          AND b.product_id = v_job.product_id
          AND (b.party_id IS NULL OR b.party_id = v_job.party_id)
        FOR SHARE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'The selected master BOM does not match this job.' USING ERRCODE = '23514';
        END IF;

        INSERT INTO public.packing_job_bom_snapshots (
            packing_job_id, source_bom_id, bom_version, is_customized, frozen_by
        ) VALUES (
            v_job.id, v_bom.id, v_bom.version_number, false, v_actor_id
        )
        RETURNING id INTO v_snapshot_id;

        FOR v_bom_line IN
            SELECT bl.*, m.canonical_unit_id
            FROM public.bom_lines bl
            JOIN public.materials m ON m.id = bl.material_id AND m.is_active = true
            WHERE bl.bom_id = v_bom.id
            ORDER BY bl.material_id
        LOOP
            v_conversion := public.fn_resolve_material_conversion(
                v_bom_line.material_id, v_bom_line.unit_id, v_bom_line.canonical_unit_id
            );
            v_factor := (v_conversion->>'factor')::numeric;
            v_direction := v_conversion->>'direction';
            v_canonical_quantity := CASE v_direction
                WHEN 'MULTIPLY' THEN v_bom_line.quantity_per_unit * v_factor
                WHEN 'DIVIDE' THEN v_bom_line.quantity_per_unit / v_factor
                ELSE v_bom_line.quantity_per_unit
            END;
            IF v_canonical_quantity IS NULL OR v_canonical_quantity <= 0
               OR v_canonical_quantity::text IN ('NaN', 'Infinity', '-Infinity') THEN
                RAISE EXCEPTION 'Resolved BOM canonical quantity is invalid.' USING ERRCODE = '23514';
            END IF;

            INSERT INTO public.packing_job_bom_snapshot_lines (
                snapshot_id, material_id, quantity_per_unit, unit_id,
                canonical_qty_per_unit, canonical_unit_id, conversion_rule_id,
                conversion_factor_frozen, conversion_direction, conversion_type,
                is_optional, notes
            ) VALUES (
                v_snapshot_id, v_bom_line.material_id, v_bom_line.quantity_per_unit,
                v_bom_line.unit_id, v_canonical_quantity, v_bom_line.canonical_unit_id,
                nullif(v_conversion->>'rule_id', 'null')::uuid, v_factor, v_direction,
                v_conversion->>'conversion_type', v_bom_line.is_optional, v_bom_line.notes
            );
        END LOOP;

        IF NOT EXISTS (
            SELECT 1 FROM public.packing_job_bom_snapshot_lines sl
            WHERE sl.snapshot_id = v_snapshot_id
        ) THEN
            RAISE EXCEPTION 'Master BOM cannot be released because it contains no active material lines.'
                USING ERRCODE = '23514';
        END IF;
    END LOOP;

    -- Lock every usable material/location pair in one global order before
    -- checking ATP. Stock movement functions use these same advisory keys.
    FOR v_lock IN
        SELECT DISTINCT sl.material_id, l.id AS location_id
        FROM public.packing_jobs pj
        JOIN public.packing_job_bom_snapshots s ON s.packing_job_id = pj.id
        JOIN public.packing_job_bom_snapshot_lines sl ON sl.snapshot_id = s.id
        CROSS JOIN public.locations l
        WHERE pj.daily_plan_id = p_daily_plan_id
          AND pj.status = 'DRAFT'
          AND sl.is_optional = false
          AND l.is_active = true
          AND l.is_leaf = true
          AND l.location_type IN ('STORE_SHELF', 'SHOP_FLOOR_BUFFER')
        ORDER BY sl.material_id, l.id
    LOOP
        PERFORM pg_catalog.pg_advisory_xact_lock(
            pg_catalog.hashtextextended(v_lock.material_id::text || ':' || v_lock.location_id::text, 0)
        );
    END LOOP;

    -- Allocate each required material from active leaf stock locations after
    -- subtracting reservations held by every other released job. Inserting
    -- reservations is part of this same transaction; any shortfall rolls the
    -- whole release back and leaves the plan/snapshots/jobs untouched.
    FOR v_req IN
        SELECT pj.id AS job_id, pj.pending_quantity, sl.material_id,
               sl.canonical_qty_per_unit, sl.canonical_unit_id
        FROM public.packing_jobs pj
        JOIN public.packing_job_bom_snapshots s ON s.packing_job_id = pj.id
        JOIN public.packing_job_bom_snapshot_lines sl ON sl.snapshot_id = s.id
        WHERE pj.daily_plan_id = p_daily_plan_id
          AND pj.status = 'DRAFT'
          AND sl.is_optional = false
        ORDER BY pj.job_code, sl.material_id
    LOOP
        v_need := v_req.canonical_qty_per_unit * v_req.pending_quantity;
        v_remaining := v_need;

        FOR v_balance IN
            SELECT mb.location_id,
                   greatest(
                       mb.on_hand_quantity - coalesce((
                           SELECT sum(sr.reserved_quantity)
                           FROM public.stock_reservations sr
                           WHERE sr.material_id = mb.material_id
                             AND sr.location_id = mb.location_id
                             AND sr.status = 'ACTIVE'
                       ), 0),
                       0
                   ) AS available_quantity
            FROM public.material_location_balances mb
            JOIN public.locations l ON l.id = mb.location_id
            WHERE mb.material_id = v_req.material_id
              AND l.is_active = true AND l.is_leaf = true
              AND l.location_type IN ('STORE_SHELF', 'SHOP_FLOOR_BUFFER')
            ORDER BY mb.location_id
            FOR UPDATE OF mb
        LOOP
            IF v_remaining <= 0 THEN
                EXIT;
            END IF;
            IF v_balance.available_quantity <= 0 THEN
                CONTINUE;
            END IF;

            v_take := least(v_remaining, v_balance.available_quantity);
            INSERT INTO public.stock_reservations (
                packing_job_id, material_id, location_id, canonical_unit_id,
                reserved_quantity, status
            ) VALUES (
                v_req.job_id, v_req.material_id, v_balance.location_id,
                v_req.canonical_unit_id, v_take, 'ACTIVE'
            );
            v_remaining := v_remaining - v_take;
        END LOOP;

        IF v_remaining > 0 THEN
            RAISE EXCEPTION 'Insufficient unreserved stock for material %: additional % canonical units required.',
                v_req.material_id, v_remaining
                USING ERRCODE = '23514';
        END IF;
    END LOOP;

    UPDATE public.packing_jobs
    SET status = 'RELEASED', updated_at = clock_timestamp()
    WHERE daily_plan_id = p_daily_plan_id AND status = 'DRAFT';

    INSERT INTO public.packing_job_events (
        packing_job_id, event_type, from_status, to_status, payload, triggered_by
    )
    SELECT pj.id, 'JOB_RELEASED', 'DRAFT', 'RELEASED',
           jsonb_build_object('dailyPlanId', p_daily_plan_id), v_actor_id
    FROM public.packing_jobs pj
    WHERE pj.daily_plan_id = p_daily_plan_id AND pj.status = 'RELEASED';

    UPDATE public.daily_plans
    SET status = 'RELEASED', released_at = clock_timestamp(),
        released_by = v_actor_id, updated_at = clock_timestamp()
    WHERE id = p_daily_plan_id;

    v_response := public.fn_daily_plan_json(p_daily_plan_id);
    PERFORM public.fn_complete_idempotency(p_idempotency_key, 'DAILY_PLAN', p_daily_plan_id, 200, v_response);
    RETURN v_response;
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_release_daily_plan(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_release_daily_plan(uuid, text, text) TO authenticated;

-- =============================================================================
-- 6. Reconcile reservations when a released job quantity changes
-- =============================================================================
CREATE OR REPLACE FUNCTION public.fn_adjust_job_reservations(
    p_packing_job_id uuid,
    p_pending_unit_delta integer
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_line record;
    v_lock record;
    v_balance record;
    v_reservation record;
    v_need numeric;
    v_remaining numeric;
    v_take numeric;
    v_available numeric;
    v_existing_id uuid;
BEGIN
    IF p_pending_unit_delta = 0 THEN
        RETURN;
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM public.packing_job_bom_snapshots s
        WHERE s.packing_job_id = p_packing_job_id
    ) THEN
        -- Draft jobs without a frozen recipe do not own reservations yet.
        RETURN;
    END IF;

    IF p_pending_unit_delta < 0 THEN
        FOR v_lock IN
            SELECT DISTINCT sr.material_id, sr.location_id
            FROM public.stock_reservations sr
            WHERE sr.packing_job_id = p_packing_job_id AND sr.status = 'ACTIVE'
            ORDER BY sr.material_id, sr.location_id
        LOOP
            PERFORM pg_catalog.pg_advisory_xact_lock(
                pg_catalog.hashtextextended(v_lock.material_id::text || ':' || v_lock.location_id::text, 0)
            );
        END LOOP;

        FOR v_line IN
            SELECT sl.material_id, sl.canonical_qty_per_unit
            FROM public.packing_job_bom_snapshot_lines sl
            JOIN public.packing_job_bom_snapshots s ON s.id = sl.snapshot_id
            WHERE s.packing_job_id = p_packing_job_id AND sl.is_optional = false
            ORDER BY sl.material_id
        LOOP
            v_remaining := abs(p_pending_unit_delta) * v_line.canonical_qty_per_unit;

            FOR v_reservation IN
                SELECT sr.id, sr.reserved_quantity
                FROM public.stock_reservations sr
                WHERE sr.packing_job_id = p_packing_job_id
                  AND sr.material_id = v_line.material_id
                  AND sr.status = 'ACTIVE'
                ORDER BY sr.location_id DESC, sr.created_at DESC, sr.id DESC
                FOR UPDATE
            LOOP
                EXIT WHEN v_remaining <= 0;
                v_take := least(v_remaining, v_reservation.reserved_quantity);
                UPDATE public.stock_reservations
                SET reserved_quantity = reserved_quantity - v_take,
                    status = CASE WHEN reserved_quantity - v_take <= 0 THEN 'RELEASED' ELSE 'ACTIVE' END,
                    updated_at = clock_timestamp()
                WHERE id = v_reservation.id;
                v_remaining := v_remaining - v_take;
            END LOOP;
            -- Any remaining delta represents material already issued to custody;
            -- this routine releases only stock that is still reserved at storage.
        END LOOP;
        RETURN;
    END IF;

    -- Increased demand needs additional stock. Lock all possible location keys
    -- before reading balances, so a transfer and a plan revision serialize.
    FOR v_lock IN
        SELECT DISTINCT sl.material_id, l.id AS location_id
        FROM public.packing_job_bom_snapshot_lines sl
        JOIN public.packing_job_bom_snapshots s ON s.id = sl.snapshot_id
        CROSS JOIN public.locations l
        WHERE s.packing_job_id = p_packing_job_id
          AND sl.is_optional = false
          AND l.is_active = true AND l.is_leaf = true
          AND l.location_type IN ('STORE_SHELF', 'SHOP_FLOOR_BUFFER')
        ORDER BY sl.material_id, l.id
    LOOP
        PERFORM pg_catalog.pg_advisory_xact_lock(
            pg_catalog.hashtextextended(v_lock.material_id::text || ':' || v_lock.location_id::text, 0)
        );
    END LOOP;

    FOR v_line IN
        SELECT sl.material_id, sl.canonical_qty_per_unit, sl.canonical_unit_id
        FROM public.packing_job_bom_snapshot_lines sl
        JOIN public.packing_job_bom_snapshots s ON s.id = sl.snapshot_id
        WHERE s.packing_job_id = p_packing_job_id AND sl.is_optional = false
        ORDER BY sl.material_id
    LOOP
        v_remaining := p_pending_unit_delta * v_line.canonical_qty_per_unit;

        FOR v_balance IN
            SELECT mb.location_id,
                   greatest(
                       mb.on_hand_quantity - coalesce((
                           SELECT sum(sr.reserved_quantity)
                           FROM public.stock_reservations sr
                           WHERE sr.material_id = mb.material_id
                             AND sr.location_id = mb.location_id
                             AND sr.status = 'ACTIVE'
                       ), 0),
                       0
                   ) AS available_quantity
            FROM public.material_location_balances mb
            JOIN public.locations l ON l.id = mb.location_id
            WHERE mb.material_id = v_line.material_id
              AND l.is_active = true AND l.is_leaf = true
              AND l.location_type IN ('STORE_SHELF', 'SHOP_FLOOR_BUFFER')
            ORDER BY mb.location_id
            FOR UPDATE OF mb
        LOOP
            EXIT WHEN v_remaining <= 0;
            IF v_balance.available_quantity <= 0 THEN
                CONTINUE;
            END IF;

            v_take := least(v_remaining, v_balance.available_quantity);
            SELECT sr.id INTO v_existing_id
            FROM public.stock_reservations sr
            WHERE sr.packing_job_id = p_packing_job_id
              AND sr.material_id = v_line.material_id
              AND sr.location_id = v_balance.location_id
              AND sr.status = 'ACTIVE'
            ORDER BY sr.created_at, sr.id
            LIMIT 1
            FOR UPDATE;

            IF FOUND THEN
                UPDATE public.stock_reservations
                SET reserved_quantity = reserved_quantity + v_take,
                    updated_at = clock_timestamp()
                WHERE id = v_existing_id;
            ELSE
                INSERT INTO public.stock_reservations (
                    packing_job_id, material_id, location_id, canonical_unit_id,
                    reserved_quantity, status
                ) VALUES (
                    p_packing_job_id, v_line.material_id, v_balance.location_id,
                    v_line.canonical_unit_id, v_take, 'ACTIVE'
                );
            END IF;
            v_remaining := v_remaining - v_take;
        END LOOP;

        IF v_remaining > 0 THEN
            RAISE EXCEPTION 'Insufficient unreserved stock to increase job % by % units for material %.',
                p_packing_job_id, p_pending_unit_delta, v_line.material_id
                USING ERRCODE = '23514';
        END IF;
    END LOOP;
END;
$$;
REVOKE ALL ON FUNCTION public.fn_adjust_job_reservations(uuid, integer)
    FROM PUBLIC, anon, authenticated;

-- API-facing wrappers give quantity revision/cancellation their own client
-- idempotency identity while retaining the prior audited RPC implementations.
CREATE OR REPLACE FUNCTION public.rpc_revise_packing_job_api(
    p_packing_job_id uuid,
    p_revised_quantity integer,
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
    v_before public.packing_jobs;
    v_after public.packing_jobs;
    v_idem jsonb;
    v_inner_response jsonb;
    v_response jsonb;
BEGIN
    IF v_role IS DISTINCT FROM 'ADMIN' AND v_role IS DISTINCT FROM 'PLANNER' THEN
        RAISE EXCEPTION 'Only planners and administrators can revise job quantities.' USING ERRCODE = '42501';
    END IF;

    v_idem := public.fn_acquire_idempotency(
        p_idempotency_key,
        'POST:/api/v1/packing-jobs/<job_id>/revise-quantity',
        p_request_hash,
        v_actor_id
    );
    IF v_idem->>'action' = 'REPLAY' THEN
        RETURN v_idem->'body';
    ELSIF v_idem->>'action' = 'EXPIRED' THEN
        RAISE EXCEPTION 'IDEMPOTENCY_RESPONSE_EXPIRED: %', v_idem USING ERRCODE = '23514';
    END IF;

    SELECT * INTO v_before
    FROM public.packing_jobs
    WHERE id = p_packing_job_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Packing job was not found.' USING ERRCODE = 'P0002';
    END IF;

    v_inner_response := public.rpc_revise_packing_job(
        p_packing_job_id, p_revised_quantity, p_reason
    );

    SELECT * INTO v_after FROM public.packing_jobs WHERE id = p_packing_job_id;
    IF v_before.current_revised_quantity <> v_after.current_revised_quantity THEN
        PERFORM public.fn_adjust_job_reservations(
            p_packing_job_id,
            v_after.pending_quantity - v_before.pending_quantity
        );
        INSERT INTO public.packing_job_events (
            packing_job_id, event_type, from_status, to_status, payload, triggered_by
        ) VALUES (
            p_packing_job_id, 'QUANTITY_REVISED', v_before.status, v_after.status,
            jsonb_build_object(
                'previousQuantity', v_before.current_revised_quantity,
                'revisedQuantity', v_after.current_revised_quantity,
                'reason', trim(p_reason)
            ), v_actor_id
        );
    END IF;

    v_response := public.fn_packing_job_json(p_packing_job_id);
    PERFORM public.fn_complete_idempotency(
        p_idempotency_key, 'PACKING_JOB', p_packing_job_id, 200, v_response
    );
    RETURN v_response;
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_revise_packing_job(uuid, integer, text)
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.rpc_revise_packing_job_api(uuid, integer, text, text, text)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_revise_packing_job_api(uuid, integer, text, text, text)
    TO authenticated;

CREATE OR REPLACE FUNCTION public.rpc_cancel_packing_job_api(
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
    v_before public.packing_jobs;
    v_after public.packing_jobs;
    v_idem jsonb;
    v_inner_response jsonb;
    v_response jsonb;
BEGIN
    IF v_role IS DISTINCT FROM 'ADMIN' AND v_role IS DISTINCT FROM 'PLANNER' THEN
        RAISE EXCEPTION 'Only planners and administrators can cancel jobs.' USING ERRCODE = '42501';
    END IF;

    v_idem := public.fn_acquire_idempotency(
        p_idempotency_key,
        'POST:/api/v1/packing-jobs/<job_id>/cancel',
        p_request_hash,
        v_actor_id
    );
    IF v_idem->>'action' = 'REPLAY' THEN
        RETURN v_idem->'body';
    ELSIF v_idem->>'action' = 'EXPIRED' THEN
        RAISE EXCEPTION 'IDEMPOTENCY_RESPONSE_EXPIRED: %', v_idem USING ERRCODE = '23514';
    END IF;

    SELECT * INTO v_before
    FROM public.packing_jobs
    WHERE id = p_packing_job_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Packing job was not found.' USING ERRCODE = 'P0002';
    END IF;

    v_inner_response := public.rpc_cancel_packing_job(p_packing_job_id, p_reason);
    SELECT * INTO v_after FROM public.packing_jobs WHERE id = p_packing_job_id;

    IF v_before.status IS DISTINCT FROM 'CANCELLED'
       AND v_after.status = 'CANCELLED' THEN
        INSERT INTO public.packing_job_events (
            packing_job_id, event_type, from_status, to_status, payload, triggered_by
        ) VALUES (
            p_packing_job_id, 'JOB_CANCELLED', v_before.status, v_after.status,
            jsonb_build_object(
                'reason', trim(p_reason),
                'cancelledQuantity', v_after.cancelled_quantity,
                'completedPreserved', v_after.completed_quantity
            ), v_actor_id
        );
    END IF;

    v_response := public.fn_packing_job_json(p_packing_job_id);
    PERFORM public.fn_complete_idempotency(
        p_idempotency_key, 'PACKING_JOB', p_packing_job_id, 200, v_response
    );
    RETURN v_response;
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_cancel_packing_job(uuid, text)
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.rpc_cancel_packing_job_api(uuid, text, text, text)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_cancel_packing_job_api(uuid, text, text, text)
    TO authenticated;

-- =============================================================================
-- 7. Prevent non-job stock movements from consuming reserved inventory, and
--    tie planned job issuance to the job's exact source-location reservation.
-- =============================================================================
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
    p_measurement_evidence text,
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
    v_reserved_quantity numeric;
BEGIN
    IF p_quantity IS NULL
       OR p_quantity::text IN ('NaN', 'Infinity', '-Infinity')
       OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Stock movement canonical quantity must be finite and strictly positive.'
            USING ERRCODE = '23514';
    END IF;

    IF p_source_location_id IS NOT NULL AND p_destination_location_id IS NOT NULL THEN
        IF p_source_location_id < p_destination_location_id THEN
            PERFORM pg_catalog.pg_advisory_xact_lock(
                pg_catalog.hashtextextended(p_material_id::text || ':' || p_source_location_id::text, 0)
            );
            PERFORM pg_catalog.pg_advisory_xact_lock(
                pg_catalog.hashtextextended(p_material_id::text || ':' || p_destination_location_id::text, 0)
            );
        ELSE
            PERFORM pg_catalog.pg_advisory_xact_lock(
                pg_catalog.hashtextextended(p_material_id::text || ':' || p_destination_location_id::text, 0)
            );
            PERFORM pg_catalog.pg_advisory_xact_lock(
                pg_catalog.hashtextextended(p_material_id::text || ':' || p_source_location_id::text, 0)
            );
        END IF;
    ELSIF p_source_location_id IS NOT NULL THEN
        PERFORM pg_catalog.pg_advisory_xact_lock(
            pg_catalog.hashtextextended(p_material_id::text || ':' || p_source_location_id::text, 0)
        );
    ELSIF p_destination_location_id IS NOT NULL THEN
        PERFORM pg_catalog.pg_advisory_xact_lock(
            pg_catalog.hashtextextended(p_material_id::text || ':' || p_destination_location_id::text, 0)
        );
    END IF;

    IF p_source_location_id IS NOT NULL AND p_destination_location_id IS NOT NULL THEN
        IF p_source_location_id < p_destination_location_id THEN
            SELECT on_hand_quantity INTO v_source_lock
            FROM public.material_location_balances
            WHERE material_id = p_material_id AND location_id = p_source_location_id
            FOR UPDATE;
            SELECT on_hand_quantity INTO v_dest_lock
            FROM public.material_location_balances
            WHERE material_id = p_material_id AND location_id = p_destination_location_id
            FOR UPDATE;
        ELSE
            SELECT on_hand_quantity INTO v_dest_lock
            FROM public.material_location_balances
            WHERE material_id = p_material_id AND location_id = p_destination_location_id
            FOR UPDATE;
            SELECT on_hand_quantity INTO v_source_lock
            FROM public.material_location_balances
            WHERE material_id = p_material_id AND location_id = p_source_location_id
            FOR UPDATE;
        END IF;
    ELSIF p_source_location_id IS NOT NULL THEN
        SELECT on_hand_quantity INTO v_source_lock
        FROM public.material_location_balances
        WHERE material_id = p_material_id AND location_id = p_source_location_id
        FOR UPDATE;
    ELSIF p_destination_location_id IS NOT NULL THEN
        SELECT on_hand_quantity INTO v_dest_lock
        FROM public.material_location_balances
        WHERE material_id = p_material_id AND location_id = p_destination_location_id
        FOR UPDATE;
    END IF;

    IF p_source_location_id IS NOT NULL THEN
        IF coalesce(v_source_lock, 0) < p_quantity THEN
            RAISE EXCEPTION 'Insufficient stock: Available % is less than required %.',
                coalesce(v_source_lock, 0), p_quantity
                USING ERRCODE = '23514';
        END IF;

        SELECT coalesce(sum(sr.reserved_quantity), 0)
        INTO v_reserved_quantity
        FROM public.stock_reservations sr
        WHERE sr.material_id = p_material_id
          AND sr.location_id = p_source_location_id
          AND sr.status = 'ACTIVE';

        IF coalesce(v_source_lock, 0) - v_reserved_quantity < p_quantity THEN
            RAISE EXCEPTION 'Movement would consume stock reserved for released packing jobs.'
                USING ERRCODE = '23514';
        END IF;
    END IF;

    v_tx_number := 'TXN-' || to_char(clock_timestamp(), 'YYYYMMDD-HH24MISS')
        || '-' || lpad(p_transaction_sequence::text, 3, '0')
        || '-' || substr(md5(random()::text), 1, 6);

    INSERT INTO public.stock_transactions (
        transaction_number, idempotency_key, transaction_sequence,
        material_id, movement_type, source_location_id, destination_location_id,
        worker_id, quantity, unit_id, entered_quantity, entered_unit_id,
        measurement_method, measurement_evidence, conversion_factor_applied,
        conversion_rule_id, conversion_direction, conversion_type_used, is_estimated,
        movement_reason, goods_receipt_id, goods_receipt_line_id, packing_job_id,
        production_completion_id, stock_adjustment_id, created_by, created_at
    ) VALUES (
        v_tx_number, p_idempotency_key, p_transaction_sequence,
        p_material_id, p_movement_type, p_source_location_id, p_destination_location_id,
        p_worker_id, p_quantity, p_unit_id, p_entered_quantity, p_entered_unit_id,
        p_measurement_method, nullif(trim(coalesce(p_measurement_evidence, '')), ''),
        p_conversion_factor, p_conversion_rule_id, p_conversion_direction,
        p_conversion_type, p_is_estimated, p_movement_reason, p_goods_receipt_id,
        p_goods_receipt_line_id, p_packing_job_id, p_production_completion_id,
        p_stock_adjustment_id, coalesce(p_created_by, auth.uid()), clock_timestamp()
    )
    RETURNING * INTO v_inserted_tx;

    RETURN v_inserted_tx;
END;
$$;
REVOKE ALL ON FUNCTION public.fn_post_stock_transaction(
    text, integer, uuid, text, uuid, uuid, uuid, numeric, uuid, numeric, uuid,
    text, text, numeric, uuid, text, text, boolean, text, uuid, uuid, uuid, uuid, uuid, uuid
) FROM PUBLIC, anon, authenticated;

-- Replace the measurement-aware issue RPC so reserved job materials can be
-- issued only against the corresponding job/material/source reservation.
CREATE OR REPLACE FUNCTION public.rpc_issue_to_worker(
    p_packing_job_id uuid,
    p_worker_id uuid,
    p_material_id uuid,
    p_source_location_id uuid,
    p_quantity numeric,
    p_unit_id uuid,
    p_idempotency_key text,
    p_request_hash text,
    p_measurement_method text,
    p_measurement_evidence text
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
    v_norm jsonb;
    v_tx public.stock_transactions;
    v_idem jsonb;
    v_job public.packing_jobs;
    v_response jsonb;
    v_remaining numeric;
    v_take numeric;
    v_reserved record;
BEGIN
    IF v_actor_id IS NULL OR v_role IS NULL OR v_role NOT IN ('ADMIN', 'STOREKEEPER', 'PLANNER') THEN
        RAISE EXCEPTION 'Unauthorized: role cannot issue stock to a worker.' USING ERRCODE = '42501';
    END IF;
    IF p_measurement_method NOT IN ('SCALE_WEIGHED', 'SEALED_BUNDLE', 'MANUALLY_COUNTED') THEN
        RAISE EXCEPTION 'Unsupported measurement method.' USING ERRCODE = '22023';
    END IF;
    IF p_measurement_method IN ('SEALED_BUNDLE', 'MANUALLY_COUNTED')
       AND nullif(trim(coalesce(p_measurement_evidence, '')), '') IS NULL THEN
        RAISE EXCEPTION 'Measurement evidence is required for bundle or manual counts.'
            USING ERRCODE = '22023';
    END IF;

    v_idem := public.fn_acquire_idempotency(
        p_idempotency_key, 'POST:/api/v1/stock/issue-to-worker', p_request_hash, v_actor_id
    );
    IF v_idem->>'action' = 'REPLAY' THEN RETURN v_idem->'body';
    ELSIF v_idem->>'action' = 'EXPIRED' THEN
        RAISE EXCEPTION 'IDEMPOTENCY_RESPONSE_EXPIRED: %', v_idem USING ERRCODE = '23514';
    END IF;

    SELECT * INTO v_job FROM public.packing_jobs WHERE id = p_packing_job_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Packing job was not found.' USING ERRCODE = '23503';
    END IF;
    IF v_job.status NOT IN ('RELEASED', 'IN_PROGRESS', 'PARTIALLY_COMPLETED') THEN
        RAISE EXCEPTION 'Cannot issue materials to a job that is not released.' USING ERRCODE = '23514';
    END IF;

    SELECT w.assigned_location_id INTO v_worker_loc_id
    FROM public.workers w
    WHERE w.id = p_worker_id AND w.is_active = true;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Worker does not exist or is inactive.' USING ERRCODE = '23503';
    END IF;

    v_norm := public.fn_normalize_stock_quantity(p_material_id, p_quantity, p_unit_id);
    v_remaining := (v_norm->>'canonical_quantity')::numeric;

    -- Use the same advisory lock order as the ledger primitive and plan release.
    IF p_source_location_id < v_worker_loc_id THEN
        PERFORM pg_catalog.pg_advisory_xact_lock(
            pg_catalog.hashtextextended(p_material_id::text || ':' || p_source_location_id::text, 0)
        );
        PERFORM pg_catalog.pg_advisory_xact_lock(
            pg_catalog.hashtextextended(p_material_id::text || ':' || v_worker_loc_id::text, 0)
        );
    ELSE
        PERFORM pg_catalog.pg_advisory_xact_lock(
            pg_catalog.hashtextextended(p_material_id::text || ':' || v_worker_loc_id::text, 0)
        );
        PERFORM pg_catalog.pg_advisory_xact_lock(
            pg_catalog.hashtextextended(p_material_id::text || ':' || p_source_location_id::text, 0)
        );
    END IF;

    FOR v_reserved IN
        SELECT sr.id, sr.reserved_quantity
        FROM public.stock_reservations sr
        WHERE sr.packing_job_id = p_packing_job_id
          AND sr.material_id = p_material_id
          AND sr.location_id = p_source_location_id
          AND sr.status = 'ACTIVE'
        ORDER BY sr.created_at, sr.id
        FOR UPDATE
    LOOP
        EXIT WHEN v_remaining <= 0;
        v_take := least(v_remaining, v_reserved.reserved_quantity);
        UPDATE public.stock_reservations
        SET reserved_quantity = reserved_quantity - v_take,
            status = CASE WHEN reserved_quantity - v_take <= 0 THEN 'FULFILLED' ELSE 'ACTIVE' END,
            updated_at = clock_timestamp()
        WHERE id = v_reserved.id;
        v_remaining := v_remaining - v_take;
    END LOOP;

    IF v_remaining > 0 THEN
        RAISE EXCEPTION 'Insufficient job-specific reservation at the selected source location.'
            USING ERRCODE = '23514';
    END IF;

    v_tx := public.fn_post_stock_transaction(
        p_idempotency_key => p_idempotency_key,
        p_transaction_sequence => 1,
        p_material_id => p_material_id,
        p_movement_type => 'ISSUE_TO_WORKER',
        p_source_location_id => p_source_location_id,
        p_destination_location_id => v_worker_loc_id,
        p_worker_id => p_worker_id,
        p_quantity => (v_norm->>'canonical_quantity')::numeric,
        p_unit_id => (v_norm->>'canonical_unit_id')::uuid,
        p_entered_quantity => p_quantity,
        p_entered_unit_id => p_unit_id,
        p_measurement_method => p_measurement_method,
        p_measurement_evidence => p_measurement_evidence,
        p_conversion_factor => (v_norm->>'conversion_factor')::numeric,
        p_conversion_rule_id => nullif(v_norm->>'conversion_rule_id', 'null')::uuid,
        p_conversion_direction => v_norm->>'conversion_direction',
        p_conversion_type => v_norm->>'conversion_type',
        p_is_estimated => (v_norm->>'is_estimated')::boolean,
        p_packing_job_id => p_packing_job_id,
        p_created_by => v_actor_id
    );

    v_response := jsonb_build_object(
        'success', true, 'stockTransactionId', v_tx.id,
        'transactionNumber', v_tx.transaction_number, 'movementType', v_tx.movement_type,
        'quantity', v_tx.quantity
    );
    PERFORM public.fn_complete_idempotency(
        p_idempotency_key, 'STOCK_TRANSACTION', v_tx.id, 200, v_response
    );
    RETURN v_response;
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_issue_to_worker(uuid, uuid, uuid, uuid, numeric, uuid, text, text, text, text)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_issue_to_worker(uuid, uuid, uuid, uuid, numeric, uuid, text, text, text, text)
    TO authenticated;

-- Existing 8-argument compatibility overload delegates to the new guarded
-- signature. It remains safe because it uses the same job-specific reservation.
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
BEGIN
    RETURN public.rpc_issue_to_worker(
        p_packing_job_id, p_worker_id, p_material_id, p_source_location_id,
        p_quantity, p_unit_id, p_idempotency_key, p_request_hash, 'SCALE_WEIGHED', NULL
    );
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_issue_to_worker(uuid, uuid, uuid, uuid, numeric, uuid, text, text)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_issue_to_worker(uuid, uuid, uuid, uuid, numeric, uuid, text, text)
    TO authenticated;
