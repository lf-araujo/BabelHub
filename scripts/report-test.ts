import { JSDOM } from 'jsdom';
import { renderTables } from '../src/run.ts';
import { buildReportHtml } from '../src/report.ts';

const dom = new JSDOM('<article id="preview"></article>');
const doc = dom.window.document;
// run.ts/report.ts reach for the global document.
globalThis.document = doc as unknown as Document;

const preview = doc.querySelector('#preview') as HTMLElement;

// 1) Tables render correctly from an execution result.
const tables = [
  { columns: ['x', 'y'], rows: [['1', 'a'], ['2', 'b'], ['3', 'c']] },
];
const box = doc.createElement('div');
preview.appendChild(box);
renderTables(box, tables);

const table = box.querySelector('table.run-table');
const headers = Array.from(box.querySelectorAll('thead th')).map((th) => th.textContent);
const bodyRows = box.querySelectorAll('tbody tr');
const firstRowCells = Array.from(bodyRows[0]?.querySelectorAll('td') ?? []).map((td) => td.textContent);

const tableOk =
  table !== null &&
  headers.join(',') === 'x,y' &&
  bodyRows.length === 3 &&
  firstRowCells.join(',') === '1,a';

console.log('table element present:', table !== null);
console.log('headers:', headers.join(','));
console.log('rows:', bodyRows.length, '| first row:', firstRowCells.join(','));
console.log('hidden when empty:', (() => { const b = doc.createElement('div'); renderTables(b, []); return b.hidden; })());

// 2) The HTML report embeds the table and an inlined image, drops Run buttons.
const result = doc.createElement('pre');
result.className = 'run-result';
result.textContent = 'ran';
preview.appendChild(result);
const img = doc.createElement('img');
img.className = 'run-plot';
img.src = 'data:image/png;base64,AAAA';
preview.appendChild(img);
const btn = doc.createElement('button');
btn.className = 'run-btn';
btn.textContent = '▶ Run';
preview.appendChild(btn);

const html = buildReportHtml(preview, 'My Report');
const reportOk =
  html.includes('<!doctype html>') &&
  html.includes('<title>My Report</title>') &&
  html.includes('class="run-table"') &&
  html.includes('<td>a</td>') &&
  html.includes('data:image/png;base64,AAAA') &&
  !html.includes('run-btn'); // interactive buttons stripped

console.log('\nreport self-contained doc:', html.includes('<!doctype html>'));
console.log('report embeds table:', html.includes('class="run-table"') && html.includes('<td>a</td>'));
console.log('report embeds image data URL:', html.includes('data:image/png;base64,AAAA'));
console.log('report strips Run buttons:', !html.includes('run-btn'));

console.log(tableOk && reportOk ? '\nPASS' : '\nFAIL');
process.exit(tableOk && reportOk ? 0 : 1);
