import { describe, expect, it } from 'vitest';
import { screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { fakeBackend, renderApp, OWNER, MODERATOR, person, UNAUTHORIZED } from './helpers';

describe('signing in', () => {
  it('signed out lands on sign-in; password then code leads to the users list', async () => {
    let signedIn = false;
    const { calls } = fakeBackend({
      'GET /admin/auth/me': () => (signedIn ? OWNER : UNAUTHORIZED),
      'POST /admin/auth/login': { mfaRequired: true, mfaToken: 'skm_x' },
      'POST /admin/auth/mfa': () => {
        signedIn = true;
        return { expiresAt: 'later' };
      },
      'GET /admin/users': [person(1)],
    });
    renderApp('/users');
    const user = userEvent.setup();

    await user.type(await screen.findByLabelText('Username'), 'owner');
    await user.type(screen.getByLabelText('Password'), 'correct horse battery');
    await user.click(screen.getByRole('button', { name: 'Sign in' }));

    await user.type(await screen.findByLabelText('Six-digit code'), '123456');
    await user.click(screen.getByRole('button', { name: 'Verify and sign in' }));

    expect(await screen.findByRole('heading', { name: 'Users' })).toBeInTheDocument();
    expect(await screen.findByText('Person 1')).toBeInTheDocument();
    expect(calls.find((c) => c.path === '/admin/auth/mfa').body).toEqual({ mfaToken: 'skm_x', code: '123456' });
  });

  it('a wrong password and an unknown username read the same', async () => {
    fakeBackend({
      'GET /admin/auth/me': UNAUTHORIZED,
      'POST /admin/auth/login': UNAUTHORIZED,
    });
    renderApp('/sign-in');
    const user = userEvent.setup();
    await user.type(await screen.findByLabelText('Username'), 'nobody');
    await user.type(screen.getByLabelText('Password'), 'whatever');
    await user.click(screen.getByRole('button', { name: 'Sign in' }));
    expect(await screen.findByRole('alert')).toHaveTextContent("That username and password didn't work.");
  });

  it('the code page cannot be opened without a pending sign-in', async () => {
    fakeBackend({ 'GET /admin/auth/me': UNAUTHORIZED });
    renderApp('/two-factor');
    expect(await screen.findByRole('heading', { name: 'Sign in' })).toBeInTheDocument();
  });
});

describe('temporary password', () => {
  it('is held on the account page until a new password is chosen', async () => {
    let me = { ...MODERATOR, mustChangePassword: true };
    fakeBackend({
      'GET /admin/auth/me': () => me,
      'POST /admin/auth/password': () => {
        me = { ...me, mustChangePassword: false };
        return { status: 204 };
      },
      'GET /admin/users': [],
    });
    renderApp('/users');
    const user = userEvent.setup();

    expect(await screen.findByRole('heading', { name: 'Choose your password' })).toBeInTheDocument();
    expect(screen.queryByRole('heading', { name: 'Users' })).not.toBeInTheDocument();

    const save = screen.getByRole('button', { name: 'Save password' });
    await user.type(screen.getByLabelText('Temporary password'), 'abcde-fghij-klmno-pqrst');
    await user.type(screen.getByLabelText('New password'), 'long enough password');
    await user.type(screen.getByLabelText('New password again'), 'long enough passwork');
    expect(screen.getByText('The two new passwords do not match.')).toBeInTheDocument();
    expect(save).toBeDisabled();

    await user.clear(screen.getByLabelText('New password again'));
    await user.type(screen.getByLabelText('New password again'), 'long enough password');
    await user.click(save);
    expect(await screen.findByText('Password changed.')).toBeInTheDocument();
    expect(screen.getByRole('heading', { name: 'Two-factor sign-in' })).toBeInTheDocument();
  });
});

describe('creating a user', () => {
  it('only the owner is offered the Admin role', async () => {
    fakeBackend({
      'GET /admin/auth/me': { ...OWNER, isOwner: false, userId: 'a2' },
      'GET /admin/users': [],
    });
    renderApp('/users');
    const user = userEvent.setup();
    await user.click(await screen.findByRole('button', { name: 'Create user' }));
    const roles = within(screen.getByRole('group', { name: 'Role' }));
    expect(roles.getByRole('button', { name: 'Admin' })).toBeDisabled();
    expect(roles.getByRole('button', { name: 'Moderator' })).toBeEnabled();
  });

  it('suggests a username, sends the initial contacts, and shows the code once', async () => {
    const alice = person(1, { displayName: 'Alice Smith', username: 'alice' });
    const { calls } = fakeBackend({
      'GET /admin/auth/me': OWNER,
      'GET /admin/users': [alice],
      'POST /admin/users': (body) => ({
        status: 201,
        body: {
          user: { ...person(2), displayName: body.displayName, username: body.username },
          activationCode: 'ABCD-EFGH-JKMN',
        },
      }),
    });
    renderApp('/users');
    const user = userEvent.setup();
    await user.click(await screen.findByRole('button', { name: 'Create user' }));
    await user.type(screen.getByLabelText('Full name'), 'Zoë Brown');
    expect(screen.getByLabelText('Username')).toHaveValue('zoe.brown');

    await user.type(screen.getByLabelText('Initial contacts'), 'ali');
    await user.click(screen.getByRole('button', { name: /Alice Smith/ }));
    await user.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Create user' }));

    expect(await screen.findByTestId('secret-value')).toHaveTextContent('ABCD-EFGH-JKMN');
    expect(calls.find((c) => c.method === 'POST' && c.path === '/admin/users').body).toEqual({
      displayName: 'Zoë Brown',
      username: 'zoe.brown',
      role: 'member',
      contactIds: [alice.userId],
    });
  });
});

describe('contact graph', () => {
  const alice = person(1, { displayName: 'Alice Smith', contacts: 0 });
  const bob = person(2, { displayName: 'Bob Jones', contacts: 0 });
  const dir = [{ ...bob, linked: false }];

  it('a switch links two people and the counts follow', async () => {
    const { calls } = fakeBackend({
      'GET /admin/auth/me': OWNER,
      'GET /admin/users': [alice, bob],
      [`GET /admin/users/${alice.userId}/contacts`]: dir,
      'POST /admin/contact-links': { linked: true, changed: true },
    });
    renderApp(`/contacts?user=${alice.userId}`);
    const user = userEvent.setup();
    expect(await screen.findByText(/has no contacts yet/)).toBeInTheDocument();
    const toggle = await screen.findByRole('switch', { name: 'Alice can talk to Bob Jones' });
    await user.click(toggle);
    await waitFor(() => expect(toggle).toHaveAttribute('aria-checked', 'true'));
    expect(calls.find((c) => c.path === '/admin/contact-links').body).toEqual({
      userId: alice.userId,
      otherUserId: bob.userId,
      linked: true,
    });
    await waitFor(() => expect(screen.getAllByLabelText('1 contacts')).toHaveLength(2));
    expect(screen.queryByText(/has no contacts yet/)).not.toBeInTheDocument();
  });

  it('a refused change is put back and explained', async () => {
    fakeBackend({
      'GET /admin/auth/me': MODERATOR,
      'GET /admin/users': [alice, bob],
      [`GET /admin/users/${alice.userId}/contacts`]: dir,
      'POST /admin/contact-links': { status: 403, body: {} },
    });
    renderApp(`/contacts?user=${alice.userId}`);
    const user = userEvent.setup();
    const toggle = await screen.findByRole('switch', { name: 'Alice can talk to Bob Jones' });
    await user.click(toggle);
    expect(await screen.findByRole('alert')).toHaveTextContent('Bob Jones: You are not allowed to do that.');
    expect(toggle).toHaveAttribute('aria-checked', 'false');
  });
});

describe('user detail', () => {
  const detail = (over = {}) => ({
    userId: person(1).userId,
    username: 'person1',
    displayName: 'Person One',
    role: 'member',
    status: 'active',
    isOwner: false,
    contacts: 2,
    devices: [],
    codes: [],
    ...over,
  });

  it("the owner's page is read-only to everyone else", async () => {
    fakeBackend({
      'GET /admin/auth/me': { ...OWNER, isOwner: false, userId: 'a2' },
      [`GET /admin/users/${person(1).userId}`]: detail({ role: 'admin', isOwner: true }),
    });
    renderApp(`/users/${person(1).userId}`);
    expect(await screen.findByText("This is the owner's account. Only the owner can change it.")).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Suspend' })).not.toBeInTheDocument();
    expect(screen.queryByLabelText('Display name')).not.toBeInTheDocument();
  });

  it('suspending asks first, then refreshes', async () => {
    let status = 'active';
    const { calls } = fakeBackend({
      'GET /admin/auth/me': OWNER,
      [`GET /admin/users/${person(1).userId}`]: () => detail({ status }),
      [`POST /admin/users/${person(1).userId}/suspend`]: () => {
        status = 'suspended';
        return { status: 204 };
      },
    });
    renderApp(`/users/${person(1).userId}`);
    const user = userEvent.setup();
    await user.click(await screen.findByRole('button', { name: 'Suspend' }));
    expect(calls.some((c) => c.path.endsWith('/suspend'))).toBe(false);
    await user.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Suspend' }));
    expect(await screen.findByRole('button', { name: 'Reinstate' })).toBeInTheDocument();
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
  });
});
