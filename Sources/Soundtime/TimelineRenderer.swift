import MetalKit
import simd

final class TimelineRenderer: NSObject, MTKViewDelegate {
    private struct TimelineVertex {
        var position: SIMD4<Float>
        var color: SIMD4<Float>
    }

    private enum RendererError: Error {
        case commandQueueUnavailable
        case shaderFunctionUnavailable
    }

    private static let inlineVertexUploadLimit = 4 * 1_024

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private var waveformOverview: WaveformOverview?

    init(device: MTLDevice, pixelFormat: MTLPixelFormat) throws {
        guard let commandQueue = device.makeCommandQueue() else {
            throw RendererError.commandQueueUnavailable
        }

        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        guard
            let vertexFunction = library.makeFunction(name: "timeline_vertex"),
            let fragmentFunction = library.makeFunction(name: "timeline_fragment")
        else {
            throw RendererError.shaderFunctionUnavailable
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = pixelFormat

        self.device = device
        self.commandQueue = commandQueue
        pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)

        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func displayWaveform(_ waveformOverview: WaveformOverview?) {
        self.waveformOverview = waveformOverview
    }

    func draw(in view: MTKView) {
        guard
            let renderPassDescriptor = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable,
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        else {
            return
        }

        let drawableSize = view.drawableSize
        let backingScale = backingScale(for: view)
        let gridVertices = makeGridVertices(drawableSize: drawableSize, backingScale: backingScale)
        let waveformVertices = makeWaveformVertices(
            drawableSize: drawableSize,
            backingScale: backingScale
        )
        let playheadVertices = makePlayheadVertices(drawableSize: drawableSize, backingScale: backingScale)

        encoder.setRenderPipelineState(pipelineState)
        draw(vertices: gridVertices, primitiveType: .line, encoder: encoder)
        draw(vertices: waveformVertices, primitiveType: .triangle, encoder: encoder)
        draw(vertices: playheadVertices, primitiveType: .triangle, encoder: encoder)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func draw(
        vertices: [TimelineVertex],
        primitiveType: MTLPrimitiveType,
        encoder: MTLRenderCommandEncoder
    ) {
        guard !vertices.isEmpty else {
            return
        }

        vertices.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return
            }

            if buffer.count <= Self.inlineVertexUploadLimit {
                encoder.setVertexBytes(baseAddress, length: buffer.count, index: 0)
            } else {
                guard let vertexBuffer = device.makeBuffer(
                    bytes: baseAddress,
                    length: buffer.count,
                    options: [.storageModeShared]
                ) else {
                    return
                }

                encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            }

            encoder.drawPrimitives(type: primitiveType, vertexStart: 0, vertexCount: vertices.count)
        }
    }

    private func makeGridVertices(drawableSize: CGSize, backingScale: Float) -> [TimelineVertex] {
        let width = Float(drawableSize.width)
        let height = Float(drawableSize.height)
        guard width > 0, height > 0 else {
            return []
        }

        let gridColor = SIMD4<Float>(0.24, 0.25, 0.26, 1.0)
        let centerColor = SIMD4<Float>(0.34, 0.36, 0.37, 1.0)
        let majorStep = max(96 * backingScale, 1)
        var vertices: [TimelineVertex] = []

        var x: Float = 0.5
        while x <= width {
            appendLine(
                to: &vertices,
                from: SIMD2<Float>(x, 0),
                to: SIMD2<Float>(x, height),
                color: gridColor,
                drawableSize: SIMD2<Float>(width, height)
            )
            x += majorStep
        }

        let centerY = floor(height * 0.5) + 0.5
        appendLine(
            to: &vertices,
            from: SIMD2<Float>(0, centerY),
            to: SIMD2<Float>(width, centerY),
            color: centerColor,
            drawableSize: SIMD2<Float>(width, height)
        )

        return vertices
    }

    private func makeWaveformVertices(drawableSize: CGSize, backingScale: Float) -> [TimelineVertex] {
        guard let waveformOverview, !waveformOverview.isEmpty else {
            return []
        }

        let width = Float(drawableSize.width)
        let height = Float(drawableSize.height)
        guard width > 0, height > 0 else {
            return []
        }

        let centerY = height * 0.5
        let amplitudeHeight = height * 0.42
        let minimumVisualHeight = max(backingScale, 1)
        let color = SIMD4<Float>(0.78, 0.92, 0.88, 1.0)
        let size = SIMD2<Float>(width, height)
        let bins = waveformOverview.bins
        var vertices: [TimelineVertex] = []
        vertices.reserveCapacity(bins.count * 6)

        for (index, bin) in bins.enumerated() {
            let x0 = Float(index) / Float(bins.count) * width
            let x1 = max(Float(index + 1) / Float(bins.count) * width, x0 + 1)
            var y0 = centerY - bin.maximumSample * amplitudeHeight
            var y1 = centerY - bin.minimumSample * amplitudeHeight

            if y1 - y0 < minimumVisualHeight {
                let midpoint = (y0 + y1) * 0.5
                y0 = midpoint - minimumVisualHeight * 0.5
                y1 = midpoint + minimumVisualHeight * 0.5
            }

            appendRectangle(
                to: &vertices,
                left: x0,
                right: min(x1, width),
                top: max(y0, 0),
                bottom: min(y1, height),
                color: color,
                drawableSize: size
            )
        }

        return vertices
    }

    private func makePlayheadVertices(drawableSize: CGSize, backingScale: Float) -> [TimelineVertex] {
        let width = Float(drawableSize.width)
        let height = Float(drawableSize.height)
        guard width > 0, height > 0 else {
            return []
        }

        let playheadX = min(max(80 * backingScale, 0), width)
        let playheadWidth = max(2 * backingScale, 1)
        let left = max(playheadX - playheadWidth * 0.5, 0)
        let right = min(left + playheadWidth, width)
        let color = SIMD4<Float>(0.0, 0.84, 0.78, 1.0)
        let size = SIMD2<Float>(width, height)

        return [
            makeVertex(pixelPosition: SIMD2<Float>(left, 0), color: color, drawableSize: size),
            makeVertex(pixelPosition: SIMD2<Float>(right, 0), color: color, drawableSize: size),
            makeVertex(pixelPosition: SIMD2<Float>(left, height), color: color, drawableSize: size),
            makeVertex(pixelPosition: SIMD2<Float>(right, 0), color: color, drawableSize: size),
            makeVertex(pixelPosition: SIMD2<Float>(right, height), color: color, drawableSize: size),
            makeVertex(pixelPosition: SIMD2<Float>(left, height), color: color, drawableSize: size),
        ]
    }

    private func appendLine(
        to vertices: inout [TimelineVertex],
        from start: SIMD2<Float>,
        to end: SIMD2<Float>,
        color: SIMD4<Float>,
        drawableSize: SIMD2<Float>
    ) {
        vertices.append(makeVertex(pixelPosition: start, color: color, drawableSize: drawableSize))
        vertices.append(makeVertex(pixelPosition: end, color: color, drawableSize: drawableSize))
    }

    private func appendRectangle(
        to vertices: inout [TimelineVertex],
        left: Float,
        right: Float,
        top: Float,
        bottom: Float,
        color: SIMD4<Float>,
        drawableSize: SIMD2<Float>
    ) {
        let topLeft = makeVertex(
            pixelPosition: SIMD2<Float>(left, top),
            color: color,
            drawableSize: drawableSize
        )
        let topRight = makeVertex(
            pixelPosition: SIMD2<Float>(right, top),
            color: color,
            drawableSize: drawableSize
        )
        let bottomLeft = makeVertex(
            pixelPosition: SIMD2<Float>(left, bottom),
            color: color,
            drawableSize: drawableSize
        )
        let bottomRight = makeVertex(
            pixelPosition: SIMD2<Float>(right, bottom),
            color: color,
            drawableSize: drawableSize
        )

        vertices.append(topLeft)
        vertices.append(topRight)
        vertices.append(bottomLeft)
        vertices.append(topRight)
        vertices.append(bottomRight)
        vertices.append(bottomLeft)
    }

    private func makeVertex(
        pixelPosition: SIMD2<Float>,
        color: SIMD4<Float>,
        drawableSize: SIMD2<Float>
    ) -> TimelineVertex {
        let x = pixelPosition.x / drawableSize.x * 2 - 1
        let y = 1 - pixelPosition.y / drawableSize.y * 2

        return TimelineVertex(
            position: SIMD4<Float>(x, y, 0, 1),
            color: color
        )
    }

    @MainActor
    private func backingScale(for view: MTKView) -> Float {
        let boundsWidth = max(Float(view.bounds.width), 1)
        let drawableWidth = max(Float(view.drawableSize.width), 1)
        return max(drawableWidth / boundsWidth, 1)
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct TimelineVertex {
        float4 position;
        float4 color;
    };

    struct RasterizedVertex {
        float4 position [[position]];
        float4 color;
    };

    vertex RasterizedVertex timeline_vertex(
        uint vertexID [[vertex_id]],
        constant TimelineVertex *vertices [[buffer(0)]]
    ) {
        RasterizedVertex out;
        out.position = vertices[vertexID].position;
        out.color = vertices[vertexID].color;
        return out;
    }

    fragment float4 timeline_fragment(RasterizedVertex in [[stage_in]]) {
        return in.color;
    }
    """
}
