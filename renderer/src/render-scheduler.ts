export class RenderScheduler {
  private frame: number | null = null;
  private last = 0;
  private visible = true;
  private stopped = false;
  private fps = 30;
  setFPS(fps: number) { this.fps = Math.max(10, Math.min(60, fps)); this.invalidate(); }
  constructor(private draw: (delta: number) => boolean) {}
  invalidate = () => {
    if (!this.stopped && this.visible && this.frame === null) this.frame = requestAnimationFrame(this.tick);
  };
  private tick = (time: number) => {
    this.frame = null;
    if (this.last && time - this.last < 1000 / this.fps - 0.5) { this.invalidate(); return; }
    const delta = this.last ? Math.min((time - this.last) / 1000, 0.1) : 0;
    this.last = time;
    if (this.draw(delta)) this.invalidate();
    else this.last = 0;
  };
  setVisible(visible: boolean) {
    this.visible = visible;
    this.last = 0;
    if (!visible && this.frame !== null) { cancelAnimationFrame(this.frame); this.frame = null; }
    if (visible) this.invalidate();
  }
  dispose() {
    this.stopped = true;
    if (this.frame !== null) cancelAnimationFrame(this.frame);
    this.frame = null;
  }
}
