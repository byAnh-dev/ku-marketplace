import { useEffect, useRef, useState } from 'react';
import { ActivityIndicator, Pressable, ScrollView, StyleSheet, Text, TextInput, View } from 'react-native';
import { login, register, resendVerification, Session } from './auth';

function passwordBytes(password: string): number {
  let bytes = 0;
  for (const character of password) {
    const point = character.codePointAt(0)!;
    bytes += point <= 0x7f ? 1 : point <= 0x7ff ? 2 : point <= 0xffff ? 3 : 4;
  }
  return bytes;
}

export function AuthScreen({ onLogin, onBack }: { onLogin: (session: Session) => void; onBack: () => void }) {
  const [mode, setMode] = useState<'login' | 'register'>('login');
  const [displayName, setDisplayName] = useState('');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [confirmation, setConfirmation] = useState('');
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const [busy, setBusy] = useState(false);
  const [cooldowns, setCooldowns] = useState<Record<string, number>>({});
  const [clock, setClock] = useState(Date.now);
  const inFlight = useRef(false);
  const normalizedEmail = email.trim().toLowerCase();
  const retryAt = cooldowns[normalizedEmail] ?? 0;
  const remaining = Math.max(0, Math.ceil((retryAt - Date.now()) / 1000));

  useEffect(() => {
    const delay = retryAt - Date.now();
    if (delay <= 0) return;
    const timer = setTimeout(() => setClock(Date.now()), Math.min(1000, delay));
    return () => clearTimeout(timer);
  }, [retryAt, clock]);

  function startCooldown(seconds: number) {
    setCooldowns(previous => ({ ...previous, [normalizedEmail]: Date.now() + seconds * 1000 }));
  }

  async function resend() {
    if (inFlight.current || retryAt > Date.now()) return;
    setError(''); setNotice('');
    if (!/^[^@\s]+@ku\.edu$/i.test(email.trim())) { setError('Use your @ku.edu email address.'); return; }
    inFlight.current = true; setBusy(true);
    try {
      const result = await resendVerification(normalizedEmail);
      setNotice(result.message);
      startCooldown(result.retryAfterSeconds);
    } catch (err) { setError(err instanceof Error ? err.message : 'Could not resend the verification email.'); }
    finally { inFlight.current = false; setBusy(false); }
  }

  async function submit() {
    if (inFlight.current) return;
    setError(''); setNotice('');
    if (!/^[^@\s]+@ku\.edu$/i.test(email.trim())) { setError('Use your @ku.edu email address.'); return; }
    if (mode === 'register') {
      if (displayName.trim().length < 2) { setError('Enter a display name.'); return; }
      const bytes = passwordBytes(password);
      if (bytes < 12 || bytes > 72) {
        setError('Use a password between 12 and 72 bytes.'); return;
      }
      if (password !== confirmation) { setError('Passwords do not match.'); return; }
    }
    inFlight.current = true; setBusy(true);
    try {
      if (mode === 'register') {
        const result = await register(displayName.trim(), email.trim(), password, confirmation);
        setNotice(result);
        startCooldown(60);
        setMode('login'); setPassword(''); setConfirmation('');
      } else {
        onLogin(await login(email.trim(), password));
      }
    } catch (err) { setError(err instanceof Error ? err.message : 'Unable to authenticate.'); }
    finally { inFlight.current = false; setBusy(false); }
  }

  return <ScrollView contentContainerStyle={styles.page} keyboardShouldPersistTaps="handled">
    <Pressable accessibilityRole="button" disabled={busy} onPress={onBack}><Text style={styles.link}>Back to marketplace</Text></Pressable>
    <Text style={styles.heading}>{mode === 'login' ? 'KU student login' : 'Create KU account'}</Text>
    <Text style={styles.body}>A verified @ku.edu address is required to sell and manage listings.</Text>
    {mode === 'register' && <Text style={styles.body}>After registering, open the link in your KU email within 30 minutes. Then return here to log in.</Text>}
    {mode === 'register' && <TextInput editable={!busy} style={styles.input} placeholder="Display name" accessibilityLabel="Display name" autoCapitalize="words" value={displayName} onChangeText={setDisplayName} />}
    <TextInput editable={!busy} style={styles.input} placeholder="KU email" accessibilityLabel="KU email" autoCapitalize="none" autoCorrect={false} keyboardType="email-address" value={email}
      onChangeText={value => { setEmail(value); setError(''); setNotice(''); }} />
    <TextInput editable={!busy} style={styles.input} placeholder="Password" accessibilityLabel="Password" secureTextEntry autoCorrect={false} autoCapitalize="none" value={password} onChangeText={setPassword} />
    {mode === 'register' && <TextInput editable={!busy} style={styles.input} placeholder="Confirm password" accessibilityLabel="Confirm password" secureTextEntry autoCorrect={false} autoCapitalize="none" value={confirmation} onChangeText={setConfirmation} />}
    {!!error && <Text accessibilityRole="alert" style={styles.error}>{error}</Text>}
    {!!notice && <Text style={styles.notice}>{notice}</Text>}
    {busy ? <ActivityIndicator accessibilityLabel="Submitting account request" /> : <Pressable style={styles.action} accessibilityRole="button" onPress={submit}><Text style={styles.actionText}>{mode === 'login' ? 'Log in' : 'Register'}</Text></Pressable>}
    {mode === 'login' && <View>
      <Pressable accessibilityRole="button" disabled={busy || remaining > 0} onPress={resend}>
        <Text style={styles.link}>Resend verification email</Text>
      </Pressable>
      {remaining > 0 && <Text style={styles.body}>You can request another link in {remaining} seconds.</Text>}
    </View>}
    <Pressable accessibilityRole="button" disabled={busy} onPress={() => { setMode(mode === 'login' ? 'register' : 'login'); setPassword(''); setConfirmation(''); setError(''); setNotice(''); }}>
      <Text style={styles.link}>{mode === 'login' ? 'New here? Create an account' : 'Already registered? Log in'}</Text>
    </Pressable>
  </ScrollView>;
}

const styles = StyleSheet.create({
  page: { padding: 24, gap: 16 },
  heading: { fontSize: 30, fontWeight: '700', color: '#152f52' },
  body: { color: '#263745', fontSize: 16 },
  input: { borderWidth: 1, borderColor: '#9aa7b5', backgroundColor: 'white', padding: 14, borderRadius: 8, color: '#152f52' },
  action: { backgroundColor: '#0051ba', padding: 15, borderRadius: 8, alignItems: 'center' },
  actionText: { color: 'white', fontWeight: '700' },
  link: { color: '#0051ba', fontWeight: '600', marginVertical: 8 },
  error: { color: '#b00020' },
  notice: { color: '#17652d' },
});
