// Rehace 00-hoja-capturas.png, el contacto de todas las capturas del expediente.
//   node registro/hoja-capturas.js
const fs = require('fs'), path = require('path'), os = require('os');
const { execFileSync } = require('child_process');
const DIR = path.join(__dirname, 'capturas');
const EDGE = ['C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
              'C:/Program Files/Microsoft/Edge/Application/msedge.exe'].find((p) => fs.existsSync(p));
if (!EDGE) { console.error('No encuentro msedge.exe'); process.exit(1); }

const files = fs.readdirSync(DIR).filter((f) => /^\d\d-/.test(f) && !f.startsWith('00-')).sort();
const web = files.filter((f) => f.endsWith('.png')), movil = files.filter((f) => f.endsWith('.jpg'));
const cel = (f) => `<div class="c"><div class="w"><img src="file:///${DIR.split(path.sep).join('/')}/${f}"></div>
  <div class="n">${f.slice(0, 2)} · ${f.replace(/^\d\d-/, '').replace(/\.(png|jpg)$/, '').replace(/-/g, ' ')}</div></div>`;

const html = `<style>
body{font-family:Segoe UI,sans-serif;margin:0;padding:20px;background:#fff;color:#222}
h1{font-size:16px;margin:0 0 3px}.s{font-size:11px;color:#999;margin-bottom:14px}
h2{font-size:10px;letter-spacing:1.4px;color:#aaa;margin:16px 0 9px;font-weight:700}
.g{display:flex;flex-wrap:wrap;gap:11px}.c{width:112px}
.w{height:190px;border:1px solid #e4e4e4;border-radius:5px;overflow:hidden;background:#fafafa;
   display:flex;align-items:center;justify-content:center}
img{max-width:100%;max-height:100%;object-fit:contain;display:block}
.n{font-size:8px;color:#888;margin-top:4px;line-height:1.25}
.gw .w{height:118px}.gw .c{width:172px}
</style>
<h1>TaxiCount — capturas de la interfaz</h1>
<div class="s">${files.length} capturas de la versión depositada · las de móvil proceden de una cuenta de demostración con datos ficticios</div>
<h2>NAVEGADOR — COMPILACIÓN WEB (${web.length})</h2><div class="g gw">${web.map(cel).join('')}</div>
<h2>ANDROID (${movil.length})</h2><div class="g">${movil.map(cel).join('')}</div>`;

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'tccaps-'));
const w = path.join(tmp, 'h.html');
fs.writeFileSync(w, html);
const salida = path.join(DIR, '00-hoja-capturas.png');
execFileSync(EDGE, ['--headless=new', '--disable-gpu', '--hide-scrollbars', '--no-first-run',
  '--allow-file-access-from-files', `--user-data-dir=${path.join(tmp, 'u')}`,
  `--screenshot=${salida}`, '--window-size=860,1400', `file:///${w.split(path.sep).join('/')}`],
  { stdio: 'ignore' });
console.log(fs.existsSync(salida) ? `00-hoja-capturas.png · ${files.length} capturas` : 'FALLO');
