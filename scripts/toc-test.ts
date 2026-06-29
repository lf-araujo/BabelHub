import { JSDOM } from 'jsdom';
import { tocRequest, applyToc } from '../src/toc.ts';

// 1) request parsing (OPTIONS / keyword)
const r1 = tocRequest('#+TOC: headlines 2\n* A');
const r2 = tocRequest('#+OPTIONS: toc:nil\n* A');
const r3 = tocRequest('#+OPTIONS: author:t toc:3\n* A');
const parseOk = r1.enabled && r1.depth === 2 && !r2.enabled && r3.enabled && r3.depth === 3;
console.log('parse:', JSON.stringify(r1), JSON.stringify(r2), JSON.stringify(r3));

function mk(html: string) {
  const dom = new JSDOM(`<article id="preview">${html}</article>`);
  globalThis.document = dom.window.document as unknown as Document;
  return dom.window.document.querySelector('#preview') as HTMLElement;
}

// 2) a `* TOC` heading -> list inserted right under it, excluding the heading
const p1 = mk('<h1>TOC</h1><h1>First</h1><h2>Sub</h2><h1>Second</h1>');
applyToc(p1, '* TOC\n* First\n** Sub\n* Second\n');
const tocH = Array.from(p1.querySelectorAll('h1')).find((h) => h.textContent === 'TOC')!;
const listAfter = tocH.nextElementSibling; // should be the toc-list
const links1 = Array.from(p1.querySelectorAll('.toc-list a')).map((a) => a.textContent);
console.log('\npositional list after heading:', listAfter?.classList.contains('toc-list'));
console.log('positional links:', links1.join(', '), '(TOC excluded)');
const posOk =
  listAfter?.classList.contains('toc-list') === true &&
  links1.join(',') === 'First,Sub,Second' &&
  (p1.querySelector('h1#first') as HTMLElement)?.id === 'first';

// 3) OPTIONS toc:2 with no heading -> nav at top, depth-limited
const p2 = mk('<h1>First</h1><h2>Sub</h2><h3>Deep</h3>');
applyToc(p2, '#+OPTIONS: toc:2\n');
const nav = p2.querySelector('nav.toc');
const links2 = Array.from(p2.querySelectorAll('nav.toc a')).map((a) => a.textContent);
console.log('top nav first child:', p2.firstElementChild === nav, '| links:', links2.join(', '));
const topOk = nav !== null && p2.firstElementChild === nav && links2.join(',') === 'First,Sub'; // h3 excluded

// 4) no request -> nothing
const p3 = mk('<h1>A</h1>');
applyToc(p3, '* A\n');
const noneOk = p3.querySelector('.toc, .toc-list') === null;

console.log(parseOk && posOk && topOk && noneOk ? '\nPASS' : '\nFAIL');
process.exit(parseOk && posOk && topOk && noneOk ? 0 : 1);
