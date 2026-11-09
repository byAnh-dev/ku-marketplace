import * as SecureStore from 'expo-secure-store';
import { apiBase } from './api';

const sessionKey = 'ku_marketplace_session';
export type PublicUser = { id: string; displayName: string; email: string; verified: boolean };
export type Session = { token: string; user: PublicUser };
type AccountResponse = { ok: boolean; status: number; data: unknown };

async function request(path: string, body?: object, token?: string): Promise<AccountResponse> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 15000);
  try {
    const response = await fetch(`${apiBase}/api/v1/auth/${path}`, {
      method: body === undefined ? 'GET' : 'POST',
      headers: {
        ...(body === undefined ? {} : { 'Content-Type': 'application/json' }),
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: controller.signal,
    });
    const data: unknown = response.status === 204 ? null : await response.json().catch(error => {
      if (controller.signal.aborted) throw error;
      return null;
    });
    return { ok: response.ok, status: response.status, data };
  } catch {
    throw new Error('Could not reach the account service. Check your connection and try again.');
  } finally {
    clearTimeout(timeout);
  }
}

function requireSuccess(response: AccountResponse): void {
  if (response.ok) return;
  const data = response.data as { reason?: unknown } | null;
  throw new Error(typeof data?.reason === 'string' ? data.reason : `Account request failed (${response.status}).`);
}

function verifiedUser(data: unknown): PublicUser {
  const user = data as Partial<PublicUser> | null;
  if (!user || typeof user.id !== 'string' || typeof user.displayName !== 'string' ||
      typeof user.email !== 'string' || user.verified !== true) {
    throw new Error('The account service returned an invalid user. Please try again.');
  }
  return user as PublicUser;
}

export async function register(displayName: string, email: string, password: string, passwordConfirmation: string): Promise<string> {
  const response = await request('register', { displayName, email, password, passwordConfirmation });
  requireSuccess(response);
  const data = response.data as { message?: unknown } | null;
  if (typeof data?.message !== 'string') throw new Error('The account service returned an invalid response.');
  return data.message;
}

export async function login(email: string, password: string): Promise<Session> {
  const response = await request('login', { email, password });
  requireSuccess(response);
  const data = response.data as Partial<Session> | null;
  if (typeof data?.token !== 'string' || !data.token) throw new Error('The account service returned an invalid session.');
  const session = { token: data.token, user: verifiedUser(data.user) };
  try {
    await SecureStore.setItemAsync(sessionKey, session.token);
  } catch {
    // Revoke the new credential if the device cannot retain it.
    await request('logout', {}, session.token).catch(() => {});
    throw new Error('Could not save your session on this device. Please try logging in again.');
  }
  return session;
}

export async function restoreSession(): Promise<Session | null> {
  const token = await SecureStore.getItemAsync(sessionKey);
  if (!token) return null;
  const response = await request('me', undefined, token);
  if (response.status === 401 || response.status === 403) {
    await SecureStore.deleteItemAsync(sessionKey);
    return null;
  }
  // Retain the token on temporary failures so the user can retry restoration.
  requireSuccess(response);
  return { token, user: verifiedUser(response.data) };
}

export async function logout(token: string): Promise<void> {
  const response = await request('logout', {}, token);
  // An expired or already revoked session is also safe to remove locally.
  if (response.status !== 401 && response.status !== 403) requireSuccess(response);
  await SecureStore.deleteItemAsync(sessionKey);
}
