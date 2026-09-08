import { afterEach, expect, it, vi } from 'vitest';
import { cleanup, render, screen } from '@testing-library/react';
import { App } from './App';

vi.mock('@clerk/react', () => ({
  useAuth: () => ({ isLoaded: true, isSignedIn: false }),
  SignIn: ({ signUpUrl, routing }: { signUpUrl: string; routing: string }) => <a href={signUpUrl} data-routing={routing}>创建商业账号</a>,
  SignUp: ({ signInUrl, routing }: { signInUrl: string; routing: string }) => <a href={signInUrl} data-routing={routing}>返回商业登录</a>,
}));

afterEach(() => { cleanup(); window.history.replaceState(null, '', '/'); });

it('routes signup inside the desktop origin instead of the blocked hosted account portal', () => {
  render(<App clerkEnabled />);
  const link = screen.getByRole('link', { name: '创建商业账号' });
  expect(link.getAttribute('href')).toBe('/?auth=signup');
  expect(link.getAttribute('data-routing')).toBe('hash');
});

it('mounts the actual signup component on the same document and keeps hash steps available', () => {
  window.history.replaceState(null, '', '/?auth=signup#/verify-email-address');
  render(<App clerkEnabled />);
  expect(screen.getByRole('link', { name: '返回商业登录' }).getAttribute('href')).toBe('/?auth=signin');
  expect(screen.queryByRole('link', { name: '创建商业账号' })).toBeNull();
});

it('treats unknown account routes as signin and never renders an arbitrary external URL', () => {
  window.history.replaceState(null, '', '/?auth=https://untrusted.invalid');
  render(<App clerkEnabled />);
  expect(screen.getByRole('link', { name: '创建商业账号' }).getAttribute('href')).toBe('/?auth=signup');
});
