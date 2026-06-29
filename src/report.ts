// Self-contained HTML report: snapshot the rendered preview (document + run
// outputs: text, plots, tables) into one standalone .html file that embeds
// everything — images as data URLs, styles inline, no external assets.

const REPORT_CSS = `
  :root { font-family: Georgia, "Times New Roman", serif; color: #1b1b1a; }
  body { margin: 0; background: #fff; }
  .report { max-width: 46rem; margin: 2.5rem auto; padding: 0 1.5rem; line-height: 1.6; }
  .report h1, .report h2, .report h3 { font-family: system-ui, sans-serif; line-height: 1.2; }
  .report pre { font-family: ui-monospace, "Cascadia Code", monospace; font-size: 0.85rem;
    background: #f3f3ee; padding: 0.75rem 1rem; border-radius: 6px; overflow-x: auto; }
  .report code { font-family: ui-monospace, monospace; }
  .report .run-result { background: #0e1f17; color: #d6f0e2; white-space: pre-wrap; }
  .report .run-result.run-error { background: #2a1414; color: #f3c7c7; }
  .report .run-plot { max-width: 100%; height: auto; border: 1px solid #e3e3dd; border-radius: 6px; }
  .report .run-table { border-collapse: collapse; font-family: ui-monospace, monospace;
    font-size: 0.85rem; margin: 0.4rem 0; }
  .report .run-table th, .report .run-table td { border: 1px solid #e3e3dd;
    padding: 0.2rem 0.55rem; text-align: right; }
  .report .run-table th { background: #f3f3ee; }
  .report .run-tables { overflow-x: auto; }
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
