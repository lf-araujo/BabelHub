// Honor org-babel `:exports` (code | results | both | none) to control whether
// a block's code and/or its results appear in the preview and the HTML report.
// Settable per block (`#+begin_src R :exports results`) or file-wide
// (`#+PROPERTY: header-args :exports both`, or `header-args:R :exports ...`).
//
// BabelHub defaults to `both` — results are the point — which also preserves the
// prior behaviour (every runnable block got a Run button).

export type ExportsMode = 'both' | 'code' | 'results' | 'none';

function normalize(v: string | undefined): ExportsMode | undefined {
  switch (v?.toLowerCase()) {
    case 'both':
      return 'both';
    case 'code':
      return 'code';
    case 'results':
      return 'results';
    case 'none':
      return 'none';
    default:
      return undefined;
  }
}

/** The `:exports` mode for each #+begin_src block, in document order. */
export function exportsForBlocks(src: string): ExportsMode[] {
  let fileDefault: ExportsMode = 'both';
  const langDefault: Record<string, ExportsMode> = {};
  const out: ExportsMode[] = [];

  for (const line of src.split('\n')) {
    const prop = line.match(/^#\+PROPERTY:\s*header-args(?::([\w-]+))?\s+(.*)$/i);
    if (prop) {
      const ex = normalize(prop[2].match(/:exports\s+(\S+)/i)?.[1]);
      if (ex) {
        if (prop[1]) langDefault[prop[1].toLowerCase()] = ex;
        else fileDefault = ex;
      }
      continue;
    }
    const begin = line.match(/^[ \t]*#\+begin_src\s+([\w-]+)(.*)$/i);
    if (begin) {
      const lang = begin[1].toLowerCase();
      out.push(
        normalize(begin[2].match(/:exports\s+(\S+)/i)?.[1]) ?? langDefault[lang] ?? fileDefault
      );
    }
  }
  return out;
}

/**
 * Tag each rendered src block with its `:exports` mode (data-exports) and hide
 * the code for results/none. attachRunButtons reads data-exports to suppress
 * results for code/none; the report drops .exports-hidden code from the export.
 */
export function applyExports(preview: HTMLElement, src: string): void {
  const modes = exportsForBlocks(src);
  preview.querySelectorAll<HTMLElement>('pre.src-block').forEach((pre, i) => {
    const mode = modes[i] ?? 'both';
    pre.dataset.exports = mode;
    if (mode === 'results' || mode === 'none') pre.classList.add('exports-hidden');
  });
}
