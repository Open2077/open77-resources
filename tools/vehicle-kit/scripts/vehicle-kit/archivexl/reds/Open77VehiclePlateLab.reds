// Open77 vehicle-customization laboratory, experiment E0.7 route W (plate text).
// LAB ONLY: never part of a release, never shipped inside a preload_mod (.reds is
// an executable extension). Installed by hand under r6/scripts/Open77Lab/ on each
// isolated test client and removed after the session.
//
// What it answers: once the open77_vehicle_plate_test archive has added a
// WorldWidgetComponent named open77_plate_text to the Galena (appearances
// open77_e07_plate, open77_e07_plate_flip, open77_e07_plate_lcd), can a script
// reach its inkTextWidget, SetText on it, and does the text stay?
//
// Trigger: the server's Open77.vehicles.setPaint(id, { primary = "#040506",
// secondary = { r = a, g = b, b = c } }), sent by /vplate.text of the lab
// resource. Primary 4,5,6 is the magic and is swallowed (the car keeps its real
// paint); a, b, c index ALPHABET and the text becomes "OP77-" + three chars.
// Secondary 255,255,255 only describes the widget tree. Paint replicates to every
// viewer and to late joiners, so this is also a two-client transport for the lab.
// Results go to the Open77 client log through Open77PlayerResetTrace ("vplate ...").
//
// Why a wrap and not functions called through Open77.rtti: every scripted
// function with parameters entered through Open77.rtti.call crashed the client
// (see tools/vehicle-customization-lab/reds/Open77VehicleCustomizationLab.reds).

public func Open77PlateLabChar(index: Int32) -> String {
  let alphabet: array<String> = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
    "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q",
    "R", "S", "T", "U", "V", "W", "X", "Y", "Z", " ", "-"];
  if index < 0 || index >= ArraySize(alphabet) {
    return "?";
  }
  return alphabet[index];
}

// The known text widget of each candidate library, then the first inkText found.
public func Open77PlateLabFindText(root: ref<inkWidget>) -> ref<inkText> {
  let compound: ref<inkCompoundWidget> = root as inkCompoundWidget;
  if !IsDefined(compound) {
    return root as inkText;
  }
  let known: array<CName> = [n"StreetNameContainer/StreetName", n"default_ui/messege_text", n"Content/Texts/Texts/MainText"];
  let i: Int32 = 0;
  while i < ArraySize(known) {
    let hit: ref<inkText> = compound.GetWidgetByPathName(known[i]) as inkText;
    if IsDefined(hit) {
      return hit;
    }
    i += 1;
  }
  return Open77PlateLabFirstText(root, 0);
}

public func Open77PlateLabFirstText(widget: ref<inkWidget>, depth: Int32) -> ref<inkText> {
  let text: ref<inkText> = widget as inkText;
  if IsDefined(text) {
    return text;
  }
  let compound: ref<inkCompoundWidget> = widget as inkCompoundWidget;
  if !IsDefined(compound) || depth > 8 {
    return null;
  }
  let i: Int32 = 0;
  let count: Int32 = compound.GetNumChildren();
  while i < count {
    let child: ref<inkWidget> = compound.GetWidgetByIndex(i);
    if IsDefined(child) {
      let found: ref<inkText> = Open77PlateLabFirstText(child, depth + 1);
      if IsDefined(found) {
        return found;
      }
    }
    i += 1;
  }
  return null;
}

// name<class>{logic controller} ="text" for each widget, depth-first, bounded.
public func Open77PlateLabTree(widget: ref<inkWidget>, depth: Int32) -> String {
  if !IsDefined(widget) {
    return "";
  }
  let out: String = " " + ToString(depth) + ":" + NameToString(widget.GetName()) + "<" + NameToString(widget.GetClassName()) + ">";
  let controller: ref<inkLogicController> = widget.GetController();
  if IsDefined(controller) {
    out += "{" + NameToString(controller.GetClassName()) + "}";
  }
  let text: ref<inkText> = widget as inkText;
  if IsDefined(text) {
    out += "=\"" + text.GetText() + "\"";
  }
  let compound: ref<inkCompoundWidget> = widget as inkCompoundWidget;
  if IsDefined(compound) && depth < 6 {
    let i: Int32 = 0;
    let count: Int32 = compound.GetNumChildren();
    while i < count && StrLen(out) < 1500 {
      let child: ref<inkWidget> = compound.GetWidgetByIndex(i);
      out += Open77PlateLabTree(child, depth + 1);
      i += 1;
    }
  }
  return out;
}

public class Open77PlateLabJob extends DelayCallback {
  public let vehicle: wref<VehicleObject>;
  public let text: String;
  public let describe: Bool;
  // 0 = find the widget and write, 1 = first read back, 2 = second read back.
  public let phase: Int32;
  public let attempt: Int32;
  public let written: wref<inkText>;

  public func Call() -> Void {
    this.Step();
  }

  public final func Next(phase: Int32, attempt: Int32, delay: Float) -> Void {
    let vehicle: ref<VehicleObject> = this.vehicle;
    if !IsDefined(vehicle) {
      return;
    }
    let next: ref<Open77PlateLabJob> = new Open77PlateLabJob();
    next.vehicle = this.vehicle;
    next.text = this.text;
    next.describe = this.describe;
    next.phase = phase;
    next.attempt = attempt;
    next.written = this.written;
    GameInstance.GetDelaySystem(vehicle.GetGame()).DelayCallback(next, delay, false);
  }

  public final func Step() -> Void {
    let vehicle: ref<VehicleObject> = this.vehicle;
    if !IsDefined(vehicle) {
      Open77PlayerResetTrace("vplate vehicle gone phase=" + ToString(this.phase));
      return;
    }
    let where: String = "app=" + NameToString(vehicle.GetCurrentAppearanceName()) + " phase=" + ToString(this.phase);
    let component: ref<IWorldWidgetComponent> = vehicle.FindComponentByName(n"open77_plate_text") as IWorldWidgetComponent;
    let root: ref<inkWidget>;
    if IsDefined(component) {
      root = component.GetWidget();
    }
    if !IsDefined(root) {
      // The widget spawns after the component, and again after each appearance
      // change: wait up to 20 s for it.
      if this.attempt < 80 {
        this.Next(this.phase, this.attempt + 1, 0.25);
        return;
      }
      Open77PlayerResetTrace("vplate FAIL " + where + " component=" + ToString(IsDefined(component)) + " widget=none tries=" + ToString(this.attempt));
      return;
    }
    if this.describe {
      Open77PlayerResetTrace("vplate tree " + where + " tries=" + ToString(this.attempt) + Open77PlateLabTree(root, 0));
      return;
    }
    let text: ref<inkText> = Open77PlateLabFindText(root);
    if !IsDefined(text) {
      Open77PlayerResetTrace("vplate FAIL " + where + " no inkText under the widget;" + Open77PlateLabTree(root, 0));
      return;
    }
    if this.phase == 0 {
      let before: String = text.GetText();
      text.SetText(this.text);
      this.written = text;
      Open77PlayerResetTrace("vplate set " + where + " tries=" + ToString(this.attempt) + " widget=" + NameToString(text.GetName())
        + " before=\"" + before + "\" after=\"" + text.GetText() + "\"");
      this.Next(1, 0, 1.0);
      return;
    }
    let now: String = text.GetText();
    let written: ref<inkText> = this.written;
    Open77PlayerResetTrace("vplate readback " + where + " expected=\"" + this.text + "\" now=\"" + now + "\" kept="
      + ToString(Equals(now, this.text)) + " sameWidget=" + ToString(text == written));
    if this.phase == 1 {
      this.Next(2, 0, 5.0);
    }
  }
}

@wrapMethod(VehicleComponent)
public final func ApplyVehicleVisualCustomizationTemplate(template: VehicleVisualCustomizationTemplate, isInstant: Bool) -> Void {
  if template.hasUniqueTemplate || Cast<Int32>(template.genericData.primaryColorR) != 4
      || Cast<Int32>(template.genericData.primaryColorG) != 5 || Cast<Int32>(template.genericData.primaryColorB) != 6 {
    wrappedMethod(template, isInstant);
    return;
  }
  let a: Int32 = Cast<Int32>(template.genericData.secondaryColorR);
  let b: Int32 = Cast<Int32>(template.genericData.secondaryColorG);
  let c: Int32 = Cast<Int32>(template.genericData.secondaryColorB);
  let job: ref<Open77PlateLabJob> = new Open77PlateLabJob();
  job.vehicle = this.GetVehicle();
  job.describe = a == 255 && b == 255 && c == 255;
  job.text = "OP77-" + Open77PlateLabChar(a) + Open77PlateLabChar(b) + Open77PlateLabChar(c);
  Open77PlayerResetTrace("vplate request text=\"" + job.text + "\" describe=" + ToString(job.describe));
  job.Step();
}
