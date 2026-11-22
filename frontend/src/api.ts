import { Platform } from 'react-native';

const host = Platform.OS === 'android' ? '10.0.2.2' : '127.0.0.1';
export const apiBase = (process.env.EXPO_PUBLIC_API_URL || `http://${host}:8080`).replace(/\/+$/, '');

export type Listing = {
  id: string; title: string; description: string; priceCents: number; condition: string;
  category: string; sellerDisplayName: string; pickupArea: string; photoURLs: string[];
};
export type ListingPage = { items: Listing[]; page: number; per: number; hasMore: boolean };

export type OwnedListing = { status: 'active' | 'sold' | 'reserved' | 'deleted'; listing: Listing; revision: string };
export type CreateListingBody = {
  title: string; description: string; priceCents: number;
  category: string; condition: string; pickupArea: string;
};
export type PickedPhoto = { uri: string };

export class ApiError extends Error {
  constructor(readonly status: number, message: string, readonly fieldErrors: Record<string, string> = {}) {
    super(message);
  }
}

async function get<T>(path: string, signal: AbortSignal): Promise<{ value: T; headers: Headers }> {
  const response = await fetch(`${apiBase}/api/v1/listings${path}`, { headers: { 'Cache-Control': 'no-cache' }, signal });
  if (!response.ok) throw new ApiError(response.status, response.status === 404 ? 'This listing is unavailable.' : 'The marketplace could not load.');
  return { value: await response.json(), headers: response.headers };
}

export async function search(q: string, page: number, signal: AbortSignal): Promise<ListingPage> {
  const result = await get<Listing[]>(`?q=${encodeURIComponent(q)}&page=${page}&per=20`, signal);
  const header = (name: string, fallback: string) => result.headers.get(name) || fallback;
  return { items: result.value, page: Number(header('X-Page', String(page))), per: Number(header('X-Page-Size', '20')),
    hasMore: header('X-Has-More', 'false') === 'true' };
}
export async function detail(id: string, signal: AbortSignal): Promise<Listing> {
  return (await get<Listing>(`/${encodeURIComponent(id)}`, signal)).value;
}

export const photoURL = (path: string) => /^https?:\/\//.test(path) ? path : `${apiBase}${path.startsWith('/') ? '' : '/'}${path}`;
export const photoThumbnailURL = (path: string, width = 480) => {
  const url = photoURL(path);
  return `${url}${url.includes('?') ? '&' : '?'}width=${width}`;
};

export async function authenticatedRequest<T>(path: string, token: string, body?: string | FormData, signal?: AbortSignal,
  options?: { revision?: string; method?: 'GET' | 'PATCH' | 'PUT' | 'POST' | 'DELETE'; messaging?: boolean }): Promise<T> {
  const controller = new AbortController();
  const abort = () => controller.abort();
  signal?.addEventListener('abort', abort);
  if (signal?.aborted) controller.abort();
  const timeout = setTimeout(abort, body !== undefined && typeof body !== 'string' ? 60000 : 15000);
  try {
    const response = await fetch(`${apiBase}/api/v1/${path}`, {
      method: options?.method ?? (options?.revision !== undefined ? 'PATCH' : body === undefined ? 'GET' : 'POST'), body,
      headers: { Authorization: `Bearer ${token}`, ...(typeof body === 'string' ? { 'Content-Type': 'application/json' } : {}),
        ...(body === undefined && !options?.revision ? { 'Cache-Control': 'no-cache' } : {}),
        ...(options?.revision !== undefined ? { 'If-Match': options.revision } : {}) },
      signal: controller.signal,
    });
    if (options?.messaging && response.status === 204) return undefined as T;
    const data = await response.json().catch(error => {
      if (controller.signal.aborted) throw error;
      return null;
    });
    if (!response.ok) {
      const fieldErrors: Record<string, string> = {};
      if (data?.fieldErrors && typeof data.fieldErrors === 'object') {
        for (const [field, value] of Object.entries(data.fieldErrors)) {
          if (typeof value === 'string') fieldErrors[field] = value;
        }
      }
      const retryAfter = response.headers.get('Retry-After');
      const message = response.status === 401 ? 'Your session has expired. Please log in again.' :
        options?.messaging ? (response.status === 429 && retryAfter ? `Try sending again in ${retryAfter} seconds.` :
          data?.reason || 'The message request could not be completed.') :
        response.status === 403 ? 'Verify your KU email before managing listings.' :
        response.status === 404 ? 'This listing is unavailable.' :
        fieldErrors.photos || (typeof data?.reason === 'string' ? data.reason : 'The listing request could not be completed.');
      throw new ApiError(response.status, message, fieldErrors);
    }
    if (data === null) throw new Error('The marketplace returned an invalid response. Please try again.');
    return data as T;
  } catch (error) {
    if (error instanceof ApiError) throw error;
    throw new Error(controller.signal.aborted ? 'The request was interrupted or timed out. Please try again.' :
      'Could not reach the marketplace. Check your connection and try again.');
  } finally {
    clearTimeout(timeout);
    signal?.removeEventListener('abort', abort);
  }
}

export const myListings = (token: string, signal: AbortSignal) => authenticatedRequest<OwnedListing[]>('me/listings', token, undefined, signal);
export const ownedListing = (id: string, token: string, signal: AbortSignal) =>
  authenticatedRequest<OwnedListing>(`me/listings/${encodeURIComponent(id)}`, token, undefined, signal);
export const editListing = (id: string, draft: CreateListingBody, revision: string, token: string) =>
  authenticatedRequest<OwnedListing>(`listings/${encodeURIComponent(id)}`, token, JSON.stringify(draft), undefined, { revision });
export const markListingSold = (id: string, revision: string, token: string) =>
  authenticatedRequest<OwnedListing>(`listings/${encodeURIComponent(id)}/sold`, token, undefined, undefined, { revision, method: 'POST' });
export const deleteListing = (id: string, revision: string, token: string) =>
  authenticatedRequest<OwnedListing>(`listings/${encodeURIComponent(id)}`, token, undefined, undefined, { revision, method: 'DELETE' });

function photoForm(photos: Blob[]): FormData {
  const form = new FormData();
  for (const photo of photos) form.append('photos[]', photo);
  return form;
}

export function createListing(draft: CreateListingBody, token: string, photos: Blob[] = []): Promise<Listing> {
  const listing = JSON.stringify(draft);
  if (photos.length === 0) return authenticatedRequest<Listing>('listings', token, listing);
  const form = photoForm(photos);
  form.append('listing', listing);
  return authenticatedRequest<Listing>('listings', token, form);
}

export async function uploadPhotos(listingId: string, photos: Blob[], token: string): Promise<Listing> {
  return authenticatedRequest<Listing>(`listings/${encodeURIComponent(listingId)}/photos`, token, photoForm(photos));
}

