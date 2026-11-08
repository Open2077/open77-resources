-- Guided setup shares the pause menu's settings/KVP owner. A short renewable
-- lease prevents a closed/crashed consumer from leaving local loopback running.
Open77VoiceSetup = {}
function Open77VoiceSetup.install(api)
    local lease, devices
    local function stop()
        if not lease then return true end
        local old=lease; lease=nil
        Open77.voice.setMicrophoneTest(false)
        Open77.voice.setVoiceActivation(old.activation,old.threshold)
        return true
    end
    local function snapshot()
        local s,why=Open77.voice.status()
        if not s then return nil,why end
        return {available=s.available==true,captureEnabled=s.captureEnabled==true,
            inputDevice=s.inputDevice or "",outputDevice=s.outputDevice or "",inputVolume=s.inputVolume or 1,outputVolume=s.outputVolume or 1,
            activation=lease and lease.activation or (not lease and s.voiceActivation==true),threshold=lease and lease.threshold or s.voiceActivationThreshold or .25,
            level=s.inputLevel or 0,transmitting=s.transmitting==true,testing=s.microphoneTest==true,captureState=s.captureState,
            key=api.key(),configured=Open77.kvp.get("voice.setupComplete",false)==true,
            inputs=devices and devices.input or {},outputs=devices and devices.output or {},
            distance=s.proximityDistance or 20}
    end
    exports("voiceSetup",function(operation,payload)
        local owner=GetInvokingResource()
        if type(owner)~="string" or owner=="" then return nil,"export_call_required" end
        if operation=="end" then if lease and lease.owner==owner then stop() end; return true end
        if operation=="begin" then
            if lease and lease.owner~=owner then return nil,"voice_setup_busy" end
            if not lease then
                local s=Open77.voice.status()
                if not s then return nil,"voice_unavailable" end
                lease={owner=owner,activation=s.voiceActivation==true,threshold=s.voiceActivationThreshold or .25}
                Open77.voice.setVoiceActivation(false,lease.threshold)
                Open77.voice.setTransmitting(false)
            end
            devices=api.devices()
        end
        if not lease or lease.owner~=owner then return nil,"voice_setup_closed" end
        lease.untilTime=Open77.time.monotonic()+3
        if operation=="refresh" then devices=api.devices()
        elseif operation=="set" then
            if type(payload)~="table" then return nil,"invalid_voice_setting" end
            local name,value=payload.name,payload.value
            local numeric={InputVolume=200,OutputVolume=200,VoiceActivationThreshold=100,CaptureEnabled=1,VoiceActivation=1}
            if numeric[name] then
                if type(value)~="number" or value~=value or value<0 or value>numeric[name] then return nil,"invalid_voice_value" end
                if (name=="CaptureEnabled" or name=="VoiceActivation") and value~=0 and value~=1 then return nil,"invalid_voice_value" end
            elseif name=="InputDevice" or name=="OutputDevice" then
                if type(value)~="string" then return nil,"invalid_voice_device" end
            elseif name=="PushToTalkKey" then
                if type(value)~="string" or #value>20 then return nil,"invalid_voice_key" end
            else return nil,"unknown_voice_setting" end
            local ok,why=api.set(name,value)
            Open77.voice.setVoiceActivation(false,lease.threshold)
            if not ok then return nil,why end
            if name=="VoiceActivation" then lease.activation=value==1 end
            if name=="VoiceActivationThreshold" then lease.threshold=value/100 end
            if name=="InputDevice" then Open77.voice.setMicrophoneTest(false) end
            Open77.voice.setVoiceActivation(false,lease.threshold)
        elseif operation=="test" then
            local on=payload==true
            if on then
                local s=Open77.voice.status()
                if not s or not s.captureEnabled then return nil,"Enable your microphone before testing." end
            end
            local ok,why=Open77.voice.setMicrophoneTest(on)
            if not ok then return nil,why end
        elseif operation=="complete" then
            local ok,why=api.persist("voice.setupComplete",true)
            if not ok then return nil,why end
            stop(); return true
        elseif operation~="begin" and operation~="status" and operation~="refresh" then return nil,"unknown_voice_operation" end
        return snapshot()
    end)
    CreateThread(function()
        while true do
            Wait(500)
            if lease and (not lease.untilTime or Open77.time.monotonic()>lease.untilTime) then stop() end
        end
    end)
    AddEventHandler("onClientResourceStop",function(name)
        if lease and (name==lease.owner or name==GetCurrentResourceName()) then stop() end
    end)
end
