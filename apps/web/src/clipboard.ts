/** Explicit UI copy only. Desktop never falls back to a permission bypass. */
export async function copyText(text: string): Promise<void> {
  if (typeof text !== 'string' || text.length === 0 || text.length > 65536 || text.includes('\0')) throw new Error('clipboard_text_rejected');
  const desktop = window.renjiDesktop;
  if (desktop) {
    if (!desktop.writeClipboardText) throw new Error('desktop_clipboard_restart_required');
    const receipt = await desktop.writeClipboardText(text);
    if (receipt?.written !== true) throw new Error('clipboard_write_unconfirmed');
    return;
  }
  if (!navigator.clipboard?.writeText) throw new Error('clipboard_unavailable');
  await navigator.clipboard.writeText(text);
}
