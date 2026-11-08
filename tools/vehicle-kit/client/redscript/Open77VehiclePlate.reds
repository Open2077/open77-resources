// Vehicle plate text (vehicle customization, route W).
//
// The plate pack (scripts/vehicle-kit/plates, an ArchiveXL patch of the dealer appearance
// resources) adds these components to every dealer appearance that has a rear plate, or a
// bumper a plate can be mounted on. All of them are DISABLED as authored, so traffic and
// unowned cars look factory:
//   open77_plate_mount       entMeshComponent: the vanilla plate mesh, only where the
//                            factory appearance has no rear plate
//   open77_plate_screen[_f]  entMeshComponent: a screen quad 3 mm proud of the plate
//   open77_plate_text[_f]    WorldWidgetComponent: draws the plate .inkwidget on that quad
// `_f` is the front pair, present only where the appearance has a front plate. A few factory
// appearances have a front plate and no rear one: they carry the `_f` pair alone.
//
// Vanilla toggles our widget too. VehicleObject.SetInteriorUIEnabled(enabled) toggles every
// component returned by the native VehicleObject.GetUIComponents(). It is called:
//   * with false by OnGameAttached, on every spawn, stream-in and garage retrieval;
//   * with true by OnMountingEvent, and with false by OnUnmountingEvent;
//   * with false, then true 0.6 s later, by TempDisableUI, which runs from
//     ApplyVehicleVisualCustomizationTemplate and DisableCurrentCustomization (every paint).
// Source: bytecode of final.redscripts (game 2.50), read offline on 2026-11-05. In game on the
// same day, a car spawned with an enabled text widget had it disabled, while its screen quad
// stayed enabled.
// Hence:
//   * Apply enables the text widget itself, and returns 0 until its ink tree exists;
//   * the wrap of SetInteriorUIEnabled below makes our widget follow the plate state after
//     every vanilla toggle, and pushes the stored text again: a re-enabled widget is a new
//     ink tree that shows the library's default text.
//
// Never twice in one frame. The text widget is drawn by the world fluff layer
// (inkWorldFluffLayer) into an atlas tile, by engine jobs that outlive the frame that queued
// them. Until 2026-11-07 the wrap flipped the widget back within the very call in which vanilla
// had flipped it: off then on in one frame on every paint (TempDisableUI), stream-in and unmount,
// five times per pass during the paint-stamp loop of that day. Vanilla never does this:
// TempDisableUI waits 0.6 s. The client crash of 2026-11-07 15:09 (Cyberpunk2077.exe+0x289E49,
// see docs/research/debugging-and-reverse.md) had two merge jobs running at once on one
// inkVirtualWindow of 995 x 400, the size of this pack's `Car` item. That correlation is not
// proven causal. So the follow now runs on a later frame, and no caller flips a text widget
// within Open77PlateSettleFrames() of a vanilla toggle: Apply then answers 0 (retry), and Clear
// and the follow finish on a later frame.
//
// Contract for the C++ caller (a VehicleComponent method, like the paint functions):
//   Open77ApplyPlateText(text) -> Int32
//     1 written; 0 not ready, retry (vehicle not attached, or widget not spawned yet);
//     2 the widget has no text field (pack and script disagree: give up);
//     3 this appearance carries no plate components (give up: model or trim without a plate).
//     An empty text clears the plate and returns 1. Texts are cut to 16 characters.
//   Open77ClearPlateText() -> Bool
//     true when the car is back to factory, or never had plate components, or the switch-off
//     is put off to a later frame. Never false: Vehicles.cpp reads false as Unsupported and
//     stops, so a deferred clear must still answer true.
// Both are idempotent and cheap (a few component lookups by name and one string compare),
// so calling them on every reconciliation is fine. An appearance change rebuilds the
// components as authored (disabled): apply again after it.
//
// Rules kept here: nothing blocks the game thread (retries go through the DelaySystem);
// no Open77.rtti; no global state, only fields on the vehicle itself.

@addField(VehicleObject)
private let open77PlateText: String;

@addField(VehicleObject)
private let open77PlateActive: Bool;

// Bumped by each apply, clear and vanilla toggle: a pending push from before is dropped.
@addField(VehicleObject)
private let open77PlatePushSerial: Int32;

// Engine frame of the last vanilla SetInteriorUIEnabled on this car (0: none yet), and the
// serial of the deferred follow: only the newest scheduled follow runs.
@addField(VehicleObject)
private let open77PlateVanillaFrame: Uint64;

@addField(VehicleObject)
private let open77PlateFollowSerial: Int32;

// Diagnostics, shown by Open77PlateDebugState: text widget flips we made, and flips we put
// off because vanilla had just switched the car's UI.
@addField(VehicleObject)
private let open77PlateWidgetFlips: Uint32;

@addField(VehicleObject)
private let open77PlateFlipsDeferred: Uint32;

// Frames after a vanilla toggle during which our text widgets stay as vanilla left them.
public func Open77PlateSettleFrames() -> Uint64 {
  return Cast<Uint64>(2);
}

// The text field of each plate library this pack can reference, then the first inkText.
public func Open77PlateTextField(root: ref<inkWidget>) -> ref<inkText> {
  let compound: ref<inkCompoundWidget> = root as inkCompoundWidget;
  if !IsDefined(compound) {
    return root as inkText;
  }
  let known: array<CName> = [n"PlateText", n"StreetNameContainer/StreetName", n"default_ui/messege_text"];
  let i: Int32 = 0;
  while i < ArraySize(known) {
    let hit: ref<inkText> = compound.GetWidgetByPathName(known[i]) as inkText;
    if IsDefined(hit) {
      return hit;
    }
    i += 1;
  }
  return Open77PlateFirstTextField(root, 0);
}

public func Open77PlateFirstTextField(widget: ref<inkWidget>, depth: Int32) -> ref<inkText> {
  let text: ref<inkText> = widget as inkText;
  if IsDefined(text) {
    return text;
  }
  let compound: ref<inkCompoundWidget> = widget as inkCompoundWidget;
  if !IsDefined(compound) || depth > 6 {
    return null;
  }
  let i: Int32 = 0;
  let count: Int32 = compound.GetNumChildren();
  while i < count {
    let found: ref<inkText> = Open77PlateFirstTextField(compound.GetWidgetByIndex(i), depth + 1);
    if IsDefined(found) {
      return found;
    }
    i += 1;
  }
  return null;
}

public class Open77PlatePushJob extends DelayCallback {
  public let vehicle: wref<VehicleObject>;
  public let serial: Int32;
  public let attempt: Int32;
  public let confirm: Bool;

  public func Call() -> Void {
    let vehicle: ref<VehicleObject> = this.vehicle;
    if IsDefined(vehicle) {
      vehicle.Open77PlatePushStep(this.serial, this.attempt, this.confirm);
    }
  }
}

public class Open77PlateFollowJob extends DelayCallback {
  public let vehicle: wref<VehicleObject>;
  public let serial: Int32;

  public func Call() -> Void {
    let vehicle: ref<VehicleObject> = this.vehicle;
    if IsDefined(vehicle) {
      vehicle.Open77PlateFollowStep(this.serial);
    }
  }
}

@addMethod(VehicleObject)
public final func Open77PlateHasComponents() -> Bool {
  return IsDefined(this.FindComponentByName(n"open77_plate_text")) || IsDefined(this.FindComponentByName(n"open77_plate_text_f"));
}

// Missing components are fine: the mount and the front pair are optional.
// For the mesh components (mount, screens), which vanilla's UI toggle does not touch.
@addMethod(VehicleObject)
private final func Open77PlateToggle(name: CName, on: Bool) -> Void {
  let component: ref<IComponent> = this.FindComponentByName(name);
  if IsDefined(component) && component.IsEnabled() != on {
    component.Toggle(on);
  }
}

// Whether vanilla switched this car's UI components within the last few frames.
@addMethod(VehicleObject)
private final func Open77PlateVanillaSettling() -> Bool {
  if this.open77PlateVanillaFrame == Cast<Uint64>(0) {
    return false;
  }
  let frame: Uint64 = GameInstance.GetFrameNumber(this.GetGame());
  return frame <= this.open77PlateVanillaFrame + Open77PlateSettleFrames();
}

// For the text widgets (open77_plate_text[_f]). False when the flip is put off because
// vanilla has just switched them: the caller comes back on a later frame.
@addMethod(VehicleObject)
private final func Open77PlateToggleWidget(name: CName, on: Bool) -> Bool {
  let component: ref<IComponent> = this.FindComponentByName(name);
  if !IsDefined(component) || component.IsEnabled() == on {
    return true;
  }
  if this.Open77PlateVanillaSettling() {
    this.open77PlateFlipsDeferred += 1u;
    return false;
  }
  component.Toggle(on);
  this.open77PlateWidgetFlips += 1u;
  return true;
}

// 1 shows the text (or the component is absent), 0 the ink tree is not there yet,
// 2 the ink tree has no text field.
@addMethod(VehicleObject)
private final func Open77PlateWrite(name: CName, text: String) -> Int32 {
  let component: ref<IWorldWidgetComponent> = this.FindComponentByName(name) as IWorldWidgetComponent;
  if !IsDefined(component) {
    return 1;
  }
  let root: ref<inkWidget> = component.GetWidget();
  if !IsDefined(root) {
    return 0;
  }
  let field: ref<inkText> = Open77PlateTextField(root);
  if !IsDefined(field) {
    return 2;
  }
  if NotEquals(field.GetText(), text) {
    field.SetText(text);
  }
  return 1;
}

@addMethod(VehicleObject)
private final func Open77PlateWriteAll() -> Int32 {
  let rear: Int32 = this.Open77PlateWrite(n"open77_plate_text", this.open77PlateText);
  let front: Int32 = this.Open77PlateWrite(n"open77_plate_text_f", this.open77PlateText);
  if rear == 2 || front == 2 {
    return 2;
  }
  if rear == 0 || front == 0 {
    return 0;
  }
  return 1;
}

@addMethod(VehicleObject)
public final func Open77PlateApply(text: String) -> Int32 {
  if !this.Open77PlateHasComponents() {
    return 3;
  }
  if StrLen(text) == 0 {
    this.Open77PlateClear();
    return 1;
  }
  let value: String = text;
  if StrLen(value) > 16 {
    value = StrLeft(value, 16);
  }
  this.open77PlateText = value;
  this.open77PlateActive = true;
  this.open77PlatePushSerial += 1;
  // The quad first: the widget renders onto it (meshTargetBinding).
  this.Open77PlateToggle(n"open77_plate_mount", true);
  this.Open77PlateToggle(n"open77_plate_screen", true);
  this.Open77PlateToggle(n"open77_plate_screen_f", true);
  let rear: Bool = this.Open77PlateToggleWidget(n"open77_plate_text", true);
  let front: Bool = this.Open77PlateToggleWidget(n"open77_plate_text_f", true);
  if !rear || !front {
    // Vanilla has just switched the car's UI: not ready, the caller retries in 250 ms.
    return 0;
  }
  return this.Open77PlateWriteAll();
}

@addMethod(VehicleObject)
public final func Open77PlateClear() -> Bool {
  this.open77PlateActive = false;
  this.open77PlateText = "";
  this.open77PlatePushSerial += 1;
  let rear: Bool = this.Open77PlateToggleWidget(n"open77_plate_text", false);
  let front: Bool = this.Open77PlateToggleWidget(n"open77_plate_text_f", false);
  this.Open77PlateToggle(n"open77_plate_screen", false);
  this.Open77PlateToggle(n"open77_plate_screen_f", false);
  this.Open77PlateToggle(n"open77_plate_mount", false);
  if !rear || !front {
    // The C++ caller reads false as "no plate here" and stops: finish the switch-off on a
    // later frame instead (the follow turns the widgets to the plate state, now inactive).
    this.Open77PlateFollowLater(0.1);
  }
  return true;
}

@addMethod(VehicleObject)
private final func Open77PlatePushLater(serial: Int32, attempt: Int32, confirm: Bool, delay: Float) -> Void {
  let job: ref<Open77PlatePushJob> = new Open77PlatePushJob();
  job.vehicle = this;
  job.serial = serial;
  job.attempt = attempt;
  job.confirm = confirm;
  GameInstance.GetDelaySystem(this.GetGame()).DelayCallback(job, delay, false);
}

// Writes the stored text once the re-enabled widget has its ink tree (up to ~10 s), then
// checks once more a second later in case the tree was rebuilt after the first write.
@addMethod(VehicleObject)
public final func Open77PlatePushStep(serial: Int32, attempt: Int32, confirm: Bool) -> Void {
  if serial != this.open77PlatePushSerial || !this.open77PlateActive {
    return;
  }
  let result: Int32 = this.Open77PlateWriteAll();
  if result == 0 && attempt < 40 {
    this.Open77PlatePushLater(serial, attempt + 1, confirm, 0.25);
    return;
  }
  if result == 1 && !confirm {
    this.Open77PlatePushLater(serial, 0, true, 1.0);
  }
}

// After a vanilla toggle of all the vehicle's UI widgets: ours shows exactly when a plate
// text is set. A plate-less car (traffic, unowned) gets its widget switched off again, so
// mounting a car never spawns a hidden plate widget. Runs from Open77PlateFollowStep, on a
// later frame than the vanilla toggle; tries again while that toggle is still settling.
@addMethod(VehicleObject)
private final func Open77PlateFollowInteriorUI() -> Void {
  if !this.Open77PlateHasComponents() {
    return;
  }
  if this.open77PlateActive {
    this.Open77PlateToggle(n"open77_plate_screen", true);
    this.Open77PlateToggle(n"open77_plate_screen_f", true);
  }
  let rear: Bool = this.Open77PlateToggleWidget(n"open77_plate_text", this.open77PlateActive);
  let front: Bool = this.Open77PlateToggleWidget(n"open77_plate_text_f", this.open77PlateActive);
  if !rear || !front {
    this.Open77PlateFollowLater(0.1);
    return;
  }
  if this.open77PlateActive {
    this.open77PlatePushSerial += 1;
    this.Open77PlatePushLater(this.open77PlatePushSerial, 0, false, 0.1);
  }
}

@addMethod(VehicleObject)
private final func Open77PlateFollowLater(delay: Float) -> Void {
  this.open77PlateFollowSerial += 1;
  let job: ref<Open77PlateFollowJob> = new Open77PlateFollowJob();
  job.vehicle = this;
  job.serial = this.open77PlateFollowSerial;
  GameInstance.GetDelaySystem(this.GetGame()).DelayCallback(job, delay, false);
}

@addMethod(VehicleObject)
public final func Open77PlateFollowStep(serial: Int32) -> Void {
  if serial != this.open77PlateFollowSerial {
    return;
  }
  this.Open77PlateFollowInteriorUI();
}

@wrapMethod(VehicleObject)
private final func SetInteriorUIEnabled(enabled: Bool) -> Void {
  wrappedMethod(enabled);
  // Vanilla has just switched every UI component of the car, our text widgets included. Put
  // them back to the plate state on a later frame, never in this one (see the header).
  this.open77PlateVanillaFrame = GameInstance.GetFrameNumber(this.GetGame());
  if !this.Open77PlateHasComponents() {
    return;
  }
  // TempDisableUI sends true 0.6 s after its false; spawn, stream-in and unmount send false
  // alone. Coming back after 0.6 s spares one off/on of the widget per paint application.
  this.Open77PlateFollowLater(enabled ? 0.1 : 0.7);
}

// One component's state for the lab and diagnostics: on/off, and the text it shows.
@addMethod(VehicleObject)
private final func Open77PlateDescribe(screen: CName, text: CName) -> String {
  let quad: ref<IComponent> = this.FindComponentByName(screen);
  let widget: ref<IWorldWidgetComponent> = this.FindComponentByName(text) as IWorldWidgetComponent;
  if !IsDefined(quad) && !IsDefined(widget) {
    return "absent";
  }
  let out: String = "screen=" + (IsDefined(quad) ? (quad.IsEnabled() ? "on" : "off") : "absent");
  if !IsDefined(widget) {
    return out + ",text=absent";
  }
  out += ",text=" + (widget.IsEnabled() ? "on" : "off");
  let root: ref<inkWidget> = widget.GetWidget();
  if !IsDefined(root) {
    return out + ",ink=none";
  }
  let field: ref<inkText> = Open77PlateTextField(root);
  if !IsDefined(field) {
    return out + ",ink=no-text-field";
  }
  return out + ",shows=\"" + field.GetText() + "\"";
}

@addMethod(VehicleObject)
public final func Open77PlateDebugState() -> String {
  if !this.Open77PlateHasComponents() {
    return "none";
  }
  let mount: ref<IComponent> = this.FindComponentByName(n"open77_plate_mount");
  return "active=" + ToString(this.open77PlateActive) + "|text=\"" + this.open77PlateText + "\""
    + "|rear=" + this.Open77PlateDescribe(n"open77_plate_screen", n"open77_plate_text")
    + "|front=" + this.Open77PlateDescribe(n"open77_plate_screen_f", n"open77_plate_text_f")
    + "|mount=" + (IsDefined(mount) ? (mount.IsEnabled() ? "on" : "off") : "absent")
    + "|flips=" + ToString(this.open77PlateWidgetFlips)
    + "|deferred=" + ToString(this.open77PlateFlipsDeferred);
}

@addMethod(VehicleComponent)
public final func Open77ApplyPlateText(text: String) -> Int32 {
  let vehicle: ref<VehicleObject> = this.GetVehicle();
  if !IsDefined(vehicle) {
    return 0;
  }
  return vehicle.Open77PlateApply(text);
}

@addMethod(VehicleComponent)
public final func Open77ClearPlateText() -> Bool {
  let vehicle: ref<VehicleObject> = this.GetVehicle();
  if !IsDefined(vehicle) {
    return false;
  }
  return vehicle.Open77PlateClear();
}

@addMethod(VehicleComponent)
public final func Open77PlateDebugState() -> String {
  let vehicle: ref<VehicleObject> = this.GetVehicle();
  if !IsDefined(vehicle) {
    return "detached";
  }
  return vehicle.Open77PlateDebugState();
}
