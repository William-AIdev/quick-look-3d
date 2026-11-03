import { RenderScheduler } from './render-scheduler';
import * as THREE from 'three';
import { GLTFLoader } from 'three/examples/jsm/loaders/GLTFLoader.js';
import { FBXLoader } from 'three/examples/jsm/loaders/FBXLoader.js';
import { MeshoptDecoder } from 'three/examples/jsm/libs/meshopt_decoder.module.js';
import { OrbitControls } from 'three/examples/jsm/controls/OrbitControls.js';
import { VRMLoaderPlugin, VRMUtils, type VRM } from '@pixiv/three-vrm';
import { createDracoLoader } from './draco';

// When launched from the WKWebView (Quick Look extension), forward the console to
// the Swift side's os_log. In a plain browser there is no messageHandlers, so this is a no-op.
const nativeLog = (window as any).webkit?.messageHandlers?.log;
if (nativeLog) {
  const forward = (level: string, args: unknown[]) => {
    try {
      nativeLog.postMessage(
        `[${level}] ` +
          args
            .map((a) => (typeof a === 'string' ? a : JSON.stringify(a)))
            .join(' '),
      );
    } catch {
      /* noop */
    }
  };
  for (const level of ['log', 'warn', 'error'] as const) {
    const orig = console[level].bind(console);
    console[level] = (...args: unknown[]) => {
      forward(level, args);
      orig(...args);
    };
  }
  window.addEventListener('error', (e) =>
    forward('error', [e.message, e.filename, e.lineno]),
  );
  window.addEventListener('unhandledrejection', (e) =>
    forward('error', ['unhandledrejection', String(e.reason)]),
  );
}

// ---------------------------------------------------------------------------
// Setup
// ---------------------------------------------------------------------------
const app = document.getElementById('app')!;
const overlay = document.getElementById('overlay')!;
const overlayText = document.getElementById('overlay-text')!;

const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true });
renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
renderer.setSize(window.innerWidth, window.innerHeight);
renderer.outputColorSpace = THREE.SRGBColorSpace;
app.appendChild(renderer.domElement);

const scene = new THREE.Scene();

const camera = new THREE.PerspectiveCamera(
  30,
  window.innerWidth / window.innerHeight,
  0.1,
  100,
);
camera.position.set(0, 1.3, 3);

const controls = new OrbitControls(camera, renderer.domElement);
controls.target.set(0, 1.0, 0);
controls.enableDamping = true;
controls.dampingFactor = 0.1;
controls.update();

// Lighting (key + fill + ambient)
const keyLight = new THREE.DirectionalLight(0xffffff, 2.0);
keyLight.position.set(1, 2, 1.5);
scene.add(keyLight);

const fillLight = new THREE.DirectionalLight(0xffffff, 0.6);
fillLight.position.set(-1.5, 1, -1);
scene.add(fillLight);

scene.add(new THREE.AmbientLight(0xffffff, 0.6));
scene.add(new THREE.HemisphereLight(0xffffff, 0x444455, 0.6));

// Floor grid
const grid = new THREE.GridHelper(10, 20, 0x444444, 0x2a2a2a);
(grid.material as THREE.Material).transparent = true;
(grid.material as THREE.Material).opacity = 0.4;
scene.add(grid);

// ---------------------------------------------------------------------------
// Loaders
// ---------------------------------------------------------------------------
const gltfLoader = new GLTFLoader();
gltfLoader.setMeshoptDecoder(MeshoptDecoder); // EXT_meshopt_compression (e.g. TripoAI / gltfpack output)
const dracoLoader = createDracoLoader();
gltfLoader.setDRACOLoader(dracoLoader); // KHR_draco_mesh_compression
gltfLoader.register((parser) => new VRMLoaderPlugin(parser));
const fbxLoader = new FBXLoader();

// Remember the root added to the scene (VRM or plain glTF/GLB) so we can swap it out
let currentRoot: THREE.Object3D | null = null;
let currentVrm: VRM | null = null;
let currentMixer: THREE.AnimationMixer | null = null;
let currentSkeletonHelper: THREE.SkeletonHelper | null = null;
let generation = 0;
let activeRequest = '';
let destroyed = false;
function report(type: string, requestID = activeRequest, message?: string) {
  const event = { type, requestID, message, time: performance.now() };
  console.log('[preview]', JSON.stringify(event));
  (window as any).webkit?.messageHandlers?.preview?.postMessage(event);
}
function disposeRoot(root: THREE.Object3D) {
  const skeletons = new Set<THREE.Skeleton>();
  root.traverse(o => { if ((o as THREE.SkinnedMesh).isSkinnedMesh) skeletons.add((o as THREE.SkinnedMesh).skeleton); });
  skeletons.forEach(skeleton => skeleton.dispose());
  VRMUtils.deepDispose(root);
}

/** Whether it has a renderable mesh. false for VRMA / skin-less FBX. */
function hasRenderableMesh(root: THREE.Object3D): boolean {
  let found = false;
  root.traverse((o) => {
    if ((o as THREE.Mesh).isMesh) found = true;
  });
  return found;
}

function showOverlay(text: string, isError = false) {
  overlayText.textContent = text;
  overlay.classList.toggle('error', isError);
  overlay.classList.remove('hidden');
}

function hideOverlay() {
  overlay.classList.add('hidden');
}

/** Fit the camera and target to the model's bounding box. */
function frameModel(root: THREE.Object3D) {
  const box = new THREE.Box3().setFromObject(root);
  // With no mesh (bones only) the box is empty, so derive it from each node's position.
  if (box.isEmpty()) {
    const p = new THREE.Vector3();
    root.updateWorldMatrix(true, true);
    root.traverse((o) => box.expandByPoint(o.getWorldPosition(p)));
  }
  const size = box.getSize(new THREE.Vector3());
  const center = box.getCenter(new THREE.Vector3());

  // Derive the distance that fits the whole model from the field of view.
  const maxDim = Math.max(size.x, size.y, size.z);
  const fov = (camera.fov * Math.PI) / 180;
  const distance = (maxDim / 2 / Math.tan(fov / 2)) * 1.4;

  controls.target.copy(center);
  camera.position.set(center.x, center.y + size.y * 0.05, center.z + distance);
  camera.near = distance / 100;
  camera.far = distance * 100;
  camera.updateProjectionMatrix();
  controls.update();
}

/** Dispose the currently shown model (VRM / glTF / FBX / VRMA alike). */
function disposeCurrent() {
  if (currentMixer) {
    currentMixer.stopAllAction();
    if (currentRoot) currentMixer.uncacheRoot(currentRoot);
    currentMixer = null;
  }
  if (currentSkeletonHelper) {
    scene.remove(currentSkeletonHelper);
    currentSkeletonHelper.dispose();
    currentSkeletonHelper = null;
  }
  if (currentRoot) {
    scene.remove(currentRoot);
    disposeRoot(currentRoot);
    currentRoot = null;
  }
  currentVrm = null;
}

/** Detect FBX from the leading bytes (VRM/GLB start with the "glTF" magic). */
function isFBX(u8: Uint8Array): boolean {
  // Binary FBX: "Kaydara FBX Binary  \x00"
  const sig = 'Kaydara FBX Binary';
  let binMatch = u8.length > sig.length;
  for (let i = 0; binMatch && i < sig.length; i++) {
    if (u8[i] !== sig.charCodeAt(i)) binMatch = false;
  }
  if (binMatch) return true;
  // ASCII FBX: contains "FBX" near the start (GLB is 'glTF', so it won't match).
  const head = new TextDecoder().decode(u8.subarray(0, 64));
  return head.includes('FBX');
}

/** Add the loaded root to the scene (shared post-processing for VRM / glTF / FBX / VRMA). */
function applyModel(
  root: THREE.Object3D,
  vrm: VRM | null,
  clips: THREE.AnimationClip[],
) {
  // Play the first clip if any (GLB/FBX animation, VRMA, etc.).
  if (clips.length > 0) {
    currentMixer = new THREE.AnimationMixer(root);
    currentMixer.clipAction(clips[0]).play();
  }
  // Disable frustum culling so meshes don't disappear unexpectedly.
  root.traverse((obj) => {
    obj.frustumCulled = false;
  });
  scene.add(root);

  // No mesh, animation only (VRMA / skin-less FBX):
  // visualize the bone hierarchy with a skeleton helper.
  if (!vrm && clips.length > 0 && !hasRenderableMesh(root)) {
    root.traverse((o) => {
      // SkeletonHelper only links bones, so mark each node as a bone.
      if (o !== root) (o as unknown as { isBone: boolean }).isBone = true;
    });
    currentSkeletonHelper = new THREE.SkeletonHelper(root);
    scene.add(currentSkeletonHelper);
  }

  currentRoot = root;
  currentVrm = vrm;
  frameModel(root);
  hideOverlay();
  scheduler.invalidate();
}

async function loadModelFromArrayBuffer(buffer: ArrayBuffer, requestID = crypto.randomUUID()) {
  const ticket = ++generation;
  activeRequest = requestID;
  showOverlay('Loading…');
  let root: THREE.Object3D | null = null;
  let url: string | undefined;
  let applied = false;
  report('parseStart', requestID);
  try {
    let vrm: VRM | null = null;
    let clips: THREE.AnimationClip[];
    if (isFBX(new Uint8Array(buffer))) {
      root = fbxLoader.parse(buffer, '');
      clips = root.animations;
    } else {
      url = URL.createObjectURL(new Blob([buffer], { type: 'model/gltf-binary' }));
      const gltf = await gltfLoader.loadAsync(url);
      root = gltf.scene;
      vrm = (gltf.userData.vrm as VRM | undefined) ?? null;
      if (vrm) {
        VRMUtils.removeUnnecessaryVertices(root);
        VRMUtils.combineSkeletons(root);
        VRMUtils.rotateVRM0(vrm);
      }
      clips = vrm ? [] : gltf.animations;
    }
    report('parseEnd', requestID);
    if (ticket !== generation || destroyed) return;
    disposeCurrent();
    applyModel(root, vrm, clips);
    applied = true;
    renderer.render(scene, camera);
    report('firstFrame', requestID);
  } catch (e) {
    console.error('[model] load failed', e);
    if (ticket === generation && !destroyed) {
      showOverlay('Failed to load', true);
      report('error', requestID, String(e));
    }
  } finally {
    if (url) URL.revokeObjectURL(url);
    if (root && !applied) disposeRoot(root);
  }
}

function base64ToArrayBuffer(base64: string): ArrayBuffer {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes.buffer;
}

// ---------------------------------------------------------------------------
// Entry point from the Swift side (WKWebView)
//   received via window.postMessage({ type: 'loadVRM', base64 })
// ---------------------------------------------------------------------------
window.addEventListener('message', (event) => {
  const message = event.data;
  if (message?.type === 'visibility') { nativeVisible = message.visible === true; updateVisibility(); return; }
  if (message?.type === 'cancel') { ++generation; return; }
  if (message?.type !== 'loadVRM' || typeof message.base64 !== 'string' || typeof message.requestID !== 'string') return;
  try { void loadModelFromArrayBuffer(base64ToArrayBuffer(message.base64), message.requestID); }
  catch (error) { report('error', message.requestID, String(error)); }
});

console.log('renderer booted, WebGL context =', !!renderer.getContext());

// Browser dev fallbacks ---------------------------------------------------
// 1) load ?url=... if present
// 2) load a file dropped onto the window
(function devFallbacks() {
  const params = new URLSearchParams(location.search);
  const url = params.get('url');
  if (url) {
    showOverlay('Loading…');
    fetch(url)
      .then((r) => r.arrayBuffer())
      .then((buf) => loadModelFromArrayBuffer(buf))
      .catch(() => showOverlay('Failed to load', true));
  } else if (location.protocol.startsWith('http')) {
    showOverlay('Drag & drop a .vrm / .vrma / .glb / .fbx');
  }

  window.addEventListener('dragover', (e) => e.preventDefault());
  window.addEventListener('drop', (e) => {
    e.preventDefault();
    const file = e.dataTransfer?.files?.[0];
    if (!file) return;
    file.arrayBuffer().then((buf) => loadModelFromArrayBuffer(buf));
  });
})();

// ---------------------------------------------------------------------------
// Render loop
// ---------------------------------------------------------------------------
let nativeVisible = true;
let frameCount = 0;
const scheduler = new RenderScheduler((delta) => {
  const moved = controls.update();
  if (currentVrm) currentVrm.update(delta);
  if (currentMixer) currentMixer.update(delta);
  renderer.render(scene, camera);
  frameCount++;
  return moved || !!currentVrm || !!currentMixer;
});
controls.addEventListener('change', scheduler.invalidate);
function updateVisibility() { scheduler.setVisible(nativeVisible && !document.hidden); }
document.addEventListener('visibilitychange', updateVisibility);
scheduler.invalidate();
(window as any).previewDiagnostics = () => ({
  requestID: activeRequest, frameCount, generation,
  geometries: renderer.info.memory.geometries, textures: renderer.info.memory.textures,
});

window.addEventListener('resize', () => {
  camera.aspect = window.innerWidth / window.innerHeight;
  camera.updateProjectionMatrix();
  renderer.setSize(window.innerWidth, window.innerHeight);
  scheduler.invalidate();
});

window.addEventListener('pagehide', () => {
  scheduler.dispose();
  controls.removeEventListener('change', scheduler.invalidate);
  document.removeEventListener('visibilitychange', updateVisibility);
  destroyed = true;
  ++generation;
  disposeCurrent();
  dracoLoader.dispose();
  controls.dispose();
  grid.geometry.dispose();
  (grid.material as THREE.Material).dispose();
  renderer.dispose();
});
report('pageReady', '');
