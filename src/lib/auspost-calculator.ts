export type ShippingSpeed = "parcel_post" | "express_post";
export type PackagingMode = "own_packaging" | "prepaid_satchel";

export interface ShippingQuote {
  netCrystalWeightGrams: number;
  packagingTareGrams: number;
  totalChargeableWeightGrams: number;
  tierLabel: string;
  postageAud: number;
  isSplitParcel: boolean;
  note: string;
}

interface RateTier {
  maxGrams: number;
  label: string;
  parcelPostOwn: number;
  parcelPostSatchel: number;
  expressPostOwn: number;
}

/**
 * Official Australia Post Domestic Flat-Rate Tiers (effective 1 July 2026)
 * Applies to all Australian postcodes up to 5kg.
 */
const AUSPOST_UP_TO_5KG_TIERS: RateTier[] = [
  {
    maxGrams: 250,
    label: "Extra Small (up to 250g)",
    parcelPostOwn: 10.20,
    parcelPostSatchel: 10.55,
    expressPostOwn: 13.20,
  },
  {
    maxGrams: 500,
    label: "Small (250g – 500g)",
    parcelPostOwn: 11.70,
    parcelPostSatchel: 12.05,
    expressPostOwn: 15.20,
  },
  {
    maxGrams: 1000,
    label: "Medium (500g – 1kg)",
    parcelPostOwn: 16.00,
    parcelPostSatchel: 16.40,
    expressPostOwn: 20.00,
  },
  {
    maxGrams: 3000,
    label: "Large (1kg – 3kg)",
    parcelPostOwn: 20.25,
    parcelPostSatchel: 20.70,
    expressPostOwn: 24.75,
  },
  {
    maxGrams: 5000,
    label: "Extra Large (3kg – 5kg)",
    parcelPostOwn: 24.45,
    parcelPostSatchel: 24.95,
    expressPostOwn: 32.95,
  },
];

function getTierPrice(
  tier: RateTier,
  speed: ShippingSpeed,
  packaging: PackagingMode
): number {
  if (speed === "express_post") return tier.expressPostOwn;
  return packaging === "prepaid_satchel"
    ? tier.parcelPostSatchel
    : tier.parcelPostOwn;
}

/**
 * Calculates domestic Australia Post shipping for an Open Box of crystals.
 *
 * @param crystalWeightsGrams Array of individual stone weights in the buyer's box
 * @param speed 'parcel_post' (default) or 'express_post'
 * @param packaging 'own_packaging' (default for boxed crystals) or 'prepaid_satchel'
 */
export function calculateOpenBoxShipping(
  crystalWeightsGrams: number[],
  speed: ShippingSpeed = "parcel_post",
  packaging: PackagingMode = "own_packaging"
): ShippingQuote {
  const itemCount = crystalWeightsGrams.length;
  const netCrystalWeightGrams = crystalWeightsGrams.reduce((sum, w) => sum + w, 0);

  // Fragile crystal packaging allowance: 120g mailer box + 25g bubble wrap per stone
  const packagingTareGrams = itemCount > 0 ? 120 + itemCount * 25 : 0;
  const totalChargeableWeightGrams = netCrystalWeightGrams + packagingTareGrams;

  // Standard path: 5kg or under (flat rate anywhere in Australia)
  if (totalChargeableWeightGrams <= 5000) {
    const matchedTier =
      AUSPOST_UP_TO_5KG_TIERS.find(
        (t) => totalChargeableWeightGrams <= t.maxGrams
      ) || AUSPOST_UP_TO_5KG_TIERS[AUSPOST_UP_TO_5KG_TIERS.length - 1];

    const postageAud = getTierPrice(matchedTier, speed, packaging);

    return {
      netCrystalWeightGrams,
      packagingTareGrams,
      totalChargeableWeightGrams,
      tierLabel: matchedTier.label,
      postageAud: Number(postageAud.toFixed(2)),
      isSplitParcel: false,
      note: `National flat rate (${packaging === "prepaid_satchel" ? "AusPost Satchel" : "Own Box"}) incl. ${packagingTareGrams}g protective wrap.`,
    };
  }

  // Heavy Open Box (> 5kg up to 10kg): Split into 2 flat-rate parcels (1x 5kg + remainder)
  // Often cheaper than interstate zone rates for heavy crystal orders.
  const firstParcelTier = AUSPOST_UP_TO_5KG_TIERS[AUSPOST_UP_TO_5KG_TIERS.length - 1]; // 5kg XL
  const remainingGrams = totalChargeableWeightGrams - 5000 + 120; // Add 2nd box tare

  const secondParcelTier =
    AUSPOST_UP_TO_5KG_TIERS.find((t) => remainingGrams <= t.maxGrams) ||
    firstParcelTier;

  const combinedPostage =
    getTierPrice(firstParcelTier, speed, packaging) +
    getTierPrice(secondParcelTier, speed, packaging);

  return {
    netCrystalWeightGrams,
    packagingTareGrams,
    totalChargeableWeightGrams,
    tierLabel: `Split Box: 1x XL (5kg) + 1x ${secondParcelTier.label}`,
    postageAud: Number(combinedPostage.toFixed(2)),
    isSplitParcel: true,
    note: `Order exceeds 5kg (${(totalChargeableWeightGrams / 1000).toFixed(2)}kg). Splitting into 2 flat-rate parcels avoids interstate heavy-zone surcharges.`,
  };
}
