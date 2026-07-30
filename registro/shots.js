// Controlador CDP minimo (sin dependencias) para capturar pantallas de la app Flutter web.
// Uso: node shots.js <recipe.json>
const fs = require('fs');
const path = require('path');

const recipe = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const { debugPort = 9333, width = 375, height = 812, scale = 2, outDir, shots } = recipe;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function cdpTargets() {
  const res = await fetch(`http://127.0.0.1:${debugPort}/json/list`);
  return res.json();
}

function rpc(ws) {
  let id = 0;
  const pending = new Map();
  ws.addEventListener('message', (ev) => {
    const msg = JSON.parse(ev.data);
    if (msg.id && pending.has(msg.id)) {
      const { resolve, reject } = pending.get(msg.id);
      pending.delete(msg.id);
      msg.error ? reject(new Error(JSON.stringify(msg.error))) : resolve(msg.result);
    }
  });
  return (method, params = {}) =>
    new Promise((resolve, reject) => {
      const myId = ++id;
      pending.set(myId, { resolve, reject });
      ws.send(JSON.stringify({ id: myId, method, params }));
      setTimeout(() => {
        if (pending.has(myId)) { pending.delete(myId); reject(new Error('timeout ' + method)); }
      }, 30000);
    });
}

async function click(send, x, y) {
  for (const type of ['mousePressed', 'mouseReleased']) {
    await send('Input.dispatchMouseEvent', {
      type, x, y, button: 'left', clickCount: 1, buttons: type === 'mousePressed' ? 1 : 0,
    });
    await sleep(60);
  }
}

(async () => {
  fs.mkdirSync(outDir, { recursive: true });

  let targets = [];
  for (let i = 0; i < 40 && !targets.length; i++) {
    try { targets = (await cdpTargets()).filter((t) => t.type === 'page'); } catch { await sleep(500); }
  }
  if (!targets.length) throw new Error('no encontre ninguna pestana CDP en el puerto ' + debugPort);

  const ws = new WebSocket(targets[0].webSocketDebuggerUrl);
  await new Promise((r, j) => { ws.addEventListener('open', r); ws.addEventListener('error', j); });
  const send = rpc(ws);

  await send('Page.enable');
  await send('Runtime.enable');
  await send('Emulation.setDeviceMetricsOverride', {
    width, height, deviceScaleFactor: scale, mobile: false,
  });

  for (const shot of shots) {
    process.stdout.write(`-> ${shot.name} `);
    if (shot.url) {
      await send('Page.navigate', { url: shot.url });
      await sleep(shot.settle || 3500);
    }
    for (const step of shot.steps || []) {
      if (step.click) { await click(send, step.click[0], step.click[1]); await sleep(step.wait || 1200); }
      if (step.eval) { await send('Runtime.evaluate', { expression: step.eval }); await sleep(step.wait || 800); }
    }
    const { data } = await send('Page.captureScreenshot', { format: 'png' });
    const file = path.join(outDir, shot.name + '.png');
    fs.writeFileSync(file, Buffer.from(data, 'base64'));
    console.log('OK ' + (fs.statSync(file).size / 1024).toFixed(0) + ' KB');
  }

  ws.close();
  console.log('\nlisto: ' + shots.length + ' capturas en ' + outDir);
  process.exit(0);
})().catch((e) => { console.error('FALLO: ' + e.message); process.exit(1); });
