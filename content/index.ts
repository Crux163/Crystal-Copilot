import {
  findFieldByAccessibleLabel,
  injectPhotosIntoFileInput,
  setReactNativeValue,
} from "./dom-helpers";

interface CrystalPayload {
  live_tag_number: number;
  seo_title: string;
  social_description: string;
  retail_price_aud: number;
  weight_grams: number;
  mineral_name: string;
  images: { dataUrl: string; filename: string }[];
}

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message.type !== "AUTOFILL_CRYSTAL") return;

  const crystal: CrystalPayload = message.payload;
  const host = window.location.hostname;

  (async () => {
    await injectPhotosIntoFileInput(crystal.images);

    if (host.includes("facebook.com")) {
      // Facebook Marketplace (/marketplace/create/item)
      const titleEl = findFieldByAccessibleLabel(["title"]);
      const priceEl = findFieldByAccessibleLabel(["price"]);
      const descEl = findFieldByAccessibleLabel(["description"]);

      if (titleEl) setReactNativeValue(titleEl, `${crystal.seo_title} [#${crystal.live_tag_number}]`);
      if (priceEl) setReactNativeValue(priceEl, Math.round(crystal.retail_price_aud).toString());
      if (descEl) setReactNativeValue(descEl, crystal.social_description);
    } else if (host.includes("gumtree.com.au")) {
      // Gumtree Australia (/p-post-ad.html)
      const titleEl = findFieldByAccessibleLabel(["ad title", "title"]);
      const priceEl = findFieldByAccessibleLabel(["price"]);
      const descEl = findFieldByAccessibleLabel(["description"]);

      if (titleEl) setReactNativeValue(titleEl, crystal.seo_title);
      if (priceEl) setReactNativeValue(priceEl, crystal.retail_price_aud.toFixed(2));
      if (descEl) setReactNativeValue(descEl, crystal.social_description);
    } else if (host.includes("depop.com")) {
      // Depop (/products/create)
      const descEl = findFieldByAccessibleLabel(["description", "tell buyers"]);
      const priceEl = findFieldByAccessibleLabel(["price"]);

      const depopCopy = `${crystal.seo_title}\n\n${crystal.social_description}\n\n#crystals #crystalshop #minerals #${crystal.mineral_name.toLowerCase().replace(/\s+/g, "")}`;
      if (descEl) setReactNativeValue(descEl, depopCopy);
      if (priceEl) setReactNativeValue(priceEl, crystal.retail_price_aud.toFixed(2));
    }

    sendResponse({ ok: true });
  })();

  return true; // Keeps message channel open for async response
});
