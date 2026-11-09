import { useRef, useState } from 'react';
import { ActivityIndicator, Button, Image, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import * as ImagePicker from 'expo-image-picker';
import { ApiError, Listing, PickedPhoto, uploadPhotos } from './api';

export const MAX_PHOTOS = 5;              // Matches PhotoUpload.maxCount on the server.
const MAX_BYTES = 8 * 1024 * 1024;        // Matches PhotoUpload.maxBytes on the server.

/**
 * Multi-photo selection with previews and removal. The first photo is the
 * primary one; tapping another photo moves it to the front.
 */
export function PhotoPicker({ photos, onChange, disabled = false, onPickingChange }: {
  photos: PickedPhoto[]; onChange: (photos: PickedPhoto[]) => void;
  disabled?: boolean; onPickingChange?: (picking: boolean) => void;
}) {
  const [notice, setNotice] = useState<string | null>(null);
  const [picking, setPicking] = useState(false);
  const inFlight = useRef(false);
  const remaining = MAX_PHOTOS - photos.length;
  const locked = disabled || picking;

  async function pick() {
    if (disabled || inFlight.current || remaining <= 0) return;
    inFlight.current = true;
    setPicking(true); onPickingChange?.(true);
    setNotice(null);
    try {
      const result = await ImagePicker.launchImageLibraryAsync({
        mediaTypes: ['images'], allowsMultipleSelection: true, orderedSelection: true,
        selectionLimit: remaining, quality: 0.8,
      });
      if (result.canceled) return;
      const seen = new Set(photos.map(photo => photo.uri));
      const fresh = result.assets.filter(asset => {
        if (seen.has(asset.uri)) return false;
        seen.add(asset.uri); return true;
      });
      const fitting = fresh.filter(asset => !asset.fileSize || asset.fileSize <= MAX_BYTES);
      const added = fitting.slice(0, remaining).map(asset => ({ uri: asset.uri, mimeType: asset.mimeType }));
      if (fitting.length < fresh.length) setNotice('Photos larger than 8 MB were skipped.');
      else if (added.length < fitting.length) setNotice(`Only ${MAX_PHOTOS} photos can be added.`);
      onChange([...photos, ...added]);
    } catch {
      setNotice('Could not open your photo library. Check photo access and try again.');
    } finally {
      inFlight.current = false;
      setPicking(false); onPickingChange?.(false);
    }
  }

  const remove = (uri: string) => onChange(photos.filter(photo => photo.uri !== uri));
  const makePrimary = (uri: string) => onChange([...photos.filter(photo => photo.uri === uri), ...photos.filter(photo => photo.uri !== uri)]);

  return <View style={s.section}>
    <View style={s.row}>
      <Text style={s.title}>Photos</Text>
      <Text style={s.label}>{photos.length}/{MAX_PHOTOS}</Text>
    </View>
    <ScrollView horizontal contentContainerStyle={s.strip} showsHorizontalScrollIndicator={false}>
      {photos.map((photo, index) => <View key={photo.uri}>
        <Pressable disabled={locked} onPress={() => makePrimary(photo.uri)}
          accessibilityRole="button" accessibilityLabel={index === 0 ? 'Primary photo' : `Photo ${index + 1}, make primary`}>
          <Image source={{ uri: photo.uri }} style={[s.thumb, index === 0 && s.primary]} />
          {index === 0 && <Text style={s.badge}>Primary</Text>}
        </Pressable>
        <Pressable disabled={locked} onPress={() => remove(photo.uri)} style={s.remove} hitSlop={8}
          accessibilityRole="button" accessibilityLabel={`Remove photo ${index + 1}`}>
          <Text style={s.removeText}>✕</Text>
        </Pressable>
      </View>)}
      {remaining > 0 && <Pressable disabled={locked} onPress={pick} style={[s.thumb, s.add]} accessibilityRole="button" accessibilityLabel="Add photos">
        <Text style={s.addText}>+</Text><Text style={s.label}>Add</Text>
      </Pressable>}
    </ScrollView>
    {photos.length > 0 && <Text style={s.label}>The first photo is the cover. Tap another photo to make it primary.</Text>}
    {picking && <ActivityIndicator accessibilityLabel="Selecting photos" />}
    {notice && <Text accessibilityRole="alert" style={s.error}>{notice}</Text>}
  </View>;
}

/**
 * Step after publishing: the create-listing form opens this with the new
 * listing's id (from the 201 body) and gets the updated listing back.
 */
export function AddPhotos({ listingId, token, onDone, onBack, onSessionExpired }: {
  listingId: string; token: string; onDone: (listing: Listing) => void;
  onBack: () => void; onSessionExpired: () => void;
}) {
  const [photos, setPhotos] = useState<PickedPhoto[]>([]);
  const [uploading, setUploading] = useState(false);
  const [picking, setPicking] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const inFlight = useRef(false);

  async function upload() {
    if (inFlight.current || picking || photos.length === 0) return;
    inFlight.current = true;
    setUploading(true);
    setError(null);
    try {
      onDone(await uploadPhotos(listingId, photos, token));
    } catch (failure) {
      if (failure instanceof ApiError && failure.status === 401) { onSessionExpired(); return; }
      setError(failure instanceof Error ? failure.message : 'Photos could not be uploaded.');
    } finally {
      inFlight.current = false;
      setUploading(false);
    }
  }

  return <ScrollView contentContainerStyle={s.page}>
    <Button title="Back to my listings" disabled={uploading || picking} onPress={onBack} />
    <Text style={s.heading}>Add photos</Text>
    <Text style={s.label}>Add up to five JPEG, PNG or HEIC photos, 8 MB each.</Text>
    <Text style={s.label}>Choose the complete photo set. Uploading replaces any existing photos after the new set is saved.</Text>
    <PhotoPicker photos={photos} onChange={setPhotos} disabled={uploading} onPickingChange={setPicking} />
    {error && <Text accessibilityRole="alert" style={s.error}>{error}</Text>}
    {uploading ? <ActivityIndicator accessibilityLabel="Uploading photos" /> :
      <Button title="Upload photos" disabled={photos.length === 0 || picking} onPress={upload} />}
  </ScrollView>;
}

const s = StyleSheet.create({
  page: { paddingHorizontal: 20, paddingTop: 24, paddingBottom: 12, gap: 12 },
  section: { gap: 8 },
  row: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'baseline' },
  strip: { gap: 12, paddingVertical: 4 },
  heading: { fontSize: 34, fontWeight: '700', color: '#152f52' },
  title: { fontSize: 20, fontWeight: '600', color: '#152f52' },
  label: { color: '#49596b', fontSize: 14, fontWeight: '500' },
  error: { color: '#b3261e', fontSize: 15 },
  thumb: { width: 96, height: 96, borderRadius: 8 },
  primary: { borderWidth: 3, borderColor: '#174d7e' },
  badge: { position: 'absolute', left: 6, bottom: 6, backgroundColor: '#174d7e', color: 'white', fontSize: 11, fontWeight: '700', paddingHorizontal: 6, paddingVertical: 2, borderRadius: 8, overflow: 'hidden' },
  remove: { position: 'absolute', top: 4, right: 4, width: 24, height: 24, borderRadius: 12, backgroundColor: 'rgba(0,0,0,0.6)', alignItems: 'center', justifyContent: 'center' },
  removeText: { color: 'white', fontSize: 13, fontWeight: '700' },
  add: { borderWidth: 1.5, borderStyle: 'dashed', borderColor: '#9aa7b5', alignItems: 'center', justifyContent: 'center', backgroundColor: 'white' },
  addText: { fontSize: 28, color: '#49596b' },
});
