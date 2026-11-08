// LAB ONLY. Open77 plate pack, lab trigger for the production plate script
// client/redscript/Open77VehiclePlate.reds. Never part of a release or of a preload_mod (.reds
// is an executable extension): installed by hand under r6/scripts/Open77Lab/ on each isolated
// test client and removed after the session.
//
// The production C++ caller does not exist yet. This file stands in for it: it calls
// VehicleComponent.Open77ApplyPlateText / Open77ClearPlateText exactly as the caller will
// (retry every 0.25 s while the result is 0, for up to 20 s; stop on 1, 2 or 3), then reads
// the state back at 1 s and 6 s.
//
// Trigger: the server's Open77.vehicles.setPaint(id, { primary = "#040507", secondary = {...} }),
// sent by the lab resource (lab/plates_server.lua). Paint replicates to every viewer and late
// joiner, so it is also a two-client transport. Primary 4,5,7 is the magic and is swallowed
// (the car keeps its real paint, and vanilla TempDisableUI does not run). Sub-agent H's E0.7
// trigger uses #040506: both files can be installed together.
//   secondary (a, b, c), each < 38   text "OP77-" + ALPHABET[a] + ALPHABET[b] + ALPHABET[c]
//   secondary (255, 255, 255)        clear the plate
//   secondary (254, 254, 254)        log the plate state only
// Results go to the Open77 client log through Open77PlayerResetTrace, lines "vplate77 ...".

public func Open77PlateLab2Char(index: Int32) -> String {
  let alphabet: array<String> = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
    "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q",
    "R", "S", "T", "U", "V", "W", "X", "Y", "Z", " ", "-"];
  if index < 0 || index >= ArraySize(alphabet) {
    return "?";
  }
  return alphabet[index];
}

public class Open77PlateLab2Job extends DelayCallback {
  public let vehicle: wref<VehicleObject>;
  // 0 apply/clear/state, 1 read back after 1 s, 2 read back after 6 s.
  public let phase: Int32;
  public let mode: Int32;             // 0 apply, 1 clear, 2 state only
  public let text: String;
  public let attempt: Int32;

  public func Call() -> Void {
    this.Step();
  }

  public final func Next(phase: Int32, attempt: Int32, delay: Float) -> Void {
    let vehicle: ref<VehicleObject> = this.vehicle;
    if !IsDefined(vehicle) {
      return;
    }
    let next: ref<Open77PlateLab2Job> = new Open77PlateLab2Job();
    next.vehicle = this.vehicle;
    next.phase = phase;
    next.mode = this.mode;
    next.text = this.text;
    next.attempt = attempt;
    GameInstance.GetDelaySystem(vehicle.GetGame()).DelayCallback(next, delay, false);
  }

  public final func Step() -> Void {
    let vehicle: ref<VehicleObject> = this.vehicle;
    if !IsDefined(vehicle) {
      Open77PlayerResetTrace("vplate77 vehicle gone phase=" + ToString(this.phase));
      return;
    }
    let component: ref<VehicleComponent> = vehicle.GetVehicleComponent();
    let where: String = "app=" + NameToString(vehicle.GetCurrentAppearanceName()) + " phase=" + ToString(this.phase);
    if !IsDefined(component) {
      Open77PlayerResetTrace("vplate77 FAIL " + where + " no VehicleComponent");
      return;
    }
    if this.phase > 0 {
      Open77PlayerResetTrace("vplate77 readback " + where + " expected=\"" + this.text + "\" state=" + component.Open77PlateDebugState());
      if this.phase == 1 {
        this.Next(2, 0, 5.0);
      }
      return;
    }
    if this.mode == 2 {
      Open77PlayerResetTrace("vplate77 state " + where + " " + component.Open77PlateDebugState());
      return;
    }
    if this.mode == 1 {
      let cleared: Bool = component.Open77ClearPlateText();
      Open77PlayerResetTrace("vplate77 clear " + where + " result=" + ToString(cleared) + " state=" + component.Open77PlateDebugState());
      this.Next(1, 0, 1.0);
      return;
    }
    let result: Int32 = component.Open77ApplyPlateText(this.text);
    if result == 0 && this.attempt < 80 {
      this.Next(0, this.attempt + 1, 0.25);
      return;
    }
    Open77PlayerResetTrace("vplate77 apply " + where + " text=\"" + this.text + "\" result=" + ToString(result) + " tries=" + ToString(this.attempt)
      + " state=" + component.Open77PlateDebugState());
    if result == 1 {
      this.Next(1, 0, 1.0);
    }
  }
}

@wrapMethod(VehicleComponent)
public final func ApplyVehicleVisualCustomizationTemplate(template: VehicleVisualCustomizationTemplate, isInstant: Bool) -> Void {
  if template.hasUniqueTemplate || Cast<Int32>(template.genericData.primaryColorR) != 4
      || Cast<Int32>(template.genericData.primaryColorG) != 5 || Cast<Int32>(template.genericData.primaryColorB) != 7 {
    wrappedMethod(template, isInstant);
    return;
  }
  let a: Int32 = Cast<Int32>(template.genericData.secondaryColorR);
  let b: Int32 = Cast<Int32>(template.genericData.secondaryColorG);
  let c: Int32 = Cast<Int32>(template.genericData.secondaryColorB);
  let job: ref<Open77PlateLab2Job> = new Open77PlateLab2Job();
  job.vehicle = this.GetVehicle();
  if a == 255 && b == 255 && c == 255 {
    job.mode = 1;
  } else {
    if a == 254 && b == 254 && c == 254 {
      job.mode = 2;
    } else {
      job.text = "OP77-" + Open77PlateLab2Char(a) + Open77PlateLab2Char(b) + Open77PlateLab2Char(c);
    }
  }
  Open77PlayerResetTrace("vplate77 request mode=" + ToString(job.mode) + " text=\"" + job.text + "\"");
  job.Step();
}
