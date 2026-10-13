// Genera un Excel y un PDF de EJEMPLO (datos inventados) para ver cómo salen los
// informes sin tocar la base de datos.
//   Uso: node tests/make_report_samples.js <carpeta_salida>
import { writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { buildExcel, buildPdf } from '../src/reports.js';

const out = process.argv[2] || '.';
mkdirSync(out, { recursive: true });

const pepe = { name: 'Pepe García', email: 'pepe@example.com' };
const ana = { name: 'Ana Puig', email: 'ana@example.com' };
let n = 0;
const tx = (user, uid, iso, type, amount, extra = {}) => ({
  id: `t${++n}`, user_id: uid, users: user, created_at: iso, type, amount, ...extra,
});
const transactions = [
  tx(pepe, 'u1', '2026-10-01T06:10:00Z', 'income', 18.5, { origin: 'Estació de Figueres', destination: 'Hospital de Figueres', odometer_km: 32442, payment_method: 'efectivo', description: 'Cliente habitual, deja propina' }),
  tx(pepe, 'u1', '2026-10-01T09:45:00Z', 'income', 42, { origin: 'Roses', destination: 'Aeropuerto de Girona', odometer_km: 32490, client_name: 'hotel almadraba', payment_method: 'credito', description: 'Factura a final de mes' }),
  tx(pepe, 'u1', '2026-10-01T22:30:00Z', 'income', 12, { origin: 'La Rambla', destination: 'Vilafant', odometer_km: 32530, payment_method: 'tarjeta' }),
  tx(pepe, 'u1', '2026-10-02T08:00:00Z', 'income', 25, { origin: 'Llançà', destination: 'Figueres', odometer_km: 32575, client_name: 'mútua', payment_method: 'credito' }),
  tx(pepe, 'u1', '2026-10-01T13:00:00Z', 'expense', 60, { category: 'gasoil', payment_method: 'tarjeta' }),
  tx(pepe, 'u1', '2026-10-02T11:00:00Z', 'expense', 8, { category: 'lavado', payment_method: 'efectivo' }),
  tx(ana, 'u2', '2026-10-01T07:20:00Z', 'income', 15, { origin: 'Plaça Catalunya', destination: 'Avinyonet', odometer_km: 118200, payment_method: 'bizum', description: 'Lleva perro' }),
  tx(ana, 'u2', '2026-10-01T16:05:00Z', 'income', 33, { origin: 'Cadaqués', destination: 'Estació AVE Figueres-Vilafant', odometer_km: 118260, payment_method: 'efectivo' }),
  tx(ana, 'u2', '2026-10-02T10:00:00Z', 'expense', 45, { category: 'otros', description: 'ITV', payment_method: 'tarjeta' }),
];
const groups = new Map();
for (const t of transactions) {
  if (!groups.has(t.user_id)) groups.set(t.user_id, { name: t.users.name, email: t.users.email, txs: [] });
  groups.get(t.user_id).txs.push(t);
}
const data = { tenantName: 'Taxis Empordà (ejemplo)', startDate: '2026-10-01', endDate: '2026-10-03', transactions, groups };

writeFileSync(join(out, 'informe-ejemplo.xlsx'), await buildExcel(data));
writeFileSync(join(out, 'informe-ejemplo.pdf'), await buildPdf(data));
console.log('ok', out);
