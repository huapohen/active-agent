import { act, cleanup, render, waitFor } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { StartupClient } from './api';
import { EmojiIcon } from './MessageActions';

afterEach(() => { cleanup(); vi.restoreAllMocks(); });
describe('authenticated emoji image lifetime', () => {
  it('revokes blobs on removal and changes identity without showing the old image', async () => {
    Object.defineProperty(URL, 'createObjectURL', { configurable: true, value: vi.fn(() => 'blob:synthetic-image') });
    Object.defineProperty(URL, 'revokeObjectURL', { configurable: true, value: vi.fn() });
    const c = new StartupClient('https://work.example', async () => null);
    vi.spyOn(c, 'emojiAsset').mockResolvedValue(new Blob(['synthetic'], { type: 'image/png' }));
    const props = { id: 'feishu:OK', asset: '/v1/emoji/assets/feishu/OK.png', revision: 'sha256:synthetic' };
    const view = render(<EmojiIcon client={c} {...props} />);
    await waitFor(() => expect(view.container.querySelector('img')?.getAttribute('src')).toBe('blob:synthetic-image'));
    const next = new StartupClient('https://work.example', async () => null);
    let finish!: (blob: Blob) => void; const pending = vi.spyOn(next, 'emojiAsset').mockImplementation(() => new Promise(ok => { finish = ok; }));
    view.rerender(<EmojiIcon client={next} {...props} />);
    expect(view.container.querySelector('img')).toBeNull(); expect(URL.revokeObjectURL).toHaveBeenCalledWith('blob:synthetic-image');
    view.unmount(); expect(pending.mock.calls[0][2]?.aborted).toBe(true);
    await act(async () => finish(new Blob(['late']))); expect(URL.createObjectURL).toHaveBeenCalledTimes(1);
  });
});
