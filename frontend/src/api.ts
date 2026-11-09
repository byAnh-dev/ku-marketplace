import { Platform } from 'react-native';

const host = Platform.OS === 'android' ? '10.0.2.2' : '127.0.0.1';
export const apiBase = (process.env.EXPO_PUBLIC_API_URL || `http://${host}:8080`).replace(/\/+$/, '');

export type Listing = {
  id: string; title: string; description: string; priceCents: number; condition: string;
  category: string; sellerDisplayName: string; pickupArea: string; photoURLs: string[];
};

async function get<T>(path: string, signal: AbortSignal): Promise<T> {
  const response = await fetch(`${apiBase}/api/v1/listings${path}`, { signal });
  if (!response.ok) throw new Error(response.status === 404 ? 'This listing is unavailable.' : 'The marketplace could not load.');
  return response.json();
}

export const search = (q: string, signal: AbortSignal) => get<Listing[]>(`?q=${encodeURIComponent(q)}`, signal);
export const detail = (id: string, signal: AbortSignal) => get<Listing>(`/${encodeURIComponent(id)}`, signal);

