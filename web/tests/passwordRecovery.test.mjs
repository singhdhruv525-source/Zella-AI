import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';

// Exercise the actual submit handler with controlled auth responses.
const source = readFileSync(new URL('../src/App.jsx', import.meta.url), 'utf8');
const handler = source.slice(source.indexOf('  async function handleSetPassword('), source.indexOf('  async function handleMfa('));
async function submit({ access = true, saveError = null } = {}) {
  const state = { mode: 'setpassword', password: 'A-long-password9!', confirmPassword: 'A-long-password9!', saves: 0, checks: 0, authorized: false, signouts: 0 };
  const context = {
    password: state.password, confirmPassword: state.confirmPassword,
    passwordProblems: () => [], friendlyAuthError: (e) => e.message,
    supabase: { auth: {
      updateUser: async () => { state.saves++; return { error: saveError }; },
      signOut: async () => { state.signouts++; },
    } },
    hasAdminAccess: async () => { state.checks++; if (access instanceof Error) throw access; return access; },
    window: { history: { replaceState() {} }, location: { pathname: '/' } },
  };
  for (const key of ['mode', 'password', 'confirmPassword', 'loading', 'message', 'messageType', 'authorized']) {
    context[key === 'authorized' ? 'setIsAuthorized' : `set${key[0].toUpperCase()}${key.slice(1)}`] = (value) => { state[key] = value; };
  }
  await runInNewContext(`${handler}\nhandleSetPassword({ preventDefault() {} })`, context);
  return state;
}

test('saved password with unavailable access leaves recovery and preserves its error', async () => {
  const s = await submit({ access: 'unavailable' });
  assert.equal(s.mode, 'signin');
  assert.equal(s.password, '');
  assert.equal(s.confirmPassword, '');
  assert.equal(s.saves, 1);
  assert.equal(s.checks, 1);
  assert.equal(s.authorized, false);
  assert.equal(s.message, 'Admin access could not be checked. Please try again.');
  assert.equal(s.messageType, 'error');
  assert.equal(s.loading, false);
});
test('save failure stays in recovery so the save can be retried', async () => {
  const s = await submit({ saveError: new Error('Save failed') });
  assert.equal(s.mode, 'setpassword');
  assert.equal(s.checks, 0);
  assert.equal(s.message, 'Save failed');
});
test('successful access authorizes; denied access still signs out', async () => {
  assert.equal((await submit()).authorized, true);
  const s = await submit({ access: false });
  assert.equal(s.mode, 'signin');
  assert.equal(s.signouts, 1);
  assert.equal(s.authorized, false);
  assert.equal(s.message, 'Your password is saved, but this account is not an authorized Zella admin yet.');
});
