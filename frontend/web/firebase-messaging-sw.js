// Avisos (push) de la WEB de TaxiCount con la web CERRADA o en segundo plano.
// Imprescindible en iPhone: la web añadida a la pantalla de inicio (iOS 16.4+)
// recibe los avisos a través de este service worker.
// Config PÚBLICA de la app web de Firebase «TaxiCount Web» (la misma que
// lib/config.dart). La versión del SDK = la de firebase_core_web (12.15.0).
importScripts('https://www.gstatic.com/firebasejs/12.15.0/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/12.15.0/firebase-messaging-compat.js');

firebase.initializeApp({
  apiKey: '__FIREBASE_WEB_API_KEY__',
  appId: '1:1063875764382:web:9c55d4eb5de28133bf1b8f',
  messagingSenderId: '1063875764382',
  projectId: 'taxicount-75bc2',
});

// El aviso (título + texto) lo pinta el navegador solo, porque el servidor lo
// manda con `notification`. Al tocarlo, abre/enfoca la web (link del servidor).
firebase.messaging();
