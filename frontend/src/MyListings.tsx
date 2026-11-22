import { useEffect, useRef, useState } from 'react';
import { ActivityIndicator, Button, Image, ScrollView, StyleSheet, Text, TextInput, View } from 'react-native';
import { ApiError, createListing, editListing, Listing, myListing, myListings, OwnedListing, photoURL } from './api';
import { AddPhotos } from './PhotoPicker';

type Props = {
  token: string; onBack: () => void; onOpen: (listing: Listing) => void; onSessionExpired: () => void;
};
type LoadState = { phase: 'loading' } | { phase: 'ready'; rows: OwnedListing[] } | { phase: 'error'; message: string; expired: boolean };

export function MyListings({ token, onBack, onOpen, onSessionExpired }: Props) {
  const [state, setState] = useState<LoadState>({ phase: 'loading' });
  const [attempt, setAttempt] = useState(0);
  const [editing, setEditing] = useState<string | null>(null);
  const [creating, setCreating] = useState(false);
  const [selected, setSelected] = useState<Listing | null>(null);
  useEffect(() => {
    const controller = new AbortController();
    setState({ phase: 'loading' });
    myListings(token, controller.signal).then(rows => {
      if (!controller.signal.aborted) setState({ phase: 'ready', rows });
    }).catch(error => {
      if (controller.signal.aborted) return;
      setState({ phase: 'error', message: error instanceof Error ? error.message : 'Could not load your listings.',
        expired: error instanceof ApiError && error.status === 401 });
    });
    return () => controller.abort();
  }, [token, attempt]);

  function backToList() {
    setSelected(null); setEditing(null); setCreating(false); setAttempt(n => n + 1);
  }

  if (editing) return <EditListing listingId={editing} token={token} onBack={backToList} onSaved={backToList} onSessionExpired={onSessionExpired} />;
  if (selected) return <AddPhotos listingId={selected.id} token={token} onBack={backToList}
    onSessionExpired={onSessionExpired} onDone={onOpen} />;
  if (creating) return <ListingForm token={token} onBack={backToList} onSessionExpired={onSessionExpired}
    onSaved={listing => { setCreating(false); setSelected(listing); }} />;

  return <ScrollView contentContainerStyle={s.page}>
    <Button title="Back to marketplace" onPress={onBack} />
    <Text style={s.heading}>My listings</Text>
    <Button title="Create listing" onPress={() => setCreating(true)} />
    {state.phase === 'loading' ? <ActivityIndicator accessibilityLabel="Loading my listings" /> :
      state.phase === 'error' ? <View style={s.card}>
        <Text accessibilityRole="alert" style={s.error}>{state.message}</Text>
        <Button title="Retry my listings" onPress={() => setAttempt(n => n + 1)} />
        {state.expired && <Button title="Log in again" onPress={onSessionExpired} />}
      </View> : state.rows.length === 0 ? <Text style={s.body}>You have no listings yet. Create one to add photos.</Text> :
        state.rows.map(({ listing, status }) => <View key={listing.id} style={s.card}>
          <Text style={s.title}>{listing.title}</Text>
          <Text style={s.body}>{status} · ${(listing.priceCents / 100).toFixed(2)}</Text>
          {!!listing.photoURLs[0] && <Image accessibilityLabel={`Cover photo for ${listing.title}`}
            source={{ uri: photoURL(listing.photoURLs[0]) }} style={s.photo} />}
          {status === 'active' && <>
            <Button title={`Edit ${listing.title}`} onPress={() => setEditing(listing.id)} />
            <Button title={`View ${listing.title}`} onPress={() => onOpen(listing)} />
            <Button title={`Add or replace photos for ${listing.title}`} onPress={() => setSelected(listing)} />
          </>}
        </View>)}
  </ScrollView>;
}

function EditListing({ listingId, token, onBack, onSaved, onSessionExpired }: {
  listingId: string; token: string; onBack: () => void; onSaved: () => void; onSessionExpired: () => void;
}) {
  const [item, setItem] = useState<OwnedListing | null>(null);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);
  const [attempt, setAttempt] = useState(0);
  useEffect(() => {
    const controller = new AbortController();
    setLoading(true); setError(''); setItem(null);
    myListing(listingId, token, controller.signal).then(value => {
      if (!controller.signal.aborted) setItem(value);
    }).catch(failure => {
      if (controller.signal.aborted) return;
      if (failure instanceof ApiError && failure.status === 401) onSessionExpired();
      setError(failure instanceof Error ? failure.message : 'Could not load the listing.');
    }).finally(() => { if (!controller.signal.aborted) setLoading(false); });
    return () => controller.abort();
  }, [listingId, token, attempt]);
  const reload = () => setAttempt(n => n + 1);
  if (!loading && item?.status === 'active') return <ListingForm key={attempt} token={token} initial={item}
    onBack={onBack} onSaved={onSaved} onSessionExpired={onSessionExpired} onReload={reload} />;
  return <ScrollView contentContainerStyle={s.page}>
    <Button title="Cancel" onPress={onBack} />
    <Text style={s.heading}>Edit listing</Text>
    {loading ? <ActivityIndicator accessibilityLabel="Loading listing" /> : <>
      <Text accessibilityRole="alert" style={s.error}>{error || `This listing is ${item?.status} and cannot be edited.`}</Text>
      <Button title="Reload listing" onPress={reload} />
    </>}
  </ScrollView>;
}

function ListingForm({ token, onBack, onSaved, onSessionExpired, initial, onReload }: {
  token: string; onBack: () => void; onSaved: (listing: Listing) => void; onSessionExpired: () => void;
  initial?: OwnedListing; onReload?: () => void;
}) {
  const [title, setTitle] = useState(initial?.listing.title ?? '');
  const [description, setDescription] = useState(initial?.listing.description ?? '');
  const [price, setPrice] = useState(initial ? (initial.listing.priceCents / 100).toFixed(2) : '');
  const [category, setCategory] = useState(initial?.listing.category ?? '');
  const [condition, setCondition] = useState(initial?.listing.condition ?? 'Good');
  const [pickupArea, setPickupArea] = useState(initial?.listing.pickupArea ?? '');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [fields, setFields] = useState<Record<string, string>>({});
  const inFlight = useRef(false);
  const [needsReload, setNeedsReload] = useState(false);

  async function publish() {
    if (inFlight.current || needsReload) return;
    setError(''); setFields({});
    const errors: Record<string, string> = {};
    for (const [key, value, limit] of [['title', title, 120], ['description', description, 2000], ['category', category, 50]] as const) {
      const label = key[0].toUpperCase() + key.slice(1);
      if (!value.trim()) errors[key] = `${label} is required.`;
      else if (Array.from(value.trim()).length > limit) errors[key] = `${label} must be ${limit} characters or fewer.`;
    }
    if (!['New', 'Like new', 'Good', 'Fair', 'Poor'].includes(condition)) errors.condition = 'Choose a valid condition.';
    if (Array.from(pickupArea.trim()).length > 80) errors.pickupArea = 'Pickup area must be 80 characters or fewer.';
    const [dollars, cents = ''] = price.trim().split('.');
    const priceCents = Number(dollars) * 100 + Number(cents.padEnd(2, '0'));
    if (!/^\d+(\.\d{1,2})?$/.test(price.trim())) {
      errors.priceCents = 'Enter a price in dollars with up to two decimal places.';
    } else if (!Number.isSafeInteger(priceCents) || priceCents < 1 || priceCents > 10_000_000) {
      errors.priceCents = 'Price must be between $0.01 and $100,000.00.';
    }
    if (Object.keys(errors).length) { setFields(errors); return; }
    inFlight.current = true; setBusy(true);
    try {
      const draft = { title: title.trim(), description: description.trim(), priceCents,
        category: category.trim(), condition, pickupArea: pickupArea.trim() };
      onSaved(initial ? (await editListing(initial.listing.id, draft, initial.revision, token)).listing : await createListing(draft, token));
    } catch (failure) {
      if (failure instanceof ApiError && failure.status === 401) { onSessionExpired(); return; }
      if (failure instanceof ApiError) {
        setFields(failure.fieldErrors);
        if (initial && [403, 404, 409, 428].includes(failure.status)) setNeedsReload(true);
      }
      setError(failure instanceof Error ? failure.message : 'Could not save the listing.');
    } finally {
      inFlight.current = false; setBusy(false);
    }
  }

  return <ScrollView contentContainerStyle={s.page} keyboardShouldPersistTaps="handled">
    <Button title={initial ? "Cancel" : "Back to my listings"} disabled={busy} onPress={onBack} />
    <Text style={s.heading}>{initial ? "Edit listing" : "Create listing"}</Text>
    {!initial && <Text style={s.body}>Publish the item details, then choose its photos. You can add photos later from My listings.</Text>}
    <TextInput style={s.input} editable={!busy} accessibilityLabel="Title" placeholder="Title" value={title} onChangeText={setTitle} maxLength={120} />
    <TextInput style={s.input} editable={!busy} accessibilityLabel="Description" placeholder="Description" value={description} onChangeText={setDescription} multiline maxLength={2000} />
    <TextInput style={s.input} editable={!busy} accessibilityLabel="Price in dollars" placeholder="Price in dollars" value={price} onChangeText={setPrice} keyboardType="decimal-pad" />
    <TextInput style={s.input} editable={!busy} accessibilityLabel="Category" placeholder="Category" value={category} onChangeText={setCategory} maxLength={50} />
    <Text style={s.body}>Condition</Text>
    <View style={s.conditions}>{['New', 'Like new', 'Good', 'Fair', 'Poor'].map(value =>
      <Button key={value} title={value === condition ? `${value} (selected)` : value} disabled={busy} onPress={() => setCondition(value)} />)}</View>
    {!initial && <TextInput style={s.input} editable={!busy} accessibilityLabel="Pickup area" placeholder="Pickup area, defaults to Campus" value={pickupArea} onChangeText={setPickupArea} maxLength={80} />}
    {!!error && <Text accessibilityRole="alert" style={s.error}>{error}</Text>}
    {Object.entries(fields).map(([field, message]) => <Text key={field} accessibilityRole="alert" style={s.error}>{message}</Text>)}
    {initial && <Button title="Reload listing" disabled={busy} onPress={onReload} />}
    {busy ? <ActivityIndicator accessibilityLabel="Saving listing" /> :
      <Button title={initial ? "Save changes" : "Publish and add photos"} disabled={needsReload} onPress={publish} />}
  </ScrollView>;
}

const s = StyleSheet.create({
  page: { paddingHorizontal: 20, paddingTop: 24, paddingBottom: 12, gap: 12 },
  heading: { fontSize: 30, fontWeight: '700', color: '#152f52' },
  title: { fontSize: 20, fontWeight: '600', color: '#152f52' },
  body: { color: '#263745', fontSize: 16 },
  error: { color: '#b3261e', fontSize: 15 },
  input: { borderWidth: 1, borderColor: '#9aa7b5', borderRadius: 8, backgroundColor: 'white', padding: 12, color: '#152f52' },
  card: { borderRadius: 12, backgroundColor: 'white', padding: 14, gap: 8 },
  photo: { width: '100%', height: 120, borderRadius: 8 },
  conditions: { flexDirection: 'row', flexWrap: 'wrap', gap: 4 },
});
