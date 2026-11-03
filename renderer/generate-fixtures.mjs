import { fileURLToPath } from 'node:url';
process.chdir(fileURLToPath(new URL('.', import.meta.url)));
import { Document, NodeIO } from '@gltf-transform/core';
import { ALL_EXTENSIONS } from '@gltf-transform/extensions';
import { draco, meshopt, cloneDocument } from '@gltf-transform/functions';
import draco3d from 'draco3dgltf';
import { MeshoptEncoder } from 'meshoptimizer';
import { mkdir, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
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
for (const kind of ['plain','draco','meshopt','animated']) {
  const copy = cloneDocument(doc);
  if (kind === 'draco') await copy.transform(draco());
  if (kind === 'meshopt') await copy.transform(meshopt({encoder:MeshoptEncoder}));
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
  const required = kind === 'draco' ? 'KHR_draco_mesh_compression' : kind === 'meshopt' ? 'EXT_meshopt_compression' : null;
  if (required && !json.extensionsRequired?.includes(required)) throw new Error('Missing compression: '+required);
  await writeFile('tests/fixtures/'+kind+'.glb', bytes);
  manifest[kind] = { bytes:bytes.length, sha256:createHash('sha256').update(bytes).digest('hex') };
}
await writeFile('tests/fixtures/broken.glb','not a model');
await writeFile('tests/fixtures/manifest.json',JSON.stringify(manifest,null,2));
