// Dedicated source-block editor — the browser analog of Emacs org-edit-special
// (C-c '). Pops the block under the cursor into a focused CodeMirror with the
// right language mode (highlighting + completion); applying writes it back.

import { EditorView, basicSetup } from 'codemirror';
import { EditorState, type Extension } from '@codemirror/state';
import { keymap } from '@codemirror/view';
import { StreamLanguage } from '@codemirror/language';
import { python } from '@codemirror/lang-python';
import { javascript } from '@codemirror/lang-javascript';
import { r } from '@codemirror/legacy-modes/mode/r';
import { shell } from '@codemirror/legacy-modes/mode/shell';
import { julia } from '@codemirror/legacy-modes/mode/julia';
import { autocompletion, completeAnyWord } from '@codemirror/autocomplete';

// Python/JS get real Lezer grammars (structural highlighting + keyword/builtin
// completion); R/bash/Julia use legacy regex modes + buffer-word completion.
function langExtensions(lang: string): Extension[] {
  switch (lang) {
    case 'python':
    case 'py':
    case 'jupyter-python':
      return [python(), autocompletion()];
    case 'js':
    case 'javascript':
    case 'node':
      return [javascript(), autocompletion()];
    case 'r':
    case 'ess-r':
      return [StreamLanguage.define(r), autocompletion({ override: [completeAnyWord] })];
    case 'bash':
    case 'sh':
    case 'shell':
      return [StreamLanguage.define(shell), autocompletion({ override: [completeAnyWord] })];
    case 'julia':
      return [StreamLanguage.define(julia), autocompletion({ override: [completeAnyWord] })];
    default:
      return [autocompletion({ override: [completeAnyWord] })];
  }
}

interface Block {
  lang: string;
  from: number; // char offset of the first body line
  to: number; // char offset of the #+end_src line
  body: string;
}

/** Locate the src block containing the cursor, or null if not in one. */
function blockAt(view: EditorView): Block | null {
  const doc = view.state.doc;
  const cur = doc.lineAt(view.state.selection.main.head).number;

  let beginLine = -1;
  let lang = '';
  for (let n = cur; n >= 1; n--) {
    const text = doc.line(n).text;
    const m = text.match(/^[ \t]*#\+begin_src\s+(\S+)/i);
    if (m) {
      beginLine = n;
      lang = m[1].toLowerCase();
      break;
    }
    if (n !== cur && /^[ \t]*#\+end_src\b/i.test(text)) return null; // left a prior block
  }
  if (beginLine === -1) return null;

  let endLine = -1;
  for (let n = beginLine + 1; n <= doc.lines; n++) {
    if (/^[ \t]*#\+end_src\b/i.test(doc.line(n).text)) {
      endLine = n;
      break;
    }
  }
  if (endLine === -1 || cur > endLine) return null;

  const from = doc.line(beginLine).to + 1; // start of the line after #+begin_src
  const to = Math.max(from, doc.line(endLine).from); // start of #+end_src line
  return { lang, from, to, body: doc.sliceString(from, to) };
}

/** Open the dedicated editor for the block at the cursor. Returns false if none. */
export function openSrcEdit(parentView: EditorView): boolean {
  const block = blockAt(parentView);
  if (!block) return false;

  const overlay = document.createElement('div');
  overlay.className = 'srcedit-overlay';
  const panel = document.createElement('div');
  panel.className = 'srcedit-panel';
  const bar = document.createElement('div');
  bar.className = 'srcedit-bar';
  const title = document.createElement('span');
  title.append('edit ');
  const strong = document.createElement('strong');
  strong.textContent = block.lang;
  title.append(strong);
  const hint = document.createElement('span');
  hint.className = 'hint';
  hint.textContent = 'Ctrl/⌘-↵ apply · Esc cancel';
  bar.append(title, hint);
  const host = document.createElement('div');
  host.className = 'srcedit-host';
  panel.append(bar, host);
  overlay.append(panel);
  document.body.append(overlay);

  let view: EditorView;
  let done = false;
  const close = (): void => {
    overlay.remove();
    parentView.focus();
  };
  const apply = (): boolean => {
    if (done) return true;
    done = true;
    let text = view.state.doc.toString();
    if (text.length > 0 && !text.endsWith('\n')) text += '\n';
    parentView.dispatch({ changes: { from: block.from, to: block.to, insert: text } });
    close();
    return true;
  };
  const cancel = (): boolean => {
    close();
    return true;
  };

  overlay.addEventListener('mousedown', (e) => {
    if (e.target === overlay) cancel();
  });

  view = new EditorView({
    parent: host,
    state: EditorState.create({
      doc: block.body.replace(/\n$/, ''),
      extensions: [
        basicSetup,
        ...langExtensions(block.lang),
        EditorView.lineWrapping,
        keymap.of([
          { key: 'Mod-Enter', run: apply },
          { key: "Mod-'", run: apply },
          { key: 'Escape', run: cancel },
        ]),
      ],
    }),
  });
  view.focus();
  return true;
}
