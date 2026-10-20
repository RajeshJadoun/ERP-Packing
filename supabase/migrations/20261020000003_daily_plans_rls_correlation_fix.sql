-- =============================================================================
-- Migration 000010: Correct Daily Plan Draft-Only RLS Correlation
-- =============================================================================
-- The previous policy referenced the inner packing_jobs.id instead of the
-- parent daily_plans.id. Correct both USING and WITH CHECK so plans cannot be
-- modified directly once any linked job has left DRAFT.
DROP POLICY IF EXISTS daily_plans_update_draft_planner_admin ON public.daily_plans;

CREATE POLICY daily_plans_update_draft_planner_admin
    ON public.daily_plans
    FOR UPDATE
    TO authenticated
    USING (
        (SELECT public.get_current_user_role()) IN ('ADMIN', 'PLANNER')
        AND NOT EXISTS (
            SELECT 1
            FROM public.packing_jobs AS pj
            WHERE pj.daily_plan_id = daily_plans.id
              AND pj.status <> 'DRAFT'
        )
    )
    WITH CHECK (
        (SELECT public.get_current_user_role()) IN ('ADMIN', 'PLANNER')
        AND NOT EXISTS (
            SELECT 1
            FROM public.packing_jobs AS pj
            WHERE pj.daily_plan_id = daily_plans.id
              AND pj.status <> 'DRAFT'
        )
    );
