/**
 * Safely updates controlled React <input> and <textarea> elements
 * by invoking the native prototype setter and firing bubbling events.
 */
export function setReactNativeValue(
  element: HTMLInputElement | HTMLTextAreaElement,
  value: string
): void {
  const prototype =
    element instanceof HTMLTextAreaElement
      ? window.HTMLTextAreaElement.prototype
      : window.HTMLInputElement.prototype;

  const nativeSetter = Object.getOwnPropertyDescriptor(prototype, "value")?.set;

  element.focus();
  if (nativeSetter) {
    nativeSetter.call(element, value);
  } else {
    element.value = value;
  }

  element.dispatchEvent(new Event("input", { bubbles: true }));
  element.dispatchEvent(new Event("change", { bubbles: true }));
  element.blur();
}

/**
 * Finds an input or textarea by its accessible label text (resilient to CSS changes).
 */
export function findFieldByAccessibleLabel(
  keywords: string[]
): HTMLInputElement | HTMLTextAreaElement | null {
  const lowerKeywords = keywords.map((k) => k.toLowerCase());

  // 1. Check aria-label and placeholder attributes directly
  const candidates = Array.from(
    document.querySelectorAll<HTMLInputElement | HTMLTextAreaElement>(
      "input:not([type='hidden']):not([type='file']), textarea"
    )
  );

  for (const el of candidates) {
    const aria = (el.getAttribute("aria-label") || "").toLowerCase();
    const placeholder = (el.getAttribute("placeholder") || "").toLowerCase();
    if (lowerKeywords.some((kw) => aria.includes(kw) || placeholder.includes(kw))) {
      return el;
    }
  }

  // 2. Fallback: Match adjacent <label> or <span> text inside the same field wrapper
  const labels = Array.from(document.querySelectorAll("label, span"));
  for (const label of labels) {
    const text = (label.textContent || "").trim().toLowerCase();
    if (lowerKeywords.some((kw) => text === kw || text.startsWith(kw))) {
      const container = label.closest("div");
      const input = container?.querySelector<HTMLInputElement | HTMLTextAreaElement>(
        "input:not([type='hidden']):not([type='file']), textarea"
      );
      if (input) return input;
    }
  }

  return null;
}

/**
 * Converts base64 image payloads from the background worker into File objects
 * and dispatches them onto the marketplace's file dropzone input.
 */
export async function injectPhotosIntoFileInput(
  base64Images: { dataUrl: string; filename: string }[]
): Promise<boolean> {
  const fileInput = document.querySelector<HTMLInputElement>('input[type="file"]');
  if (!fileInput || base64Images.length === 0) return false;

  const dataTransfer = new DataTransfer();

  for (const img of base64Images) {
    const res = await fetch(img.dataUrl);
    const blob = await res.blob();
    const file = new File([blob], img.filename, { type: blob.type || "image/jpeg" });
    dataTransfer.items.add(file);
  }

  fileInput.files = dataTransfer.files;
  fileInput.dispatchEvent(new Event("change", { bubbles: true }));
  return true;
}
