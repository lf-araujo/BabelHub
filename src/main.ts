import { renderOrg } from './render';
import {
  attachRunButtons,
  setRunStatusHandler,
  loadExecCaps,
  setRunMode,
  setSessionIdProvider,
} from './run';
import { createEditor, setEditorContent } from './editor';
import * as store from './storage';
import { setAuthMode, getMe, getLicense } from './api.ts';
import { exportReport } from './report.ts';
import './style.css';
import sampleOrg from '../public/sample.org?raw';

const editorMount = document.querySelector<HTMLElement>('#editor')!;
const preview = document.querySelector<HTMLElement>('#preview')!;
const status = document.querySelector<HTMLElement>('#webr-status')!;
const docList = document.querySelector<HTMLSelectElement>('#doc-list')!;
const docNew = document.querySelector<HTMLButtonElement>('#doc-new')!;
const docSave = document.querySelector<HTMLButtonElement>('#doc-save')!;
const docExport = document.querySelector<HTMLButtonElement>('#doc-export')!;
const docName = document.querySelector<HTMLElement>('#doc-name')!;
const runMode = document.querySelector<HTMLSelectElement>('#run-mode')!;
const auth = document.querySelector<HTMLElement>('#auth')!;
const licenseBadge = document.querySelector<HTMLElement>('#license')!;

void getLicense().then((l) => {
  if (!l.licensed) return;
  licenseBadge.textContent = '● licensed';
  licenseBadge.title = `Licensed to ${l.sub ?? ''}${l.tier ? ' · ' + l.tier : ''}`;
});

setRunStatusHandler((text) => {
  status.textContent = text;
});

// Persistent server sessions are keyed per document (unsaved = "scratch").
setSessionIdProvider(() => currentSlug ?? 'scratch');

// New documents start session-ready, so they behave the same in Emacs.
const NEW_TEMPLATE = `#+TITLE: Untitled
#+PROPERTY: header-args:R :session *R* :results output
#+PROPERTY: header-args:python :session *py* :results output

*
`;

// --- document state -------------------------------------------------------
let currentSlug: string | null = null; // null = unsaved scratch buffer
let current = sampleOrg;
let dirty = false;

function showName(): void {
  docName.textContent = (currentSlug ?? 'unsaved') + (dirty ? ' •' : '');
}

async function render(): Promise<void> {
  preview.innerHTML = await renderOrg(current);
  attachRunButtons(preview);
}

// --- editor ---------------------------------------------------------------
let timer: number | undefined;
const view = createEditor(editorMount, sampleOrg, (value) => {
  current = value;
  dirty = true;
  showName();
  window.clearTimeout(timer);
  timer = window.setTimeout(render, 200);
});

// --- document list / open / new / save -----------------------------------
async function refreshList(): Promise<void> {
  const docs = await store.listDocs();
  docList.replaceChildren(new Option('— open —', ''));
  for (const slug of docs) docList.add(new Option(slug, slug));
  docList.value = currentSlug ?? '';
}

docList.addEventListener('change', async () => {
  const slug = docList.value;
  if (!slug) return;
  try {
    const text = await store.loadDoc(slug);
    current = text;
    setEditorContent(view, text);
    currentSlug = slug;
    dirty = false;
    showName();
    await render();
  } catch (err) {
    alert(`Could not open ${slug}: ${err}`);
  }
});

docNew.addEventListener('click', () => {
  currentSlug = null;
  current = NEW_TEMPLATE;
  setEditorContent(view, NEW_TEMPLATE);
  docList.value = '';
  dirty = false;
  showName();
  void render();
});

docExport.addEventListener('click', () => {
  const titled = current.match(/^#\+TITLE:\s*(.+)$/im)?.[1].trim();
  exportReport(preview, titled || currentSlug || 'BabelHub report');
});

docSave.addEventListener('click', async () => {
  let slug = currentSlug;
  if (!slug) {
    const name = prompt('Save as (letters, numbers, - and _):', '');
    if (!name) return;
    if (!store.validSlug(name)) {
      alert('Name must be 1–64 chars: letters, numbers, - or _ only.');
      return;
    }
    slug = name;
  }
  docSave.disabled = true;
  try {
    await store.saveDoc(slug, current);
    currentSlug = slug;
    dirty = false;
    showName();
    await refreshList();
  } catch (err) {
    alert(`Save failed: ${err}`);
  } finally {
    docSave.disabled = false;
  }
});

runMode.addEventListener('change', () => {
  setRunMode(runMode.value === 'server' ? 'server' : 'client');
  void render(); // relabel/reroute Run buttons
});

void render();
void refreshList();
// Once we know the backend's exec capabilities: reveal the browser/session
// toggle if sessions are available, and re-render so server-only blocks
// (bash, julia, …) pick up their Run buttons.
async function renderAuth(oauth: boolean): Promise<void> {
  auth.replaceChildren();
  if (!oauth) return;
  const login = await getMe();
  if (login) {
    const me = document.createElement('span');
    me.className = 'me';
    me.textContent = '@' + login;
    const out = document.createElement('a');
    out.href = '/auth/logout';
    out.textContent = 'logout';
    auth.append(me, ' ', out);
  } else {
    const a = document.createElement('a');
    a.className = 'login';
    a.href = '/auth/login';
    a.textContent = 'Login with GitHub';
    auth.append(a);
  }
}

void loadExecCaps().then((caps) => {
  if (caps.enabled && caps.sessionLanguages.length > 0) runMode.hidden = false;
  setAuthMode(caps.oauth ? 'oauth' : caps.authRequired ? 'token' : 'open');
  void renderAuth(caps.oauth);
  return render();
});
