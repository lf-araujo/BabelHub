import type { WebR } from 'webr';
import type { PyodideInterface } from 'pyodide';
import { apiFetch } from './api.ts';

// Both runtimes run client-side in the visitor's browser, so executing code
// costs the server nothing. Each is dynamically imported on first Run, so
// neither heavy runtime touches page load.

type StatusFn = (text: string) => void;
let onStatus: StatusFn = () => {};

export function setRunStatusHandler(fn: StatusFn): void {
  onStatus = fn;
}

interface RunResult {
  text: string;
  images: (ImageBitmap | string)[]; // ImageBitmap (webR) or PNG data URL (matplotlib)
}

// --- R via webR -----------------------------------------------------------
let webRPromise: Promise<WebR> | null = null;

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

async function runR(code: string): Promise<RunResult> {
  const webR = await getWebR();
  const shelter = await new webR.Shelter();
  try {
    // withAutoprint makes top-level visible values print like a REPL would.
    // captureConditions:false lets R errors surface as thrown exceptions (our
    // catch renders them). captureGraphics is on by default: plots land in `images`.
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

// --- Python via Pyodide ---------------------------------------------------
// Keep this version in sync with pyodide in package.json; the loader requires a
// matching CDN folder.
const PYODIDE_INDEX_URL = 'https://cdn.jsdelivr.net/pyodide/v314.0.0/full/';
let pyodidePromise: Promise<PyodideInterface> | null = null;

function getPyodide(): Promise<PyodideInterface> {
  if (!pyodidePromise) {
    onStatus('Python: downloading runtime…');
    pyodidePromise = import('pyodide').then(async ({ loadPyodide }) => {
      const py = await loadPyodide({ indexURL: PYODIDE_INDEX_URL });
      // Force a non-interactive matplotlib backend so plt.show() is a no-op and
      // figures can be grabbed with savefig (set before any import of matplotlib).
      await py.runPythonAsync('import os; os.environ.setdefault("MPLBACKEND", "AGG")');
      onStatus('Python: ready');
      return py;
    });
  }
  return pyodidePromise;
}

// Run after user code: if matplotlib was used, return open figures as base64 PNGs.
const MPL_CAPTURE = `
import sys, io, base64
_bh_imgs = []
if 'matplotlib.pyplot' in sys.modules:
    import matplotlib.pyplot as _plt
    for _n in _plt.get_fignums():
        _b = io.BytesIO()
        _plt.figure(_n).savefig(_b, format='png', bbox_inches='tight')
        _bh_imgs.append(base64.b64encode(_b.getvalue()).decode())
    _plt.close('all')
_bh_imgs
`;

async function runPython(code: string): Promise<RunResult> {
  const py = await getPyodide();
  let buf = '';
  const sink = { batched: (s: string) => { buf += s + '\n'; } };
  py.setStdout(sink);
  py.setStderr(sink);
  try {
    await py.loadPackagesFromImports(code); // auto-load numpy/pandas/matplotlib/…
    const result = await py.runPythonAsync(code);
    if (result !== undefined && result !== null) {
      const repr = String(result);
      if (repr) buf += repr + '\n';
      (result as { destroy?: () => void })?.destroy?.();
    }
    let images: (ImageBitmap | string)[] = [];
    try {
      const figs = await py.runPythonAsync(MPL_CAPTURE);
      const arr = (figs?.toJs?.() ?? []) as string[];
      images = arr.map((b64) => `data:image/png;base64,${b64}`);
      figs?.destroy?.();
    } catch {
      /* matplotlib not used or capture failed — keep the text output */
    }
    return { text: buf.trimEnd(), images };
  } finally {
    py.setStdout({});
    py.setStderr({});
  }
}

// --- server execution (containerised, paid tier) --------------------------
interface ExecCaps {
  enabled: boolean;
  languages: string[]; // ephemeral, one throwaway container per block
  sessionLanguages: string[]; // persistent session (shared state)
}
let execCaps: ExecCaps = { enabled: false, languages: [], sessionLanguages: [] };

// For languages that have both a client runtime and a server session (R,
// Python), this picks which one Run uses. Default: client (free, no server).
let runMode: 'client' | 'server' = 'client';
export function setRunMode(mode: 'client' | 'server'): void {
  runMode = mode;
}

// The persistent session is keyed per document; main supplies the current id.
let sessionId: () => string = () => 'scratch';
export function setSessionIdProvider(fn: () => string): void {
  sessionId = fn;
}

/** Ask the backend whether server execution is on, and for which languages. */
export async function loadExecCaps(): Promise<ExecCaps> {
  try {
    const r = await apiFetch('/api/exec');
    if (r.ok) execCaps = (await r.json()) as ExecCaps;
  } catch {
    /* backend unreachable — server execution simply stays unavailable */
  }
  return execCaps;
}

async function postExec(body: Record<string, string>): Promise<RunResult> {
  const r = await apiFetch('/api/exec', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  if (r.status === 429) {
    const retry = r.headers.get('Retry-After');
    throw new Error(`rate limited — wait ${retry ?? 'a moment'}s and retry`);
  }
  if (!r.ok) throw new Error(`server exec failed (${r.status})`);
  const data = (await r.json()) as { ok: boolean; output: string };
  if (!data.ok) throw new Error(data.output);
  return { text: data.output, images: [] };
}

const runEphemeral = (lang: string, code: string) => postExec({ lang, code });
const runSession = (lang: string, code: string) =>
  postExec({ lang, code, session: sessionId() });

// --- dispatch -------------------------------------------------------------
type Runtime = 'r' | 'python';

function runtimeFor(lang: string): Runtime | null {
  if (lang === 'r' || lang === 'ess-r') return 'r';
  if (lang === 'python' || lang === 'py' || lang === 'jupyter-python') return 'python';
  return null;
}

/**
 * Attach a Run button to every R or Python source block in `root`. uniorg
 * renders src blocks as <pre class="src-block"><code class="language-X">…</code>.
 */
export function attachRunButtons(root: ParentNode): void {
  const blocks = root.querySelectorAll<HTMLElement>('pre.src-block > code[class*="language-"]');
  for (const code of Array.from(blocks)) {
    const lang = (code.className.match(/language-([\w-]+)/)?.[1] ?? '').toLowerCase();
    const clientRuntime = runtimeFor(lang); // webR / Pyodide

    // Decide how this block runs:
    //  - client    : R/Python in the browser (default)
    //  - session    : R/Python in a persistent server container (shared state)
    //  - ephemeral  : other languages in a throwaway server container
    let kind: 'client' | 'session' | 'ephemeral' | null = null;
    if (clientRuntime) {
      kind =
        runMode === 'server' && execCaps.enabled && execCaps.sessionLanguages.includes(lang)
          ? 'session'
          : 'client';
    } else if (execCaps.enabled && execCaps.languages.includes(lang)) {
      kind = 'ephemeral';
    }
    if (!kind) continue;

    const pre = code.parentElement as HTMLElement;
    if (pre.dataset.runnable) continue; // idempotent across re-renders
    pre.dataset.runnable = 'true';

    const button = document.createElement('button');
    button.className = 'run-btn';
    button.textContent =
      kind === 'session' ? '▶ Run (session)'
      : kind === 'ephemeral' ? '▶ Run (container)'
      : '▶ Run';
    if (kind !== 'client') button.dataset.server = '';

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
        const src = code.textContent ?? '';
        const exec =
          kind === 'client'
            ? (clientRuntime === 'r' ? runR : runPython)
            : kind === 'session'
            ? (s: string) => runSession(lang, s)
            : (s: string) => runEphemeral(lang, s);
        const { text, images } = await exec(src);
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

/** Paint captured plots — canvases for webR ImageBitmaps, <img> for PNG URLs. */
function renderPlots(container: HTMLElement, images: (ImageBitmap | string)[]): void {
  container.replaceChildren();
  for (const img of images) {
    if (typeof img === 'string') {
      const el = document.createElement('img');
      el.className = 'run-plot';
      el.src = img;
      container.appendChild(el);
    } else {
      const canvas = document.createElement('canvas');
      canvas.className = 'run-plot';
      canvas.width = img.width;
      canvas.height = img.height;
      canvas.getContext('2d')?.drawImage(img, 0, 0);
      container.appendChild(canvas);
    }
  }
  container.hidden = images.length === 0;
}
