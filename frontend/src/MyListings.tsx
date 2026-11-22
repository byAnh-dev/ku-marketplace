import { useEffect, useRef, useState } from 'react';
import { ActivityIndicator, Button, Image, ScrollView, StyleSheet, Text, TextInput, View } from 'react-native';
import { File } from 'expo-file-system';
import { ApiError, createListing, CreateListingBody, Listing, myListings, OwnedListing, photoThumbnailURL, PickedPhoto } from './api';
import { AddPhotos, PhotoPicker } from './PhotoPicker';

type Props = {
  token: string; onBack: () => void; onOpen: (listing: Listing) => void; onSessionExpired: () => void;
};
type LoadState = { phase: 'loading' } | { phase: 'ready'; rows: OwnedListing[] } | { phase: 'error'; message: string; expired: boolean };

export function MyListings({ token, onBack, onOpen, onSessionExpired }: Props) {
  const [state, setState] = useState<LoadState>({ phase: 'loading' });
  const [attempt, setAttempt] = useState(0);
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
    setSelected(null); setCreating(false); setAttempt(n => n + 1);
  }

  if (selected) return <AddPhotos listingId={selected.id} token={token} onBack={backToList}
    onSessionExpired={onSessionExpired} onDone={onOpen} />;
  if (creating) return <CreateListing token={token} onBack={backToList} onSessionExpired={onSessionExpired}
    onCreated={onOpen} />;

  return <ScrollView contentContainerStyle={s.page}>
    <Button title="Back to marketplace" onPress={onBack} />
    <Text style={s.heading}>My listings</Text>
    <Button title="Create listing" onPress={() => setCreating(true)} />
    {state.phase === 'loading' ? <ActivityIndicator accessibilityLabel="Loading my listings" /> :
      state.phase === 'error' ? <View style={s.card}>
        <Text accessibilityRole="alert" style={s.error}>{state.message}</Text>
        <Button title="Retry my listings" onPress={() => setAttempt(n => n + 1)} />
        {state.expired && <Button title="Log in again" onPress={onSessionExpired} />}
      </View> : state.rows.length === 0 ? <Text style={s.body}>You have no listings yet.</Text> :
        state.rows.map(({ listing, status }) => <View key={listing.id} style={s.card}>
          <Text style={s.title}>{listing.title}</Text>
          <Text style={s.body}>{status} · ${(listing.priceCents / 100).toFixed(2)}</Text>
          {!!listing.photoURLs[0] && <Image accessibilityLabel={`Cover photo for ${listing.title}`}
            source={{ uri: photoThumbnailURL(listing.photoURLs[0]) }} style={s.photo} />}
          {status === 'active' && <>
            <Button title={`View ${listing.title}`} onPress={() => onOpen(listing)} />
            <Button title={`Add or replace photos for ${listing.title}`} onPress={() => setSelected(listing)} />
          </>}
        </View>)}
  </ScrollView>;
}

const conditions = ['New', 'Like new', 'Good', 'Fair', 'Poor'];

function listingErrors(draft: CreateListingBody, price: string): Record<string, string> {
  const errors: Record<string, string> = {};
  function checkText(field: 'title' | 'description' | 'category' | 'pickupArea', label: string, max: number) {
    if (!draft[field] && field !== 'pickupArea') errors[field] = `${label} is required.`;
    else if (draft[field].length > max) errors[field] = `${label} must be ${max} characters or fewer.`;
  }
  checkText('title', 'Title', 120);
  checkText('description', 'Description', 2000);
  checkText('category', 'Category', 50);
  checkText('pickupArea', 'Pickup area', 80);
  if (!conditions.includes(draft.condition)) errors.condition = 'Choose a condition.';
  if (!price) errors.priceCents = 'Price is required.';
  else if (!/^\d+(\.\d{1,2})?$/.test(price)) errors.priceCents = 'Enter a price in dollars with up to two decimal places.';
  else if (!Number.isSafeInteger(draft.priceCents) || draft.priceCents < 1 || draft.priceCents > 10_000_000) {
    errors.priceCents = 'Price must be between $0.01 and $100,000.00.';
  }
  return errors;
}

function CreateListing({ token, onBack, onCreated, onSessionExpired }: {
  token: string; onBack: () => void; onCreated: (listing: Listing) => void; onSessionExpired: () => void;
}) {
  const [title, setTitle] = useState('');
  const [description, setDescription] = useState('');
  const [price, setPrice] = useState('');
  const [category, setCategory] = useState('');
  const [condition, setCondition] = useState('Good');
  const [pickupArea, setPickupArea] = useState('');
  const [photos, setPhotos] = useState<PickedPhoto[]>([]);
  const [picking, setPicking] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [fields, setFields] = useState<Record<string, string>>({});
  const inFlight = useRef(false);

  async function publish() {
    if (inFlight.current || picking) return;
    const priceText = price.trim();
    const [dollars, cents = ''] = priceText.split('.');
    const draft = {
      title: title.trim(), description: description.trim(), category: category.trim(), condition,
      priceCents: Number(dollars) * 100 + Number(cents.padEnd(2, '0')), pickupArea: pickupArea.trim(),
    };
    const errors = listingErrors(draft, priceText);
    setError(''); setFields(errors);
    if (Object.keys(errors).length > 0) return;
    inFlight.current = true; setBusy(true);
    try {
      onCreated(await createListing(draft, token, photos.map(photo => new File(photo.uri))));
    } catch (failure) {
      if (failure instanceof ApiError && failure.status === 401) { onSessionExpired(); return; }
      if (failure instanceof ApiError) setFields(failure.fieldErrors);
      setError(failure instanceof Error ? failure.message : 'Could not create the listing.');
    } finally {
      inFlight.current = false; setBusy(false);
    }
  }

  return <ScrollView contentContainerStyle={s.page} keyboardShouldPersistTaps="handled">
    <Button title="Back to my listings" disabled={busy || picking} onPress={onBack} />
    <Text style={s.heading}>Create listing</Text>
    <TextInput style={s.input} editable={!busy} accessibilityLabel="Title" placeholder="Title" value={title} onChangeText={setTitle} maxLength={120} />
    <TextInput style={s.input} editable={!busy} accessibilityLabel="Description" placeholder="Description" value={description} onChangeText={setDescription} multiline maxLength={2000} />
    <TextInput style={s.input} editable={!busy} accessibilityLabel="Price in dollars" placeholder="Price in dollars" value={price} onChangeText={setPrice} keyboardType="decimal-pad" />
    <TextInput style={s.input} editable={!busy} accessibilityLabel="Category" placeholder="Category" value={category} onChangeText={setCategory} maxLength={50} />
    <Text style={s.body}>Condition</Text>
    <View style={s.conditions}>{conditions.map(value =>
      <Button key={value} title={value === condition ? `${value} (selected)` : value} disabled={busy} onPress={() => setCondition(value)} />)}</View>
    <TextInput style={s.input} editable={!busy} accessibilityLabel="Pickup area" placeholder="Pickup area, defaults to Campus" value={pickupArea} onChangeText={setPickupArea} maxLength={80} />
    <PhotoPicker photos={photos} onChange={setPhotos} disabled={busy} onPickingChange={setPicking} />
    <Text style={s.body}>Photos are optional.</Text>
    {!!error && <Text accessibilityRole="alert" style={s.error}>{error}</Text>}
    {Object.entries(fields).map(([field, message]) => <Text key={field} accessibilityRole="alert" style={s.error}>{message}</Text>)}
    {busy ? <ActivityIndicator accessibilityLabel="Creating listing" /> : <Button title="Publish listing" disabled={picking} onPress={publish} />}
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
