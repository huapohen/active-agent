import { afterEach, describe, expect, it } from 'vitest';
import { cleanup, render, screen, within } from '@testing-library/react';
import { DocumentMarkdown, documentLink } from './DocumentMarkdown';
afterEach(cleanup);
describe('readable Markdown without HTML execution', () => {
  it('retains headings, list nesting, table headers, cell order, bold and inline/fenced code', () => {
    const body = '# 交付\n\n## 验收\n\n- 人\n  - Agent\n\n| 主体 | 状态 |\n| --- | --- |\n| **机伴** | `ready` |\n\n```ts\nconst x = "<script>";\n```';
    const view = render(<DocumentMarkdown content={body} />);
    expect(screen.getByRole('heading', { level: 1, name: '交付' })).toBeTruthy(); expect(screen.getByRole('heading', { level: 2, name: '验收' })).toBeTruthy();
    expect(screen.getAllByRole('list')).toHaveLength(2); expect(screen.getAllByRole('columnheader').map(x => x.textContent)).toEqual(['主体', '状态']);
    const cells = screen.getAllByRole('cell'); expect(cells.map(x => x.textContent)).toEqual(['机伴', 'ready']);
    expect(cells[0].querySelector('strong')).toBeTruthy(); expect(cells[1].querySelector('code')).toBeTruthy();
    expect(view.container.querySelector('pre code')?.textContent).toBe('const x = "<script>";');
    expect(screen.getByRole('region', { name: '文档表格，可横向滚动' }).getAttribute('tabindex')).toBe('0');
  });
  it('renders raw scripts/iframes/images as literal text and never inserts their elements', () => {
    const view = render(<DocumentMarkdown content={'<script>alert(1)</script>\n\n<iframe src="https://evil.invalid"></iframe>\n\n<img src=x onerror="alert(1)">\n\n![示意图](https://example.com/image.png)'} />);
    expect(view.container.querySelector('script,iframe,img,object,embed')).toBeNull();
    expect(view.container.textContent).toContain('<script>alert(1)</script>'); expect(screen.getByRole('link', { name: '打开图片链接' }).getAttribute('referrerpolicy')).toBe('no-referrer');
  });
  it('blocks dangerous/credential/relative URLs while preserving visible labels and destinations', () => {
    for (const url of ['javascript:alert(1)', 'java\nscript:alert(1)', 'java&#x73;cript:alert(1)', 'data:text/html,a', 'file:///etc/passwd', 'https://user:secret@example.com', 'MANUAL_STARTUP_GUIDE.md', '//example.com']) expect(documentLink(url)).toBeNull();
    render(<DocumentMarkdown content={'[危险](javascript:alert) [安全](https://example.com/doc?q=1) [教程](MANUAL_STARTUP_GUIDE.md)'} />);
    const links = screen.getAllByRole('link'); expect(links).toHaveLength(1); expect(links[0].getAttribute('href')).toBe('https://example.com/doc?q=1'); expect(links[0].getAttribute('target')).toBe('_blank');
    expect(screen.getByText('教程').getAttribute('title')).toContain('MANUAL_STARTUP_GUIDE.md');
  });
  it('decodes text entities without treating decoded characters as HTML or code entities as markup', () => {
    const view = render(<DocumentMarkdown content={'&lt;script&gt; &amp; &#x4EBA; **&copy;** `&lt;b&gt;`'} />);
    expect(view.container.textContent).toContain('<script> & 人 © &lt;b&gt;'); expect(view.container.querySelector('script')).toBeNull(); expect(view.container.querySelector('code')?.textContent).toBe('&lt;b&gt;');
  });
  it('keeps links to same-document headings in the local reader instead of API routes', () => {
    const view = render(<DocumentMarkdown content={'## 验收记录\n\n[回到验收](#验收记录)'} />);
    const header = screen.getByRole('heading', { level: 2 }); expect(screen.getByRole('link').getAttribute('href')).toBe('#' + header.id); expect(view.container.querySelector('a')?.getAttribute('target')).toBeNull();
  });
  it('keeps ordered and task lists as inert read-only content', () => {
    render(<DocumentMarkdown content={'3. 三\n4. 四\n\n- [x] 完成\n- [ ] 待办'} />);
    expect(screen.getAllByRole('list')[0].getAttribute('start')).toBe('3'); expect(screen.getAllByRole('checkbox').every(x => (x as HTMLInputElement).disabled)).toBe(true);
    expect(within(screen.getAllByRole('list')[0]).getAllByRole('listitem')).toHaveLength(2);
  });
});
