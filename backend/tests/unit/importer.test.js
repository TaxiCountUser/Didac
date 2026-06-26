// Test del importador de Excel/CSV antiguo (parseImportFile). Sin red ni DB.
import assert from 'node:assert';
import ExcelJS from 'exceljs';
import { parseImportFile } from '../../src/importer.js';

let failed = 0;
function check(name, cond) {
  if (cond) {
    console.log(`  ok  ${name}`);
  } else {
    failed++;
    console.error(`  FAIL ${name}`);
  }
}

// --- CSV con ; y formato español de fecha/importe ---
const csv = [
  'Fecha;Tipo;Importe;Categoria;Forma de pago;Matricula',
  '12/01/2024;Ingreso;25,50;Carrera;Tarjeta;1234ABC',
  '15/01/2024;Gasto;40;Gasolina;Efectivo;1234ABC',
  ';;;;;', // fila vacía -> ignorada
].join('\n');

const rCsv = await parseImportFile(Buffer.from(csv, 'utf8'), 'viejo.csv', { defaultType: 'auto' });
check('csv: 2 filas válidas', rCsv.rows.length === 2);
check('csv: ingreso 25,50 -> 25.5', rCsv.rows[0].amount === 25.5 && rCsv.rows[0].type === 'income');
check('csv: gasto -> expense', rCsv.rows[1].type === 'expense' && rCsv.rows[1].category === 'Gasolina');
check('csv: fecha dd/mm/aaaa', rCsv.rows[0].date instanceof Date && rCsv.rows[0].date.getUTCFullYear() === 2024);

// --- XLSX en memoria con columnas separadas Ingresos/Gastos ---
const wb = new ExcelJS.Workbook();
const ws = wb.addWorksheet('Datos');
ws.addRow(['Día', 'Ingresos', 'Gastos', 'Concepto']);
ws.addRow([new Date(Date.UTC(2025, 1, 3)), 100, '', 'Carrera aeropuerto']);
ws.addRow([new Date(Date.UTC(2025, 1, 4)), '', 30, 'Peaje']);
const buf = await wb.xlsx.writeBuffer();

const rXlsx = await parseImportFile(Buffer.from(buf), 'datos.xlsx', { defaultType: 'auto' });
check('xlsx: 2 filas', rXlsx.rows.length === 2);
check('xlsx: columna Ingresos -> income 100', rXlsx.rows[0].type === 'income' && rXlsx.rows[0].amount === 100);
check('xlsx: columna Gastos -> expense 30', rXlsx.rows[1].type === 'expense' && rXlsx.rows[1].amount === 30);

// --- Sin cabeceras reconocibles -> error controlado ---
const bad = await parseImportFile(Buffer.from('hola,mundo\n1,2', 'utf8'), 'x.csv', {});
check('sin cabeceras -> error no_headers', bad.error === 'no_headers');

if (failed > 0) {
  console.error(`\nImporter: ${failed} test(s) fallidos`);
  process.exit(1);
}
console.log('\nImporter: todos los tests OK');
