import { authenticatedRequest, type OwnedListing } from './api';

export type Conversation = {
  id: string; listingId: string; listingTitle: string; listingStatus: OwnedListing['status'];
  peerDisplayName: string; isBuyer: boolean; blockedByMe: boolean; canMessage: boolean;
};
export type Message = {
  sequence: number; clientMessageId: string; senderId: string; recipientId: string;
  senderDisplayName: string; body: string; createdAt: string;
};
export type History = Pick<Conversation, 'listingStatus' | 'blockedByMe' | 'canMessage'> & {
  items: Message[]; hasOlder: boolean; hasNewer: boolean;
};
export type Destination = { listingId: string } | { conversationId: string };

export function messagingRequest<T>(path: string, token: string, method: 'GET' | 'POST' | 'PUT' | 'DELETE' = 'GET',
  body?: unknown, signal?: AbortSignal): Promise<T> {
  return authenticatedRequest<T>(path, token, body === undefined ? undefined : JSON.stringify(body), signal, { method, messaging: true });
}

export const inbox = (token: string, signal?: AbortSignal) =>
  messagingRequest<Conversation[]>('conversations', token, 'GET', undefined, signal);

export function history(token: string, id: string, cursor?: { before: number } | { after: number }, signal?: AbortSignal) {
  const query = cursor ? ('before' in cursor ? `?before=${cursor.before}` : `?after=${cursor.after}`) : '';
  return messagingRequest<History>(`conversations/${encodeURIComponent(id)}/messages${query}`, token, 'GET', undefined, signal);
}

export function sendMessage(token: string, to: Destination, body: string, clientMessageId: string) {
  const path = 'listingId' in to ? `listings/${encodeURIComponent(to.listingId)}/conversations` :
    `conversations/${encodeURIComponent(to.conversationId)}/messages`;
  return messagingRequest<{ conversationId: string; message: Message }>(path, token, 'POST', { body, clientMessageId });
}

export function mergeMessages(current: Message[], incoming: Message[]) {
  const bySequence = new Map(current.map(message => [message.sequence, message]));
  for (const message of incoming) bySequence.set(message.sequence, message);
  return [...bySequence.values()].sort((a, b) => a.sequence - b.sequence);
}
