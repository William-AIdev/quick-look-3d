import { fileURLToPath } from 'node:url';
process.chdir(fileURLToPath(new URL('.', import.meta.url)));
import { Document, NodeIO } from '@gltf-transform/core';
import { ALL_EXTENSIONS } from '@gltf-transform/extensions';
import { draco, meshopt, cloneDocument } from '@gltf-transform/functions';
import draco3d from 'draco3dgltf';
import { MeshoptEncoder } from 'meshoptimizer';
import { mkdir, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { deflateSync, crc32 } from 'node:zlib';
function largeTexture() {
  const size = 4096;
  const raw = Buffer.alloc((size * 4 + 1) * size);
  for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) {
    const offset = y * (size * 4 + 1) + 1 + x * 4;
    raw[offset] = x % 256; raw[offset+1] = y % 256; raw[offset+2] = 150; raw[offset+3] = 255;
  }
  const chunk = (type, data) => {
    const tag = Buffer.from(type);
    const length = Buffer.alloc(4); length.writeUInt32BE(data.length);
    const checksum = Buffer.alloc(4); checksum.writeUInt32BE(crc32(Buffer.concat([tag,data])));
    return Buffer.concat([length,tag,data,checksum]);
  };
  const header = Buffer.alloc(13); header.writeUInt32BE(size); header.writeUInt32BE(size,4); header[8]=8; header[9]=6;
  return Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]),chunk('IHDR',header),chunk('IDAT',deflateSync(raw)),chunk('IEND',Buffer.alloc(0))]);
}
const texturePNG = largeTexture();
const io = new NodeIO().registerExtensions(ALL_EXTENSIONS).registerDependencies({
  'draco3d.encoder': await draco3d.createEncoderModule(),
  'draco3d.decoder': await draco3d.createDecoderModule(),
  'meshopt.encoder': MeshoptEncoder,
});
await MeshoptEncoder.ready;
const doc = new Document();
const buffer = doc.createBuffer();
const positions = doc.createAccessor().setType('VEC3').setArray(new Float32Array([-1,0,0,1,0,0,0,2,0])).setBuffer(buffer);
const mesh = doc.createMesh().addPrimitive(doc.createPrimitive().setAttribute('POSITION', positions).setMaterial(doc.createMaterial().setDoubleSided(true)));
doc.createScene().addChild(doc.createNode().setMesh(mesh));
await mkdir('tests/fixtures', {recursive:true});
const manifest = {};
for (const kind of ['plain','draco','meshopt','animated','textured','textured-draco','textured-meshopt']) {
  const copy = cloneDocument(doc);
  if (kind.startsWith('textured')) copy.getRoot().listMaterials()[0].setBaseColorTexture(copy.createTexture().setMimeType('image/png').setImage(texturePNG));
  if (kind.endsWith('draco')) await copy.transform(draco());
  if (kind.endsWith('meshopt')) await copy.transform(meshopt({encoder:MeshoptEncoder}));
  if (kind === 'animated') {
    const target = copy.getRoot().listNodes()[0];
    const buffer = copy.getRoot().listBuffers()[0];
    const times = copy.createAccessor().setType('SCALAR').setArray(new Float32Array([0,1,2])).setBuffer(buffer);
    const values = copy.createAccessor().setType('VEC3').setArray(new Float32Array([0,0,0,0.5,0,0,0,0,0])).setBuffer(buffer);
    const sampler = copy.createAnimationSampler().setInput(times).setOutput(values);
    copy.createAnimation().addSampler(sampler).addChannel(copy.createAnimationChannel().setTargetNode(target).setTargetPath('translation').setSampler(sampler));
  }
  const bytes = await io.writeBinary(copy);
  const json = JSON.parse(new TextDecoder().decode(bytes.subarray(20,20+new DataView(bytes.buffer,bytes.byteOffset).getUint32(12,true))));
  const required = kind.endsWith('draco') ? 'KHR_draco_mesh_compression' : kind.endsWith('meshopt') ? 'EXT_meshopt_compression' : null;
  if (required && !json.extensionsRequired?.includes(required)) throw new Error('Missing compression: '+required);
  await writeFile('tests/fixtures/'+kind+'.glb', bytes);
  manifest[kind] = { bytes:bytes.length, sha256:createHash('sha256').update(bytes).digest('hex') };
}
await writeFile('tests/fixtures/broken.glb','not a model');
await writeFile('tests/fixtures/manifest.json',JSON.stringify(manifest,null,2));
