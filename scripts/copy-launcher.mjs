import { copyFile, mkdir } from 'node:fs/promises';
import { resolve } from 'node:path';

const root = resolve(import.meta.dirname, '..');
await mkdir(resolve(root, 'dist'), { recursive: true });
await copyFile(resolve(root, 'launcher.sh'), resolve(root, 'dist', 'launcher.sh'));
