// Translation unit so SwiftPM treats CSherpaOnnx as a buildable C target. The
// header is declarations only (the implementations live in the vendored
// libsherpa-onnx-c-api.dylib, linked by the LocalClicky executable target), so
// this compiles to an essentially empty object file.
#include "c-api.h"
