//
//  HardwareAdvisor.swift
//  LocalBrainKit
//
//  The native, always-available half of LocalClicky's "autotune" integration.
//  It detects the Mac's memory + CPU, holds a small curated catalog of the
//  models LocalClicky knows how to run (with realistic resident-RAM footprints),
//  and recommends the best models for THIS machine — including whether two
//  models can stay resident at once (text + vision) for snappy answers.
//
//  This is a pure port of the ideas in the user's `autotune` tool so the app
//  works for everyone with no Python dependency. When the real `autotune` CLI is
//  installed, AutotuneBridge layers its richer recommendation on top — but the
//  app is fully functional on this alone.
//
//  The recommendation logic is a pure function of a HardwareProfile, so it is
//  unit-tested from the harness with synthetic profiles (no real hardware
//  needed).
//

import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A snapshot of the machine's relevant capabilities.
public struct HardwareProfile: Sendable, Equatable {
    /// Total physical RAM, in GB (1 GB = 1024^3 bytes here, matching how macOS
    /// reports "16 GB").
    public let totalRAMGB: Double
    /// Currently-available RAM (free + inactive + purgeable + speculative), in GB.
    /// Used for the more dynamic "can both models stay resident right now"
    /// decision. Fluctuates with what else is open.
    public let availableRAMGB: Double
    public let physicalCores: Int
    public let isAppleSilicon: Bool

    public init(totalRAMGB: Double, availableRAMGB: Double, physicalCores: Int, isAppleSilicon: Bool) {
        self.totalRAMGB = totalRAMGB
        self.availableRAMGB = availableRAMGB
        self.physicalCores = physicalCores
        self.isAppleSilicon = isAppleSilicon
    }

    /// A short human description for logs / the panel.
    public var summary: String {
        let chip = isAppleSilicon ? "Apple silicon" : "Intel"
        return String(format: "%.0f GB RAM · %d cores · %@", totalRAMGB, physicalCores, chip)
    }
}

/// One model LocalClicky knows how to run, with the numbers the advisor + the
/// in-app download UI need. `residentGB` is the approximate memory the model
/// occupies once loaded (weights + a typical KV cache), which is larger than the
/// on-disk `sizeGB`.
public struct CatalogModel: Sendable, Equatable {
    public let name: String
    public let sizeGB: Double          // approximate download / on-disk size
    public let residentGB: Double      // approximate resident footprint when loaded
    public let isChat: Bool            // can fill the text role
    public let isVision: Bool          // can describe the screen
    public let grounds: Bool           // can return pointing coordinates (cursor)
    public let qualityTier: Int        // 1 (small) … 5 (best)
    public let blurb: String

    public init(name: String, sizeGB: Double, residentGB: Double,
                isChat: Bool, isVision: Bool, grounds: Bool, qualityTier: Int, blurb: String) {
        self.name = name
        self.sizeGB = sizeGB
        self.residentGB = residentGB
        self.isChat = isChat
        self.isVision = isVision
        self.grounds = grounds
        self.qualityTier = qualityTier
        self.blurb = blurb
    }
}

/// The curated set of models LocalClicky recommends + can one-click download.
/// Kept deliberately small so the download picker stays scannable, and tuned so
/// the defaults match a 16 GB Mac. Footprints are conservative estimates.
public enum ModelCatalog {
    public static let all: [CatalogModel] = [
        // — Text / reasoning —
        CatalogModel(name: "llama3.2:1b", sizeGB: 1.3, residentGB: 2.0,
                     isChat: true, isVision: false, grounds: false, qualityTier: 2,
                     blurb: "Tiny, fast text — for low-RAM Macs"),
        CatalogModel(name: "llama3.2:3b", sizeGB: 2.0, residentGB: 2.8,
                     isChat: true, isVision: false, grounds: false, qualityTier: 3,
                     blurb: "Fast all-round text (default)"),
        CatalogModel(name: "qwen2.5:3b", sizeGB: 1.9, residentGB: 2.7,
                     isChat: true, isVision: false, grounds: false, qualityTier: 3,
                     blurb: "Strong general text"),
        CatalogModel(name: "qwen2.5-coder:3b", sizeGB: 1.9, residentGB: 2.7,
                     isChat: true, isVision: false, grounds: false, qualityTier: 4,
                     blurb: "Great at code + summaries, still small"),
        CatalogModel(name: "qwen2.5-coder:7b", sizeGB: 4.7, residentGB: 6.0,
                     isChat: true, isVision: false, grounds: false, qualityTier: 4,
                     blurb: "Stronger coding (needs ~24 GB)"),
        // — Vision (describe) —
        CatalogModel(name: "moondream", sizeGB: 1.7, residentGB: 2.4,
                     isChat: false, isVision: true, grounds: false, qualityTier: 3,
                     blurb: "Small, fast screen describer (default)"),
        // — Vision + grounding (pointing) —
        CatalogModel(name: "qwen2.5vl:3b", sizeGB: 3.2, residentGB: 4.4,
                     isChat: false, isVision: true, grounds: true, qualityTier: 4,
                     blurb: "Describes AND points the cursor (default grounding)"),
        CatalogModel(name: "qwen3-vl:8b", sizeGB: 6.1, residentGB: 7.8,
                     isChat: false, isVision: true, grounds: true, qualityTier: 5,
                     blurb: "Best vision + pointing (needs ~32 GB)"),
    ]

    public static func model(named name: String) -> CatalogModel? {
        // Tolerate ":latest" vs tagless (Ollama normalizes these).
        func norm(_ n: String) -> String { n.contains(":") ? n : n + ":latest" }
        let target = norm(name)
        return all.first { norm($0.name) == target || $0.name == name }
    }

    /// Approximate resident footprint for a model name, falling back to a safe
    /// estimate for models not in the catalog (e.g. a user's custom pick).
    public static func residentGB(of name: String) -> Double {
        model(named: name)?.residentGB ?? 4.0
    }
}

/// The advisor's recommendation for a machine: which model to use per role, what
/// to keep resident, and a one-line human summary for the blue-text popup.
public struct ModelRecommendation: Sendable, Equatable {
    public let chatModel: String
    public let visionModel: String
    public let groundingModel: String
    /// Models to keep warm/resident (long keep_alive) given the memory budget.
    public let residentModels: [String]
    /// Whether the grounding model can also stay resident (vs. load on demand).
    public let keepsGroundingResident: Bool
    /// keep_alive string to use for resident models.
    public let keepAlive: String
    /// One-line, user-facing recommendation (used by the blue-text popup).
    public let summary: String

    public init(chatModel: String, visionModel: String, groundingModel: String,
                residentModels: [String], keepsGroundingResident: Bool,
                keepAlive: String, summary: String) {
        self.chatModel = chatModel
        self.visionModel = visionModel
        self.groundingModel = groundingModel
        self.residentModels = residentModels
        self.keepsGroundingResident = keepsGroundingResident
        self.keepAlive = keepAlive
        self.summary = summary
    }
}

public enum HardwareAdvisor {

    /// Detects the current machine. Safe to call on any Mac; falls back to
    /// conservative values if a metric can't be read.
    public static func detect() -> HardwareProfile {
        let bytesPerGB = 1024.0 * 1024.0 * 1024.0
        let total = Double(ProcessInfo.processInfo.physicalMemory) / bytesPerGB
        let available = Double(availableMemoryBytes()) / bytesPerGB
        let cores = ProcessInfo.processInfo.processorCount
        return HardwareProfile(
            totalRAMGB: total,
            availableRAMGB: available > 0 ? available : total * 0.5,
            physicalCores: cores,
            isAppleSilicon: isAppleSiliconHost())
    }

    /// True if the sum of resident footprints of `models` fits within `budgetGB`,
    /// leaving a small safety margin so we never recommend filling RAM to the brim.
    public static func fits(_ models: [String], inBudgetGB budget: Double, marginGB: Double = 1.5) -> Bool {
        let needed = models.reduce(0.0) { $0 + ModelCatalog.residentGB(of: $1) }
        return needed + marginGB <= budget
    }

    /// The core recommendation. Pure function of the profile → unit-testable.
    public static func recommend(for profile: HardwareProfile) -> ModelRecommendation {
        let total = profile.totalRAMGB
        // The memory we'll actually plan models against: prefer live availability,
        // but never plan against less than 45% of total (the user can close apps),
        // so the recommendation is stable rather than jittering with every app.
        let budget = max(profile.availableRAMGB, total * 0.45)

        // Per-role picks by total RAM. The 8–24 GB tier is exactly the shipped
        // default arrangement (the owner's setup), so most users get it.
        let chatModel: String
        let visionModel = "moondream"          // small, fast describer — default everywhere
        let groundingModel: String
        if total >= 28 {
            chatModel = "qwen2.5-coder:7b"
            groundingModel = "qwen3-vl:8b"
        } else if total >= 7 {
            chatModel = "llama3.2:3b"
            groundingModel = "qwen2.5vl:3b"
        } else {
            chatModel = "llama3.2:1b"
            groundingModel = "qwen2.5vl:3b"
        }

        // Residency: keep {text + vision} resident if they fit; add grounding too
        // when there's room, otherwise it loads on demand for pointing turns.
        var resident: [String] = []
        if fits([chatModel, visionModel], inBudgetGB: budget) {
            resident = [chatModel, visionModel]
        } else if fits([visionModel], inBudgetGB: budget) {
            resident = [visionModel]
        } else if fits([chatModel], inBudgetGB: budget) {
            resident = [chatModel]
        }
        let keepsGrounding = fits([chatModel, visionModel, groundingModel], inBudgetGB: budget)
        if keepsGrounding { resident.append(groundingModel) }

        let keepAlive = total >= 14 ? "30m" : "10m"
        let summary = "for your \(Int(total.rounded())) GB mac: \(chatModel) for text, \(visionModel) for the screen"

        return ModelRecommendation(
            chatModel: chatModel, visionModel: visionModel, groundingModel: groundingModel,
            residentModels: resident, keepsGroundingResident: keepsGrounding,
            keepAlive: keepAlive, summary: summary)
    }

    /// Convenience: recommend for the detected machine.
    public static func recommendForThisMachine() -> ModelRecommendation {
        recommend(for: detect())
    }

    // MARK: - Low-level detection

    /// Available physical memory in bytes (free + inactive + purgeable +
    /// speculative pages), via mach. Returns 0 if it can't be read.
    static func availableMemoryBytes() -> UInt64 {
        #if canImport(Darwin)
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPointer in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPointer, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let pageSize = UInt64(vm_kernel_page_size)
        let free = UInt64(stats.free_count) * pageSize
        let inactive = UInt64(stats.inactive_count) * pageSize
        let purgeable = UInt64(stats.purgeable_count) * pageSize
        let speculative = UInt64(stats.speculative_count) * pageSize
        return free + inactive + purgeable + speculative
        #else
        return 0
        #endif
    }

    /// True on Apple-silicon Macs (arm64), false on Intel.
    static func isAppleSiliconHost() -> Bool {
        #if arch(arm64)
        return true
        #else
        // Rosetta detection: a process translated on Apple silicon reports x86_64
        // but `sysctl.proc_translated` is 1. Treat that as Apple silicon too.
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0 {
            return translated == 1
        }
        return false
        #endif
    }
}
