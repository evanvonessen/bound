import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';

const root = fileURLToPath(new URL('../', import.meta.url));
const target = path.join(root, 'build', 'heroic');
const bundle = fs.readFileSync(path.join(root, 'build', 'index.js'));
fs.mkdirSync(target, { recursive: true });
fs.writeFileSync(path.join(target, 'index.js'), bundle);
fs.copyFileSync(path.join(root, 'heroic', 'nakama-config.yml'), path.join(target, 'nakama-config.yml'));
fs.writeFileSync(path.join(target, 'manifest.json'), JSON.stringify({
  protocol: 'bound-room-v1',
  entrypoint: 'index.js',
  sha256: createHash('sha256').update(bundle).digest('hex'),
  compiler: 'typescript@5.9.3',
  runtimeTypesCommit: '189a8ea03d9038126437666745a9d5f74ee21c30',
}, null, 2) + '\n');
console.log('Prepared deployment bundle: ' + target);
console.log('No remote build or deployment was started.');
