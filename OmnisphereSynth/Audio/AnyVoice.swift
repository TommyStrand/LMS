import Foundation

protocol AnyVoice: AnyObject {
    var filterCutoffMod: Float { get set }
    var lfoDepthMod: Float { get set }
    var isFinished: Bool { get }
    func start()
    func release()
    func nextSample() -> Float
}
