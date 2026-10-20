-- Phase 7: Production completion, physical consumption verification, and shift closing.
-- All business writes remain atomic PostgreSQL RPCs; the Flask API forwards the verified caller JWT.

ALTER TABLE public.production_completions
    ADD COLUMN IF NOT EXISTS completion_policy text NOT NULL DEFAULT 'AUTO_BOM_THEORETICAL';

ALTER TABLE public.material_consumption_records
    ADD COLUMN IF NOT EXISTS physically_confirmed_unit_id uuid
        REFERENCES public.units(id) ON DELETE RESTRICT,
    ADD COLUMN IF NOT EXISTS physical_measurement_method text,
    ADD COLUMN IF NOT EXISTS physical_measurement_evidence text;

ALTER TABLE public.daily_closings
    ADD COLUMN IF NOT EXISTS pending_dispositions jsonb NOT NULL DEFAULT '[]'::jsonb,
    ADD COLUMN IF NOT EXISTS discrepancy_details jsonb NOT NULL DEFAULT '[]'::jsonb;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_constraint
        WHERE conrelid = 'public.material_consumption_records'::regclass
          AND conname = 'chk_consumption_physical_measurement_method'
    ) THEN
        ALTER TABLE public.material_consumption_records
            ADD CONSTRAINT chk_consumption_physical_measurement_method
            CHECK (physical_measurement_method IS NULL OR
                   physical_measurement_method IN ('SCALE_WEIGHED', 'SEALED_BUNDLE', 'MANUALLY_COUNTED'));
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_constraint
        WHERE conrelid = 'public.production_completions'::regclass
          AND conname = 'chk_production_completion_policy'
    ) THEN
        ALTER TABLE public.production_completions
            ADD CONSTRAINT chk_production_completion_policy
            CHECK (completion_policy IN ('AUTO_BOM_THEORETICAL', 'CONFIRMED_ACTUAL_ENTRY'));
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_constraint
        WHERE conrelid = 'public.material_consumption_records'::regclass
          AND conname = 'chk_consumption_verification_consistency'
    ) THEN
        ALTER TABLE public.material_consumption_records
            ADD CONSTRAINT chk_consumption_verification_consistency
            CHECK (
                (variance_status = 'UNVERIFIED'
                    AND physically_confirmed_quantity IS NULL
                    AND variance_quantity IS NULL
                    AND physically_confirmed_unit_id IS NULL
                    AND physical_measurement_method IS NULL
                    AND physical_measurement_evidence IS NULL)
                OR
                (variance_status = 'VERIFIED_ZERO'
                    AND physically_confirmed_quantity IS NOT NULL
                    AND variance_quantity = 0
                    AND physically_confirmed_unit_id IS NOT NULL
                    AND physical_measurement_method IS NOT NULL)
                OR
                (variance_status = 'VARIANCE_RECORDED'
                    AND physically_confirmed_quantity IS NOT NULL
                    AND variance_quantity IS NOT NULL
                    AND variance_quantity <> 0
                    AND physically_confirmed_unit_id IS NOT NULL
                    AND physical_measurement_method IS NOT NULL)
            );
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_constraint
        WHERE conrelid = 'public.daily_closings'::regclass
          AND conname = 'chk_daily_closing_pending_dispositions_array'
    ) THEN
        ALTER TABLE public.daily_closings
            ADD CONSTRAINT chk_daily_closing_pending_dispositions_array
            CHECK (pg_catalog.jsonb_typeof(pending_dispositions) = 'array');
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_constraint
        WHERE conrelid = 'public.daily_closings'::regclass
          AND conname = 'chk_daily_closing_discrepancy_details_array'
    ) THEN
        ALTER TABLE public.daily_closings
            ADD CONSTRAINT chk_daily_closing_discrepancy_details_array
            CHECK (pg_catalog.jsonb_typeof(discrepancy_details) = 'array');
    END IF;
END;
$$;

-- Private read model used only by the trusted transactional procedures.
CREATE OR REPLACE FUNCTION public.fn_production_consumptions_json(p_completion_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
    SELECT coalesce(
        jsonb_agg(
            jsonb_build_object(
                'id', mc.id,
                'materialId', mc.material_id,
                'theoreticalQuantity', mc.theoretical_quantity,
                'postedLedgerQuantity', mc.posted_ledger_quantity,
                'physicallyConfirmedQuantity', mc.physically_confirmed_quantity,
                'physicallyConfirmedUnitId', mc.physically_confirmed_unit_id,
                'varianceQuantity', mc.variance_quantity,
                'varianceStatus', mc.variance_status,
                'physicalMeasurementMethod', mc.physical_measurement_method,
                'physicalMeasurementEvidence', mc.physical_measurement_evidence,
                'stockTransactionId', mc.stock_transaction_id,
                'ledgerQuantityEstimated', st.is_estimated
            )
            ORDER BY mc.material_id
        ),
        '[]'::jsonb
    )
    FROM public.material_consumption_records mc
    JOIN public.stock_transactions st ON st.id = mc.stock_transaction_id
    WHERE mc.production_completion_id = p_completion_id;
$function$;

REVOKE ALL ON FUNCTION public.fn_production_consumptions_json(uuid) FROM PUBLIC, anon, authenticated;

-- Replacing the old six-argument overload avoids an ambiguous PostgREST RPC call.
DROP FUNCTION IF EXISTS public.rpc_complete_production(uuid, integer, uuid, text, text, text);

CREATE FUNCTION public.rpc_complete_production(
    p_packing_job_id uuid,
    p_completed_units integer,
    p_worker_id uuid,
    p_remarks text,
    p_idempotency_key text,
    p_request_hash text,
    p_completion_policy text DEFAULT 'AUTO_BOM_THEORETICAL',
    p_actual_material_usage jsonb DEFAULT '[]'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
    v_actor_id uuid := auth.uid();
    v_role text := public.get_current_user_role();
    v_idem jsonb;
    v_job public.packing_jobs%ROWTYPE;
    v_snapshot public.packing_job_bom_snapshots%ROWTYPE;
    v_worker_location_id uuid;
    v_completion_id uuid := pg_catalog.gen_random_uuid();
    v_completion_number text;
    v_line record;
    v_actual jsonb;
    v_actual_quantity numeric;
    v_theoretical numeric;
    v_required_count integer;
    v_matches integer;
    v_response jsonb;
BEGIN
    IF v_actor_id IS NULL THEN
        RAISE EXCEPTION 'A signed-in user is required.' USING ERRCODE = '42501';
    END IF;
    IF v_role IS DISTINCT FROM 'ADMIN'
       AND v_role IS DISTINCT FROM 'OPERATOR'
       AND v_role IS DISTINCT FROM 'PLANNER' THEN
        RAISE EXCEPTION 'Only operators, planners, and admins can record production.' USING ERRCODE = '42501';
    END IF;
    IF p_completed_units IS NULL OR p_completed_units <= 0 THEN
        RAISE EXCEPTION 'Completed units must be strictly positive.' USING ERRCODE = '23514';
    END IF;
    IF p_completion_policy IS NULL OR p_completion_policy NOT IN ('AUTO_BOM_THEORETICAL', 'CONFIRMED_ACTUAL_ENTRY') THEN
        RAISE EXCEPTION 'Unsupported completion policy.' USING ERRCODE = '23514';
    END IF;
    IF p_actual_material_usage IS NULL OR pg_catalog.jsonb_typeof(p_actual_material_usage) <> 'array' THEN
        RAISE EXCEPTION 'actualMaterialUsage must be an array.' USING ERRCODE = '23514';
    END IF;
    IF p_completion_policy = 'AUTO_BOM_THEORETICAL'
       AND pg_catalog.jsonb_array_length(p_actual_material_usage) <> 0 THEN
        RAISE EXCEPTION 'AUTO_BOM_THEORETICAL cannot contain physical count entries.' USING ERRCODE = '23514';
    END IF;

    v_idem := public.fn_acquire_idempotency(
        p_idempotency_key,
        'POST:/api/v1/production/completions',
        p_request_hash,
        v_actor_id
    );
    IF v_idem->>'action' = 'REPLAY' THEN
        RETURN v_idem->'body';
    ELSIF v_idem->>'action' = 'EXPIRED' THEN
        RAISE EXCEPTION 'IDEMPOTENCY_RESPONSE_EXPIRED: %', v_idem USING ERRCODE = '23514';
    END IF;

    SELECT * INTO v_job
    FROM public.packing_jobs
    WHERE id = p_packing_job_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Packing job was not found.' USING ERRCODE = 'P0002';
    END IF;
    IF v_job.status NOT IN ('RELEASED', 'IN_PROGRESS', 'PARTIALLY_COMPLETED') THEN
        RAISE EXCEPTION 'This packing job cannot receive production completions in its current status.' USING ERRCODE = '23514';
    END IF;
    IF p_completed_units > v_job.pending_quantity THEN
        RAISE EXCEPTION 'Completed units cannot exceed the job pending quantity.' USING ERRCODE = '23514';
    END IF;
    IF v_job.assigned_worker_id IS NOT NULL AND v_job.assigned_worker_id <> p_worker_id THEN
        RAISE EXCEPTION 'The production worker must match the worker assigned to this job.' USING ERRCODE = '23514';
    END IF;

    SELECT w.assigned_location_id INTO v_worker_location_id
    FROM public.workers w
    WHERE w.id = p_worker_id AND w.is_active = true;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'The selected worker does not exist or is inactive.' USING ERRCODE = '23503';
    END IF;

    SELECT * INTO v_snapshot
    FROM public.packing_job_bom_snapshots s
    WHERE s.packing_job_id = p_packing_job_id
    FOR SHARE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'The packing job has no frozen BOM snapshot.' USING ERRCODE = '23514';
    END IF;

    SELECT count(*)::integer INTO v_required_count
    FROM public.packing_job_bom_snapshot_lines sl
    WHERE sl.snapshot_id = v_snapshot.id AND sl.is_optional = false;
    IF v_required_count < 1 THEN
        RAISE EXCEPTION 'The frozen BOM contains no required material lines.' USING ERRCODE = '23514';
    END IF;

    IF p_completion_policy = 'CONFIRMED_ACTUAL_ENTRY' THEN
        IF pg_catalog.jsonb_array_length(p_actual_material_usage) <> v_required_count THEN
            RAISE EXCEPTION 'Provide exactly one physical count for each required BOM material.' USING ERRCODE = '23514';
        END IF;
        IF EXISTS (
            SELECT element.value->>'materialId'
            FROM pg_catalog.jsonb_array_elements(p_actual_material_usage) AS element(value)
            GROUP BY element.value->>'materialId'
            HAVING count(*) > 1
        ) THEN
            RAISE EXCEPTION 'Duplicate material entries are not permitted in actualMaterialUsage.' USING ERRCODE = '23514';
        END IF;
    END IF;

    -- Job counters and reservation release change in the same transaction as the ledger.
    UPDATE public.packing_jobs
    SET completed_quantity = completed_quantity + p_completed_units,
        pending_quantity = pending_quantity - p_completed_units,
        status = CASE WHEN pending_quantity - p_completed_units = 0
                      THEN 'COMPLETED' ELSE 'PARTIALLY_COMPLETED' END,
        updated_at = pg_catalog.clock_timestamp()
    WHERE id = p_packing_job_id;

    PERFORM public.fn_adjust_job_reservations(p_packing_job_id, -p_completed_units);

    v_completion_number := 'COMP-' ||
        pg_catalog.to_char(pg_catalog.clock_timestamp(), 'YYYYMMDD') || '-' ||
        pg_catalog.substr(pg_catalog.replace(v_completion_id::text, '-', ''), 1, 8);

    INSERT INTO public.production_completions (
        id, packing_job_id, completion_number, completed_units,
        completed_by_worker_id, idempotency_key, remarks, recorded_by, created_at, completion_policy
    ) VALUES (
        v_completion_id, p_packing_job_id, v_completion_number, p_completed_units,
        p_worker_id, p_idempotency_key, nullif(pg_catalog.btrim(p_remarks), ''),
        v_actor_id, pg_catalog.clock_timestamp(), p_completion_policy
    );

    -- The stock ledger posts frozen theoretical usage as estimated. Physical counts
    -- are separately recorded and never rewrite immutable stock transactions.
    FOR v_line IN
        SELECT sl.material_id, sl.canonical_qty_per_unit, sl.canonical_unit_id
        FROM public.packing_job_bom_snapshot_lines sl
        WHERE sl.snapshot_id = v_snapshot.id AND sl.is_optional = false
        ORDER BY sl.material_id
    LOOP
        v_theoretical := p_completed_units * v_line.canonical_qty_per_unit;
        v_actual := NULL;
        v_actual_quantity := NULL;

        IF p_completion_policy = 'CONFIRMED_ACTUAL_ENTRY' THEN
            SELECT element.value INTO v_actual
            FROM pg_catalog.jsonb_array_elements(p_actual_material_usage) AS element(value)
            WHERE element.value->>'materialId' = v_line.material_id::text;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'A required BOM material is missing from actualMaterialUsage.' USING ERRCODE = '23514';
            END IF;
            SELECT count(*)::integer INTO v_matches
            FROM pg_catalog.jsonb_array_elements(p_actual_material_usage) AS element(value)
            WHERE element.value->>'materialId' = v_line.material_id::text;
            IF v_matches <> 1 THEN
                RAISE EXCEPTION 'Each required BOM material must appear exactly once in actualMaterialUsage.' USING ERRCODE = '23514';
            END IF;
            IF (pg_catalog.jsonb_typeof(v_actual->'physicallyConfirmedQuantity') IS DISTINCT FROM 'number'
                AND pg_catalog.jsonb_typeof(v_actual->'physicallyConfirmedQuantity') IS DISTINCT FROM 'string')
               OR pg_catalog.jsonb_typeof(v_actual->'unitId') IS DISTINCT FROM 'string'
               OR pg_catalog.jsonb_typeof(v_actual->'measurementMethod') IS DISTINCT FROM 'string' THEN
                RAISE EXCEPTION 'Physical count quantity, unitId, and measurementMethod are required.' USING ERRCODE = '23514';
            END IF;
            IF (v_actual->>'unitId')::uuid IS DISTINCT FROM v_line.canonical_unit_id THEN
                RAISE EXCEPTION 'Physical count unitId must match the frozen canonical unit for the material.' USING ERRCODE = '23514';
            END IF;
            IF v_actual->>'measurementMethod' IS NULL OR v_actual->>'measurementMethod' NOT IN ('SCALE_WEIGHED', 'SEALED_BUNDLE', 'MANUALLY_COUNTED') THEN
                RAISE EXCEPTION 'Unsupported physical measurement method.' USING ERRCODE = '23514';
            END IF;
            v_actual_quantity := (v_actual->>'physicallyConfirmedQuantity')::numeric;
            IF v_actual_quantity::text IN ('NaN', 'Infinity', '-Infinity') THEN
                RAISE EXCEPTION 'Physical consumption quantity must be finite.' USING ERRCODE = '23514';
            END IF;
            IF v_actual_quantity < 0 THEN
                RAISE EXCEPTION 'Physical consumption quantity cannot be negative.' USING ERRCODE = '23514';
            END IF;
            IF pg_catalog.length(coalesce(v_actual->>'measurementEvidence', '')) > 500 THEN
                RAISE EXCEPTION 'Physical measurement evidence must not exceed 500 characters.' USING ERRCODE = '23514';
            END IF;
        END IF;

        PERFORM public.fn_post_stock_transaction(
            p_idempotency_key => p_idempotency_key,
            p_transaction_sequence => (
                SELECT count(*)::integer + 1
                FROM public.stock_transactions st
                WHERE st.idempotency_key = p_idempotency_key
            ),
            p_material_id => v_line.material_id,
            p_movement_type => 'CONSUMPTION',
            p_source_location_id => v_worker_location_id,
            p_destination_location_id => NULL,
            p_worker_id => p_worker_id,
            p_quantity => v_theoretical,
            p_unit_id => v_line.canonical_unit_id,
            p_entered_quantity => v_theoretical,
            p_entered_unit_id => v_line.canonical_unit_id,
            p_measurement_method => 'AUTO_BOM_BACKFLUSH',
            p_measurement_evidence => NULL,
            p_is_estimated => true,
            p_packing_job_id => p_packing_job_id,
            p_production_completion_id => v_completion_id,
            p_created_by => v_actor_id
        );

        -- Retrieve the transaction just inserted for this completion/material.
        DECLARE
            v_tx_id uuid;
        BEGIN
            SELECT st.id INTO v_tx_id
            FROM public.stock_transactions st
            WHERE st.production_completion_id = v_completion_id
              AND st.material_id = v_line.material_id
            ORDER BY st.transaction_sequence DESC
            LIMIT 1;

            INSERT INTO public.material_consumption_records (
                production_completion_id, material_id, theoretical_quantity,
                posted_ledger_quantity, physically_confirmed_quantity,
                variance_quantity, variance_status, stock_transaction_id,
                physically_confirmed_unit_id, physical_measurement_method,
                physical_measurement_evidence
            ) VALUES (
                v_completion_id, v_line.material_id, v_theoretical, v_theoretical,
                v_actual_quantity,
                CASE WHEN v_actual_quantity IS NULL THEN NULL ELSE v_actual_quantity - v_theoretical END,
                CASE WHEN v_actual_quantity IS NULL THEN 'UNVERIFIED'
                     WHEN v_actual_quantity = v_theoretical THEN 'VERIFIED_ZERO'
                     ELSE 'VARIANCE_RECORDED' END,
                v_tx_id,
                CASE WHEN v_actual IS NULL THEN NULL ELSE v_line.canonical_unit_id END,
                v_actual->>'measurementMethod',
                nullif(pg_catalog.btrim(v_actual->>'measurementEvidence'), '')
            );
        END;
    END LOOP;

    v_response := jsonb_build_object(
        'success', true,
        'id', v_completion_id,
        'completionId', v_completion_id,
        'completionNumber', v_completion_number,
        'packingJobId', p_packing_job_id,
        'completedUnits', p_completed_units,
        'workerId', p_worker_id,
        'createdAt', pg_catalog.clock_timestamp(),
        'remainingPending', v_job.pending_quantity - p_completed_units,
        'completionPolicy', p_completion_policy,
        'consumptions', public.fn_production_consumptions_json(v_completion_id)
    );

    INSERT INTO public.audit_logs (
        event_type, actor_id, target_entity_type, target_entity_id, old_state, new_state
    ) VALUES (
        'PRODUCTION_COMPLETION_RECORDED', v_actor_id, 'production_completions',
        v_completion_id, pg_catalog.to_jsonb(v_job),
        jsonb_build_object('completedUnits', p_completed_units, 'packingJobId', p_packing_job_id,
                           'completionPolicy', p_completion_policy)
    );

    PERFORM public.fn_complete_idempotency(
        p_idempotency_key, 'PRODUCTION_COMPLETION', v_completion_id, 200, v_response
    );
    RETURN v_response;
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_complete_production(uuid, integer, uuid, text, text, text, text, jsonb)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_complete_production(uuid, integer, uuid, text, text, text, text, jsonb)
    TO authenticated;

CREATE OR REPLACE FUNCTION public.rpc_verify_production_consumption(
    p_completion_id uuid,
    p_actual_material_usage jsonb,
    p_idempotency_key text,
    p_request_hash text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
    v_actor_id uuid := auth.uid();
    v_role text := public.get_current_user_role();
    v_idem jsonb;
    v_completion public.production_completions%ROWTYPE;
    v_record record;
    v_actual jsonb;
    v_quantity numeric;
    v_matches integer;
    v_verified_count integer := 0;
    v_response jsonb;
BEGIN
    IF v_actor_id IS NULL THEN
        RAISE EXCEPTION 'A signed-in user is required.' USING ERRCODE = '42501';
    END IF;
    IF v_role IS DISTINCT FROM 'ADMIN' AND v_role IS DISTINCT FROM 'OPERATOR' AND v_role IS DISTINCT FROM 'PLANNER' THEN
        RAISE EXCEPTION 'Only operators, planners, and admins can verify production consumption.' USING ERRCODE = '42501';
    END IF;
    IF p_actual_material_usage IS NULL OR pg_catalog.jsonb_typeof(p_actual_material_usage) <> 'array' THEN
        RAISE EXCEPTION 'actualMaterialUsage must be an array.' USING ERRCODE = '23514';
    END IF;

    v_idem := public.fn_acquire_idempotency(
        p_idempotency_key,
        'POST:/api/v1/production/completions/<completion_id>/consumption/verify',
        p_request_hash,
        v_actor_id
    );
    IF v_idem->>'action' = 'REPLAY' THEN
        RETURN v_idem->'body';
    ELSIF v_idem->>'action' = 'EXPIRED' THEN
        RAISE EXCEPTION 'IDEMPOTENCY_RESPONSE_EXPIRED: %', v_idem USING ERRCODE = '23514';
    END IF;

    SELECT * INTO v_completion
    FROM public.production_completions
    WHERE id = p_completion_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Production completion was not found.' USING ERRCODE = 'P0002';
    END IF;

    SELECT count(*)::integer INTO v_matches
    FROM public.material_consumption_records
    WHERE production_completion_id = p_completion_id;
    IF v_matches < 1 OR pg_catalog.jsonb_array_length(p_actual_material_usage) <> v_matches THEN
        RAISE EXCEPTION 'Provide exactly one physical count for each material in this completion.' USING ERRCODE = '23514';
    END IF;
    IF EXISTS (
        SELECT element.value->>'materialId'
        FROM pg_catalog.jsonb_array_elements(p_actual_material_usage) AS element(value)
        GROUP BY element.value->>'materialId'
        HAVING count(*) > 1
    ) THEN
        RAISE EXCEPTION 'Duplicate material entries are not permitted.' USING ERRCODE = '23514';
    END IF;

    FOR v_record IN
        SELECT mc.id, mc.material_id, mc.theoretical_quantity, mc.variance_status,
               st.unit_id AS canonical_unit_id
        FROM public.material_consumption_records mc
        JOIN public.stock_transactions st ON st.id = mc.stock_transaction_id
        WHERE mc.production_completion_id = p_completion_id
        ORDER BY mc.material_id
        FOR UPDATE OF mc
    LOOP
        IF v_record.variance_status <> 'UNVERIFIED' THEN
            RAISE EXCEPTION 'All consumption rows must still be UNVERIFIED before physical verification.' USING ERRCODE = '23514';
        END IF;

        v_actual := NULL;
        SELECT element.value INTO v_actual
        FROM pg_catalog.jsonb_array_elements(p_actual_material_usage) AS element(value)
        WHERE element.value->>'materialId' = v_record.material_id::text;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'A material consumption row is missing from actualMaterialUsage.' USING ERRCODE = '23514';
        END IF;
        SELECT count(*)::integer INTO v_matches
        FROM pg_catalog.jsonb_array_elements(p_actual_material_usage) AS element(value)
        WHERE element.value->>'materialId' = v_record.material_id::text;
        IF v_matches <> 1 THEN
            RAISE EXCEPTION 'Each material must appear exactly once.' USING ERRCODE = '23514';
        END IF;

        IF (pg_catalog.jsonb_typeof(v_actual->'physicallyConfirmedQuantity') IS DISTINCT FROM 'number'
            AND pg_catalog.jsonb_typeof(v_actual->'physicallyConfirmedQuantity') IS DISTINCT FROM 'string')
           OR pg_catalog.jsonb_typeof(v_actual->'unitId') IS DISTINCT FROM 'string'
           OR pg_catalog.jsonb_typeof(v_actual->'measurementMethod') IS DISTINCT FROM 'string' THEN
            RAISE EXCEPTION 'Physical count quantity, unitId, and measurementMethod are required.' USING ERRCODE = '23514';
        END IF;
        IF (v_actual->>'unitId')::uuid IS DISTINCT FROM v_record.canonical_unit_id THEN
            RAISE EXCEPTION 'Physical count unitId must match the canonical ledger unit.' USING ERRCODE = '23514';
        END IF;
        IF v_actual->>'measurementMethod' IS NULL OR v_actual->>'measurementMethod' NOT IN ('SCALE_WEIGHED', 'SEALED_BUNDLE', 'MANUALLY_COUNTED') THEN
            RAISE EXCEPTION 'Unsupported physical measurement method.' USING ERRCODE = '23514';
        END IF;
        v_quantity := (v_actual->>'physicallyConfirmedQuantity')::numeric;
        IF v_quantity::text IN ('NaN', 'Infinity', '-Infinity') THEN
            RAISE EXCEPTION 'Physical consumption quantity must be finite.' USING ERRCODE = '23514';
        END IF;
        IF v_quantity < 0 THEN
            RAISE EXCEPTION 'Physical consumption quantity cannot be negative.' USING ERRCODE = '23514';
        END IF;
        IF pg_catalog.length(coalesce(v_actual->>'measurementEvidence', '')) > 500 THEN
            RAISE EXCEPTION 'Physical measurement evidence must not exceed 500 characters.' USING ERRCODE = '23514';
        END IF;

        UPDATE public.material_consumption_records
        SET physically_confirmed_quantity = v_quantity,
            variance_quantity = v_quantity - v_record.theoretical_quantity,
            variance_status = CASE WHEN v_quantity = v_record.theoretical_quantity
                                   THEN 'VERIFIED_ZERO' ELSE 'VARIANCE_RECORDED' END,
            physically_confirmed_unit_id = v_record.canonical_unit_id,
            physical_measurement_method = v_actual->>'measurementMethod',
            physical_measurement_evidence = nullif(pg_catalog.btrim(v_actual->>'measurementEvidence'), '')
        WHERE id = v_record.id;

        INSERT INTO public.audit_logs (
            event_type, actor_id, target_entity_type, target_entity_id, old_state, new_state
        ) VALUES (
            'PRODUCTION_CONSUMPTION_VERIFIED', v_actor_id, 'material_consumption_records',
            v_record.id,
            jsonb_build_object('varianceStatus', 'UNVERIFIED'),
            jsonb_build_object('physicallyConfirmedQuantity', v_quantity,
                               'varianceQuantity', v_quantity - v_record.theoretical_quantity,
                               'varianceStatus', CASE WHEN v_quantity = v_record.theoretical_quantity
                                                      THEN 'VERIFIED_ZERO' ELSE 'VARIANCE_RECORDED' END,
                               'measurementMethod', v_actual->>'measurementMethod')
        );
        v_verified_count := v_verified_count + 1;
    END LOOP;

    v_response := jsonb_build_object(
        'success', true,
        'id', p_completion_id,
        'completionId', p_completion_id,
        'verifiedCount', v_verified_count,
        'consumptions', public.fn_production_consumptions_json(p_completion_id)
    );
    PERFORM public.fn_complete_idempotency(
        p_idempotency_key, 'PRODUCTION_COMPLETION', p_completion_id, 200, v_response
    );
    RETURN v_response;
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_verify_production_consumption(uuid, jsonb, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_verify_production_consumption(uuid, jsonb, text, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.fn_daily_closing_json(p_daily_closing_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
    SELECT jsonb_build_object(
        'id', dc.id,
        'dailyPlanId', dc.daily_plan_id,
        'shiftCode', dc.shift_code,
        'closingDate', dc.closing_date,
        'totalPlannedUnits', dc.total_planned_units,
        'totalCompletedUnits', dc.total_completed_units,
        'totalPendingUnits', dc.total_pending_units,
        'totalCancelledUnits', dc.total_cancelled_units,
        'totalJobsPlanned', (
            SELECT count(*)::integer FROM public.packing_jobs pj
            WHERE pj.daily_plan_id = dc.daily_plan_id
        ),
        'totalUnitsPacked', dc.total_completed_units,
        'unresolvedDiscrepanciesCount', dc.unresolved_discrepancies_count,
        'supervisorOverrideReason', dc.override_reason,
        'closedAt', dc.closed_at,
        'isReopened', dc.is_reopened,
        'reopenReason', dc.reopen_reason,
        'pendingDispositions', dc.pending_dispositions,
        'discrepancyDetails', dc.discrepancy_details
    )
    FROM public.daily_closings dc
    WHERE dc.id = p_daily_closing_id;
$function$;

REVOKE ALL ON FUNCTION public.fn_daily_closing_json(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.rpc_close_daily_plan(
    p_daily_plan_id uuid,
    p_shift_code text,
    p_allow_discrepancy_override boolean,
    p_supervisor_override_reason text,
    p_pending_dispositions jsonb,
    p_idempotency_key text,
    p_request_hash text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
    v_actor_id uuid := auth.uid();
    v_role text := public.get_current_user_role();
    v_idem jsonb;
    v_plan public.daily_plans%ROWTYPE;
    v_existing public.daily_closings%ROWTYPE;
    v_has_existing boolean := false;
    v_job public.packing_jobs%ROWTYPE;
    v_target_plan public.daily_plans%ROWTYPE;
    v_source_snapshot public.packing_job_bom_snapshots%ROWTYPE;
    v_request jsonb;
    v_disposition text;
    v_reason text;
    v_target_date date;
    v_target_shift text;
    v_pending integer;
    v_disposition_results jsonb := '[]'::jsonb;
    v_discrepancies jsonb := '[]'::jsonb;
    v_unresolved integer := 0;
    v_total_planned integer := 0;
    v_total_completed integer := 0;
    v_total_pending integer := 0;
    v_total_cancelled integer := 0;
    v_job_count integer := 0;
    v_closing_id uuid;
    v_target_plan_id uuid;
    v_target_job_id uuid;
    v_target_snapshot_id uuid;
    v_target_plan_number text;
    v_target_job_code text;
    v_snapshot_line_count integer;
    v_now timestamptz := pg_catalog.clock_timestamp();
    v_response jsonb;
    v_old_plan_status text;
    v_req_count integer;
    v_distinct_req_count integer;
BEGIN
    IF v_actor_id IS NULL THEN
        RAISE EXCEPTION 'A signed-in user is required.' USING ERRCODE = '42501';
    END IF;
    IF v_role IS DISTINCT FROM 'ADMIN' AND v_role IS DISTINCT FROM 'STOREKEEPER' THEN
        RAISE EXCEPTION 'Only storekeepers and admins can close a daily plan.' USING ERRCODE = '42501';
    END IF;
    IF p_shift_code IS NULL OR pg_catalog.btrim(p_shift_code) = '' THEN
        RAISE EXCEPTION 'shiftCode is required.' USING ERRCODE = '23514';
    END IF;
    IF p_pending_dispositions IS NULL OR pg_catalog.jsonb_typeof(p_pending_dispositions) <> 'array' THEN
        RAISE EXCEPTION 'pendingDispositions must be an array.' USING ERRCODE = '23514';
    END IF;

    IF p_allow_discrepancy_override IS TRUE THEN
        IF v_role <> 'ADMIN' THEN
            RAISE EXCEPTION 'Only an admin can override unresolved closing discrepancies.' USING ERRCODE = '42501';
        END IF;
        IF pg_catalog.length(pg_catalog.btrim(coalesce(p_supervisor_override_reason, ''))) < 3 THEN
            RAISE EXCEPTION 'A meaningful supervisorOverrideReason is required for an override.' USING ERRCODE = '23514';
        END IF;
    END IF;

    v_idem := public.fn_acquire_idempotency(
        p_idempotency_key, 'POST:/api/v1/closings', p_request_hash, v_actor_id
    );
    IF v_idem->>'action' = 'REPLAY' THEN
        RETURN v_idem->'body';
    ELSIF v_idem->>'action' = 'EXPIRED' THEN
        RAISE EXCEPTION 'IDEMPOTENCY_RESPONSE_EXPIRED: %', v_idem USING ERRCODE = '23514';
    END IF;

    SELECT * INTO v_plan
    FROM public.daily_plans
    WHERE id = p_daily_plan_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Daily plan was not found.' USING ERRCODE = 'P0002';
    END IF;
    IF v_plan.shift_code <> pg_catalog.upper(pg_catalog.btrim(p_shift_code)) THEN
        RAISE EXCEPTION 'shiftCode does not match the selected daily plan.' USING ERRCODE = '23514';
    END IF;
    IF v_plan.status <> 'RELEASED' THEN
        RAISE EXCEPTION 'Only a released daily plan can be closed.' USING ERRCODE = '23514';
    END IF;

    SELECT count(*)::integer,
           count(DISTINCT element.value->>'packingJobId')::integer
    INTO v_req_count, v_distinct_req_count
    FROM pg_catalog.jsonb_array_elements(p_pending_dispositions) AS element(value);
    IF v_req_count <> v_distinct_req_count THEN
        RAISE EXCEPTION 'A pending job may have only one disposition.' USING ERRCODE = '23514';
    END IF;

    -- Validate every caller-supplied disposition before mutating any job.
    FOR v_request IN
        SELECT element.value FROM pg_catalog.jsonb_array_elements(p_pending_dispositions) AS element(value)
    LOOP
        IF pg_catalog.jsonb_typeof(v_request) <> 'object'
           OR pg_catalog.jsonb_typeof(v_request->'packingJobId') <> 'string'
           OR pg_catalog.jsonb_typeof(v_request->'disposition') <> 'string' THEN
            RAISE EXCEPTION 'Each pending disposition requires packingJobId and disposition.' USING ERRCODE = '23514';
        END IF;
        v_disposition := v_request->>'disposition';
        IF v_disposition NOT IN ('CARRY_FORWARD', 'RESCHEDULE', 'CANCEL') THEN
            RAISE EXCEPTION 'Unsupported pending unit disposition.' USING ERRCODE = '23514';
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM public.packing_jobs pj
            WHERE pj.id = (v_request->>'packingJobId')::uuid
              AND pj.daily_plan_id = p_daily_plan_id
              AND pj.pending_quantity > 0
        ) THEN
            RAISE EXCEPTION 'A disposition references a job outside this plan or with no pending units.' USING ERRCODE = '23514';
        END IF;
        v_reason := pg_catalog.btrim(coalesce(v_request->>'reason', ''));
        IF v_disposition IN ('CANCEL', 'RESCHEDULE') AND pg_catalog.length(v_reason) < 3 THEN
            RAISE EXCEPTION 'Cancellation and reschedule dispositions require a reason.' USING ERRCODE = '23514';
        END IF;
        IF v_disposition = 'RESCHEDULE' THEN
            IF nullif(v_request->>'targetPlanDate', '') IS NULL
               OR nullif(v_request->>'targetShiftCode', '') IS NULL THEN
                RAISE EXCEPTION 'RESCHEDULE requires targetPlanDate and targetShiftCode.' USING ERRCODE = '23514';
            END IF;
            v_target_date := (v_request->>'targetPlanDate')::date;
            v_target_shift := pg_catalog.upper(pg_catalog.btrim(v_request->>'targetShiftCode'));
            IF v_target_date <= v_plan.plan_date THEN
                RAISE EXCEPTION 'A reschedule target must be on a later date.' USING ERRCODE = '23514';
            END IF;
            IF v_target_shift !~ '^[A-Z0-9_-]{1,30}$' THEN
                RAISE EXCEPTION 'targetShiftCode has an invalid format.' USING ERRCODE = '23514';
            END IF;
        END IF;
    END LOOP;

    SELECT dc.* INTO v_existing
    FROM public.daily_closings dc
    WHERE dc.daily_plan_id = p_daily_plan_id
    FOR UPDATE;
    v_has_existing := FOUND;
    IF v_has_existing AND NOT v_existing.is_reopened THEN
        RAISE EXCEPTION 'This daily plan already has a closing; an admin must reopen it before reclosing.' USING ERRCODE = '23514';
    END IF;

    -- Every pending job receives a durable disposition. CARRY_FORWARD schedules
    -- it for the next calendar day on the same shift; RESCHEDULE uses its target.
    -- Both create a new job with the frozen BOM lines; they never silently drop units.
    FOR v_job IN
        SELECT pj.* FROM public.packing_jobs pj
        WHERE pj.daily_plan_id = p_daily_plan_id AND pj.pending_quantity > 0
        ORDER BY pj.id
    LOOP
        v_pending := v_job.pending_quantity;
        v_request := NULL;
        SELECT element.value INTO v_request
        FROM pg_catalog.jsonb_array_elements(p_pending_dispositions) AS element(value)
        WHERE element.value->>'packingJobId' = v_job.id::text;

        IF NOT FOUND THEN
            v_disposition := 'CARRY_FORWARD';
            v_reason := NULL;
            v_target_date := GREATEST(v_plan.plan_date + 1, current_date + 1);
            v_target_shift := v_plan.shift_code;
        ELSE
            v_disposition := v_request->>'disposition';
            v_reason := nullif(pg_catalog.btrim(v_request->>'reason'), '');
            IF v_disposition = 'RESCHEDULE' THEN
                v_target_date := (v_request->>'targetPlanDate')::date;
                v_target_shift := pg_catalog.upper(pg_catalog.btrim(v_request->>'targetShiftCode'));
            ELSIF v_disposition = 'CARRY_FORWARD' THEN
                v_target_date := GREATEST(v_plan.plan_date + 1, current_date + 1);
                v_target_shift := v_plan.shift_code;
            ELSE
                v_target_date := NULL;
                v_target_shift := NULL;
            END IF;
        END IF;

        IF v_disposition = 'CANCEL' THEN
            PERFORM public.fn_adjust_job_reservations(v_job.id, -v_pending);
            UPDATE public.packing_jobs
            SET pending_quantity = 0,
                cancelled_quantity = cancelled_quantity + v_pending,
                status = 'CANCELLED',
                cancellation_reason = coalesce(v_reason, 'Cancelled during daily closing'),
                cancelled_at = v_now,
                updated_at = v_now
            WHERE id = v_job.id;

            INSERT INTO public.packing_job_events (
                packing_job_id, event_type, from_status, to_status, payload, triggered_by, created_at
            ) VALUES (
                v_job.id, 'DAILY_CLOSE_PENDING_CANCELLED', v_job.status, 'CANCELLED',
                jsonb_build_object('cancelledPendingUnits', v_pending, 'reason', v_reason,
                                   'dailyPlanId', p_daily_plan_id),
                v_actor_id, v_now
            );
        ELSE
            -- Release old reservations first so a released target plan can reserve
            -- the same still-on-shelf materials without double-counting availability.
            PERFORM public.fn_adjust_job_reservations(v_job.id, -v_pending);

            SELECT * INTO v_target_plan
            FROM public.daily_plans dp
            WHERE dp.plan_date = v_target_date AND dp.shift_code = v_target_shift
            FOR UPDATE;

            IF NOT FOUND THEN
                v_target_plan_id := pg_catalog.gen_random_uuid();
                v_target_plan_number := 'PLAN-' ||
                    pg_catalog.to_char(v_target_date, 'YYYYMMDD') || '-' || v_target_shift || '-' ||
                    pg_catalog.substr(pg_catalog.replace(pg_catalog.gen_random_uuid()::text, '-', ''), 1, 6);
                INSERT INTO public.daily_plans (
                    id, plan_number, plan_date, shift_code, created_by, status, notes
                ) VALUES (
                    v_target_plan_id, v_target_plan_number, v_target_date, v_target_shift,
                    v_actor_id, 'DRAFT',
                    'Created by daily closing disposition from plan ' || v_plan.plan_number
                )
                RETURNING * INTO v_target_plan;
            ELSE
                v_target_plan_id := v_target_plan.id;
            END IF;

            IF v_target_plan.status NOT IN ('DRAFT', 'RELEASED') THEN
                RAISE EXCEPTION 'Pending units cannot be moved to a target plan that is closed or archived.' USING ERRCODE = '23514';
            END IF;

            SELECT * INTO v_source_snapshot
            FROM public.packing_job_bom_snapshots ss
            WHERE ss.packing_job_id = v_job.id
            FOR SHARE;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'The source job has no frozen BOM snapshot for pending-unit transfer.' USING ERRCODE = '23514';
            END IF;

            v_target_job_id := pg_catalog.gen_random_uuid();
            v_target_job_code := 'JOB-RS-' ||
                pg_catalog.substr(pg_catalog.replace(v_target_job_id::text, '-', ''), 1, 12);

            INSERT INTO public.packing_jobs (
                id, daily_plan_id, job_code, party_id, product_id, master_bom_id,
                original_planned_quantity, current_revised_quantity, completed_quantity,
                pending_quantity, cancelled_quantity, assigned_worker_id, status, priority,
                created_at, updated_at
            ) VALUES (
                v_target_job_id, v_target_plan_id, v_target_job_code,
                v_job.party_id, v_job.product_id, NULL,
                v_pending, v_pending, 0, v_pending, 0, NULL,
                CASE WHEN v_target_plan.status = 'DRAFT' THEN 'DRAFT' ELSE 'RELEASED' END,
                v_job.priority, v_now, v_now
            );

            -- Re-freeze the exact historic lines as a custom snapshot. The schema
            -- requires custom snapshots to have a NULL source BOM/version, so later
            -- master-BOM edits cannot change the rescheduled job's material needs.
            INSERT INTO public.packing_job_bom_snapshots (
                packing_job_id, source_bom_id, bom_version, is_customized,
                customization_notes, frozen_by, frozen_at
            ) VALUES (
                v_target_job_id, NULL, NULL, true,
                'Frozen BOM copied from rescheduled job ' || v_job.job_code,
                v_actor_id, v_now
            )
            RETURNING id INTO v_target_snapshot_id;

            INSERT INTO public.packing_job_bom_snapshot_lines (
                snapshot_id, material_id, quantity_per_unit, unit_id,
                canonical_qty_per_unit, canonical_unit_id, conversion_rule_id,
                conversion_factor_frozen, conversion_direction, conversion_type,
                is_optional, notes
            )
            SELECT
                v_target_snapshot_id, sl.material_id, sl.quantity_per_unit, sl.unit_id,
                sl.canonical_qty_per_unit, sl.canonical_unit_id, sl.conversion_rule_id,
                sl.conversion_factor_frozen, sl.conversion_direction, sl.conversion_type,
                sl.is_optional, sl.notes
            FROM public.packing_job_bom_snapshot_lines sl
            WHERE sl.snapshot_id = v_source_snapshot.id;
            GET DIAGNOSTICS v_snapshot_line_count = ROW_COUNT;
            IF v_snapshot_line_count < 1 THEN
                RAISE EXCEPTION 'The source frozen BOM snapshot contains no lines.' USING ERRCODE = '23514';
            END IF;

            IF v_target_plan.status = 'RELEASED' THEN
                PERFORM public.fn_adjust_job_reservations(v_target_job_id, v_pending);
            END IF;

            UPDATE public.packing_jobs
            SET pending_quantity = 0,
                cancelled_quantity = cancelled_quantity + v_pending,
                status = 'CANCELLED',
                cancellation_reason = 'Pending units transferred to ' || v_target_job_code,
                cancelled_at = v_now,
                updated_at = v_now
            WHERE id = v_job.id;

            INSERT INTO public.packing_job_events (
                packing_job_id, event_type, from_status, to_status, payload, triggered_by, created_at
            ) VALUES (
                v_job.id, 'DAILY_CLOSE_PENDING_TRANSFERRED', v_job.status, 'CANCELLED',
                jsonb_build_object(
                    'disposition', v_disposition,
                    'transferredUnits', v_pending,
                    'targetDailyPlanId', v_target_plan_id,
                    'targetPackingJobId', v_target_job_id,
                    'targetJobCode', v_target_job_code,
                    'targetPlanDate', v_target_date,
                    'targetShiftCode', v_target_shift,
                    'reason', v_reason
                ),
                v_actor_id, v_now
            );
        END IF;

        v_disposition_results := v_disposition_results || jsonb_build_array(
            jsonb_strip_nulls(jsonb_build_object(
                'packingJobId', v_job.id,
                'disposition', v_disposition,
                'units', v_pending,
                'reason', v_reason,
                'targetPlanDate', v_target_date,
                'targetShiftCode', v_target_shift,
                'targetDailyPlanId', CASE WHEN v_disposition = 'CANCEL' THEN NULL ELSE v_target_plan_id END,
                'targetPackingJobId', CASE WHEN v_disposition = 'CANCEL' THEN NULL ELSE v_target_job_id END
            ))
        );
    END LOOP;

    -- Report (rather than silently treating as clean) unverified counts, recorded
    -- physical variances, outstanding job-linked worker custody, and quarantined BOM stock.
    SELECT coalesce(
        jsonb_agg(d.item ORDER BY d.sort_order, d.item->>'materialId'),
        '[]'::jsonb
    ) INTO v_discrepancies
    FROM (
        SELECT 1 AS sort_order,
               jsonb_build_object(
                   'type', CASE WHEN mc.variance_status = 'UNVERIFIED'
                                THEN 'UNVERIFIED_CONSUMPTION' ELSE 'RECORDED_CONSUMPTION_VARIANCE' END,
                   'completionId', mc.production_completion_id,
                   'materialId', mc.material_id,
                   'theoreticalQuantity', mc.theoretical_quantity,
                   'physicallyConfirmedQuantity', mc.physically_confirmed_quantity,
                   'varianceQuantity', mc.variance_quantity,
                   'varianceStatus', mc.variance_status
               ) AS item
        FROM public.material_consumption_records mc
        JOIN public.production_completions pc ON pc.id = mc.production_completion_id
        JOIN public.packing_jobs pj ON pj.id = pc.packing_job_id
        WHERE pj.daily_plan_id = p_daily_plan_id
          AND mc.variance_status IN ('UNVERIFIED', 'VARIANCE_RECORDED')

        UNION ALL

        SELECT 2 AS sort_order,
               jsonb_build_object(
                   'type', 'OUTSTANDING_WORKER_CUSTODY',
                   'packingJobId', activity.packing_job_id,
                   'workerId', activity.worker_id,
                   'materialId', activity.material_id,
                   'outstandingQuantity', activity.outstanding_quantity
               ) AS item
        FROM (
            SELECT st.packing_job_id, st.worker_id, st.material_id,
                   sum(CASE
                       WHEN st.movement_type = 'ISSUE_TO_WORKER' THEN st.quantity
                       WHEN st.movement_type IN ('RETURN_FROM_WORKER', 'CONSUMPTION', 'DAMAGE_QUARANTINE')
                            AND st.worker_id IS NOT NULL THEN -st.quantity
                       ELSE 0
                   END) AS outstanding_quantity
            FROM public.stock_transactions st
            WHERE st.packing_job_id IN (
                SELECT pj.id FROM public.packing_jobs pj WHERE pj.daily_plan_id = p_daily_plan_id
            )
              AND st.movement_type IN ('ISSUE_TO_WORKER', 'RETURN_FROM_WORKER', 'CONSUMPTION', 'DAMAGE_QUARANTINE')
              AND st.worker_id IS NOT NULL
            GROUP BY st.packing_job_id, st.worker_id, st.material_id
            HAVING sum(CASE
                       WHEN st.movement_type = 'ISSUE_TO_WORKER' THEN st.quantity
                       WHEN st.movement_type IN ('RETURN_FROM_WORKER', 'CONSUMPTION', 'DAMAGE_QUARANTINE')
                            AND st.worker_id IS NOT NULL THEN -st.quantity
                       ELSE 0
                   END) > 0.00000001
        ) AS activity

        UNION ALL

        SELECT 3 AS sort_order,
               jsonb_build_object(
                   'type', 'QUARANTINED_BOM_MATERIAL',
                   'materialId', mb.material_id,
                   'locationId', mb.location_id,
                   'onHandQuantity', mb.on_hand_quantity
               ) AS item
        FROM public.material_location_balances mb
        JOIN public.locations l ON l.id = mb.location_id
        WHERE mb.on_hand_quantity > 0
          AND l.is_active = true
          AND l.location_type = 'DAMAGE_QUARANTINE'
          AND EXISTS (
              SELECT 1
              FROM public.stock_transactions qt
              WHERE qt.movement_type = 'DAMAGE_QUARANTINE'
                AND qt.material_id = mb.material_id
                AND qt.destination_location_id = mb.location_id
                AND qt.packing_job_id IN (
                    SELECT pj.id FROM public.packing_jobs pj WHERE pj.daily_plan_id = p_daily_plan_id
                )
          )
    ) AS d;

    v_unresolved := pg_catalog.jsonb_array_length(v_discrepancies);
    IF v_unresolved > 0 AND p_allow_discrepancy_override IS NOT TRUE THEN
        RAISE EXCEPTION 'Daily closing has % unresolved material discrepancies. Verify counts, reconcile custody/quarantine, or use an authorized admin override.',
            v_unresolved USING ERRCODE = '23514';
    END IF;

    SELECT coalesce(sum(pj.current_revised_quantity), 0)::integer,
           coalesce(sum(pj.completed_quantity), 0)::integer,
           coalesce(sum(pj.pending_quantity), 0)::integer,
           coalesce(sum(pj.cancelled_quantity), 0)::integer,
           count(*)::integer
    INTO v_total_planned, v_total_completed, v_total_pending, v_total_cancelled, v_job_count
    FROM public.packing_jobs pj
    WHERE pj.daily_plan_id = p_daily_plan_id;
    IF v_job_count < 1 THEN
        RAISE EXCEPTION 'A daily plan must contain at least one packing job before closing.' USING ERRCODE = '23514';
    END IF;

    IF v_has_existing THEN
        UPDATE public.daily_closings
        SET closing_date = v_plan.plan_date,
            total_planned_units = v_total_planned,
            total_completed_units = v_total_completed,
            total_pending_units = v_total_pending,
            total_cancelled_units = v_total_cancelled,
            total_variance_cost = 0,
            unresolved_discrepancies_count = v_unresolved,
            override_reason = CASE WHEN p_allow_discrepancy_override THEN pg_catalog.btrim(p_supervisor_override_reason) ELSE NULL END,
            closed_by = v_actor_id,
            closed_at = v_now,
            is_reopened = false,
            pending_dispositions = v_disposition_results,
            discrepancy_details = v_discrepancies
        WHERE id = v_existing.id
        RETURNING id INTO v_closing_id;
    ELSE
        INSERT INTO public.daily_closings (
            daily_plan_id, shift_code, closing_date,
            total_planned_units, total_completed_units, total_pending_units, total_cancelled_units,
            total_variance_cost, unresolved_discrepancies_count, override_reason, closed_by, closed_at,
            is_reopened, pending_dispositions, discrepancy_details
        ) VALUES (
            p_daily_plan_id, v_plan.shift_code, v_plan.plan_date,
            v_total_planned, v_total_completed, v_total_pending, v_total_cancelled,
            0, v_unresolved,
            CASE WHEN p_allow_discrepancy_override THEN pg_catalog.btrim(p_supervisor_override_reason) ELSE NULL END,
            v_actor_id, v_now, false, v_disposition_results, v_discrepancies
        )
        RETURNING id INTO v_closing_id;
    END IF;

    v_old_plan_status := v_plan.status;
    UPDATE public.daily_plans
    SET status = 'CLOSED', updated_at = v_now
    WHERE id = p_daily_plan_id;

    INSERT INTO public.audit_logs (
        event_type, actor_id, target_entity_type, target_entity_id, old_state, new_state
    ) VALUES (
        'DAILY_PLAN_CLOSED', v_actor_id, 'daily_closings', v_closing_id,
        jsonb_build_object('dailyPlanStatus', v_old_plan_status),
        jsonb_build_object('dailyPlanId', p_daily_plan_id, 'shiftCode', v_plan.shift_code,
                           'unresolvedDiscrepanciesCount', v_unresolved,
                           'pendingDispositions', v_disposition_results,
                           'overrideReason', CASE WHEN p_allow_discrepancy_override THEN pg_catalog.btrim(p_supervisor_override_reason) ELSE NULL END)
    );

    v_response := public.fn_daily_closing_json(v_closing_id);
    PERFORM public.fn_complete_idempotency(
        p_idempotency_key, 'DAILY_CLOSING', v_closing_id, 200, v_response
    );
    RETURN v_response;
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_close_daily_plan(uuid, text, boolean, text, jsonb, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_close_daily_plan(uuid, text, boolean, text, jsonb, text, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.rpc_reopen_daily_closing(
    p_daily_closing_id uuid,
    p_reopen_reason text,
    p_idempotency_key text,
    p_request_hash text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
    v_actor_id uuid := auth.uid();
    v_role text := public.get_current_user_role();
    v_idem jsonb;
    v_closing public.daily_closings%ROWTYPE;
    v_plan public.daily_plans%ROWTYPE;
    v_response jsonb;
    v_reason text := pg_catalog.btrim(coalesce(p_reopen_reason, ''));
BEGIN
    IF v_actor_id IS NULL OR v_role IS DISTINCT FROM 'ADMIN' THEN
        RAISE EXCEPTION 'Only a signed-in admin can reopen a daily closing.' USING ERRCODE = '42501';
    END IF;
    IF pg_catalog.length(v_reason) < 3 OR pg_catalog.length(v_reason) > 2000 THEN
        RAISE EXCEPTION 'reopenReason must contain 3 to 2000 non-space characters.' USING ERRCODE = '23514';
    END IF;

    v_idem := public.fn_acquire_idempotency(
        p_idempotency_key,
        'POST:/api/v1/closings/<closing_id>/reopen',
        p_request_hash,
        v_actor_id
    );
    IF v_idem->>'action' = 'REPLAY' THEN
        RETURN v_idem->'body';
    ELSIF v_idem->>'action' = 'EXPIRED' THEN
        RAISE EXCEPTION 'IDEMPOTENCY_RESPONSE_EXPIRED: %', v_idem USING ERRCODE = '23514';
    END IF;

    SELECT * INTO v_closing
    FROM public.daily_closings
    WHERE id = p_daily_closing_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Daily closing was not found.' USING ERRCODE = 'P0002';
    END IF;
    IF v_closing.is_reopened THEN
        RAISE EXCEPTION 'This daily closing is already reopened.' USING ERRCODE = '23514';
    END IF;

    SELECT * INTO v_plan
    FROM public.daily_plans
    WHERE id = v_closing.daily_plan_id
    FOR UPDATE;
    IF NOT FOUND OR v_plan.status <> 'CLOSED' THEN
        RAISE EXCEPTION 'Only a closed daily plan can be reopened.' USING ERRCODE = '23514';
    END IF;

    UPDATE public.daily_closings
    SET is_reopened = true,
        reopened_by = v_actor_id,
        reopened_at = pg_catalog.clock_timestamp(),
        reopen_reason = v_reason
    WHERE id = p_daily_closing_id;

    UPDATE public.daily_plans
    SET status = 'RELEASED', updated_at = pg_catalog.clock_timestamp()
    WHERE id = v_plan.id;

    INSERT INTO public.audit_logs (
        event_type, actor_id, target_entity_type, target_entity_id, old_state, new_state
    ) VALUES (
        'DAILY_CLOSING_REOPENED', v_actor_id, 'daily_closings', p_daily_closing_id,
        jsonb_build_object('dailyPlanStatus', 'CLOSED', 'isReopened', false),
        jsonb_build_object('dailyPlanStatus', 'RELEASED', 'isReopened', true, 'reopenReason', v_reason)
    );

    v_response := public.fn_daily_closing_json(p_daily_closing_id);
    PERFORM public.fn_complete_idempotency(
        p_idempotency_key, 'DAILY_CLOSING', p_daily_closing_id, 200, v_response
    );
    RETURN v_response;
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_reopen_daily_closing(uuid, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_reopen_daily_closing(uuid, text, text, text) TO authenticated;
