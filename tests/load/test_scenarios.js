/* eslint-disable */
// ============================================================
// TaxiCount - Fase 6: pruebas de carga con k6.
//
// Escenarios (umbrales p95):
//   a) login            -> < 500 ms   (50 usuarios login simultáneo)
//   b) insert_tx        -> < 800 ms   (100 conductores insertando cada 10s/5min)
//   c) dashboard        -> < 1500 ms  (20 Owners cargando dashboard con filtros)
//   d) export           -> < 10000 ms (5 Owners exportando Excel/PDF)
//
// NO ejecutar contra producción. Solo local o staging.
//
// Escala por defecto = especificación completa. Para una ejecución local
// reducida (hardware de desarrollo, contenedor único), pásala por env:
//   k6 run -e VUS_LOGIN=10 -e VUS_INSERT=15 -e VUS_DASH=8 -e VUS_EXPORT=3 \
//          -e DUR_INSERT=20s tests/load/test_scenarios.js
//
// Variables de entorno (con defaults locales):
//   BASE_URL, BACKEND_URL, ANON_KEY, SERVICE_KEY
// ============================================================
import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE = __ENV.BASE_URL || 'http://localhost:54321';
const BACKEND = __ENV.BACKEND_URL || 'http://localhost:3000';
const ANON =
  __ENV.ANON_KEY ||
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoiYW5vbiIsImlzcyI6InN1cGFiYXNlLWRlbW8iLCJpYXQiOjE3MDAwMDAwMDAsImV4cCI6MjAwMDAwMDAwMH0.ZxBhVEYye2lqm5NDdkey-JP6uTHcqvZriXUoBtyQniY';
const SERVICE =
  __ENV.SERVICE_KEY ||
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoic2VydmljZV9yb2xlIiwiaXNzIjoic3VwYWJhc2UtZGVtbyIsImlhdCI6MTcwMDAwMDAwMCwiZXhwIjoyMDAwMDAwMDAwfQ.8T3kmJ5SaqY3bVmU02ZJ4MIoHe5z7R4qQ4T9VqJA8hk';

const VUS_LOGIN = Number(__ENV.VUS_LOGIN || 50);
const VUS_INSERT = Number(__ENV.VUS_INSERT || 100);
const VUS_DASH = Number(__ENV.VUS_DASH || 20);
const VUS_EXPORT = Number(__ENV.VUS_EXPORT || 5);
const DUR_INSERT = __ENV.DUR_INSERT || '5m';
const POOL = Number(__ENV.POOL || 8); // nº de conductores creados en setup

const jsonHeaders = (token) => ({
  apikey: ANON,
  Authorization: `Bearer ${token || ANON}`,
  'Content-Type': 'application/json',
});

export const options = {
  scenarios: {
    login: {
      executor: 'constant-vus',
      vus: VUS_LOGIN,
      duration: '30s',
      exec: 'loginScenario',
      startTime: '0s',
      tags: { scenario: 'login' },
    },
    insert_tx: {
      executor: 'constant-vus',
      vus: VUS_INSERT,
      duration: DUR_INSERT,
      exec: 'insertScenario',
      startTime: '5s',
      tags: { scenario: 'insert_tx' },
    },
    dashboard: {
      executor: 'constant-vus',
      vus: VUS_DASH,
      duration: '30s',
      exec: 'dashboardScenario',
      startTime: '5s',
      tags: { scenario: 'dashboard' },
    },
    export: {
      executor: 'constant-vus',
      vus: VUS_EXPORT,
      duration: '30s',
      exec: 'exportScenario',
      startTime: '5s',
      tags: { scenario: 'export' },
    },
  },
  thresholds: {
    'http_req_duration{scenario:login}': ['p(95)<500'],
    'http_req_duration{scenario:insert_tx}': ['p(95)<800'],
    'http_req_duration{scenario:dashboard}': ['p(95)<1500'],
    'http_req_duration{scenario:export}': ['p(95)<10000'],
    checks: ['rate>0.95'],
  },
};

// ---------------- setup: crea owner + pool de conductores ----------------
export function setup() {
  const stamp = Date.now();
  const ownerEmail = `load.owner.${stamp}@test.com`;
  const pwd = 'Owner12345!';

  // 1) Owner (signup auto-confirma y devuelve sesión)
  const su = http.post(
    `${BASE}/auth/v1/signup`,
    JSON.stringify({ email: ownerEmail, password: pwd, data: { company_name: 'Carga' } }),
    { headers: jsonHeaders() },
  );
  const ownerToken = su.json('access_token');
  const ownerId = su.json('user.id');

  // 2) tenant_id del owner
  const prof = http.get(`${BASE}/rest/v1/users?select=tenant_id&id=eq.${ownerId}`, {
    headers: jsonHeaders(ownerToken),
  });
  const tenantId = prof.json('0.tenant_id');

  // 3) Pool de conductores vía backend, luego login para obtener tokens
  const creds = [{ email: ownerEmail, pwd }];
  const driverTokens = [];
  const driverIds = [];
  for (let i = 0; i < POOL; i++) {
    const email = `load.d${i}.${stamp}@test.com`;
    const inv = http.post(
      `${BACKEND}/api/v1/drivers`,
      JSON.stringify({ email, name: `Driver ${i}` }),
      { headers: jsonHeaders(ownerToken) },
    );
    if (inv.status !== 201) continue;
    const tempPwd = inv.json('tempPassword');
    driverIds.push(inv.json('id'));
    creds.push({ email, pwd: tempPwd });
    const login = http.post(
      `${BASE}/auth/v1/token?grant_type=password`,
      JSON.stringify({ email, password: tempPwd }),
      { headers: jsonHeaders() },
    );
    const t = login.json('access_token');
    if (t) driverTokens.push({ token: t, id: inv.json('id') });
  }

  return { ownerToken, ownerId, tenantId, creds, driverTokens, driverIds };
}

// a) login simultáneo
export function loginScenario(data) {
  const c = data.creds[Math.floor(Math.random() * data.creds.length)];
  const res = http.post(
    `${BASE}/auth/v1/token?grant_type=password`,
    JSON.stringify({ email: c.email, password: c.pwd }),
    { headers: jsonHeaders() },
  );
  check(res, { 'login 200': (r) => r.status === 200 && !!r.json('access_token') });
  sleep(1);
}

// b) inserción de transacciones (cada conductor ~cada 10s)
export function insertScenario(data) {
  if (data.driverTokens.length === 0) return;
  const d = data.driverTokens[Math.floor(Math.random() * data.driverTokens.length)];
  const res = http.post(
    `${BASE}/rest/v1/transactions`,
    JSON.stringify({
      tenant_id: data.tenantId,
      user_id: d.id,
      amount: Math.round(Math.random() * 5000) / 100,
      type: Math.random() > 0.5 ? 'income' : 'expense',
      category: 'otros',
      payment_method: 'tarjeta',
    }),
    { headers: { ...jsonHeaders(d.token), Prefer: 'return=minimal' } },
  );
  check(res, { 'insert 201': (r) => r.status === 201 });
  sleep(10);
}

// c) carga del dashboard con filtros (Owner)
export function dashboardScenario(data) {
  const url =
    `${BASE}/rest/v1/transactions?select=*,users:user_id(name,email),vehicles:vehicle_id(license_plate,model)` +
    `&tenant_id=eq.${data.tenantId}&order=created_at.desc&limit=20`;
  const res = http.get(url, { headers: jsonHeaders(data.ownerToken) });
  check(res, { 'dashboard 200': (r) => r.status === 200 });
  sleep(1);
}

// d) exportación Excel/PDF (Owner)
export function exportScenario(data) {
  const fmt = Math.random() > 0.5 ? 'excel' : 'pdf';
  const res = http.post(`${BACKEND}/api/v1/reports/${fmt}`, JSON.stringify({}), {
    headers: jsonHeaders(data.ownerToken),
    timeout: '35s',
  });
  check(res, { 'export 200': (r) => r.status === 200 });
  sleep(2);
}

// ---------------- teardown: elimina los usuarios creados ----------------
export function teardown(data) {
  const adminHeaders = { apikey: SERVICE, Authorization: `Bearer ${SERVICE}` };
  for (const id of data.driverIds) {
    http.del(`${BASE}/auth/v1/admin/users/${id}`, null, { headers: adminHeaders });
  }
  if (data.ownerId) http.del(`${BASE}/auth/v1/admin/users/${data.ownerId}`, null, { headers: adminHeaders });
}
