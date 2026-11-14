import AppKit
import ImageIO

/// System-wide metadata, including browser video. Adapter: ungive/mediaremote-adapter,
/// BSD-3-Clause; source and licence are bundled under Vendor and Resources/mediaremote.
final class SystemMediaStream {
    static let shared=SystemMediaStream()
    private var process:Process?
    private var lifeline:Pipe?
    private var buffer=Data()
    private var state:[String:Any]=[:]
    private var failures=0
    private var startedAt=Date()
    private var stamp=Date()
    private var cachedArtwork:NSImage?
    private var value:NowPlaying?
    var onUpdate:((NowPlaying?)->Void)?
    var running:Bool {process?.isRunning == true}
    private var resources:URL? {Bundle.main.resourceURL?.appendingPathComponent("mediaremote")}
    var current:NowPlaying? {
        guard var value else{return nil}
        if value.playing {value.elapsed += max(0,Date().timeIntervalSince(stamp))}
        return value
    }
    func start() {
        guard process == nil,failures<3,let resources else{return}
        let script=resources.appendingPathComponent("mediaremote-adapter.pl").path
        let framework=resources.appendingPathComponent("MediaRemoteAdapter.framework").path
        guard FileManager.default.fileExists(atPath:script) else{return}
        let proc=Process(),out=Pipe(),life=Pipe()
        proc.executableURL=URL(fileURLWithPath:"/bin/sh")
        // Closing the parent's pipe terminates the helper even after an app crash.
        proc.arguments=["-c","exec 3<&0; /usr/bin/perl \"$@\" </dev/null & p=$!; (read _ <&3; kill $p 2>/dev/null) & trap 'kill $p 2>/dev/null; exit 0' TERM; wait $p","notchdeck-media",script,framework,"stream","--micros","--debounce=100"]
        proc.standardInput=life;proc.standardOutput=out;proc.standardError=FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data=handle.availableData
            if data.isEmpty {handle.readabilityHandler=nil;return}
            DispatchQueue.main.async {self?.ingest(data)}
        }
        proc.terminationHandler = { [weak self] _ in DispatchQueue.main.async {
            guard let self else{return};self.process=nil;self.lifeline=nil;self.value=nil
            if Date().timeIntervalSince(self.startedAt)<5 {self.failures+=1}
            self.onUpdate?(nil)
            DispatchQueue.main.asyncAfter(deadline:.now()+3) {self.start()}
        }}
        do {try proc.run();process=proc;lifeline=life;startedAt=Date()}
        catch {failures+=1;Dbg.log("system media unavailable: \(error.localizedDescription)")}
    }
    private func ingest(_ data:Data) {
        buffer.append(data)
        while let newline=buffer.firstIndex(of:10) {
            let line=Data(buffer[..<newline]);buffer.removeSubrange(...newline)
            guard let json=try? JSONSerialization.jsonObject(with:line) as? [String:Any],
                  let payload=json["payload"] as? [String:Any] else {continue}
            if json["diff"] as? Bool == true {
                for (key,value) in payload {if value is NSNull {state.removeValue(forKey:key)} else {state[key]=value}}
            } else {state=payload}
            if payload.keys.contains("artworkData") || json["diff"] as? Bool != true {
                cachedArtwork=Self.artwork(from:state["artworkData"] as? String)
            }
            value=Self.decode(state,includeArtwork:false)
            value?.artwork=cachedArtwork
            stamp=Date();onUpdate?(value)
        }
        if buffer.count>8_000_000 {buffer.removeAll()}
    }
    static func decode(_ state:[String:Any],includeArtwork:Bool=true)->NowPlaying? {
        guard let title=state["title"] as? String,!title.isEmpty else{return nil}
        return NowPlaying(title:title,artist:state["artist"] as? String ?? "",
            duration:(state["durationMicros"] as? Double ?? 0)/1_000_000,
            elapsed:(state["elapsedTimeNowMicros"] as? Double ?? state["elapsedTimeMicros"] as? Double ?? 0)/1_000_000,
            playing:state["playing"] as? Bool ?? false,source:"system",
            artwork:includeArtwork ? artwork(from:state["artworkData"] as? String):nil,
            sourceBundleID:state["parentApplicationBundleIdentifier"] as? String ?? state["bundleIdentifier"] as? String)
    }
    static func artwork(from base64:String?)->NSImage? {
        guard let base64,base64.utf8.count<=8_000_000,
              let data=Data(base64Encoded:base64,options:.ignoreUnknownCharacters),
              let source=CGImageSourceCreateWithData(data as CFData,nil),
              let thumbnail=CGImageSourceCreateThumbnailAtIndex(source,0,[
                kCGImageSourceCreateThumbnailFromImageAlways:true,
                kCGImageSourceThumbnailMaxPixelSize:96,
                kCGImageSourceCreateThumbnailWithTransform:true
              ] as CFDictionary) else{return nil}
        return NSImage(cgImage:thumbnail,size:NSSize(width:48,height:48))
    }
    func seek(to seconds:Double) {
        guard let resources else{return}
        let proc=Process();proc.executableURL=URL(fileURLWithPath:"/usr/bin/perl")
        proc.arguments=[resources.appendingPathComponent("mediaremote-adapter.pl").path,
            resources.appendingPathComponent("MediaRemoteAdapter.framework").path,"seek",String(Int64(seconds*1_000_000))]
        proc.standardOutput=FileHandle.nullDevice;proc.standardError=FileHandle.nullDevice;try? proc.run()
    }
    func stop() {
        process?.terminationHandler=nil
        lifeline?.fileHandleForWriting.closeFile();lifeline=nil
        process?.terminate();process=nil
    }
}
