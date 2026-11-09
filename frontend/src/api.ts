import { Platform } from 'react-native';

const host = Platform.OS === 'android' ? '10.0.2.2' : '127.0.0.1';
export const apiBase = (process.env.EXPO_PUBLIC_API_URL || `http://${host}:8080`).replace(/\/+$/, '');

export type Listing = {
  id: string; title: string; description: string; priceCents: number; condition: string;
  category: string; sellerDisplayName: string; pickupArea: string; photoURLs: string[];
};

export type OwnedListing = { status: 'active' | 'sold' | 'reserved' | 'deleted'; listing: Listing };
export type CreateListingBody = {
  title: string; description: string; priceCents: number;
  category: string; condition: string; pickupArea: string;
};
export type PickedPhoto = { uri: string; mimeType?: string };

export class ApiError extends Error {
  constructor(readonly status: number, message: string, readonly fieldErrors: Record<string, string> = {}) {
    super(message);
  }
}

async function get<T>(path: string, signal: AbortSignal): Promise<T> {
  const response = await fetch(`${apiBase}/api/v1/listings${path}`, { signal });
  if (!response.ok) throw new ApiError(response.status, response.status === 404 ? 'This listing is unavailable.' : 'The marketplace could not load.');
  return response.json();
}

export const search = (q: string, signal: AbortSignal) => get<Listing[]>(`?q=${encodeURIComponent(q)}`, signal);
export const detail = (id: string, signal: AbortSignal) => get<Listing>(`/${encodeURIComponent(id)}`, signal);

export const photoURL = (path: string) => /^https?:\/\//.test(path) ? path : `${apiBase}${path.startsWith('/') ? '' : '/'}${path}`;

async function authenticatedRequest<T>(path: string, token: string, body?: string | FormData, signal?: AbortSignal): Promise<T> {
  const controller = new AbortController();
  const abort = () => controller.abort();
  signal?.addEventListener('abort', abort);
  if (signal?.aborted) controller.abort();
  const timeout = setTimeout(abort, body !== undefined && typeof body !== 'string' ? 60000 : 15000);
  try {
    const response = await fetch(`${apiBase}/api/v1/${path}`, {
      method: body === undefined ? 'GET' : 'POST', body,
      headers: { Authorization: `Bearer ${token}`, ...(typeof body === 'string' ? { 'Content-Type': 'application/json' } : {}) },
      signal: controller.signal,
    });
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
      const message = response.status === 401 ? 'Your session has expired. Please log in again.' :
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
export const createListing = (draft: CreateListingBody, token: string) => authenticatedRequest<Listing>('listings', token, JSON.stringify(draft));

export async function uploadPhotos(listingId: string, photos: PickedPhoto[], token: string): Promise<Listing> {
  const form = new FormData();
  photos.forEach((photo, index) => {
    const type = photo.mimeType || 'image/jpeg';
    const extension = type === 'image/png' ? 'png' : type === 'image/heic' || type === 'image/heif' ? 'heic' : 'jpg';
    // React Native encodes local file references as multipart file parts.
    form.append('photos[]', { uri: photo.uri, name: `photo-${index}.${extension}`, type } as unknown as Blob);
  });
  return authenticatedRequest<Listing>(`listings/${encodeURIComponent(listingId)}/photos`, token, form);
}

