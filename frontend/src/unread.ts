import { messagingRequest } from './messaging';

export type UnreadSummary = {
  total: number;
  threads: { conversationId: string; unreadCount: number }[];
};

export function fetchUnread(token: string, signal?: AbortSignal): Promise<UnreadSummary> {
  return messagingRequest<UnreadSummary>('me/unread', token, 'GET', undefined, signal);
}

export async function markDisplayed(token: string, id: string, sequences: readonly number[]): Promise<void> {
  const unique = Array.from(new Set(sequences));
  const path = 'conversations/' + encodeURIComponent(id) + '/read';
  for (let offset = 0; offset < unique.length; offset += 100) {
    await messagingRequest<void>(path, token, 'POST', { sequences: unique.slice(offset, offset + 100) });
  }
}
