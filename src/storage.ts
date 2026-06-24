// Client for the git-backed document API served by the Nim backend.
// Degrades gracefully when the API isn't reachable (e.g. `nimble dev` without
// the server running) so the editor still works as a scratch pad.

export async function listDocs(): Promise<string[]> {
  try {
    const r = await fetch('/api/docs');
    if (!r.ok) return [];
    const body = (await r.json()) as { docs?: string[] };
    return body.docs ?? [];
  } catch {
    return [];
  }
}

export async function loadDoc(slug: string): Promise<string> {
  const r = await fetch(`/api/docs/${encodeURIComponent(slug)}`);
  if (!r.ok) throw new Error(`load failed (${r.status})`);
  return r.text();
}

export async function saveDoc(slug: string, content: string): Promise<void> {
  const r = await fetch(`/api/docs/${encodeURIComponent(slug)}`, {
    method: 'PUT',
    body: content,
  });
  if (!r.ok) throw new Error(`save failed (${r.status})`);
}

/** Same rule the server enforces — fail fast client-side for a nicer message. */
export function validSlug(slug: string): boolean {
  return /^[A-Za-z0-9_-]{1,64}$/.test(slug);
}
