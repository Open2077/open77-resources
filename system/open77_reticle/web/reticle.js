// Draws nothing on its own: the client script owns the decision and this page
// only renders the state it is handed.
//
// Keeping the decision on the Lua side is deliberate. `engaged`, `armed` and
// `aiming` are read from the arbiter and from the character; a page that guessed
// any of them would drift from what the arbiter actually holds, which is the
// split state the arbiter exists to prevent.
(() => {
  "use strict";

  const node = document.getElementById("reticle");

  function render(payload) {
    if (node === null) return;
    let next = "hidden";
    if (payload && payload.visible === true && payload.aiming === true) {
      next = "aim";
    }
    if (node.getAttribute("data-state") !== next) {
      node.setAttribute("data-state", next);
    }
  }

  Open77.on("reticle:state", render);
  Open77.ready();
  Open77.emit("reticle:ready", {});
})();
