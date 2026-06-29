// Authenticated fetch for the BabelHub API. When the backend requires a shared
// token, the user is prompted once on the first 401; the token is kept in
// localStorage and attached as a bearer header thereafter.

const TOKEN_KEY = 'babelhub-token';

// How the backend authenticates: 'open' (no auth), 'token' (shared secret), or
// 'oauth' (GitHub session cookie). Set from the capability probe; it decides
// what a 401 means — prompt for a token, or leave login to the UI.
let authMode: 'open' | 'token' | 'oauth' = 'open';
export function setAuthMode(mode: 'open' | 'token' | 'oauth'): void {
  authMode = mode;
}

export interface LicenseStatus {
  licensed: boolean;
  sub?: string;
  tier?: string;
}

/** Server license status (for the activation badge). */
export async function getLicense(): Promise<LicenseStatus> {
  try {
    const r = await fetch('/api/license');
    if (r.ok) return (await r.json()) as LicenseStatus;
  } catch {
    /* ignore */
  }
  return { licensed: false };
}

/** Current GitHub login, or '' when anonymous / not in OAuth mode. */
export async function getMe(): Promise<string> {
  try {
    const r = await fetch('/api/me');
    if (r.ok) return ((await r.json()) as { login?: string }).login ?? '';
  } catch {
    /* ignore */
  }
  return '';
}

export function getToken(): string {
  return localStorage.getItem(TOKEN_KEY) ?? '';
}

function setToken(token: string): void {
  if (token) localStorage.setItem(TOKEN_KEY, token);
  else localStorage.removeItem(TOKEN_KEY);
}

function withToken(init: RequestInit, token: string): RequestInit {
  const headers = new Headers(init.headers);
  if (token) headers.set('Authorization', `Bearer ${token}`);
  return { ...init, headers };
}

export async function apiFetch(url: string, init: RequestInit = {}): Promise<Response> {
  let res = await fetch(url, withToken(init, getToken()));
  // Only prompt for a token in shared-token mode; in OAuth mode a 401 just means
  // "log in", which the UI surfaces as a button (no prompt, no auto-redirect).
  if (res.status === 401 && authMode === 'token') {
    const token = window.prompt('Access token required for BabelHub:') ?? '';
    if (!token) return res;
    setToken(token);
    res = await fetch(url, withToken(init, token));
    if (res.status === 401) setToken(''); // bad token — clear so we re-prompt next time
  }
  return res;
}
