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

(() => {
  const dialog = document.querySelector('#download-dialog');
  if (!dialog || typeof dialog.showModal !== 'function') return;
  let returnFocus = null;
  document.querySelectorAll('[data-download-dialog]').forEach(trigger => {
    trigger.addEventListener('click', event => {
      // Modified clicks retain the browser's ordinary direct-link behavior.
      if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
      event.preventDefault();
      returnFocus = trigger;
      dialog.showModal();
    });
  });
  dialog.querySelector('[data-dialog-close]').addEventListener('click', () => dialog.close());
  dialog.addEventListener('click', event => {
    const bounds = dialog.getBoundingClientRect();
    if (event.target === dialog && (event.clientX < bounds.left || event.clientX > bounds.right || event.clientY < bounds.top || event.clientY > bounds.bottom)) dialog.close();
  });
  dialog.addEventListener('close', () => {
    returnFocus?.focus();
    returnFocus = null;
  });
  const copy = dialog.querySelector('[data-copy-command]');
  copy.addEventListener('click', async () => {
    const status = dialog.querySelector('.copy-status');
    try {
      await navigator.clipboard.writeText(dialog.querySelector('code').textContent);
      status.textContent = copy.dataset.copiedLabel;
    } catch {
      status.textContent = copy.dataset.copyFailedLabel;
    }
  });
})();
