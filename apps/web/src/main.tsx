import React from 'react';
import ReactDOM from 'react-dom/client';
import { ClerkProvider } from '@clerk/react';
import { App } from './App';
import './style.css';

const key = import.meta.env.VITE_CLERK_PUBLISHABLE_KEY?.trim();
const app = <App clerkEnabled={Boolean(key)} />;
ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>{key ? <ClerkProvider publishableKey={key}>{app}</ClerkProvider> : app}</React.StrictMode>,
);
