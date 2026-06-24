import { renderOrg } from './render';
import { attachRunButtons, setRunStatusHandler } from './run';
import { createEditor } from './editor';
import './style.css';
import sampleOrg from '../public/sample.org?raw';

const editorMount = document.querySelector<HTMLElement>('#editor')!;
const preview = document.querySelector<HTMLElement>('#preview')!;
const status = document.querySelector<HTMLElement>('#webr-status')!;

setRunStatusHandler((text) => {
  status.textContent = text;
});

let current = sampleOrg;

async function render(): Promise<void> {
  preview.innerHTML = await renderOrg(current);
  attachRunButtons(preview);
}

// Re-render on a short debounce so typing stays responsive.
let timer: number | undefined;
createEditor(editorMount, sampleOrg, (value) => {
  current = value;
  window.clearTimeout(timer);
  timer = window.setTimeout(render, 200);
});

void render();
