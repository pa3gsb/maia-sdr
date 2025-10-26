import init, { maia_wasm_start } from "./pkg/maia_wasm.js";

async function run() {
    await init();
    maia_wasm_start();
};

run();

const canvas = document.getElementById("canvas");
const panel  = document.querySelector("form.ui"); // main control panel

canvas.addEventListener("dblclick", () => {
  panel.classList.toggle("hidden");
});
