import { useEffect, useState } from 'react';
import { ActivityIndicator, Button, FlatList, Image, Pressable, SafeAreaView, ScrollView, StyleSheet, Text, TextInput, View } from 'react-native';
import { StatusBar } from 'expo-status-bar';
import { detail, Listing, search } from './src/api';
import { AuthScreen } from './src/AuthScreen';
import { logout, restoreSession, Session } from './src/auth';

type State<T> = { phase: 'loading' } | { phase: 'error'; message: string } | { phase: 'ready'; value: T };
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
      if (!request.signal.aborted) set({ phase: 'error', message: error.message });
    });
    return () => request.abort();
  }, [key, load, attempt]);
  return { state, retry: () => retry(n => n + 1) };
}

function Feedback({ state, retry }: { state: Exclude<State<never>, {phase: 'ready'}>; retry: () => void }) {
  return state.phase === 'loading' ? <ActivityIndicator accessibilityLabel="Loading listings" /> :
    <View><Text style={s.body}>{state.message}</Text><Button title="Try again" onPress={retry} /></View>;
}

function Photo({ uri }: { uri?: string }) {
  return uri ? <Image accessibilityLabel="Listing photo" source={{ uri }} style={s.photo} /> :
    <View style={[s.photo, s.placeholder]}><Text style={s.label}>No photo</Text></View>;
}

function Details({ id, back }: { id: string; back: () => void }) {
  const { state, retry } = useResource(id, detail);
  return <ScrollView contentContainerStyle={s.page}>
    <Button title="Back to marketplace" onPress={back} />
    {state.phase !== 'ready' ? <Feedback state={state} retry={retry} /> : <>
      <Text style={s.label}>{state.value.category}</Text><Text style={s.heading}>{state.value.title}</Text>
      <Text style={s.price}>{money(state.value.priceCents)}</Text>
      {state.value.photoURLs.length ? state.value.photoURLs.map(uri => <Photo key={uri} uri={uri} />) : <Photo />}
      <Text style={s.body}>{state.value.description}</Text>
      <Text style={s.body}>Condition: {state.value.condition}</Text>
      <Text style={s.body}>Seller: {state.value.sellerDisplayName}</Text>
      <Text style={s.body}>Pickup: {state.value.pickupArea}</Text>
      <Text style={s.label}>Buyers and sellers arrange pickup and payment themselves.</Text>
    </>}
  </ScrollView>;
}

function Market({ query, setQuery, open, account }: { query: string; setQuery: (q: string) => void; open: (id: string) => void; account: React.ReactNode }) {
  const { state, retry } = useResource(query, search);
  return <View style={[s.page, s.fill]}>
    <Text style={s.label}>UNIVERSITY OF KANSAS</Text><Text style={s.heading}>KU Marketplace</Text>
    {account}
    <TextInput style={s.input} accessibilityLabel="Search listings" placeholder="Search items by keyword" placeholderTextColor="#606975" value={query} onChangeText={setQuery} />
    {query.length > 0 && <Button title="Clear search" onPress={() => setQuery('')} />}
    {state.phase !== 'ready' ? <Feedback state={state} retry={retry} /> :
      <FlatList data={state.value} keyExtractor={item => item.id}
        ListEmptyComponent={<Text style={s.body}>{query.trim() ? 'No matching items. Try another keyword.' : 'No active listings yet.'}</Text>}
        renderItem={({ item }) => <Pressable accessibilityRole="button" style={s.card} onPress={() => open(item.id)}>
          <Photo uri={item.photoURLs[0]} /><Text style={s.label}>{item.category}</Text>
          <Text style={s.title}>{item.title}</Text><Text style={s.price}>{money(item.priceCents)}</Text>
        </Pressable>} />}
  </View>;
}

export default function App() {
  const [id, setId] = useState<string | null>(null);
  const [query, setQuery] = useState('');
  const [authOpen, setAuthOpen] = useState(false);
  const [session, setSession] = useState<Session | null>(null);
  const [restoring, setRestoring] = useState(true);
  const [authError, setAuthError] = useState('');
  const [signingOut, setSigningOut] = useState(false);
  useEffect(() => { restoreSession().then(setSession).catch(() => {}).finally(() => setRestoring(false)); }, []);
  async function signOut() {
    if (!session) return;
    setSigningOut(true); setAuthError('');
    try { await logout(session.token); setSession(null); }
    catch { setAuthError('Logout could not reach the server. Reconnect and retry to revoke your session.'); }
    finally { setSigningOut(false); }
  }
  const account = restoring ? <ActivityIndicator /> : session ? <View style={{ gap: 4 }}>
    <Text style={s.body}>Signed in as {session.user.displayName}</Text>
    <Button title={signingOut ? 'Logging out...' : 'Log out'} disabled={signingOut} onPress={signOut} />
    {!!authError && <Text style={s.body}>{authError}</Text>}
  </View> : <Button title="Student login / register" onPress={() => setAuthOpen(true)} />;
  return <SafeAreaView style={s.fill}><StatusBar style="dark" />
    {authOpen ? <AuthScreen onBack={() => setAuthOpen(false)} onLogin={value => { setSession(value); setAuthOpen(false); }} /> :
      id ? <Details id={id} back={() => setId(null)} /> :
      <Market query={query} setQuery={setQuery} open={setId} account={account} />}
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
  placeholder: { backgroundColor: '#e7edf0', alignItems: 'center', justifyContent: 'center' },
  price: { color: '#174d7e', fontSize: 20, fontWeight: '700' },
  body: { color: '#263745', fontSize: 17 },
});
