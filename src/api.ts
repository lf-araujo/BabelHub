// Authenticated fetch for the BabelHub API. When the backend requires a shared
// token, the user is prompted once on the first 401; the token is kept in
// localStorage and attached as a bearer header thereafter.

const TOKEN_KEY = 'babelhub-token';

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
  if (res.status === 401) {
    const token = window.prompt('Access token required for BabelHub:') ?? '';
    if (!token) return res;
    setToken(token);
    res = await fetch(url, withToken(init, token));
    if (res.status === 401) setToken(''); // bad token — clear so we re-prompt next time
  }
  return res;
}
