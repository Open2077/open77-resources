const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
let state = 'hidden', render, ready = false;
const node = { getAttribute: () => state, setAttribute: (_, value) => { state = value; } };
vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../web/reticle.js'), 'utf8'), {
  document: { getElementById: () => node },
  Open77: {
    on: (event, callback) => { assert.equal(event, 'reticle:state'); render = callback; },
    ready: () => { ready = true; },
    emit: event => { assert(ready); assert.equal(event, 'reticle:ready'); assert(render); },
  },
});
for (const input of [null, {}, {visible:true}, {visible:true, aiming:false}, {visible:false, aiming:true}]) {
  render(input); assert.equal(state, 'hidden');
}
render({visible:true, aiming:true}); assert.equal(state, 'aim');
render({visible:false, aiming:false}); assert.equal(state, 'hidden');
console.log('Reticle renderer: ADS only and handler registered before readiness OK');
