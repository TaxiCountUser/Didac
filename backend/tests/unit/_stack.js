// Utilidad compartida para los tests de INTEGRACIÓN (webhook, billing_endpoints,
// excel, pdf). Estos necesitan el stack local de Supabase (db + kong en :54321)
// arriba para insertar/leer datos reales. Si el stack NO está accesible, es
// preferible OMITIR el test limpiamente (exit 0) que fallar con errores confusos
// del tipo "Cannot read properties of null" (porque el insert falla en silencio
// y el select devuelve data: null).
//
// El CI usa "npm run test:ci" (unit puro, sin Docker) y no depende de esto; con
// el stack levantado ("docker compose up -d"), la sonda pasa y los tests corren
// de verdad.
import { createClient } from '@supabase/supabase-js';

// Sonda ligera: intenta una lectura trivial. Devuelve true solo si responde.
export async function stackReachable(sb) {
  try {
    const client = sb || createClient(
      process.env.SUPABASE_URL,
      process.env.SUPABASE_SERVICE_ROLE_KEY,
      { auth: { persistSession: false } },
    );
    const { error } = await client.from('tenants').select('id').limit(1);
    return !error;
  } catch {
    return false;
  }
}

// Omite el test con un mensaje claro y termina con éxito (0). Cierra la app si
// se pasa (para no dejar el puerto/handles abiertos).
export async function skipNoStack(name, app) {
  console.log(
    `⚠ ${name}: OMITIDO — el stack local de Supabase (db/kong en :54321) no ` +
    `responde. Levántalo con "docker compose up -d" para ejecutar este test de ` +
    `integración. (El CI usa test:ci y no lo necesita.)`,
  );
  try { if (app) await app.close(); } catch { /* best-effort */ }
  process.exit(0);
}
