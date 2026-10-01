import Foundation
import AVFAudio
import Darwin
import Dispatch

@main struct SoakRunner {
    static func main() {
        DispatchQueue.global(qos: .userInitiated).async {
            do { try run(); exit(0) }
            catch { fputs("SOAK_FAILED: \(error.localizedDescription)\n",stderr); exit(1) }
        }
        dispatchMain()
    }
    static func usage() -> (Double,Int64) {
        var r=rusage();getrusage(RUSAGE_SELF,&r)
        let cpu=Double(r.ru_utime.tv_sec+r.ru_stime.tv_sec)+Double(r.ru_utime.tv_usec+r.ru_stime.tv_usec)*1e-6
        return (cpu,Int64(r.ru_maxrss)) // macOS bytes, peak RSS; not current heap size.
    }
    static func run() throws {
        let duration=Double(CommandLine.arguments.dropFirst().first ?? "3600") ?? 3600
        guard duration.isFinite && duration>=10 && duration<=86400 else { throw AudioFailure(stage:"Soak duration",status:nil,advice:"Use 10 to 86400 seconds.") }
        let rate=48000.0
        let f=AudioStreamBasicDescription(mSampleRate:rate,mFormatID:kAudioFormatLinearPCM,mFormatFlags:kAudioFormatFlagIsFloat|kAudioFormatFlagIsPacked,mBytesPerPacket:8,mFramesPerPacket:1,mBytesPerFrame:8,mChannelsPerFrame:2,mBitsPerChannel:32,mReserved:0)
        guard let bridge=cvp_bridge_create(f,16096,1920,5760) else { throw AudioFailure(stage:"Soak bridge",status:nil,advice:"Allocation failed.") }
        let engine=AVAudioEngine(),effects=try EffectsFactory.make()
        let format=AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:rate,channels:2,interleaved:false)!
        let source=AVAudioSourceNode(format:format) { silent,_,frames,output in
            var empty=true;let status=cvp_bridge_render(bridge,frames,output,&empty);silent.pointee=ObjCBool(empty);return status
        }
        engine.attach(source);engine.attach(effects)
        var settings=EffectSettings();settings.pitchEnabled=true;settings.pitch=3;settings.preserveVocalShape=true;settings.formantEnabled=true;settings.formant=2;settings.eqEnabled=true;settings.mid=3;settings.compressorEnabled=true;settings.volume=0.8
        let unit=effects.auAudioUnit as! DVCEffectsAudioUnit;unit.apply(settings.parameters)
        engine.connect(source,to:effects,format:format);engine.connect(effects,to:engine.mainMixerNode,format:format)
        try engine.enableManualRenderingMode(.offline,format:format,maximumFrameCount:512)
        engine.prepare();try engine.start()
        guard let producer=dvc_soak_feed_start(bridge,rate) else { throw AudioFailure(stage:"Soak producer",status:nil,advice:"Thread startup failed.") }
        defer { engine.stop();dvc_soak_feed_stop(producer);cvp_bridge_destroy(bridge) }
        let output=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:512)!
        let began=ProcessInfo.processInfo.systemUptime,initial=usage()
        var frames:UInt64=0,nextReport=0.0,maximumQueue:UInt32=0,slowBlocks=0,retries=0
        var baseline:CVPStats?,failed=false
        print("SOAK_STARTED core=signalsmith_80ms pitch=3 formant=2 preserve_shape=true EQ_mid_db=3 compressor=true synthetic_only=true hardware_output=false capture_clock_ppm=150 target_seconds=\(duration)")
        fflush(stdout)
        while ProcessInfo.processInfo.systemUptime-began<duration {
            let before=ProcessInfo.processInfo.systemUptime
            let status=try engine.renderOffline(512,to:output)
            if status == .cannotDoInCurrentContext { retries+=1; if retries>100 {throw AudioFailure(stage:"Soak rendering",status:nil,advice:"Render stalled.")};continue }
            guard status == .success || status == .insufficientDataFromInputNode else {throw AudioFailure(stage:"Soak rendering",status:nil,advice:"Render failed.")}
            retries=0
            if ProcessInfo.processInfo.systemUptime-before>512/rate { slowBlocks+=1 }
            for c in 0..<2 { for i in 0..<Int(output.frameLength) {let v=output.floatChannelData![c][i];if !v.isFinite || abs(v)>0.981 {failed=true} } }
            frames+=512
            let s=cvp_bridge_stats(bridge),elapsed=ProcessInfo.processInfo.systemUptime-began
            maximumQueue=max(maximumQueue,s.queued_frames)
            if baseline == nil && elapsed>=5 { baseline=s }
            if elapsed>=nextReport {
                let u=usage(),d=unit.statistics()
                print(String(format:"SOAK elapsed=%.1f CPU_percent=%.2f peak_RSS_bytes=%lld queue=%u max_queue=%u underflows=%llu overflows=%llu resets=%llu invalid=%llu slow_blocks=%d",elapsed,(u.0-initial.0)/max(0.001,elapsed)*100,u.1,s.queued_frames,maximumQueue,s.underflows,s.overflows,s.backlog_resets,d.nonfinite_samples,slowBlocks));fflush(stdout)
                nextReport+=30
            }
            let wait=began+Double(frames)/rate-ProcessInfo.processInfo.systemUptime
            if wait>0 { Thread.sleep(forTimeInterval:wait) }
        }
        let s=cvp_bridge_stats(bridge),d=unit.statistics(),base=baseline ?? CVPStats()
        let steadyUnderflows=s.underflows-base.underflows,steadyOverflows=s.overflows-base.overflows,steadyResets=s.backlog_resets-base.backlog_resets
        print("SOAK_FINISHED seconds=\(ProcessInfo.processInfo.systemUptime-began) steady_underflows=\(steadyUnderflows) steady_overflows=\(steadyOverflows) steady_resets=\(steadyResets) format_errors=\(s.format_errors) dsp_invalid=\(d.nonfinite_samples)")
        guard !failed,s.format_errors==0,d.nonfinite_samples==0,steadyUnderflows==0,steadyOverflows==0,steadyResets==0 else {throw AudioFailure(stage:"Soak acceptance",status:nil,advice:"A steady-state dropout, overflow, backlog reset, or invalid sample occurred. This is not a pass.")}
        print("SOAK_PASS software_paced_only=true physical_device_tests_still_required=true");fflush(stdout)
    }
}
