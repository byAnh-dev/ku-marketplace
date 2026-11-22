import { useCallback, useEffect, useRef, useState } from 'react';
import { uuid } from 'expo';
import { ActivityIndicator, AppState, Button, FlatList, KeyboardAvoidingView, Platform, Pressable, StyleSheet, Text, TextInput, View } from 'react-native';
import { ApiError, type Listing } from './api';
import type { Session } from './auth';
import { setBlocked } from './blocks';
import { history, inbox, mergeMessages, sendMessage, type Conversation, type Message } from './messaging';
import { fetchUnread, markDisplayed } from './unread';

export type MessageScreen = { kind: 'inbox' } | { kind: 'thread'; conversation: Conversation } | { kind: 'new'; listing: Listing };

// A slow foreground request can finish across ticks. Leaving the screen, backgrounding,
// or changing accounts cancels it and prevents stale results from reaching the UI.
function usePoll(active: boolean, tick: number, load: (signal: AbortSignal) => Promise<void>) {
  const pending = useRef<AbortController | null>(null);
  useEffect(() => () => { pending.current?.abort(); pending.current = null; }, [active, load]);
  useEffect(() => {
    if (!active || pending.current) return;
    const request = new AbortController();
    pending.current = request;
    void load(request.signal).finally(() => { if (pending.current === request) pending.current = null; });
  }, [active, tick, load]);
}

// The inbox, open thread, and badges share one foreground clock per signed-in session.
export function useMessageRefresh(session: Session | null, onExpired: () => void) {
  const [active, setActive] = useState(AppState.currentState === 'active');
  const [tick, setTick] = useState(0);
  const [counts, setCounts] = useState<Awaited<ReturnType<typeof fetchUnread>> | null>(null);
  const refresh = useCallback(() => setTick(value => value + 1), []);
  useEffect(() => {
    if (!session) return;
    const change = (state: string | null | undefined) => setActive(state === 'active');
    change(AppState.currentState);
    const subscription = AppState.addEventListener('change', change);
    return () => subscription.remove();
  }, [session]);
  useEffect(() => {
    if (!session || !active) return;
    const timer = setInterval(refresh, 5000);
    return () => clearInterval(timer);
  }, [session, active, refresh]);
  useEffect(() => { setCounts(null); }, [session]);
  usePoll(!!session && active, tick, useCallback(async signal => {
    if (!session) return;
    await fetchUnread(session.token, signal).then(result => {
      if (!signal.aborted) setCounts(result);
    }).catch(error => {
      if (!signal.aborted && error instanceof ApiError && error.status === 401) onExpired();
    });
  }, [session, onExpired]));
  return { active, tick, counts, refresh };
}

type Shared = { session: Session; poll: ReturnType<typeof useMessageRefresh>; back: () => void; onExpired: () => void };

export function InboxScreen({ session, poll, back, onExpired, open }: Shared & { open: (conversation: Conversation) => void }) {
  const [rows, setRows] = useState<Conversation[] | null>(null);
  const [error, setError] = useState('');
  usePoll(poll.active, poll.tick, useCallback(async signal => {
    await inbox(session.token, signal).then(result => {
      if (!signal.aborted) { setRows(result); setError(''); }
    }).catch(cause => {
      if (signal.aborted) return;
      if (cause instanceof ApiError && cause.status === 401) onExpired();
      else setError(cause.message);
    });
  }, [session.token, onExpired]));
  const unread = new Map(poll.counts?.threads.map(row => [row.conversationId, row.unreadCount]));
  return <View style={s.page}>
    <Button title="Back to marketplace" onPress={back} />
    <Text style={s.heading}>Messages</Text>
    {!!error && <View><Text accessibilityRole="alert">{error}</Text><Button title="Retry inbox" onPress={poll.refresh} /></View>}
    {rows ? <FlatList data={rows} keyExtractor={row => row.id}
      ListEmptyComponent={<Text>No conversations yet.</Text>}
      renderItem={({ item }) => <Pressable accessibilityRole="button" style={s.row} onPress={() => open(item)}>
        <Text style={s.subtitle}>{item.listingTitle}</Text><Text>{item.peerDisplayName}</Text>
        {!!unread.get(item.id) && <Text>{unread.get(item.id)} unread</Text>}
        {!item.canMessage && <Text>Read-only</Text>}
      </Pressable>} /> : !error && <ActivityIndicator accessibilityLabel="Loading conversations" />}
  </View>;
}

export function ThreadScreen({ screen, session, poll, back, onExpired }: Omit<Shared, 'back'> & { back: (sent: boolean) => void; screen: Exclude<MessageScreen, { kind: 'inbox' }> }) {
  const existing = screen.kind === 'thread' ? screen.conversation : null;
  const [id, setId] = useState(existing?.id);
  const [messages, setMessages] = useState<Message[]>([]);
  const [hasOlder, setHasOlder] = useState(false);
  const [olderBusy, setOlderBusy] = useState(false);
  const [state, setState] = useState({ canMessage: existing?.canMessage ?? true, blockedByMe: existing?.blockedByMe ?? false,
    listingStatus: existing?.listingStatus ?? 'active' });
  const [draft, setDraft] = useState('');
  const [busy, setBusy] = useState(false);
  const [sendError, setSendError] = useState('');
  const [historyError, setHistoryError] = useState('');
  const mounted = useRef(false);
  const inFlight = useRef(false);
  const olderRequest = useRef<AbortController | null>(null);
  const pending = useRef<{ body: string; key: string } | null>(null);
  const lastFetched = useRef<number | undefined>(undefined);
  const policyGeneration = useRef(0);
  const visibleIncoming = useRef(new Set<number>());
  const pendingReads = useRef(new Set<number>());
  const acknowledged = useRef(new Set<number>());
  const reading = useRef(false);
  const [viewRevision, setViewRevision] = useState(0);
  const userId = session.user.id.toLowerCase();
  useEffect(() => {
    mounted.current = true;
    return () => { mounted.current = false; olderRequest.current?.abort(); };
  }, []);
  const failed = useCallback((cause: unknown, display: (message: string) => void) => {
    if (!mounted.current) return;
    if (cause instanceof ApiError && cause.status === 401) onExpired();
    else display(cause instanceof Error ? cause.message : 'Please try again.');
  }, [onExpired]);

  usePoll(!!id && poll.active, poll.tick, useCallback(async signal => {
    if (!id) return;
    const generation = policyGeneration.current;
    async function load(conversationId: string) {
      // Only fetched pages advance this cursor. A send response may skip another participant's message.
      let after = lastFetched.current;
      while (!signal.aborted) {
        const page = await history(session.token, conversationId, after === undefined ? undefined : { after }, signal);
        if (signal.aborted) return;
        if (policyGeneration.current === generation) setState({ blockedByMe: page.blockedByMe, canMessage: page.canMessage, listingStatus: page.listingStatus });
        if (after === undefined) setHasOlder(page.hasOlder);
        setMessages(current => mergeMessages(current, page.items));
        setHistoryError('');
        const newest = page.items.at(-1)?.sequence;
        if (newest === undefined || (after !== undefined && newest <= after)) return;
        lastFetched.current = newest;
        after = newest;
        if (!page.hasNewer) return;
      }
    }
    await load(id).catch(cause => { if (!signal.aborted) failed(cause, setHistoryError); });
  }, [id, session.token, failed]));

  async function loadOlder() {
    if (!id || !messages.length || olderRequest.current) return;
    const request = new AbortController();
    olderRequest.current = request;
    setOlderBusy(true);
    try {
      const page = await history(session.token, id, { before: messages[0].sequence }, request.signal);
      if (!request.signal.aborted) {
        setMessages(current => mergeMessages(current, page.items)); setHasOlder(page.hasOlder); setHistoryError('');
      }
    } catch (cause) { if (!request.signal.aborted) failed(cause, setHistoryError); }
    finally { olderRequest.current = null; if (mounted.current) setOlderBusy(false); }
  }

  const viewabilityConfig = useRef({ itemVisiblePercentThreshold: 50 }).current;
  const queueVisible = useCallback(() => {
    for (const sequence of visibleIncoming.current) {
      if (!acknowledged.current.has(sequence)) pendingReads.current.add(sequence);
    }
  }, []);
  const onViewableItemsChanged = useCallback(({ viewableItems }: { viewableItems: ReadonlyArray<{ isViewable: boolean; item: Message }> }) => {
    visibleIncoming.current = new Set(viewableItems.filter(row => row.isViewable && row.item.recipientId.toLowerCase() === userId)
      .map(row => row.item.sequence));
    if (mounted.current && AppState.currentState === 'active') {
      // Capture this event before React batches another scroll update.
      queueVisible();
      setViewRevision(n => n + 1);
    }
  }, [userId, queueVisible]);
  useEffect(() => {
    if (!id || !poll.active || AppState.currentState !== 'active') return;
    queueVisible(); // Include rows still on screen when returning from the background.
    if (reading.current) return;
    const sequences = [...pendingReads.current].slice(0, 100);
    if (!sequences.length) return;
    reading.current = true;
    markDisplayed(session.token, id, sequences).then(() => {
      for (const sequence of sequences) {
        acknowledged.current.add(sequence);
        pendingReads.current.delete(sequence);
      }
      reading.current = false;
      if (mounted.current) poll.refresh();
    }).catch(cause => {
      reading.current = false;
      failed(cause, setHistoryError);
    });
  }, [id, poll.active, poll.tick, poll.refresh, session.token, viewRevision, failed, queueVisible]);

  async function send() {
    if (inFlight.current || !state.canMessage || !draft.trim()) return;
    inFlight.current = true; setBusy(true); setSendError('');
    try {
      if (pending.current?.body !== draft) pending.current = { body: draft, key: uuid.v4() };
      const to = id ? { conversationId: id } : { listingId: screen.kind === 'new' ? screen.listing.id : screen.conversation.listingId };
      const result = await sendMessage(session.token, to, draft, pending.current.key);
      if (!mounted.current) return;
      pending.current = null; setDraft(''); setId(result.conversationId);
      setMessages(current => mergeMessages(current, [result.message]));
      poll.refresh();
    } catch (cause) {
      failed(cause, setSendError);
      if (mounted.current && cause instanceof ApiError && (cause.status === 403 || cause.status === 409)) poll.refresh();
    } finally { inFlight.current = false; if (mounted.current) setBusy(false); }
  }

  async function toggleBlock() {
    if (!id || inFlight.current) return;
    inFlight.current = true; setBusy(true); setSendError('');
    policyGeneration.current++;
    try {
      const next = await setBlocked(session.token, id, !state.blockedByMe);
      if (mounted.current) setState(current => ({ ...current, ...next, canMessage: next.canMessage && current.listingStatus !== 'sold' && current.listingStatus !== 'deleted' }));
    } catch (cause) { failed(cause, setSendError); }
    finally {
      policyGeneration.current++; inFlight.current = false;
      if (mounted.current) { setBusy(false); poll.refresh(); }
    }
  }
  return <KeyboardAvoidingView style={s.page} behavior={Platform.OS === 'ios' ? 'padding' : undefined}>
    <Button title={id ? 'Back to messages' : 'Back to listing'} onPress={() => back(!!id)} disabled={busy} />
    <Text style={s.heading}>{screen.kind === 'new' ? screen.listing.title : screen.conversation.listingTitle}</Text>
    <Text>{screen.kind === 'new' ? screen.listing.sellerDisplayName : screen.conversation.peerDisplayName}</Text>
    {!!id && <Button title={state.blockedByMe ? 'Unblock user' : 'Block user'} onPress={toggleBlock} disabled={busy} />}
    {!!historyError && <Text accessibilityRole="alert">{historyError}</Text>}
    {hasOlder && <Button title="Load older messages" disabled={olderBusy} onPress={loadOlder} />}
    <FlatList style={{ flex: 1 }} inverted data={[...messages].reverse()} keyExtractor={item => String(item.sequence)}
      maintainVisibleContentPosition={{ minIndexForVisible: 0 }} viewabilityConfig={viewabilityConfig} onViewableItemsChanged={onViewableItemsChanged}
      renderItem={({ item }) => <View style={s.row}><Text style={s.subtitle}>{item.senderDisplayName}</Text><Text>{item.body}</Text>
        <Text>{new Date(item.createdAt).toLocaleString()}</Text></View>} />
    {!!sendError && <Text accessibilityRole="alert">{sendError}</Text>}
    {state.canMessage ? <><TextInput multiline accessibilityLabel="Message" placeholder="Write a message" style={s.input} editable={!busy}
      value={draft} onChangeText={setDraft} /><Button title={sendError && pending.current?.body === draft ? 'Retry send' : 'Send'}
      disabled={busy || !draft.trim()} onPress={send} /></> : <Text>This conversation is read-only.</Text>}
  </KeyboardAvoidingView>;
}

const s = StyleSheet.create({
  page: { flex: 1, padding: 16, gap: 8, backgroundColor: '#f7f6f1' },
  heading: { fontSize: 26, fontWeight: '700', color: '#152f52' },
  subtitle: { fontSize: 16, fontWeight: '600', color: '#152f52' },
  row: { padding: 12, marginVertical: 4, gap: 4, borderRadius: 8, backgroundColor: 'white' },
  input: { color: '#152f52', backgroundColor: 'white', borderColor: '#9aa7b5', borderWidth: 1, padding: 10, borderRadius: 8, maxHeight: 110 },
});
