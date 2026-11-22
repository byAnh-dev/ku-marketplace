import { messagingRequest } from './messaging';

type BlockState = { blockedByMe: boolean; canMessage: boolean };

export function setBlocked(token: string, id: string, blocked: boolean): Promise<BlockState> {
  return messagingRequest<BlockState>(
    `conversations/${encodeURIComponent(id)}/block`, token, blocked ? 'PUT' : 'DELETE',
  );
}
