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
const SEED_TX = Number(__ENV.SEED_TX || 0); // tx a sembrar en el tenant (A/B del dashboard)

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
  // Fail-fast: sin sesión del owner, TODO el test sería basura (Bearer
  // undefined en cada request). Causas típicas: "Confirm email" activado
  // (el signup no devuelve access_token) o ANON_KEY incorrecta.
  if (!ownerToken) {
    throw new Error(
      `setup: el signup no devolvió access_token (HTTP ${su.status}). ` +
      '¿"Confirm email" desactivado (Authentication → Providers → Email)? ' +
      `¿ANON_KEY correcta? Respuesta: ${String(su.body).slice(0, 200)}`,
    );
  }

  // 2) tenant_id del owner
  const prof = http.get(`${BASE}/rest/v1/users?select=tenant_id&id=eq.${ownerId}`, {
    headers: jsonHeaders(ownerToken),
  });
  const tenantId = prof.json('0.tenant_id');
  if (!tenantId) {
    throw new Error(
      'setup: el owner no tiene tenant_id. Falta el trigger on_auth_user_created ' +
      'en el proyecto (paso 3c del manual load-test-t8.md).',
    );
  }

  // 2-bis) Siembra opcional de tx en el tenant, para que el resumen del dashboard
  // agregue un volumen realista (A/B M3-5). Vía service_role (salta RLS), en lotes.
  if (SEED_TX > 0) {
    const svcHeaders = {
      apikey: SERVICE, Authorization: `Bearer ${SERVICE}`,
      'Content-Type': 'application/json', Prefer: 'return=minimal',
    };
    const batch = 500;
    for (let done = 0; done < SEED_TX; done += batch) {
      const n = Math.min(batch, SEED_TX - done);
      const rows = [];
      for (let i = 0; i < n; i++) {
        rows.push({
          tenant_id: tenantId, user_id: ownerId,
          amount: Math.round(Math.random() * 5000) / 100,
          type: Math.random() > 0.5 ? 'income' : 'expense',
          category: 'otros', payment_method: 'tarjeta',
        });
      }
      http.post(`${BASE}/rest/v1/transactions`, JSON.stringify(rows), { headers: svcHeaders });
    }
  }

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

  if (driverTokens.length === 0) {
    throw new Error(
      'setup: no se pudo crear/loguear ningún conductor. ¿Backend local ' +
      `corriendo y apuntando al MISMO proyecto? (BACKEND=${BACKEND})`,
    );
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
  // Defensa: sin tokens no hay nada que medir; duerme para no girar en vacío
  // a cientos de miles de iteraciones/segundo (el setup ya aborta antes).
  if (data.driverTokens.length === 0) { sleep(1); return; }
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

// c) carga del dashboard (Owner). El coste real del dashboard es el RESUMEN
// económico (KPIs), que agrega sobre TODAS las tx del rango. Mes 3 lo movió a la
// BD (RPC report_summary). Este escenario mide ese resumen y permite un A/B:
//   DASH_MODE=rpc     (por defecto) → agregación en la BD (lo que hace hoy la app)
//   DASH_MODE=legacy              → trae TODAS las filas (lo que hacía antes)
// El feed (lista de 20 tx con joins) va aparte y no es el cuello (ya acotado).
export function dashboardScenario(data) {
  let res;
  if ((__ENV.DASH_MODE || 'rpc') === 'legacy') {
    // ANTES: el cliente traía todas las tx del tenant y sumaba en el navegador.
    const url =
      `${BASE}/rest/v1/transactions?select=amount,type,category&tenant_id=eq.${data.tenantId}`;
    res = http.get(url, { headers: jsonHeaders(data.ownerToken) });
  } else {
    // AHORA: agregación en Postgres, devuelve un JSON pequeño.
    res = http.post(`${BASE}/rest/v1/rpc/report_summary`, JSON.stringify({}),
      { headers: jsonHeaders(data.ownerToken) });
  }
  check(res, { 'dashboard 200': (r) => r.status === 200 });
  // Feed de las últimas 20 tx (sin cambios; ya acotado): parte de la misma carga.
  const feed = http.get(
    `${BASE}/rest/v1/transactions?select=*,users:user_id(name,email),vehicles:vehicle_id(license_plate,model)` +
    `&tenant_id=eq.${data.tenantId}&order=created_at.desc&limit=20`,
    { headers: jsonHeaders(data.ownerToken) });
  check(feed, { 'feed 200': (r) => r.status === 200 });
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
