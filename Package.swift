// swift-tools-version:5.9
import PackageDescription
import Foundation

// LocalClicky — a fully local, no-cloud rebuild of Clicky.
//
// The package is split so the parts that have no UI (the "brain": the Ollama
// client, the pointing-tag parser, the prompt builders, the coordinate math)
// live in a plain library, `LocalBrainKit`. That library can be unit-tested and
// exercised end-to-end from a command-line harness on any Apple-silicon Mac
// without launching the menu-bar GUI — which is how we verify the local
// inference pipeline actually works before it ever reaches the cursor overlay.

// Absolute path to this package, so the linker (and the dev binary's rpath) can
// find the vendored sherpa-onnx neural-TTS dylibs without hardcoding a username.
let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let sherpaLibDirectory = "\(packageDirectory)/vendor/sherpa/lib"

let package = Package(
    name: "LocalClicky",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LocalBrainKit", targets: ["LocalBrainKit"]),
        .executable(name: "localbrain-harness", targets: ["localbrain-harness"]),
        .executable(name: "LocalClicky", targets: ["LocalClicky"]),
    ],
    targets: [
        .target(
            name: "LocalBrainKit",
            path: "Sources/LocalBrainKit"
        ),
        // C interop shim exposing the sherpa-onnx C API (neural text-to-speech)
        // to Swift. The implementations live in the vendored dylib that the
        // LocalClicky target links against; this just provides the header/module.
        .target(
            name: "CSherpaOnnx",
            path: "Sources/CSherpaOnnx"
        ),
        .executableTarget(
            name: "localbrain-harness",
            dependencies: ["LocalBrainKit"],
            path: "Sources/localbrain-harness"
        ),
        // The menu-bar app itself. Built here with `swift build`, then wrapped
        // into LocalClicky.app by scripts/build-app.sh. Resources (sounds, icon,
        // and the bundled sherpa-onnx runtime + Piper voice) are placed into the
        // bundle by that script, so they're not declared as SwiftPM resources —
        // the code loads them via Bundle.main.
        .executableTarget(
            name: "LocalClicky",
            dependencies: ["LocalBrainKit", "CSherpaOnnx"],
            path: "Sources/LocalClicky",
            exclude: ["Resources"],
            linkerSettings: [
                // Link the vendored neural-TTS runtime. The first rpath lets the
                // dev binary (`swift run`) find the dylibs in the repo; the second
                // is where build-app.sh copies them inside LocalClicky.app.
                .unsafeFlags([
                    "-L\(sherpaLibDirectory)",
                    "-lsherpa-onnx-c-api",
                    "-Xlinker", "-rpath", "-Xlinker", sherpaLibDirectory,
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Resources/sherpa/lib",
                ]),
            ]
        ),
        .testTarget(
            name: "LocalBrainKitTests",
            dependencies: ["LocalBrainKit"],
            path: "Tests/LocalBrainKitTests"
        ),
    ]
)
