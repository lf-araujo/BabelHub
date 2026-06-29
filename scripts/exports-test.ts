import { JSDOM } from 'jsdom';
import { exportsForBlocks, applyExports } from '../src/exports.ts';
import { buildReportHtml } from '../src/report.ts';

// 1) Parsing: file-level default + per-language default + per-block override.
const src = `#+PROPERTY: header-args :exports both
#+PROPERTY: header-args:python :exports code

#+begin_src R
1
#+end_src

#+begin_src R :exports results
2
#+end_src

#+begin_src python
3
#+end_src

#+begin_src bash :exports none
echo hi
#+end_src
`;
const modes = exportsForBlocks(src);
console.log('modes:', modes.join(','));
const parseOk = modes.join(',') === 'both,results,code,none';

// 2) applyExports tags each pre and hides results/none code.
const dom = new JSDOM('<article id="preview"></article>');
const doc = dom.window.document;
globalThis.document = doc as unknown as Document;
const preview = doc.querySelector('#preview') as HTMLElement;
// one <pre class="src-block"> per block, in order
for (let i = 0; i < 4; i++) {
  const pre = doc.createElement('pre');
  pre.className = 'src-block';
  pre.textContent = `block ${i}`;
  preview.appendChild(pre);
}
applyExports(preview, src);
const pres = preview.querySelectorAll('pre.src-block');
const tagged = Array.from(pres).map((p) => (p as HTMLElement).dataset.exports).join(',');
const hidden = Array.from(pres).map((p) => p.classList.contains('exports-hidden'));
console.log('data-exports:', tagged);
console.log('hidden:', hidden.join(','));
const applyOk =
  tagged === 'both,results,code,none' &&
  hidden.join(',') === 'false,true,false,true'; // results + none hide code (code shows it)

// 3) Report drops .exports-hidden code from the export.
const html = buildReportHtml(preview, 'T');
const reportOk = html.includes('block 0') && !html.includes('block 1') && !html.includes('block 3');
console.log('report keeps both(0):', html.includes('block 0'));
console.log('report drops results-hidden(1):', !html.includes('block 1'));
console.log('report drops none(3):', !html.includes('block 3'));

console.log(parseOk && applyOk && reportOk ? '\nPASS' : '\nFAIL');
process.exit(parseOk && applyOk && reportOk ? 0 : 1);
