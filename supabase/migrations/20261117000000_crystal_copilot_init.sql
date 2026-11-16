-- Enable UUID generation
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Custom Enums
CREATE TYPE crystal_status AS ENUM (
  'draft',
  'available',
  'claimed_unpaid',
  'paid',
  'shipped'
);

CREATE TYPE listing_platform AS ENUM (
  'ebay_au',
  'fb_marketplace',
  'fb_group',
  'gumtree',
  'depop',
  'fb_live',
  'ig_live'
);

CREATE TYPE listing_sync_status AS ENUM (
  'active',
  'needs_manual_delist',
  'ended'
);

CREATE TYPE box_payment_status AS ENUM (
  'open',
  'invoiced',
  'paid'
);

CREATE TYPE box_fulfillment_status AS ENUM (
  'accumulating',
  'ready_to_pack',
  'shipped'
);

-- 1. Seller Profiles (PayID & Store Settings)
CREATE TABLE public.seller_profiles (
  user_id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  shop_name TEXT NOT NULL DEFAULT 'My Crystal Studio',
  shop_slug TEXT UNIQUE NOT NULL,
  payid_identifier TEXT, -- Phone, Email, or ABN
  payid_account_name TEXT,
  origin_postcode TEXT NOT NULL DEFAULT '2000',
  default_markup_multiplier NUMERIC(4,2) NOT NULL DEFAULT 2.50,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 2. Wholesale Lots (Cost & Margin Tracking)
CREATE TABLE public.wholesale_lots (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  supplier_name TEXT NOT NULL,
  purchase_date DATE NOT NULL DEFAULT CURRENT_DATE,
  total_cost_aud NUMERIC(10,2) NOT NULL CHECK (total_cost_aud >= 0),
  shipping_paid_aud NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (shipping_paid_aud >= 0),
  total_weight_grams INTEGER CHECK (total_weight_grams > 0),
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 3. Crystals (Single Source of Truth for OOAK Inventory)
CREATE TABLE public.crystals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  lot_id UUID REFERENCES public.wholesale_lots(id) ON DELETE SET NULL,
  live_tag_number INTEGER NOT NULL,
  mineral_name TEXT NOT NULL,
  shape_type TEXT NOT NULL DEFAULT 'specimen',
  weight_grams INTEGER NOT NULL CHECK (weight_grams > 0),
  cost_aud NUMERIC(10,2) NOT NULL DEFAULT 0,
  floor_price_aud NUMERIC(10,2) NOT NULL DEFAULT 0,
  retail_price_aud NUMERIC(10,2) NOT NULL,
  sold_price_aud NUMERIC(10,2),
  sold_channel listing_platform,
  sold_at TIMESTAMPTZ,
  seo_title TEXT NOT NULL,
  social_description TEXT NOT NULL,
  care_warning TEXT,
  photo_urls TEXT[] NOT NULL DEFAULT '{}',
  status crystal_status NOT NULL DEFAULT 'available',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (user_id, live_tag_number)
);

-- Auto-assign next sequential # tag (starting at 101) if omitted
CREATE OR REPLACE FUNCTION public.assign_next_live_tag()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.live_tag_number IS NULL THEN
    SELECT COALESCE(MAX(live_tag_number), 100) + 1
    INTO NEW.live_tag_number
    FROM public.crystals
    WHERE user_id = NEW.user_id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_assign_live_tag
BEFORE INSERT ON public.crystals
FOR EACH ROW EXECUTE FUNCTION public.assign_next_live_tag();

-- 4. Channel Listings (Anti-Double-Sell Sync Tracker)
CREATE TABLE public.channel_listings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  crystal_id UUID NOT NULL REFERENCES public.crystals(id) ON DELETE CASCADE,
  platform listing_platform NOT NULL,
  external_listing_id TEXT,
  listing_url TEXT,
  sync_status listing_sync_status NOT NULL DEFAULT 'active',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (crystal_id, platform)
);

-- 5. Buyers (Live Stream & Repeat Customer CRM)
CREATE TABLE public.buyers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  facebook_name TEXT NOT NULL,
  display_name TEXT,
  email TEXT,
  shipping_address TEXT,
  postcode TEXT,
  prefers_open_box BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (user_id, facebook_name)
);

-- 6. Open Boxes (Multi-Stream Customer Tabs)
CREATE TABLE public.open_boxes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  buyer_id UUID NOT NULL REFERENCES public.buyers(id) ON DELETE CASCADE,
  payid_reference TEXT NOT NULL, -- e.g., GEM-1042
  cumulative_weight_grams INTEGER NOT NULL DEFAULT 0,
  estimated_postage_aud NUMERIC(10,2) NOT NULL DEFAULT 0,
  payment_status box_payment_status NOT NULL DEFAULT 'open',
  box_status box_fulfillment_status NOT NULL DEFAULT 'accumulating',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 7. Live Claims (Line Items inside an Open Box)
CREATE TABLE public.live_claims (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  open_box_id UUID NOT NULL REFERENCES public.open_boxes(id) ON DELETE CASCADE,
  crystal_id UUID NOT NULL UNIQUE REFERENCES public.crystals(id) ON DELETE RESTRICT,
  claimed_price_aud NUMERIC(10,2) NOT NULL,
  claimed_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Performance Indexes
CREATE INDEX idx_crystals_user_status ON public.crystals(user_id, status);
CREATE INDEX idx_crystals_ebay_cap ON public.crystals(user_id, sold_channel, sold_at);
CREATE INDEX idx_channel_listings_sync ON public.channel_listings(user_id, sync_status);
CREATE INDEX idx_open_boxes_buyer ON public.open_boxes(user_id, buyer_id, box_status);

-- 8. Rolling 12-Month eBay Australia $25,000 AUD Fee-Free Cap View
CREATE OR REPLACE VIEW public.ebay_au_rolling_12m_cap
WITH (security_invoker = true) AS
SELECT
  sp.user_id,
  COALESCE(SUM(c.sold_price_aud), 0.00) AS rolling_12m_sales_aud,
  25000.00 - COALESCE(SUM(c.sold_price_aud), 0.00) AS remaining_cap_aud,
  ROUND((COALESCE(SUM(c.sold_price_aud), 0.00) / 25000.00) * 100, 1) AS percent_used,
  CASE
    WHEN COALESCE(SUM(c.sold_price_aud), 0.00) >= 25000.00 THEN 'exceeded'
    WHEN COALESCE(SUM(c.sold_price_aud), 0.00) >= 23750.00 THEN 'critical_95pct'
    WHEN COALESCE(SUM(c.sold_price_aud), 0.00) >= 20000.00 THEN 'warning_80pct'
    ELSE 'safe'
  END AS cap_status
FROM public.seller_profiles sp
LEFT JOIN public.crystals c
  ON c.user_id = sp.user_id
  AND c.sold_channel = 'ebay_au'
  AND c.status IN ('paid', 'shipped')
  AND c.sold_at >= (NOW() - INTERVAL '365 days')
GROUP BY sp.user_id;

-- ============================================================================
-- ROW LEVEL SECURITY (RLS) POLICIES
-- ============================================================================
ALTER TABLE public.seller_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wholesale_lots ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.crystals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.channel_listings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.buyers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.open_boxes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.live_claims ENABLE ROW LEVEL SECURITY;

-- Owner full access policies (using cached SELECT auth.uid() for speed)
CREATE POLICY "Owner full access on seller_profiles" ON public.seller_profiles
  FOR ALL USING ((SELECT auth.uid()) = user_id) WITH CHECK ((SELECT auth.uid()) = user_id);

CREATE POLICY "Owner full access on wholesale_lots" ON public.wholesale_lots
  FOR ALL USING ((SELECT auth.uid()) = user_id) WITH CHECK ((SELECT auth.uid()) = user_id);

CREATE POLICY "Owner full access on crystals" ON public.crystals
  FOR ALL USING ((SELECT auth.uid()) = user_id) WITH CHECK ((SELECT auth.uid()) = user_id);

CREATE POLICY "Owner full access on channel_listings" ON public.channel_listings
  FOR ALL USING ((SELECT auth.uid()) = user_id) WITH CHECK ((SELECT auth.uid()) = user_id);

CREATE POLICY "Owner full access on buyers" ON public.buyers
  FOR ALL USING ((SELECT auth.uid()) = user_id) WITH CHECK ((SELECT auth.uid()) = user_id);

CREATE POLICY "Owner full access on open_boxes" ON public.open_boxes
  FOR ALL USING ((SELECT auth.uid()) = user_id) WITH CHECK ((SELECT auth.uid()) = user_id);

CREATE POLICY "Owner full access on live_claims" ON public.live_claims
  FOR ALL USING ((SELECT auth.uid()) = user_id) WITH CHECK ((SELECT auth.uid()) = user_id);

-- Public read-only access for the /drop Live Preview Gallery
CREATE POLICY "Public can view shop names" ON public.seller_profiles
  FOR SELECT TO anon USING (TRUE);

CREATE POLICY "Public can view available crystals" ON public.crystals
  FOR SELECT TO anon USING (status = 'available');

-- Enable Realtime for Live Showrunner Grid
ALTER PUBLICATION supabase_realtime ADD TABLE public.crystals, public.open_boxes, public.live_claims;
