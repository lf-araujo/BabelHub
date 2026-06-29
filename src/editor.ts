import { EditorView, basicSetup } from 'codemirror';
import { EditorState } from '@codemirror/state';
import { keymap } from '@codemirror/view';
import {
  StreamLanguage,
  type StreamParser,
  HighlightStyle,
  syntaxHighlighting,
} from '@codemirror/language';
import { tags as t } from '@lezer/highlight';

// There's no mature CodeMirror 6 grammar for org-mode, so we hand-roll a small
// line-oriented StreamLanguage. It's deliberately shallow — enough to make the
// structure legible (headlines, blocks, keywords, inline markup) without
// pretending to be org-element.el. The preview pane is the source of truth.
interface OrgState {
  inBlock: boolean;
}

const orgParser: StreamParser<OrgState> = {
  startState: () => ({ inBlock: false }),
  token(stream, state) {
    if (stream.sol()) {
      if (stream.match(/^[ \t]*#\+begin_\w+.*$/i)) {
        state.inBlock = true;
        return 'blockMeta';
      }
      if (stream.match(/^[ \t]*#\+end_\w+.*$/i)) {
        state.inBlock = false;
        return 'blockMeta';
      }
      if (state.inBlock) {
        stream.skipToEnd();
        return 'blockContent';
      }
      if (stream.match(/^\*+\s.*$/)) return 'heading';
      if (stream.match(/^[ \t]*#\+\w+:.*$/)) return 'keywordLine';
      if (stream.match(/^[ \t]*#\s.*$/)) return 'comment';
      if (stream.match(/^[ \t]*[-+]\s/)) return 'bullet';
    }
    if (state.inBlock) {
      stream.skipToEnd();
      return 'blockContent';
    }
    if (stream.match(/\*[^*\s][^*\n]*\*/)) return 'strong';
    if (stream.match(/\/[^/\s][^/\n]*\//)) return 'emphasis';
    if (stream.match(/[~=][^~=\n]+[~=]/)) return 'mono';
    if (stream.match(/\[\[[^\]]*\](\[[^\]]*\])?\]/)) return 'link';
    stream.next();
    return null;
  },
  tokenTable: {
    heading: t.heading,
    blockMeta: t.meta,
    blockContent: t.string,
    keywordLine: t.keyword,
    comment: t.comment,
    bullet: t.list,
    strong: t.strong,
    emphasis: t.emphasis,
    mono: t.monospace,
    link: t.link,
  },
};

const orgLanguage = StreamLanguage.define(orgParser);

const orgHighlight = HighlightStyle.define([
  { tag: t.heading, color: '#2f7d5b', fontWeight: 'bold' },
  { tag: t.meta, color: '#9a6b00' },
  { tag: t.keyword, color: '#9a6b00' },
  { tag: t.string, color: '#555' },
  { tag: t.comment, color: '#8a8a82', fontStyle: 'italic' },
  { tag: t.list, color: '#2f7d5b' },
  { tag: t.strong, fontWeight: 'bold' },
  { tag: t.emphasis, fontStyle: 'italic' },
  { tag: t.monospace, color: '#9b4d2e' },
  { tag: t.link, color: '#2563a8', textDecoration: 'underline' },
]);

/** Replace the editor's whole document (used when opening a saved doc). */
export function setEditorContent(view: EditorView, text: string): void {
  view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: text } });
}

export function createEditor(
  parent: HTMLElement,
  doc: string,
  onChange: (value: string) => void
): EditorView {
  return new EditorView({
    parent,
    state: EditorState.create({
      doc,
      extensions: [
        // Mod-' opens the block at the cursor in a dedicated language editor
        // (browser analog of Emacs C-c '). The editor + language grammars are
        // loaded lazily on first use to keep the initial bundle small.
        keymap.of([
          {
            key: "Mod-'",
            run: (v) => {
              void import('./srcedit.ts').then((m) => m.openSrcEdit(v));
              return true;
            },
          },
        ]),
        basicSetup,
        orgLanguage,
        syntaxHighlighting(orgHighlight),
        EditorView.lineWrapping,
        EditorView.updateListener.of((u) => {
          if (u.docChanged) onChange(u.state.doc.toString());
        }),
      ],
    }),
  });
}
