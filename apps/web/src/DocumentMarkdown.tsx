import { Fragment, createElement, useId, useMemo, type ReactNode } from 'react';
import { marked, type Token, type Tokens } from 'marked';
import { decodeHTML } from 'entities';

/** Only explicit web links. Never resolve relative paths against the IM/API or
 * expose local files, custom protocols, credentials, raw HTML or remote images. */
export function documentLink(href: string): string | null {
  try {
    const url = new URL(decodeHTML(href));
    if (!['https:', 'http:'].includes(url.protocol) || url.username || url.password) return null;
    return url.href;
  } catch { return null; }
}

export function DocumentMarkdown({ content }: { content: string }) {
  const prefix = useId();
  const tokens = useMemo(() => {
    if (content.length > 200000) return null;
    try { return marked.lexer(content, { gfm: true, breaks: false }); } catch { return null; }
  }, [content]);
  if (!tokens) return <div className="document-format-error" role="alert">正文格式暂时无法预览，请刷新或在现有客户端查看。</div>;
  let visited = 0;
  const slugs = new Map<string, number>();
  function slug(text: string) { return decodeHTML(text).toLocaleLowerCase().replace(/[^\p{L}\p{N}\s_-]/gu, '').trim().replace(/\s+/g, '-'); }
  function link(t: Tokens.Link, depth: number): ReactNode {
    const text = inline(t.tokens ?? [{ type: 'text', raw: t.raw, text: t.text ?? t.raw }], depth + 1);
    if (t.href.startsWith('#')) return <a href={`#${prefix}-${slug(t.href.slice(1))}`} title={t.title || undefined}>{text}</a>;
    const href = documentLink(t.href);
    return href ? <a href={href} target="_blank" rel="noopener noreferrer" referrerPolicy="no-referrer" title={t.title || href}>{text}</a>
      : <span className="document-unresolved-link" title={`此链接尚未绑定可打开的在线地址：${t.href}`}>{text}<small>（链接未绑定）</small></span>;
  }
  function inline(items: Token[], depth: number): ReactNode[] {
    return items.map((t, i) => {
      if (++visited > 30000 || depth > 64) return <Fragment key={i}>{t.raw}</Fragment>;
      let node: ReactNode;
      switch (t.type) {
        case 'text': node = t.tokens ? inline(t.tokens ?? [{ type: 'text', raw: t.raw, text: t.text ?? t.raw }], depth + 1) : decodeHTML(t.text); break;
        case 'escape': node = decodeHTML(t.text); break;
        case 'strong': node = <strong>{inline(t.tokens ?? [{ type: 'text', raw: t.raw, text: t.text ?? t.raw }], depth + 1)}</strong>; break;
        case 'em': node = <em>{inline(t.tokens ?? [{ type: 'text', raw: t.raw, text: t.text ?? t.raw }], depth + 1)}</em>; break;
        case 'del': node = <del>{inline(t.tokens ?? [{ type: 'text', raw: t.raw, text: t.text ?? t.raw }], depth + 1)}</del>; break;
        case 'codespan': node = <code>{t.text}</code>; break;
        case 'br': node = <br />; break;
        case 'link': node = link(t as Tokens.Link, depth); break;
        case 'image': {
          const href = documentLink(t.href);
          node = <span className="document-image-placeholder">[图片：{decodeHTML(t.text || '未命名图片')}]{href && <a href={href} target="_blank" rel="noopener noreferrer" referrerPolicy="no-referrer">打开图片链接</a>}</span>;
          break;
        }
        // React escapes the literal source. No dangerouslySetInnerHTML anywhere.
        default: node = t.raw;
      }
      return <Fragment key={i}>{node}</Fragment>;
    });
  }
  function blocks(items: Token[], depth = 0): ReactNode[] {
    return items.map((t, i) => {
      if (++visited > 30000 || depth > 64) return <pre className="document-literal" key={i}>{t.raw}</pre>;
      let node: ReactNode;
      switch (t.type) {
        case 'space': case 'def': return null;
        case 'heading': {
          const stem = slug(t.text), count = slugs.get(stem) ?? 0; slugs.set(stem, count + 1);
          node = createElement(`h${Math.max(1, Math.min(6, t.depth))}`, { id: `${prefix}-${stem}${count ? `-${count}` : ''}` }, inline(t.tokens ?? [{ type: 'text', raw: t.raw, text: t.text ?? t.raw }], depth + 1)); break;
        }
        case 'paragraph': case 'text': node = <p>{t.tokens ? inline(t.tokens ?? [{ type: 'text', raw: t.raw, text: t.text ?? t.raw }], depth + 1) : decodeHTML(t.text)}</p>; break;
        case 'blockquote': node = <blockquote>{blocks(t.tokens ?? [{ type: 'text', raw: t.raw, text: t.text ?? t.raw }], depth + 1)}</blockquote>; break;
        case 'code': node = <pre><code>{t.text}</code></pre>; break;
        case 'hr': node = <hr />; break;
        case 'list': {
          const content = t.items.map((item: Tokens.ListItem, j: number) => <li key={j}>{item.task && <input type="checkbox" checked={item.checked === true} disabled aria-label={item.checked ? '已完成' : '未完成'} />}{blocks(item.tokens, depth + 1)}</li>);
          node = t.ordered ? <ol start={Number(t.start) || 1}>{content}</ol> : <ul>{content}</ul>; break;
        }
        case 'table': {
          const cell = (c: Tokens.TableCell, j: number, header: boolean) => createElement(header ? 'th' : 'td', { key: j, ...(header ? { scope: 'col' } : {}), style: { textAlign: t.align[j] ?? undefined } }, inline(c.tokens, depth + 1));
          node = <div className="document-table-scroll" tabIndex={0} role="region" aria-label="文档表格，可横向滚动"><table><thead><tr>{t.header.map((c: Tokens.TableCell, j: number) => cell(c, j, true))}</tr></thead><tbody>{t.rows.map((row: Tokens.TableCell[], j: number) => <tr key={j}>{row.map((c, k) => cell(c, k, false))}</tr>)}</tbody></table></div>; break;
        }
        default: node = <pre className="document-literal">{t.raw}</pre>;
      }
      return <Fragment key={i}>{node}</Fragment>;
    });
  }
  return <div className="document-markdown">{blocks(tokens)}</div>;
}
