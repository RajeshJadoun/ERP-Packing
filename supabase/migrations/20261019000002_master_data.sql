-- =============================================================================
-- Migration 000002: Master Data Catalogs and Conversion Framework
-- Packing Material Inventory & BOM Management System
-- Database: Supabase PostgreSQL 15+
-- =============================================================================

-- 1. Table 2: material_categories (Data-driven categorization)
CREATE TABLE public.material_categories (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code text NOT NULL UNIQUE,
    name text NOT NULL,
    description text,
    is_active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX idx_material_categories_active ON public.material_categories(is_active);

-- 2. Table 3: parties (Customers / Brand Owners)
CREATE TABLE public.parties (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code text NOT NULL UNIQUE,
    name text NOT NULL,
    contact_info jsonb,
    is_active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX idx_parties_active ON public.parties(is_active);

-- 3. Table 4: products (Finished Goods Catalog)
CREATE TABLE public.products (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    sku_code text NOT NULL UNIQUE,
    name text NOT NULL,
    description text,
    default_party_id uuid REFERENCES public.parties(id) ON DELETE RESTRICT,
    is_active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX idx_products_party ON public.products(default_party_id);
CREATE INDEX idx_products_active ON public.products(is_active);

-- 4. Table 5: vendors (Raw Material Suppliers)
CREATE TABLE public.vendors (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    vendor_code text NOT NULL UNIQUE,
    name text NOT NULL,
    contact_details jsonb,
    is_active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX idx_vendors_active ON public.vendors(is_active);

-- 5. Table 6: units (Measurement Units across physical dimensions)
CREATE TABLE public.units (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code text NOT NULL UNIQUE,
    name text NOT NULL,
    dimension text NOT NULL CHECK (dimension IN ('MASS', 'COUNT', 'LENGTH', 'VOLUME', 'AREA')),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

-- 6. Table 7: materials (Packing Material Variants)
CREATE TABLE public.materials (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    material_code text NOT NULL UNIQUE,
    name text NOT NULL,
    category_id uuid NOT NULL REFERENCES public.material_categories(id) ON DELETE RESTRICT,
    canonical_unit_id uuid NOT NULL REFERENCES public.units(id) ON DELETE RESTRICT,
    specifications jsonb,
    is_active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX idx_materials_category ON public.materials(category_id);
CREATE INDEX idx_materials_canonical_unit ON public.materials(canonical_unit_id);
CREATE INDEX idx_materials_active ON public.materials(is_active);

-- Immutability Protection: Canonical unit cannot be mutated once assigned
CREATE OR REPLACE FUNCTION public.trg_protect_material_canonical_unit()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.canonical_unit_id IS DISTINCT FROM OLD.canonical_unit_id THEN
        RAISE EXCEPTION 'Cannot modify canonical_unit_id of an existing material variant.'
            USING ERRCODE = '23514';
    END IF;
    NEW.updated_at = clock_timestamp();
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_protect_material_canonical_unit_before_update
BEFORE UPDATE ON public.materials
FOR EACH ROW
EXECUTE FUNCTION public.trg_protect_material_canonical_unit();

-- 7. Table 8: material_conversions (Material-specific Unit Conversion Rules)
CREATE TABLE public.material_conversions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    material_id uuid NOT NULL REFERENCES public.materials(id) ON DELETE RESTRICT,
    from_unit_id uuid NOT NULL REFERENCES public.units(id) ON DELETE RESTRICT,
    to_unit_id uuid NOT NULL REFERENCES public.units(id) ON DELETE RESTRICT,
    conversion_factor numeric NOT NULL CHECK (conversion_factor > 0),
    is_exact boolean NOT NULL DEFAULT false,
    effective_from timestamptz NOT NULL,
    effective_to timestamptz,
    notes text,
    created_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT chk_conversions_diff_units CHECK (from_unit_id != to_unit_id),
    CONSTRAINT chk_conversions_effective_range CHECK (effective_to IS NULL OR effective_to > effective_from)
);

CREATE INDEX idx_material_conversions_material ON public.material_conversions(material_id);
CREATE INDEX idx_material_conversions_units ON public.material_conversions(from_unit_id, to_unit_id);
CREATE INDEX idx_material_conversions_effective ON public.material_conversions(material_id, effective_from, effective_to);

-- 8. Table 9: locations (Warehouse Topology and Shop-Floor Zones)
CREATE TABLE public.locations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    location_code text NOT NULL UNIQUE,
    name text NOT NULL,
    parent_location_id uuid REFERENCES public.locations(id) ON DELETE RESTRICT,
    location_type text NOT NULL CHECK (location_type IN ('STORE_SHELF', 'SHOP_FLOOR_BUFFER', 'RECEIVING_BAY', 'WORKER_CUSTODY', 'DAMAGE_QUARANTINE', 'DISPATCH')),
    is_leaf boolean NOT NULL DEFAULT true,
    is_active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT chk_locations_not_self_parent CHECK (parent_location_id IS DISTINCT FROM id)
);

CREATE INDEX idx_locations_parent ON public.locations(parent_location_id);
CREATE INDEX idx_locations_type_leaf ON public.locations(location_type, is_leaf, is_active);

-- 9. Table 10: workers (Shop-Floor Packing Operators)
CREATE TABLE public.workers (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    worker_code text NOT NULL UNIQUE,
    name text NOT NULL,
    assigned_location_id uuid NOT NULL UNIQUE REFERENCES public.locations(id) ON DELETE RESTRICT,
    is_active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX idx_workers_active ON public.workers(is_active);

-- 10. Seed Legitimate Standard Physical Units
INSERT INTO public.units (code, name, dimension) VALUES
    ('KG', 'Kilogram', 'MASS'),
    ('G', 'Gram', 'MASS'),
    ('PCS', 'Piece', 'COUNT'),
    ('ROLL', 'Roll', 'COUNT'),
    ('BUNDLE', 'Bundle', 'COUNT'),
    ('BOX', 'Box', 'COUNT'),
    ('M', 'Meter', 'LENGTH'),
    ('MM', 'Millimeter', 'LENGTH')
ON CONFLICT (code) DO NOTHING;

-- 11. Seed Initial Packaging Material Categories
INSERT INTO public.material_categories (code, name, description) VALUES
    ('CORRUGATED_BOX', 'Corrugated Boxes', 'Outer shipper cartons and corrugated inner boxes'),
    ('POLY_BAG', 'Poly Bags', 'LDPE/PP protective plastic bags and pouches'),
    ('TAPE', 'Adhesive Tapes', 'BOPP packing and sealing tapes'),
    ('LABEL', 'Labels & Stickers', 'Barcode, shipping, and branding printed labels'),
    ('STRAPPING', 'Strapping Rolls', 'Polypropylene plastic strapping rolls')
ON CONFLICT (code) DO NOTHING;
