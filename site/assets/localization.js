// Explicit locale URLs are authoritative. No storage, language sniffing or redirect
// can override an English selection, including when browser storage is blocked.
(() => {
  const selector = document.querySelector('#website-language');
  if (!selector) return;
  selector.addEventListener('change', () => {
    const destination = new URL(selector.value, window.location.href);
    destination.search = window.location.search;
    destination.hash = window.location.hash;
    window.location.assign(destination.href);
  });
})();
