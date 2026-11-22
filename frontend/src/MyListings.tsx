import { useEffect, useRef, useState } from 'react';
import { ActivityIndicator, Button, ScrollView, StyleSheet, Text, TextInput, View } from 'react-native';
import { File } from 'expo-file-system';
import { ApiError, createListing, CreateListingBody, Listing, myListings, OwnedListing, editListing, ownedListing, PickedPhoto } from './api';
import { AddPhotos, PhotoPicker } from './PhotoPicker';
import { EditListingForm } from './EditListingForm';
import { OwnedListingCard } from './OwnedListingCard';

type Props = {
  token: string; onBack: () => void; onOpen: (listing: Listing) => void;
  onViewOwned: (id: string) => void; onSessionExpired: () => void;
};
type LoadState = { phase: 'loading' } | { phase: 'ready'; rows: OwnedListing[] } | { phase: 'error'; message: string; expired: boolean };

export function MyListings({ token, onBack, onOpen, onViewOwned, onSessionExpired }: Props) {
  const [state, setState] = useState<LoadState>({ phase: 'loading' });
  const [attempt, setAttempt] = useState(0);
  const [managing, setManaging] = useState(false);
  const [notice, setNotice] = useState('');
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
    onSaved={onOpen} />;

  return <ScrollView style={{ backgroundColor: '#f9f9ff' }} contentContainerStyle={s.page}>
    <Button title="Back to marketplace" disabled={managing} onPress={onBack} />
    <Text style={s.heading}>My listings</Text>
    <Button title="Create listing" disabled={managing} onPress={() => setCreating(true)} />
    {!!notice && <Text accessibilityRole="status" style={s.body}>{notice}</Text>}
    {state.phase === 'loading' ? <ActivityIndicator accessibilityLabel="Loading my listings" /> :
      state.phase === 'error' ? <View style={s.card}>
        <Text accessibilityRole="alert" style={s.error}>{state.message}</Text>
        <Button title="Retry my listings" onPress={() => setAttempt(n => n + 1)} />
        {state.expired && <Button title="Log in again" onPress={onSessionExpired} />}
      </View> : state.rows.length === 0 ? <Text style={s.body}>You have no listings yet.</Text> :
        state.rows.map(item => <OwnedListingCard key={item.listing.id} item={item} token={token} disabled={managing}
          onEdit={() => setEditing(item.listing.id)} onOpen={() => onViewOwned(item.listing.id)} onPhotos={() => setSelected(item.listing)}
          onBusy={setManaging} onSessionExpired={onSessionExpired} onReload={() => { setNotice(''); setAttempt(n => n + 1); }}
          onChanged={updated => {
            setState(current => current.phase === 'ready' ? { phase: 'ready', rows: updated.status === 'deleted'
              ? current.rows.filter(row => row.listing.id !== updated.listing.id)
              : current.rows.map(row => row.listing.id === updated.listing.id ? updated : row) } : current);
            setNotice(updated.status === 'deleted' ? 'Listing deleted.' : 'Listing marked as sold.');
          }} />)}
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
    ownedListing(listingId, token, controller.signal).then(value => {
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

const conditions = ['New', 'Like new', 'Good', 'Fair', 'Poor'];

function listingErrors(draft: CreateListingBody, price: string): Record<string, string> {
  const errors: Record<string, string> = {};
  function checkText(field: 'title' | 'description' | 'category' | 'pickupArea', label: string, max: number) {
    if (!draft[field] && field !== 'pickupArea') errors[field] = `${label} is required.`;
    else if (Array.from(draft[field]).length > max) errors[field] = `${label} must be ${max} characters or fewer.`;
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
  const [photos, setPhotos] = useState<PickedPhoto[]>([]);
  const [picking, setPicking] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [fields, setFields] = useState<Record<string, string>>({});
  const inFlight = useRef(false);
  const [needsReload, setNeedsReload] = useState(false);

  async function publish() {
    if (inFlight.current || picking || needsReload) return;
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
      const listing = initial
        ? (await editListing(initial.listing.id, draft, initial.revision, token)).listing
        : await createListing(draft, token, photos.map(photo => new File(photo.uri)));
      onSaved(listing);
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

  if (initial) return <EditListingForm title={title} description={description} price={price} category={category} condition={condition}
    setTitle={setTitle} setDescription={setDescription} setPrice={setPrice} setCategory={setCategory} setCondition={setCondition}
    busy={busy} needsReload={needsReload} error={error} fields={fields} onBack={onBack} onReload={onReload} onSave={publish} />;

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
  body: { color: '#263745', fontSize: 16 },
  error: { color: '#b3261e', fontSize: 15 },
  input: { borderWidth: 1, borderColor: '#9aa7b5', borderRadius: 8, backgroundColor: 'white', padding: 12, color: '#152f52' },
  card: { borderRadius: 12, backgroundColor: 'white', padding: 14, gap: 8 },
  conditions: { flexDirection: 'row', flexWrap: 'wrap', gap: 4 },
});
