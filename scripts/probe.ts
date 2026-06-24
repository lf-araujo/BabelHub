import { readFileSync } from 'node:fs';
import { JSDOM } from 'jsdom';
import { renderOrg } from '../src/render.ts';
import { attachRunButtons } from '../src/run.ts';

const org = readFileSync(new URL('../public/sample.org', import.meta.url), 'utf8');
const html = await renderOrg(org);

const dom = new JSDOM(`<article id="preview">${html}</article>`);
const preview = dom.window.document.querySelector('#preview')!;

// Provide the globals attachRunButtons reaches for via the DOM tree it's given.
globalThis.document = dom.window.document;
attachRunButtons(preview);

const rBlocks = preview.querySelectorAll('pre.src-block code.language-R').length;
const pyBlocks = preview.querySelectorAll('pre.src-block code.language-python').length;
const runButtons = preview.querySelectorAll('button.run-btn').length;
const resultSlots = preview.querySelectorAll('pre.run-result').length;

console.log(`R blocks rendered:     ${rBlocks}`);
console.log(`Python blocks rendered: ${pyBlocks}`);
console.log(`Run buttons attached:  ${runButtons}`);
console.log(`Result slots attached: ${resultSlots}`);

// Run buttons should appear on every R block and no others.
const ok = rBlocks > 0 && runButtons === rBlocks && resultSlots === rBlocks && pyBlocks >= 1;

// Idempotency: a second pass (as happens on re-render of the same node) must
// not double up buttons.
attachRunButtons(preview);
const afterSecondPass = preview.querySelectorAll('button.run-btn').length;
console.log(`Run buttons after 2nd pass: ${afterSecondPass}`);

console.log(ok && afterSecondPass === rBlocks ? '\nPASS' : '\nFAIL');
process.exit(ok && afterSecondPass === rBlocks ? 0 : 1);
