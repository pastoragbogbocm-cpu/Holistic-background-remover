// Embeds the segmentation models as a JS module so any static host (and
// Claude's page host) can serve them; MediaPipe takes them as buffers.
import { readFileSync, writeFileSync } from 'node:fs';
const dir = process.argv[2];
const b64 = (f) => readFileSync(`${dir}/${f}`).toString('base64');
writeFileSync(process.argv[3],
  `export const SQUARE = "${b64('selfie_segmenter.tflite')}";\n` +
  `export const LANDSCAPE = "${b64('selfie_segmenter_landscape.tflite')}";\n`);
