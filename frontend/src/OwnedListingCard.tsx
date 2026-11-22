import { useRef, useState } from 'react';
import { ActivityIndicator, Image, Pressable, StyleSheet, Text, View } from 'react-native';
import { Image as AssetImage } from 'expo-image';
import { useFonts, PlusJakartaSans_400Regular, PlusJakartaSans_500Medium, PlusJakartaSans_700Bold } from '@expo-google-fonts/plus-jakarta-sans';
import { ApiError, deleteListing, Listing, markListingSold, OwnedListing, photoThumbnailURL } from './api';

type Props = {
  item: OwnedListing; token: string; disabled: boolean;
  onEdit: () => void; onOpen: (listing: Listing) => void; onPhotos: () => void;
  onChanged: (item: OwnedListing) => void; onReload: () => void;
  onBusy: (value: boolean) => void; onSessionExpired: () => void;
};

// Figma profile listing cards (1:1249 onward): compact photo, price above
// title, condition badge, pale-blue actions and red Mark Sold treatment.
export function OwnedListingCard(p: Props) {
  const { listing, status } = p.item;
  const [confirmation, setConfirmation] = useState<'sold' | 'deleted' | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [stale, setStale] = useState(false);
  const inFlight = useRef(false);
  const [loaded] = useFonts({ PlusJakartaSans_400Regular, PlusJakartaSans_500Medium, PlusJakartaSans_700Bold });
  const font = { fontFamily: loaded ? 'PlusJakartaSans_400Regular' : undefined };
  const bold = { fontFamily: loaded ? 'PlusJakartaSans_700Bold' : undefined, fontWeight: loaded ? undefined : '700' as const };
  const locked = p.disabled || busy;

  async function confirm() {
    if (!confirmation || inFlight.current || locked || stale) return;
    inFlight.current = true; setBusy(true); p.onBusy(true); setError('');
    try {
      const action = confirmation === 'sold' ? markListingSold : deleteListing;
      const updated = await action(listing.id, p.item.revision, p.token);
      setConfirmation(null);
      p.onChanged(updated);
    } catch (failure) {
      if (failure instanceof ApiError && failure.status === 401) { p.onSessionExpired(); return; }
      setError(failure instanceof Error ? failure.message : 'Could not update this listing. Please try again.');
      if (failure instanceof ApiError && [403, 404, 409, 428].includes(failure.status)) setStale(true);
    } finally {
      inFlight.current = false; setBusy(false); p.onBusy(false);
    }
  }

  function action(label: string, text: string, onPress: () => void, danger = false) {
    return <Pressable accessibilityRole="button" accessibilityLabel={label} disabled={locked || stale}
      onPress={onPress} style={({ pressed }) => [s.action, danger && s.dangerAction, (locked || stale) && s.disabled, pressed && s.pressed]}>
      {text === 'Edit' && <AssetImage source={require('../assets/listing-actions/edit.svg')} style={{ width: 11.25, height: 11.25 }} />}
      {text === 'Mark Sold' && <AssetImage source={require('../assets/listing-actions/sold.svg')} style={{ width: 10.1875, height: 7.51562 }} />}
      <Text style={[s.actionText, bold, danger && s.dangerText]}>{text}</Text>
    </Pressable>;
  }

  return <View style={s.card}>
    <View style={s.row}>
      <View style={s.photoBox}>
        {listing.photoURLs[0] ? <Image accessibilityLabel={`Cover photo for ${listing.title}`}
          source={{ uri: photoThumbnailURL(listing.photoURLs[0]) }} style={s.photo} /> : <View style={[s.photo, s.placeholder]}><Text style={[s.small, font]}>No photo</Text></View>}
        <Text style={[s.condition, bold]}>{listing.condition}</Text>
      </View>
      <View style={s.details}>
        <View style={s.priceRow}><Text style={[s.price, bold]}>${(listing.priceCents / 100).toFixed(2)}</Text>
          <Text style={[s.status, bold, status === 'sold' && s.sold]}>{status === 'sold' ? 'Sold' : status === 'reserved' ? 'Reserved' : 'Active'}</Text></View>
        <Text style={[s.title, bold]}>{listing.title}</Text>
        <Text style={[s.small, font]} numberOfLines={2}>{listing.description}</Text>
        {!confirmation && <>
          <View style={s.actions}>
            {status === 'active' && action(`Edit ${listing.title}`, 'Edit', p.onEdit)}
            {(status === 'active' || status === 'reserved') && action(`Mark sold ${listing.title}`, 'Mark Sold', () => setConfirmation('sold'), true)}
            {status === 'sold' && <Text style={[s.small, font]}>No longer visible to buyers</Text>}
          </View>
        </>}
      </View>
    </View>
    {!confirmation && <View style={s.secondaryActions}>
      {action(`View ${listing.title}`, 'View listing', () => p.onOpen(listing))}
      {status === 'active' && action(`Add or replace photos for ${listing.title}`, 'Photos', p.onPhotos)}
      {action(`Delete ${listing.title}`, 'Delete', () => setConfirmation('deleted'), true)}
    </View>}
    {!!confirmation && <View style={s.confirmation}>
      <Text style={[s.confirmTitle, bold]}>{confirmation === 'sold' ? 'Mark this listing as sold?' : 'Delete this listing?'}</Text>
      <Text style={[s.small, font]}>{confirmation === 'sold'
        ? 'Buyers will no longer see it in the marketplace. It will stay in your sold listings.'
        : 'This removes the listing from the marketplace and My listings. You cannot restore it from the app.'}</Text>
      <View style={s.actions}>
        <Pressable accessibilityRole="button" accessibilityLabel="Cancel listing action" disabled={locked} onPress={() => { setConfirmation(null); setError(''); }} style={[s.action, locked && s.disabled]}>
          <Text style={[s.actionText, bold]}>Cancel</Text>
        </Pressable>
        <Pressable accessibilityRole="button" accessibilityLabel={confirmation === 'sold' ? 'Confirm mark sold' : 'Confirm delete'} disabled={locked || stale}
          onPress={confirm} style={[s.confirmButton, (locked || stale) && s.disabled]}>
          {busy ? <ActivityIndicator color="white" accessibilityLabel="Updating listing" /> :
            <Text style={[s.confirmText, bold]}>{confirmation === 'sold' ? 'Mark Sold' : 'Delete listing'}</Text>}
        </Pressable>
      </View>
    </View>}
    {!!error && <Text accessibilityRole="alert" style={[s.error, font]}>{error}</Text>}
    {stale && <Pressable accessibilityRole="button" accessibilityLabel="Reload my listings" disabled={locked} onPress={p.onReload} style={s.action}>
      <Text style={[s.actionText, bold]}>Reload my listings</Text>
    </Pressable>}
  </View>;
}

const s = StyleSheet.create({
  card: { backgroundColor: '#fff', borderRadius: 12, padding: 12, gap: 12 },
  row: { flexDirection: 'row', alignItems: 'flex-start', gap: 12 },
  photoBox: { width: 96, height: 96, borderRadius: 8, overflow: 'hidden' },
  photo: { width: 96, height: 96, borderRadius: 8 },
  placeholder: { backgroundColor: '#f0f3ff', justifyContent: 'center', alignItems: 'center' },
  condition: { position: 'absolute', left: 4, bottom: 4, borderRadius: 4, backgroundColor: 'rgba(255,255,255,0.9)', color: '#003b8c', fontSize: 11, paddingHorizontal: 6, paddingVertical: 2 },
  details: { flex: 1, gap: 4 },
  priceRow: { flexDirection: 'row', flexWrap: 'wrap', alignItems: 'center', justifyContent: 'space-between', gap: 4 },
  price: { fontSize: 22, lineHeight: 28, color: '#003b8c' },
  title: { fontSize: 18, lineHeight: 24, color: '#111c2d' },
  small: { fontSize: 14, lineHeight: 20, color: '#424653' },
  status: { fontSize: 10, color: '#003b8c', backgroundColor: '#e7eeff', borderRadius: 4, paddingHorizontal: 6, paddingVertical: 3 },
  sold: { color: '#146345', backgroundColor: '#e5f5ed' },
  actions: { flexDirection: 'row', gap: 6, marginTop: 4, flexWrap: 'wrap' },
  secondaryActions: { flexDirection: 'row', gap: 6, flexWrap: 'wrap' },
  action: { flexGrow: 1, flexDirection: 'row', gap: 4, backgroundColor: '#e7eeff', borderRadius: 8, minHeight: 36, paddingHorizontal: 10, paddingVertical: 8, justifyContent: 'center', alignItems: 'center' },
  dangerAction: { backgroundColor: '#e7eeff' },
  actionText: { fontSize: 11, lineHeight: 16, color: '#0051ba' },
  dangerText: { color: '#bc0008' },
  confirmation: { backgroundColor: '#f0f3ff', padding: 12, borderRadius: 12, gap: 8 },
  confirmTitle: { fontSize: 14, color: '#111c2d' },
  confirmButton: { flexGrow: 1, minHeight: 44, borderRadius: 8, backgroundColor: '#bc0008', paddingHorizontal: 12, paddingVertical: 10, alignItems: 'center', justifyContent: 'center' },
  confirmText: { color: '#fff', fontSize: 12 },
  error: { color: '#ba1a1a', fontSize: 12, lineHeight: 18 },
  disabled: { opacity: 0.45 },
  pressed: { opacity: 0.75 },
});
