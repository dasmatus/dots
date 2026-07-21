// Snipping Tool-style selection overlay. The #sel div carries a huge-spread
// box-shadow that fills the whole screen with a translucent dim outside the
// rectangle; the rectangle itself is transparent, so the live desktop shows
// through. Hyprland's blur window rule frosts the dimmed area; the transparent
// hole (alpha 0) reads as a crisp desktop — no image processing needed.
const sel = document.getElementById("sel");
let start = null;

// Tauri v2 exposes the IPC on window.__TAURI__.core.invoke; v1 used the flat
// window.__TAURI__.invoke. Support both so the static (no-bundler) frontend
// keeps working across Tauri revisions.
const invoke = (cmd, args) => {
  const t = window.__TAURI__;
  return (t.core?.invoke || t.invoke)(cmd, args);
};

const rectArg = (r) => ({
  rect: {
    x: Math.round(r.left),
    y: Math.round(r.top),
    w: Math.round(r.width),
    h: Math.round(r.height),
  },
});

function setRect(x, y, w, h) {
  sel.style.left = `${x}px`;
  sel.style.top = `${y}px`;
  sel.style.width = `${w}px`;
  sel.style.height = `${h}px`;
}

function confirmSelection() {
  const r = sel.getBoundingClientRect();
  if (r.width < 2 || r.height < 2) {
    invoke("cancel");
    return;
  }
  invoke("capture", rectArg(r));
}

document.addEventListener("mousedown", (e) => {
  if (e.button !== 0) return;
  start = { x: e.clientX, y: e.clientY };
  sel.style.display = "block";
  setRect(e.clientX, e.clientY, 0, 0);
});

document.addEventListener("mousemove", (e) => {
  if (!start) return;
  const x = Math.min(start.x, e.clientX);
  const y = Math.min(start.y, e.clientY);
  const w = Math.abs(e.clientX - start.x);
  const h = Math.abs(e.clientY - start.y);
  setRect(x, y, w, h);
});

document.addEventListener("mouseup", () => {
  if (!start) return;
  start = null;
  confirmSelection();
});

document.addEventListener("keydown", (e) => {
  if (e.key === "Escape") {
    invoke("cancel");
  } else if (e.key === "Enter") {
    confirmSelection();
  }
});