/* Pure fitting-room state. Kept separate so persistence patches and cancel
 * semantics can be tested without CEF or a running game. */
(function(root) {
  "use strict";
  const slots = ["Head", "Face", "InnerChest", "OuterChest", "Legs", "Feet", "Outfit"];
  const labels = {Head:"Headwear",Face:"Eyewear",InnerChest:"Tops",OuterChest:"Jackets",Legs:"Bottoms",Feet:"Footwear",Outfit:"Full body"};
  const clone = value => JSON.parse(JSON.stringify(value));
  const equal = (a,b) => {
    if (a === b) return true;
    if (!a || !b || typeof a !== "object" || typeof b !== "object") return false;
    const keys = Object.keys(a);
    return keys.length === Object.keys(b).length && keys.every(key => equal(a[key],b[key]));
  };
  function normalize(source) {
    const state=clone(source), w=state.wardrobe || {};
    state.equipment=Object.assign({},state.equipment || {});
    state.wardrobe={active:Number.isInteger(w.active) && w.active>=0 && w.active<=6 ? w.active:false,outfits:{},names:{}};
    for(let i=0;i<7;i++) {
      state.wardrobe.outfits[i]=Object.assign({},clone((w.outfits || {})[i] || {}));
      state.wardrobe.names[i]=(w.names || {})[i] || `Outfit ${i+1}`;
    }
    return state;
  }
  function patch(original,current) {
    const equipment={},wardrobe={outfits:{},names:{}};
    for(const slot of slots) if(!equal(original.equipment[slot],current.equipment[slot])) equipment[slot]=current.equipment[slot] || false;
    for(let i=0;i<7;i++) {
      if(!equal(original.wardrobe.outfits[i],current.wardrobe.outfits[i])) wardrobe.outfits[i]=clone(current.wardrobe.outfits[i]);
      if(original.wardrobe.names[i]!==current.wardrobe.names[i]) wardrobe.names[i]=current.wardrobe.names[i];
    }
    if(original.wardrobe.active!==current.wardrobe.active) wardrobe.active=current.wardrobe.active;
    return {expectedRevision:original.revision,characterKey:original.characterKey,equipment,wardrobe};
  }
  function dirty(original,current) {
    const p=patch(original,current);
    return Object.keys(p.equipment).length>0 || Object.keys(p.wardrobe.outfits).length>0 || Object.keys(p.wardrobe.names).length>0 || Object.hasOwn(p.wardrobe,"active");
  }
  function title(record) {
    return String(record || "").replace(/^Items\./,"").replace(/([a-z])([A-Z])/g,"$1 $2").replace(/_/g," ").replace(/\bbasic\b/gi,"Classic");
  }
  const api={slots,labels,clone,equal,normalize,patch,dirty,title};
  if(typeof module!=="undefined" && module.exports) module.exports=api;
  else root.WardrobeModel=api;
})(typeof globalThis!=="undefined"?globalThis:this);
