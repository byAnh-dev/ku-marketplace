import { useCallback, useEffect, useRef, useState } from 'react';
import { ActivityIndicator, Button, FlatList, Image, Pressable, SafeAreaView, ScrollView, StyleSheet, Text, TextInput, View } from 'react-native';
import { StatusBar } from 'expo-status-bar';
import { ApiError, detail, Listing, ListingFilters, ListingSort, ownedListing, photoURL, search } from './src/api';
import { listingCategories, listingConditions } from './src/listingChoices';
import { postedLabel } from './src/dates';
import { AuthScreen } from './src/AuthScreen';
import { logout, restoreSession, Session } from './src/auth';
import { MyListings } from './src/MyListings';
import { InboxScreen, ThreadScreen, useMessageRefresh, type MessageScreen } from './src/MessageScreens';
import { inbox, type Conversation } from './src/messaging';

type State<T> = { phase: 'loading' } | { phase: 'error'; message: string; unavailable: boolean } | { phase: 'ready'; value: T };
const money = (cents: number) => `$${(cents / 100).toFixed(2)}`;

function useResource<T>(key: string, load: (key: string, signal: AbortSignal) => Promise<T>) {
  const [attempt, retry] = useState(0);
  const [state, set] = useState<State<T>>({ phase: 'loading' });
  useEffect(() => {
    const request = new AbortController();
    set({ phase: 'loading' });
    load(key, request.signal).then(value => {
      if (!request.signal.aborted) set({ phase: 'ready', value });
    }).catch(error => {
      if (!request.signal.aborted) set({ phase: 'error', message: error.message, unavailable: error instanceof ApiError && error.status === 404 });
    });
    return () => request.abort();
  }, [key, load, attempt]);
  return { state, retry: () => retry(n => n + 1) };
}

function Feedback({ state, retry }: { state: Exclude<State<never>, {phase: 'ready'}>; retry: () => void }) {
  if (state.phase === 'loading') return <ActivityIndicator accessibilityLabel="Loading listings" />;
  return <View><Text style={s.body}>{state.message}</Text>
    {state.unavailable ? <Text style={s.body}>It may have sold or been removed.</Text> : <Button title="Try again" onPress={retry} />}
  </View>;
}

function Photo({ uri }: { uri?: string }) {
  return uri ? <Image accessibilityLabel="Listing photo" source={{ uri: photoURL(uri) }} style={s.photo} /> :
    <View style={[s.photo, s.placeholder]}><Text style={s.label}>No photo</Text></View>;
}

function Details({ id, back, ownerToken, contact, token, onExpired }: { id: string; back: () => void; ownerToken?: string;
  contact: (listing: Listing, existing?: Conversation) => void; token?: string; onExpired: () => void }) {
  const pendingContact = useRef<AbortController | null>(null);
  const [checking, setChecking] = useState(false);
  const [contactError, setContactError] = useState('');
  useEffect(() => () => { pendingContact.current?.abort(); pendingContact.current = null; }, [id, token]);
  async function messageSeller(listing: Listing) {
    if (!token) { contact(listing); return; }
    if (pendingContact.current) return;
    const request = new AbortController();
    pendingContact.current = request;
    setChecking(true); setContactError('');
    try {
      const rows = await inbox(token, request.signal);
      if (request.signal.aborted) return;
      const existing = rows.find(row => row.listingId === listing.id);
      if (existing && !existing.isBuyer) setContactError('This is your listing. Open Messages to reply to buyers.');
      else contact(listing, existing);
    } catch (error) {
      if (request.signal.aborted) return;
      if (error instanceof ApiError && error.status === 401) onExpired();
      else setContactError(error instanceof Error ? error.message : 'Could not open messages.');
    } finally {
      if (!request.signal.aborted) { pendingContact.current = null; setChecking(false); }
    }
  }
  const load = useCallback(async (listingId: string, signal: AbortSignal): Promise<{ listing: Listing; status?: string }> => {
    if (ownerToken) return ownedListing(listingId, ownerToken, signal);
    return { listing: await detail(listingId, signal) };
  }, [ownerToken]);
  const { state, retry } = useResource(id, load);
  return <ScrollView contentContainerStyle={s.page}>
    <Button title={ownerToken ? 'Back to my listings' : 'Back to marketplace'} onPress={back} />
    {state.phase !== 'ready' ? <Feedback state={state} retry={retry} /> : <>
      <Text style={s.label}>{state.value.listing.category}</Text><Text style={s.heading}>{state.value.listing.title}</Text>
      <Text style={s.price}>{money(state.value.listing.priceCents)}</Text>
      {state.value.status && <Text style={s.body}>Status: {state.value.status}</Text>}
      {state.value.listing.photoURLs.length ? state.value.listing.photoURLs.map(uri => <Photo key={uri} uri={uri} />) : <Photo />}
      <Text style={s.body}>{state.value.listing.description}</Text>
      <Text style={s.body}>Condition: {state.value.listing.condition}</Text>
      <Text style={s.body}>Seller: {state.value.listing.sellerDisplayName}</Text>
      {!!postedLabel(state.value.listing.postedAt) && <Text style={s.label}>{postedLabel(state.value.listing.postedAt)}</Text>}
      {!ownerToken && <Text style={s.body}>Status: Active</Text>}
      {!ownerToken && <Button title={token ? 'Message seller' : 'Log in to message seller'} disabled={checking} onPress={() => messageSeller(state.value.listing)} />}
      {!!contactError && <Text accessibilityRole="alert">{contactError}</Text>}
      <Text style={s.body}>Pickup: {state.value.listing.pickupArea}</Text>
      <Text style={s.label}>Buyers and sellers arrange pickup and payment themselves.</Text>
    </>}
  </ScrollView>;
}

type FilterDraft = { category: string; condition: string; minimum: string; maximum: string };
const noFilters: FilterDraft = { category: '', condition: '', minimum: '', maximum: '' };

const filterCount = (filters: ListingFilters) =>
  (filters.category ? 1 : 0) + (filters.condition ? 1 : 0) +
  (filters.minPriceCents !== undefined ? 1 : 0) + (filters.maxPriceCents !== undefined ? 1 : 0);

const draftOf = (filters: ListingFilters): FilterDraft => ({
  category: filters.category ?? '', condition: filters.condition ?? '',
  minimum: filters.minPriceCents !== undefined ? String(filters.minPriceCents / 100) : '',
  maximum: filters.maxPriceCents !== undefined ? String(filters.maxPriceCents / 100) : '',
});

// Returns undefined for a blank field, null for an invalid one, cents otherwise.
function centsFrom(value: string): number | undefined | null {
  const trimmed = value.trim();
  if (!trimmed) return undefined;
  if (!/^\d+(\.\d{1,2})?$/.test(trimmed)) return null;
  return Math.round(Number(trimmed) * 100);
}

const sortChoices: { value: ListingSort; label: string }[] = [
  { value: 'newest', label: 'Newest' },
  { value: 'price_asc', label: 'Lowest price' },
  { value: 'price_desc', label: 'Highest price' },
];

function Market({ query, setQuery, filters, setFilters, sort, setSort, open, account }: {
  query: string; setQuery: (q: string) => void; filters: ListingFilters; setFilters: (value: ListingFilters) => void;
  sort: ListingSort; setSort: (value: ListingSort) => void;
  open: (id: string) => void; account: React.ReactNode }) {
  const [page, setPage] = useState(1);
  const [panelOpen, setPanelOpen] = useState(false);
  const [draft, setDraft] = useState<FilterDraft>(() => draftOf(filters));
  const [filterError, setFilterError] = useState('');
  useEffect(() => setPage(1), [query, filters, sort]);
  const loadPage = useCallback((key: string, signal: AbortSignal) => {
    const [term, currentPage, filtersJSON, order] = key.split('\u0000');
    return search(term, Number(currentPage), JSON.parse(filtersJSON) as ListingFilters, order as ListingSort, signal);
  }, []);
  const { state, retry } = useResource(
    `${query}\u0000${page}\u0000${JSON.stringify(filters)}\u0000${sort}`, loadPage);
  const applied = filterCount(filters);

  function applyFilters() {
    const minimum = centsFrom(draft.minimum);
    const maximum = centsFrom(draft.maximum);
    if (minimum === null || maximum === null) { setFilterError('Enter prices like 10 or 10.50.'); return; }
    if (minimum !== undefined && maximum !== undefined && minimum > maximum) {
      setFilterError('Minimum price must not be greater than the maximum.'); return;
    }
    setFilterError('');
    setFilters({ category: draft.category || undefined, condition: draft.condition || undefined,
      minPriceCents: minimum, maxPriceCents: maximum });
    setPanelOpen(false);
  }
  function clearFilters() {
    setDraft(noFilters); setFilterError('');
    setFilters({});
  }

  return <View style={[s.page, s.fill]}>
    <Text style={s.label}>UNIVERSITY OF KANSAS</Text><Text style={s.heading}>KU Marketplace</Text>
    {account}
    <TextInput style={s.input} accessibilityLabel="Search listings" placeholder="Search items by keyword" placeholderTextColor="#606975" value={query} onChangeText={setQuery} />
    <View style={s.chips}>{sortChoices.map(choice =>
      <Pressable key={choice.value} accessibilityRole="button" accessibilityLabel={choice.label}
        accessibilityState={{ selected: sort === choice.value }}
        onPress={() => setSort(choice.value)}
        style={[s.chip, sort === choice.value && s.activeChip]}>
        <Text style={[s.chipText, sort === choice.value && s.activeChipText]}>{choice.label}</Text>
      </Pressable>)}</View>
    <View style={s.filterRow}>
      <Button title="Filters" onPress={() => setPanelOpen(open => !open)} />
      {applied > 0 && <Text style={s.label}>{applied} applied</Text>}
      {applied > 0 && <Button title="Clear filters" onPress={clearFilters} />}
    </View>
    {panelOpen && <View style={s.filterPanel}>
      <Text style={s.label}>Category</Text>
      <View style={s.chips}>{listingCategories.map(([emoji, value]) =>
        <Pressable key={value} accessibilityRole="button" accessibilityLabel={value}
          accessibilityState={{ selected: draft.category === value }}
          onPress={() => setDraft(current => ({ ...current, category: current.category === value ? '' : value }))}
          style={[s.chip, draft.category === value && s.activeChip]}>
          <Text style={[s.chipText, draft.category === value && s.activeChipText]}>{emoji} {value}</Text>
        </Pressable>)}</View>
      <Text style={s.label}>Condition</Text>
      <View style={s.chips}>{listingConditions.map(value =>
        <Pressable key={value} accessibilityRole="button" accessibilityLabel={value}
          accessibilityState={{ selected: draft.condition === value }}
          onPress={() => setDraft(current => ({ ...current, condition: current.condition === value ? '' : value }))}
          style={[s.chip, draft.condition === value && s.activeChip]}>
          <Text style={[s.chipText, draft.condition === value && s.activeChipText]}>{value}</Text>
        </Pressable>)}</View>
      <Text style={s.label}>Price range (USD)</Text>
      <View style={s.priceRow}>
        <TextInput accessibilityLabel="Minimum price" placeholder="Min" placeholderTextColor="#606975" keyboardType="decimal-pad"
          value={draft.minimum} onChangeText={minimum => setDraft(current => ({ ...current, minimum }))} style={[s.input, s.priceInput]} />
        <TextInput accessibilityLabel="Maximum price" placeholder="Max" placeholderTextColor="#606975" keyboardType="decimal-pad"
          value={draft.maximum} onChangeText={maximum => setDraft(current => ({ ...current, maximum }))} style={[s.input, s.priceInput]} />
      </View>
      {!!filterError && <Text accessibilityRole="alert" style={s.error}>{filterError}</Text>}
      <Button title="Apply filters" onPress={applyFilters} />
    </View>}
    {query.length > 0 && <Button title="Clear search" onPress={() => setQuery('')} />}
    {state.phase !== 'ready' ? <Feedback state={state} retry={retry} /> :
      <FlatList data={state.value.items} keyExtractor={item => item.id}
        ListEmptyComponent={<Text style={s.body}>{applied > 0 ? 'No listings match these filters.' :
          query.trim() ? 'No matching items. Try another keyword.' : 'No active listings yet.'}</Text>}
        renderItem={({ item }) => <Pressable accessibilityRole="button" style={s.card} onPress={() => open(item.id)}>
          <Photo uri={item.photoURLs[0]} /><Text style={s.label}>{item.category}</Text>
          <Text style={s.title}>{item.title}</Text><Text style={s.price}>{money(item.priceCents)}</Text>
          {!!postedLabel(item.postedAt) && <Text style={s.label}>{postedLabel(item.postedAt)}</Text>}
        </Pressable>}
        ListFooterComponent={<View style={s.pagination}>
          {page > 1 && <Button title="Previous page" onPress={() => setPage(current => current - 1)} />}
          {state.value.hasMore && <Button title="Next page" onPress={() => setPage(current => current + 1)} />}
        </View>} />}
  </View>;
}

export default function App() {
  const [id, setId] = useState<string | null>(null);
  const [query, setQuery] = useState('');
  const [filters, setFilters] = useState<ListingFilters>({});
  const [sort, setSort] = useState<ListingSort>('newest');
  const [authOpen, setAuthOpen] = useState(false);
  const [myListingsOpen, setMyListingsOpen] = useState(false);
  const [session, setSession] = useState<Session | null>(null);
  const [messageScreen, setMessageScreen] = useState<MessageScreen | null>(null);
  const [restoring, setRestoring] = useState(true);
  const [restoreAttempt, setRestoreAttempt] = useState(0);
  const [restoreError, setRestoreError] = useState('');
  const [authError, setAuthError] = useState('');
  const [signingOut, setSigningOut] = useState(false);
  useEffect(() => {
    let active = true;
    setRestoring(true); setRestoreError('');
    restoreSession().then(value => {
      if (active) setSession(value);
    }).catch(() => {
      if (active) setRestoreError('Could not restore your session. You can keep browsing and retry when connected.');
    }).finally(() => { if (active) setRestoring(false); });
    return () => { active = false; };
  }, [restoreAttempt]);
  async function signOut() {
    if (!session) return;
    setSigningOut(true); setAuthError('');
    try { await logout(session.token); setMessageScreen(null); setSession(null); }
    catch { setAuthError('Could not finish logging out. Check your connection and try again.'); }
    finally { setSigningOut(false); }
  }
  const sessionExpired = useCallback(() => {
    setSession(null); setMessageScreen(null); setMyListingsOpen(false); setAuthOpen(true);
  }, []);
  const poll = useMessageRefresh(session, sessionExpired);
  const account = restoring ? <ActivityIndicator accessibilityLabel="Restoring session" /> : restoreError ? <View>
    <Text accessibilityRole="alert" style={s.body}>{restoreError}</Text>
    <Button title="Retry session" onPress={() => setRestoreAttempt(n => n + 1)} />
  </View> : session ? <View style={{ gap: 4 }}>
    <Text style={s.body}>Signed in as {session.user.displayName}</Text>
    <Button title={poll.counts?.total ? `Messages (${poll.counts.total} unread)` : 'Messages'} disabled={signingOut} onPress={() => setMessageScreen({ kind: 'inbox' })} />
    <Button title="My listings" disabled={signingOut} onPress={() => setMyListingsOpen(true)} />
    <Button title={signingOut ? 'Logging out...' : 'Log out'} disabled={signingOut} onPress={signOut} />
    {!!authError && <Text accessibilityRole="alert" style={s.body}>{authError}</Text>}
  </View> : <Button title="Student login / register" onPress={() => setAuthOpen(true)} />;
  return <SafeAreaView style={s.fill}><StatusBar style="dark" />
    {authOpen ? <AuthScreen onBack={() => setAuthOpen(false)} onLogin={value => { setSession(value); setAuthError(''); setAuthOpen(false); }} /> :
      session && messageScreen?.kind === 'inbox' ? <InboxScreen key={session.token} session={session} poll={poll} onExpired={sessionExpired}
        back={() => { setId(null); setMessageScreen(null); }} open={conversation => setMessageScreen({ kind: 'thread', conversation })} /> :
      session && messageScreen && messageScreen.kind !== 'inbox' ? <ThreadScreen key={session.token} screen={messageScreen} session={session} poll={poll} onExpired={sessionExpired}
        back={sent => setMessageScreen(sent || messageScreen.kind === 'thread' ? { kind: 'inbox' } : null)} /> :
      id ? <Details id={id} back={() => setId(null)} ownerToken={myListingsOpen ? session?.token : undefined} token={session?.token} onExpired={sessionExpired}
        contact={(listing, existing) => session ? setMessageScreen(existing ? { kind: 'thread', conversation: existing } : { kind: 'new', listing }) : setAuthOpen(true)} /> :
      myListingsOpen && session ? <MyListings token={session.token} onBack={() => setMyListingsOpen(false)} onViewOwned={setId}
        onOpen={listing => { setMyListingsOpen(false); setId(listing.id); }} onSessionExpired={sessionExpired} /> :
      <Market query={query} setQuery={setQuery} filters={filters} setFilters={setFilters} sort={sort} setSort={setSort} open={setId} account={account} />}
  </SafeAreaView>;
}

const s = StyleSheet.create({
  fill: { flex: 1, backgroundColor: '#f7f6f1' },
  page: { paddingHorizontal: 20, paddingTop: 24, paddingBottom: 12, gap: 12 },
  heading: { fontSize: 34, fontWeight: '700', color: '#152f52' },
  title: { fontSize: 20, fontWeight: '600', color: '#152f52' },
  label: { color: '#49596b', fontSize: 14, fontWeight: '500' },
  input: { borderWidth: 1, borderColor: '#9aa7b5', borderRadius: 8, backgroundColor: 'white', padding: 12, color: '#152f52' },
  card: { borderRadius: 12, backgroundColor: 'white', padding: 14, gap: 6, marginBottom: 12 },
  photo: { width: '100%', height: 120, borderRadius: 8 },
  pagination: { flexDirection: 'row', justifyContent: 'space-between', paddingVertical: 8 },
  filterRow: { flexDirection: 'row', gap: 12, alignItems: 'center', flexWrap: 'wrap' },
  filterPanel: { gap: 8, backgroundColor: 'white', borderRadius: 12, padding: 14 },
  chips: { flexDirection: 'row', flexWrap: 'wrap', gap: 8 },
  chip: { borderWidth: 1, borderColor: '#9aa7b5', borderRadius: 999, paddingVertical: 6, paddingHorizontal: 12 },
  activeChip: { backgroundColor: '#152f52', borderColor: '#152f52' },
  chipText: { color: '#152f52', fontSize: 14 },
  activeChipText: { color: 'white' },
  priceRow: { flexDirection: 'row', gap: 8 },
  priceInput: { flex: 1 },
  error: { color: '#b00020' },
  placeholder: { backgroundColor: '#e7edf0', alignItems: 'center', justifyContent: 'center' },
  price: { color: '#174d7e', fontSize: 20, fontWeight: '700' },
  body: { color: '#263745', fontSize: 17 },
});
