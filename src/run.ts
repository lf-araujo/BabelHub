import type { WebR } from 'webr';

// A single lazily-initialised webR instance, shared across every Run button on
// the page. The `webr` module itself is dynamically imported on first Run, so
// neither the ~30MB R runtime nor its worker code touch page load — the whole
// point of client-side execution.
let webRPromise: Promise<WebR> | null = null;

type StatusFn = (text: string) => void;
let onStatus: StatusFn = () => {};

export function setRunStatusHandler(fn: StatusFn): void {
  onStatus = fn;
}

function getWebR(): Promise<WebR> {
  if (!webRPromise) {
    onStatus('R: downloading runtime…');
    webRPromise = import('webr').then(async ({ WebR }) => {
      const webR = new WebR();
      await webR.init();
      onStatus('R: ready');
      return webR;
    });
  }
  return webRPromise;
}

interface RunResult {
  text: string;
  images: ImageBitmap[];
}

/** Run R source, returning combined stream text plus any plots drawn. */
async function runR(code: string): Promise<RunResult> {
  const webR = await getWebR();
  const shelter = await new webR.Shelter();
  try {
    // withAutoprint makes top-level visible values print like a REPL would —
    // otherwise `sprintf(...)` or `summary(...)` returns a value but emits
    // nothing, and the user just sees "(no output)".
    // captureConditions:false lets R errors surface as thrown exceptions (our
    // catch renders them), while warnings/messages still land on the streams.
    // captureGraphics is on by default: any plot() lands in `images`.
    const { output, images } = await shelter.captureR(code, {
      withAutoprint: true,
      captureStreams: true,
      captureConditions: false,
    });
    const text = output
      .filter((line) => line.type === 'stdout' || line.type === 'stderr')
      .map((line) => line.data as string)
      .join('\n')
      .trimEnd();
    return { text, images };
  } finally {
    shelter.purge();
  }
}

/**
 * Find every R source block in `root` and attach a Run button. uniorg renders
 * src blocks as <pre class="src-block"><code class="language-R">…</code></pre>;
 * org accepts R, r, ess-R, etc. as the language, so we match case-insensitively.
 */
export function attachRunButtons(root: ParentNode): void {
  const blocks = root.querySelectorAll<HTMLElement>('pre.src-block > code[class*="language-"]');
  for (const code of Array.from(blocks)) {
    const lang = (code.className.match(/language-([\w-]+)/)?.[1] ?? '').toLowerCase();
    if (lang !== 'r' && lang !== 'ess-r') continue;

    const pre = code.parentElement as HTMLElement;
    if (pre.dataset.runnable) continue; // idempotent across re-renders
    pre.dataset.runnable = 'true';

    const button = document.createElement('button');
    button.className = 'run-btn';
    button.textContent = '▶ Run';

    const result = document.createElement('pre');
    result.className = 'run-result';
    result.hidden = true;

    const plots = document.createElement('div');
    plots.className = 'run-plots';
    plots.hidden = true;

    button.addEventListener('click', async () => {
      button.disabled = true;
      const original = button.textContent;
      button.textContent = '… running';
      try {
        const { text, images } = await runR(code.textContent ?? '');
        result.textContent = text || (images.length ? '' : '(no output)');
        result.hidden = text.length === 0;
        result.classList.remove('run-error');
        renderPlots(plots, images);
      } catch (err) {
        result.textContent = String(err);
        result.hidden = false;
        result.classList.add('run-error');
        renderPlots(plots, []);
      } finally {
        button.disabled = false;
        button.textContent = original;
      }
    });

    pre.insertAdjacentElement('beforebegin', button);
    pre.insertAdjacentElement('afterend', result);
    result.insertAdjacentElement('afterend', plots);
  }
}

/** Paint webR's captured plots (ImageBitmaps) into `container` as canvases. */
function renderPlots(container: HTMLElement, images: ImageBitmap[]): void {
  container.replaceChildren();
  for (const bmp of images) {
    const canvas = document.createElement('canvas');
    canvas.className = 'run-plot';
    canvas.width = bmp.width;
    canvas.height = bmp.height;
    canvas.getContext('2d')?.drawImage(bmp, 0, 0);
    container.appendChild(canvas);
  }
  container.hidden = images.length === 0;
}
