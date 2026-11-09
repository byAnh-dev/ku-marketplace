import { useEffect, useState } from 'react';
import { ActivityIndicator, Button, FlatList, Image, Pressable, SafeAreaView, ScrollView, StyleSheet, Text, TextInput, View } from 'react-native';
import { StatusBar } from 'expo-status-bar';
import { ApiError, detail, Listing, photoURL, search } from './src/api';

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
  // A 404 won't change on retry: the item sold or was removed, so only "Back" helps.
  if (state.unavailable) return <View><Text style={s.title}>{state.message}</Text>
    <Text style={s.body}>It may have sold or been removed.</Text></View>;
  return <View><Text style={s.body}>{state.message}</Text><Button title="Try again" onPress={retry} /></View>;
}

function Photo({ uri }: { uri?: string }) {
  return uri ? <Image accessibilityLabel="Listing photo" source={{ uri: photoURL(uri) }} style={s.photo} /> :
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

function Market({ query, setQuery, open }: { query: string; setQuery: (q: string) => void; open: (id: string) => void }) {
  const { state, retry } = useResource(query, search);
  return <View style={[s.page, s.fill]}>
    <Text style={s.label}>UNIVERSITY OF KANSAS</Text><Text style={s.heading}>KU Marketplace</Text>
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
  return <SafeAreaView style={s.fill}><StatusBar style="dark" />
    {id ? <Details id={id} back={() => setId(null)} /> : <Market query={query} setQuery={setQuery} open={setId} />}
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
