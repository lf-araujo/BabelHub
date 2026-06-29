// Self-contained HTML report: snapshot the rendered preview (document + run
// outputs: text, plots, tables) into one standalone .html file that embeds
// everything — images as data URLs, styles inline, no external assets.

// House org style: Roboto-based Tufte layout (720px column + 240px sidenote
// rail). Standalone reports can load Google Fonts freely.
const REPORT_CSS = `
  @import url('https://fonts.googleapis.com/css2?family=Roboto:wght@300;400;500&family=Roboto+Slab:wght@300;400;500&family=Roboto+Condensed:wght@300;400;500&family=Roboto+Mono:wght@300;400&display=swap');
  :root {
    --accent: #673ab7; --rule: #555599; --box: #f9f9ff;
    --body: "Roboto", system-ui, sans-serif;
    --head: "Roboto Slab", Georgia, serif;
    --cond: "Roboto Condensed", "Roboto", sans-serif;
    --mono: "Roboto Mono", ui-monospace, monospace;
  }
  body { margin: 0; background: #fff; color: #1b1b1a; font-family: var(--body);
    font-weight: 300; font-size: 16px; line-height: 1.3; }
  .report { max-width: 720px; margin: 4em auto; padding: 0 1.5rem; padding-right: 240px; }
  .report h1, .report h2, .report h3, .report h4 { font-family: var(--head);
    font-weight: 400; line-height: 1.2; clear: both; }
  .report p { text-align: justify; text-justify: inter-word; hyphens: auto; }
  .report a { color: var(--accent); text-decoration: none; }
  .report blockquote { font-size: 95%; border-left: 2px solid #e3e3dd; margin: 1em 0; padding-left: 1em; }
  .report .toc { border-left: 2px solid var(--rule); background: var(--box);
    padding: 0.5rem 1rem 0.6rem; margin: 0 0 1.5rem; font-family: var(--cond); font-size: 0.9rem; }
  .report .toc-title { font-weight: 500; color: var(--accent); padding-bottom: 0.25rem; }
  .report .toc ul { margin: 0; padding-left: 1.1rem; list-style: none; }
  .report .toc > ul { padding-left: 0; }
  .report .toc a, .report .toc-list a { color: #1b1b1a; text-decoration: none; }
  .report .toc-list { font-family: var(--cond); list-style: none; padding-left: 0; margin: 0.25rem 0 1rem; }
  .report .toc-list ul { list-style: none; padding-left: 1.1rem; margin: 0; }
  .report code { font-family: var(--mono); font-weight: 300; }
  .report pre.src-block { background: var(--box); border: 0.5px solid var(--rule);
    padding: 0.6rem 1rem; overflow-x: auto; margin: 0.25rem 0 0.5rem;
    font-family: var(--mono); font-size: 0.8rem; line-height: 1.4; }
  .report .run-result { background: var(--box); border: 0.5px solid var(--rule);
    padding: 0.5rem 1rem 0.6rem; margin: 0.4rem 0 0.75rem; white-space: pre-wrap;
    font-family: var(--mono); font-weight: 300; font-size: 0.8rem; line-height: 1.4; }
  .report .run-result::before { content: "Output"; display: block; font-family: var(--cond);
    font-size: 0.85em; color: #6b6b66; padding-bottom: 0.25em; }
  .report .run-result.run-error { background: #fdf3f3; color: #8a1c1c; border-color: #b06a6a; }
  .report .run-plot { max-width: 100%; height: auto; }
  .report .run-tables { overflow-x: auto; max-width: calc(100% + 240px); }
  .report .run-table { border-collapse: collapse; font-family: var(--mono);
    font-weight: 300; font-size: 0.8rem; line-height: 1.4; }
  .report .run-table th { font-family: var(--cond); font-weight: 500; text-align: right;
    border-bottom: 1.5px solid #1b1b1a; padding: 0.15rem 0.7rem; }
  .report .run-table td { text-align: right; border-bottom: 0.5px solid #e3e3dd;
    padding: 0.15rem 0.7rem; }
  @media (max-width: 1100px) {
    .report { padding-right: 1.5rem; }
    .report .run-tables { max-width: 100%; }
  }
`;

function escapeHtml(s: string): string {
  return s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!);
}

function slugify(s: string): string {
  return s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
}

/**
 * Build a standalone HTML document from the live preview. Run buttons are
 * dropped; live canvases (webR plots) are baked into <img> data URLs so they
 * survive serialization. Pure (returns a string) so it can be unit-tested.
 */
export function buildReportHtml(preview: HTMLElement, title: string): string {
  const clone = preview.cloneNode(true) as HTMLElement;
  clone.querySelectorAll('.run-btn').forEach((b) => b.remove());
  // :exports results/none hides the code from the export — drop it entirely.
  clone.querySelectorAll('.exports-hidden').forEach((e) => e.remove());

  // cloneNode doesn't copy canvas bitmaps — bake them from the originals.
  const orig = preview.querySelectorAll('canvas');
  clone.querySelectorAll('canvas').forEach((c, i) => {
    try {
      const img = (clone.ownerDocument ?? document).createElement('img');
      img.src = (orig[i] as HTMLCanvasElement).toDataURL('image/png');
      img.className = 'run-plot';
      c.replaceWith(img);
    } catch {
      /* canvas not rasterizable here — leave it out rather than break export */
      c.remove();
    }
  });

  return `<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHtml(title)}</title>
<style>${REPORT_CSS}</style></head>
<body><article class="report">${clone.innerHTML}</article></body>
</html>`;
}

/** Build the report and trigger a download. */
export function exportReport(preview: HTMLElement, title: string): void {
  const blob = new Blob([buildReportHtml(preview, title)], { type: 'text/html' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = (slugify(title) || 'report') + '.html';
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(url);
}
