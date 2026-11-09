import { Platform } from 'react-native';

const host = Platform.OS === 'android' ? '10.0.2.2' : '127.0.0.1';
const base = (process.env.EXPO_PUBLIC_API_URL || `http://${host}:8080`).replace(/\/+$/, '');

export type Listing = {
  id: string; title: string; description: string; priceCents: number; condition: string;
  category: string; sellerDisplayName: string; pickupArea: string; photoURLs: string[];
};

/** Keeps the HTTP status so screens can tell "unavailable" (404) from other failures. */
export class ApiError extends Error {
  constructor(readonly status: number, message: string) { super(message); }
}

async function get<T>(path: string, signal: AbortSignal): Promise<T> {
  const response = await fetch(`${base}/api/v1/listings${path}`, { signal });
  if (!response.ok) throw new ApiError(response.status, response.status === 404 ? 'This listing is unavailable.' : 'The marketplace could not load.');
  return response.json();
}

export const search = (q: string, signal: AbortSignal) => get<Listing[]>(`?q=${encodeURIComponent(q)}`, signal);
export const detail = (id: string, signal: AbortSignal) => get<Listing>(`/${encodeURIComponent(id)}`, signal);

/** Uploaded photos come back as server paths ("/uploads/..."); Image needs a full URL. */
export const photoURL = (path: string) => /^https?:\/\//.test(path) ? path : `${base}${path.startsWith('/') ? '' : '/'}${path}`;

export type PickedPhoto = { uri: string; mimeType?: string };

/**
 * Attaches photos to a listing the signed-in seller owns, in display order:
 * the first photo becomes the primary one. Replaces any earlier photo set.
 */
export async function uploadPhotos(listingId: string, photos: PickedPhoto[]): Promise<Listing> {
  const form = new FormData();
  photos.forEach((photo, index) => {
    const type = photo.mimeType || 'image/jpeg';
    const extension = type === 'image/png' ? 'png' : type === 'image/heic' ? 'heic' : 'jpg';
    // React Native's FormData takes { uri, name, type } for a local file.
    form.append('photos[]', { uri: photo.uri, name: `photo-${index}.${extension}`, type } as unknown as Blob);
  });
  // The accounts feature adds the session here once sign-in exists; until then the server returns 401.
  const response = await fetch(`${base}/api/v1/listings/${encodeURIComponent(listingId)}/photos`, { method: 'POST', body: form });
  if (response.ok) return response.json();
  const body = await response.json().catch(() => null);
  const message =
    response.status === 401 ? 'Sign in to add photos.' :
    response.status === 403 ? 'Verify your KU email before adding photos.' :
    response.status === 404 ? 'This listing is unavailable.' :
    response.status === 422 ? body?.fieldErrors?.photos ?? 'Check your photos.' :
    'Photos could not be uploaded.';
  throw new ApiError(response.status, message);
}
