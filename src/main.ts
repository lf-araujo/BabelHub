import { renderOrg } from './render';
import { attachRunButtons, setRunStatusHandler } from './run';
import { createEditor, setEditorContent } from './editor';
import * as store from './storage';
import './style.css';
import sampleOrg from '../public/sample.org?raw';

const editorMount = document.querySelector<HTMLElement>('#editor')!;
const preview = document.querySelector<HTMLElement>('#preview')!;
const status = document.querySelector<HTMLElement>('#webr-status')!;
const docList = document.querySelector<HTMLSelectElement>('#doc-list')!;
const docNew = document.querySelector<HTMLButtonElement>('#doc-new')!;
const docSave = document.querySelector<HTMLButtonElement>('#doc-save')!;
const docName = document.querySelector<HTMLElement>('#doc-name')!;

setRunStatusHandler((text) => {
  status.textContent = text;
});

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
  current = '';
  setEditorContent(view, '');
  docList.value = '';
  dirty = false;
  showName();
  void render();
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

void render();
void refreshList();
