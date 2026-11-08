import * as SecureStore from 'expo-secure-store';
import { Platform } from 'react-native';

const host = Platform.OS === 'android' ? '10.0.2.2' : '127.0.0.1';
const base = (process.env.EXPO_PUBLIC_API_URL || `http://${host}:8080`).replace(/\/+$/, '');
const sessionKey = 'ku_marketplace_session';

export type PublicUser = { id: string; displayName: string; email: string; verified: boolean };
export type Session = { token: string; user: PublicUser };

async function request<T>(path: string, body: object, token?: string): Promise<T> {
  const response = await fetch(`${base}/api/v1/auth/${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify(body),
  });
  if (!response.ok) {
    const data = await response.json().catch(() => null);
    throw new Error(typeof data?.reason === 'string' ? data.reason : `Request failed (${response.status}).`);
  }
  return response.status === 204 ? undefined as T : response.json();
}

export async function register(displayName: string, email: string, password: string, passwordConfirmation: string): Promise<string> {
  const result = await request<{ message: string }>('register', { displayName, email, password, passwordConfirmation });
  return result.message;
}

export async function login(email: string, password: string): Promise<Session> {
  const session = await request<Session>('login', { email, password });
  await SecureStore.setItemAsync(sessionKey, session.token);
  return session;
}

export async function restoreSession(): Promise<Session | null> {
  const token = await SecureStore.getItemAsync(sessionKey);
  if (!token) return null;
  try {
    const response = await fetch(`${base}/api/v1/auth/me`, { headers: { Authorization: `Bearer ${token}` } });
    if (!response.ok) {
      if (response.status === 401 || response.status === 403) await SecureStore.deleteItemAsync(sessionKey);
      return null;
    }
    const user = await response.json() as PublicUser;
    return { token, user };
  } catch {
    // Keep the stored session during a temporary network outage.
    return null;
  }
}

export async function logout(token: string): Promise<void> {
  // Only clear the token after successful server revocation. Retry if offline.
  await request<void>('logout', {}, token);
  await SecureStore.deleteItemAsync(sessionKey);
}
