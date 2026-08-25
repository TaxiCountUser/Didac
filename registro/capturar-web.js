// Levanta un servidor estatico sobre una compilacion web, abre Edge headless con
// el puerto de depuracion, ejecuta una receta de shots.js y lo recoge todo.
//   node registro/capturar-web.js <carpeta-build> <receta.json>
//
// Existe porque la app no expone rutas por URL —la navegacion es por
// MaterialPageRoute— ni arbol de accesibilidad: no se puede llegar a una
// pantalla concreta cambiando la direccion, hay que pulsar por coordenadas.
const { spawn, spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const os = require('os');

const BUILD = path.resolve(process.argv[2]);
const RECETA = path.resolve(process.argv[3]);
const PUERTO = 8099;

const receta = JSON.parse(fs.readFileSync(RECETA, 'utf8'));
const DEBUG = receta.debugPort || 9333;

const EDGE = [
  'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
  'C:/Program Files/Microsoft/Edge/Application/msedge.exe',
].find((p) => fs.existsSync(p));
if (!EDGE) { console.error('No encuentro msedge.exe'); process.exit(1); }
if (!fs.existsSync(path.join(BUILD, 'index.html'))) {
  console.error('No hay index.html en ' + BUILD + ' — falta compilar'); process.exit(1);
}

const perfil = fs.mkdtempSync(path.join(os.tmpdir(), 'tcshots-'));
const servidor = spawn(process.execPath, [path.join(__dirname, 'serve.js'), BUILD, String(PUERTO)],
  { stdio: 'ignore' });
const navegador = spawn(EDGE, [
  '--headless=new', '--disable-gpu', '--hide-scrollbars', '--no-first-run',
  `--remote-debugging-port=${DEBUG}`, `--user-data-dir=${perfil}`,
  `http://localhost:${PUERTO}/`,
], { stdio: 'ignore' });

const recoger = () => { try { navegador.kill(); } catch {} try { servidor.kill(); } catch {} };
process.on('exit', recoger);

const r = spawnSync(process.execPath, [path.join(__dirname, 'shots.js'), RECETA],
  { stdio: 'inherit' });
recoger();
process.exit(r.status ?? 1);
