import { ActivityIndicator, KeyboardAvoidingView, Platform, Pressable, ScrollView, StyleSheet, Text, TextInput, View } from 'react-native';
import { useFonts, PlusJakartaSans_400Regular, PlusJakartaSans_500Medium, PlusJakartaSans_600SemiBold, PlusJakartaSans_700Bold, PlusJakartaSans_800ExtraBold } from '@expo-google-fonts/plus-jakarta-sans';
import { listingCategories as categories, listingConditions as conditions } from './listingChoices';

// Adapted from Figma 1:816, 1:878–1:953 and 1:1045–1:1057.
// This is presentation only; MyListings owns validation, requests and revisions.
type Props = {
  title: string; description: string; price: string; category: string; condition: string;
  setTitle: (value: string) => void; setDescription: (value: string) => void;
  setPrice: (value: string) => void; setCategory: (value: string) => void; setCondition: (value: string) => void;
  busy: boolean; needsReload: boolean; error: string; fields: Record<string, string>;
  onBack: () => void; onReload?: () => void; onSave: () => void;
};

export function EditListingForm(p: Props) {
  const [fontsLoaded] = useFonts({ PlusJakartaSans_400Regular, PlusJakartaSans_500Medium,
    PlusJakartaSans_600SemiBold, PlusJakartaSans_700Bold, PlusJakartaSans_800ExtraBold });
  const regular = { fontFamily: fontsLoaded ? 'PlusJakartaSans_400Regular' : undefined };
  const medium = { fontFamily: fontsLoaded ? 'PlusJakartaSans_500Medium' : undefined };
  const bold = { fontFamily: fontsLoaded ? 'PlusJakartaSans_700Bold' : undefined, fontWeight: fontsLoaded ? undefined : '700' as const };
  const extraBold = { fontFamily: fontsLoaded ? 'PlusJakartaSans_800ExtraBold' : undefined, fontWeight: fontsLoaded ? undefined : '800' as const };
  const amount = /^\d+(\.\d{1,2})?$/.test(p.price.trim()) && Number(p.price) <= 100000 ? `$${Number(p.price).toFixed(2)}` : '—';
  const fieldError = (name: string) => p.fields[name] ? <Text accessibilityRole="alert" style={[s.error, regular]}>{p.fields[name]}</Text> : null;

  return <KeyboardAvoidingView style={s.screen} behavior={Platform.OS === 'ios' ? 'padding' : undefined}>
    <ScrollView keyboardShouldPersistTaps="handled" contentContainerStyle={s.page}>
      <View style={s.header}>
        <Pressable accessibilityRole="button" accessibilityLabel="Cancel" disabled={p.busy} onPress={p.onBack}
          style={({ pressed }) => [s.cancel, p.busy && s.disabled, pressed && s.pressed]}>
          <Text style={[s.smallAction, bold]}>Cancel</Text>
        </Pressable>
        <View style={s.headingGroup}>
          <Text accessibilityRole="header" style={[s.heading, bold]}>Edit Campus Listing</Text>
          <View style={s.subtitle}><View style={s.dot} /><Text style={[s.caption, medium]}>Listing Details</Text></View>
        </View>
      </View>

      <View style={s.card}>
        <View style={s.field}>
          <View style={s.labelRow}><Text style={[s.label, bold]}>Item Title</Text><Text style={[s.caption, regular]}>Max 120 chars</Text></View>
          <TextInput accessibilityLabel="Title" value={p.title} onChangeText={p.setTitle} editable={!p.busy} maxLength={120}
            placeholder="What are you selling?" placeholderTextColor="#737784" style={[s.input, medium, !!p.fields.title && s.invalid]} />
          {fieldError('title')}
        </View>

        <View style={s.field}>
          <View style={s.labelRow}><Text style={[s.label, bold]}>Category</Text><Text style={[s.selectHint, medium]}>Select 1</Text></View>
          <View style={s.chips}>
            {categories.map(([emoji, value]) => <Pressable key={value} accessibilityRole="button" accessibilityLabel={value}
              accessibilityState={{ selected: p.category === value, disabled: p.busy }} disabled={p.busy}
              onPress={() => p.setCategory(value)} style={({ pressed }) => [s.chip, p.category === value && s.activeChip, pressed && s.pressed]}>
              <Text style={s.emoji}>{emoji}</Text><Text style={[s.chipText, medium, p.category === value && s.activeChipText]}>{value}</Text>
            </Pressable>)}
          </View>
          {/* Keep existing/custom categories editable without silently remapping stored values. */}
          <TextInput accessibilityLabel="Category" value={p.category} onChangeText={p.setCategory} editable={!p.busy} maxLength={50}
            placeholder="Or enter a category" placeholderTextColor="#737784" style={[s.input, medium, !!p.fields.category && s.invalid]} />
          {fieldError('category')}
        </View>

        <View style={s.field}>
          <Text style={[s.label, bold]}>Condition</Text>
          <View style={s.segments}>
            {conditions.map(value => <Pressable key={value} accessibilityRole="button"
              accessibilityLabel={value === p.condition ? `${value} (selected)` : value}
              accessibilityState={{ selected: value === p.condition, disabled: p.busy }} disabled={p.busy}
              onPress={() => p.setCondition(value)} style={({ pressed }) => [s.segment, value === p.condition && s.selectedSegment, pressed && s.pressed]}>
              <Text style={[s.segmentText, medium, value === p.condition && s.selectedText]}>{value === 'New' ? 'Brand New' : value === 'Like new' ? 'Like New' : value}</Text>
            </Pressable>)}
          </View>
          {fieldError('condition')}
        </View>

        <View style={s.field}>
          <Text style={[s.label, bold]}>Listing Price</Text>
          <View style={[s.priceBox, !!p.fields.priceCents && s.invalid]}>
            <Text style={[s.currency, extraBold]}>$</Text>
            <TextInput accessibilityLabel="Price in dollars" value={p.price} onChangeText={p.setPrice} editable={!p.busy}
              keyboardType="decimal-pad" placeholder="0.00" placeholderTextColor="#737784" style={[s.priceInput, extraBold]} />
            <Text style={[s.caption, bold]}>USD</Text>
          </View>
          {fieldError('priceCents')}
        </View>

        <View style={s.field}>
          <View style={s.labelRow}><Text style={[s.label, bold]}>Description</Text><Text style={[s.caption, regular]}>Max 2000 chars</Text></View>
          <TextInput accessibilityLabel="Description" value={p.description} onChangeText={p.setDescription} editable={!p.busy}
            multiline maxLength={2000} placeholder="Share the details buyers should know." placeholderTextColor="#737784"
            style={[s.input, s.description, medium, !!p.fields.description && s.invalid]} />
          {fieldError('description')}
        </View>
      </View>

      {!!p.error && <View style={s.errorCard}><Text accessibilityRole="alert" style={[s.error, regular]}>{p.error}</Text></View>}
      {Object.entries(p.fields).filter(([key]) => !['title', 'category', 'condition', 'priceCents', 'description'].includes(key))
        .map(([key, message]) => <Text key={key} accessibilityRole="alert" style={[s.error, regular]}>{message}</Text>)}
      <View style={s.reloadCard}>
        <Text style={[s.reloadNote, regular]}>{p.needsReload ? 'Reload the latest listing before saving again.' : 'Reload to discard your edits and load the latest listing.'}</Text>
        <Pressable accessibilityRole="button" accessibilityLabel="Reload listing" disabled={p.busy} onPress={p.onReload}
          style={({ pressed }) => [s.reload, p.busy && s.disabled, pressed && s.pressed]}>
          <Text style={[s.smallAction, bold]}>Reload listing</Text>
        </Pressable>
      </View>
    </ScrollView>

    <View style={s.footer}>
      <View style={s.summary}><Text style={[s.caption, bold]}>Listing Price</Text><Text style={[s.total, extraBold]}>{amount}</Text></View>
      <Pressable accessibilityRole="button" accessibilityLabel="Save changes" disabled={p.busy || p.needsReload} onPress={p.onSave}
        style={({ pressed }) => [s.save, (p.busy || p.needsReload) && s.disabled, pressed && s.pressed]}>
        {p.busy ? <ActivityIndicator color="#ffffff" accessibilityLabel="Saving listing" /> : <Text style={[s.saveText, bold]}>Save changes</Text>}
      </Pressable>
    </View>
  </KeyboardAvoidingView>;
}

const s = StyleSheet.create({
  screen: { flex: 1, backgroundColor: '#f9f9ff' },
  page: { padding: 16, paddingTop: 24, gap: 16, paddingBottom: 24, width: '100%', maxWidth: 600, alignSelf: 'center' },
  header: { flexDirection: 'row', alignItems: 'center', gap: 12 },
  cancel: { minHeight: 44, paddingHorizontal: 12, borderRadius: 999, backgroundColor: '#e7eeff', alignItems: 'center', justifyContent: 'center' },
  headingGroup: { flex: 1, gap: 2 },
  heading: { color: '#003b8c', fontSize: 20, lineHeight: 28, letterSpacing: -0.5 },
  subtitle: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  dot: { width: 8, height: 8, borderRadius: 4, backgroundColor: '#bc0008' },
  caption: { fontSize: 11, lineHeight: 16, color: '#424653', letterSpacing: 0.25 },
  card: { backgroundColor: '#ffffff', borderRadius: 12, padding: 16, gap: 24, shadowColor: '#000000', shadowOpacity: 0.04, shadowRadius: 2, shadowOffset: { width: 0, height: 1 } },
  field: { gap: 8 },
  labelRow: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', flexWrap: 'wrap', gap: 4 },
  label: { color: '#111c2d', fontSize: 18, lineHeight: 24 },
  input: { minHeight: 48, borderRadius: 12, backgroundColor: '#f0f3ff', paddingHorizontal: 16, paddingVertical: 12, color: '#111c2d', fontSize: 14, lineHeight: 22, borderWidth: 1, borderColor: 'transparent' },
  description: { minHeight: 120, textAlignVertical: 'top' },
  selectHint: { color: '#003b8c', fontSize: 11, lineHeight: 16 },
  chips: { flexDirection: 'row', flexWrap: 'wrap', gap: 8 },
  chip: { flexDirection: 'row', alignItems: 'center', gap: 6, paddingHorizontal: 12, minHeight: 36, paddingVertical: 8, borderRadius: 999, backgroundColor: '#e7eeff' },
  activeChip: { backgroundColor: '#0051ba' },
  emoji: { fontSize: 12 },
  chipText: { color: '#424653', fontSize: 12, lineHeight: 16 },
  activeChipText: { color: '#ffffff' },
  segments: { backgroundColor: '#f0f3ff', borderRadius: 12, padding: 4, flexDirection: 'row', flexWrap: 'wrap', gap: 4 },
  segment: { flexGrow: 1, minHeight: 40, justifyContent: 'center', alignItems: 'center', borderRadius: 8, paddingHorizontal: 6, paddingVertical: 10 },
  selectedSegment: { backgroundColor: '#ffffff', shadowColor: '#000', shadowOpacity: 0.05, shadowRadius: 2, shadowOffset: { width: 0, height: 1 } },
  segmentText: { color: '#424653', fontSize: 11, lineHeight: 16 },
  selectedText: { color: '#003b8c' },
  priceBox: { backgroundColor: '#f0f3ff', borderRadius: 12, minHeight: 56, flexDirection: 'row', alignItems: 'center', paddingHorizontal: 16, gap: 8, borderWidth: 1, borderColor: 'transparent' },
  currency: { color: '#003b8c', fontSize: 22, lineHeight: 28 },
  priceInput: { flex: 1, minWidth: 0, color: '#111c2d', fontSize: 22, paddingVertical: 12 },
  invalid: { borderColor: '#ba1a1a' },
  error: { color: '#ba1a1a', fontSize: 13, lineHeight: 20 },
  errorCard: { backgroundColor: '#fff0f0', borderRadius: 12, padding: 14 },
  reloadCard: { backgroundColor: '#e7eeff', borderRadius: 12, padding: 14, alignItems: 'flex-start', gap: 8 },
  reloadNote: { color: '#424653', fontSize: 12, lineHeight: 18 },
  reload: { minHeight: 44, justifyContent: 'center', backgroundColor: '#dee8ff', paddingHorizontal: 14, borderRadius: 999 },
  smallAction: { color: '#003b8c', fontSize: 12, lineHeight: 18 },
  footer: { flexDirection: 'row', gap: 16, padding: 16, alignItems: 'center', backgroundColor: '#f9f9ff', borderTopWidth: 1, borderTopColor: '#e7eeff' },
  summary: { minWidth: 90, flexShrink: 1 },
  total: { color: '#003b8c', fontSize: 22, lineHeight: 28, letterSpacing: -0.44 },
  save: { flex: 1, minHeight: 48, borderRadius: 12, backgroundColor: '#0051ba', justifyContent: 'center', alignItems: 'center', paddingHorizontal: 16, paddingVertical: 12 },
  saveText: { color: '#ffffff', fontSize: 18, lineHeight: 24, textAlign: 'center' },
  disabled: { opacity: 0.45 },
  pressed: { opacity: 0.75 },
});
