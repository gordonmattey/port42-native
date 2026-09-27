// Build the page's script and name its hash in the page (subresource integrity).
import { build } from 'esbuild';
import { readFileSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';

await build({ entryPoints: ['src/main.js'], bundle: true, format: 'esm', minify: true, outfile: 'dist/port42-guest.js' });
const hash = 'sha384-' + createHash('sha384').update(readFileSync('dist/port42-guest.js')).digest('base64');
const page = readFileSync('invite.html', 'utf8').replace(/integrity="sha384-[^"]*"/, `integrity="${hash}"`);
writeFileSync('invite.html', page);
console.log('built dist/port42-guest.js', hash);
