// Table of contents. Built when the document asks for one, two ways:
//   - a `* TOC` (or `* Table of Contents`) headline — the contents are inserted
//     right under it (the heading marks the spot);
//   - `#+OPTIONS: toc:t|N|nil` or a `#+TOC: headlines N` keyword — placed at top.
// uniorg drops those keywords and gives headings no ids, so we detect the
// request from source / the heading text, id the headings, and build the list.

export interface TocRequest {
  enabled: boolean;
  depth: number;
}

export function tocRequest(src: string): TocRequest {
  const toc = src.match(/^[ \t]*#\+TOC:\s*headlines\s*(\d+)?/im);
  if (toc) return { enabled: true, depth: toc[1] ? parseInt(toc[1], 10) : 3 };

  const opt = src.match(/^[ \t]*#\+OPTIONS:.*\btoc:(\S+)/im);
  if (opt) {
    const v = opt[1].toLowerCase();
    if (v === 'nil' || v === 'no' || v === 'false') return { enabled: false, depth: 0 };
    if (/^\d+$/.test(v)) return { enabled: true, depth: parseInt(v, 10) };
    return { enabled: true, depth: 3 }; // toc:t
  }
  return { enabled: false, depth: 0 };
}

function slugify(s: string): string {
  return s.toLowerCase().trim().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '') || 'section';
}

function isTocHeading(h: Element): boolean {
  const t = (h.textContent ?? '').trim().toLowerCase();
  return t === 'toc' || t === 'table of contents';
}

interface Item { level: number; text: string; id: string; }

function buildList(doc: Document, items: Item[]): HTMLUListElement {
  const root = doc.createElement('ul');
  const ulStack: HTMLUListElement[] = [root];
  const levelStack: number[] = [Math.min(...items.map((i) => i.level))];
  for (const it of items) {
    while (ulStack.length > 1 && it.level < levelStack[levelStack.length - 1]) {
      ulStack.pop();
      levelStack.pop();
    }
    while (it.level > levelStack[levelStack.length - 1]) {
      const parent = ulStack[ulStack.length - 1];
      let host = parent.lastElementChild as HTMLElement | null;
      if (!host) {
        host = doc.createElement('li');
        parent.appendChild(host);
      }
      const sub = doc.createElement('ul');
      host.appendChild(sub);
      ulStack.push(sub);
      levelStack.push(levelStack[levelStack.length - 1] + 1);
    }
    const li = doc.createElement('li');
    const a = doc.createElement('a');
    a.href = `#${it.id}`;
    a.textContent = it.text;
    li.appendChild(a);
    ulStack[ulStack.length - 1].appendChild(li);
  }
  return root;
}

/** Insert a linked TOC if the document requests one (heading, OPTIONS, or keyword). */
export function applyToc(preview: HTMLElement, src: string): void {
  const doc = preview.ownerDocument;
  const req = tocRequest(src);
  const tocHeading = Array.from(preview.querySelectorAll('h1,h2,h3,h4,h5,h6')).find(isTocHeading) as
    | HTMLElement
    | undefined;

  if (!tocHeading && !req.enabled) return;

  const depth = req.depth || 3;
  const selector = Array.from({ length: depth }, (_, i) => `h${i + 1}`).join(',');
  const heads = Array.from(preview.querySelectorAll<HTMLElement>(selector)).filter(
    (h) => h !== tocHeading
  );
  if (heads.length === 0) return;

  const used = new Set<string>();
  const items: Item[] = heads.map((h) => {
    let id = h.id || slugify(h.textContent ?? '');
    const base = id;
    let n = 2;
    while (used.has(id)) id = `${base}-${n++}`;
    used.add(id);
    h.id = id;
    return { level: parseInt(h.tagName[1], 10), text: h.textContent ?? '', id };
  });

  const list = buildList(doc, items);

  if (tocHeading) {
    // The `* TOC` heading is the title; drop the list directly under it.
    list.className = 'toc-list';
    tocHeading.insertAdjacentElement('afterend', list);
  } else {
    const nav = doc.createElement('nav');
    nav.className = 'toc';
    const title = doc.createElement('div');
    title.className = 'toc-title';
    title.textContent = 'Table of Contents';
    nav.append(title, list);
    preview.prepend(nav);
  }
}
