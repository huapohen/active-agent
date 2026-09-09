import { afterEach, describe, expect, it, vi } from 'vitest';
import { copyText } from './clipboard';
const desktop = (writeClipboardText?: (text: string) => Promise<{ written: boolean }>) => ({ platform: 'darwin', writeClipboardText, connectRongCloud: vi.fn(), disconnectRongCloud: vi.fn(), onRongCloud: vi.fn() });
afterEach(() => { delete window.renjiDesktop; vi.restoreAllMocks(); });
describe('explicit clipboard copy', () => {
  it('uses the bounded native bridge in desktop without calling denied browser clipboard', async () => {
    const native = vi.fn(async () => ({ written: true })), browser = vi.fn(async () => { throw new Error('permission denied'); });
    window.renjiDesktop = desktop(native); Object.defineProperty(navigator, 'clipboard', { configurable: true, value: { writeText: browser } });
    await copyText('合成文本'); expect(native).toHaveBeenCalledWith('合成文本'); expect(browser).not.toHaveBeenCalled();
  });
  it('uses browser clipboard with the original receiver when no desktop bridge is present', async () => {
    const clipboard = { writeText: vi.fn(async function (this: unknown, text: string) { expect(this).toBe(clipboard); expect(text).toBe('合成文本'); }) };
    Object.defineProperty(navigator, 'clipboard', { configurable: true, value: clipboard }); await copyText('合成文本'); expect(clipboard.writeText).toHaveBeenCalledOnce();
  });
  it('rejects unavailable or unconfirmed desktop writes instead of reporting a false success or falling back', async () => {
    const browser = vi.fn(); Object.defineProperty(navigator, 'clipboard', { configurable: true, value: { writeText: browser } });
    window.renjiDesktop = desktop(); await expect(copyText('synthetic')).rejects.toThrow('desktop_clipboard_restart_required');
    window.renjiDesktop = desktop(vi.fn(async () => ({ written: false }))); await expect(copyText('synthetic')).rejects.toThrow('clipboard_write_unconfirmed'); expect(browser).not.toHaveBeenCalled();
  });
  it('rejects invalid and oversized input before any native call', async () => {
    const native = vi.fn(async () => ({ written: true })); window.renjiDesktop = desktop(native);
    for (const value of ['', 'x\0y', 'x'.repeat(65537)]) await expect(copyText(value)).rejects.toThrow('clipboard_text_rejected'); expect(native).not.toHaveBeenCalled();
  });
});
