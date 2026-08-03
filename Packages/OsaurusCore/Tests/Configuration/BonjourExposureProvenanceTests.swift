//
//  BonjourExposureProvenanceTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Bonjour exposure provenance")
struct BonjourExposureProvenanceTests {

    // MARK: - Decoding

    @Test("a config written before the flag existed decodes as user-owned")
    func legacyConfigDecodesAsUserOwned() throws {
        // The conservative reading: an exposure whose origin is unknown is
        // treated as deliberate, so upgrading never closes someone's port.
        let legacy = #"{"port":1337,"exposeToNetwork":true}"#
        let config = try JSONDecoder().decode(
            ServerConfiguration.self,
            from: Data(legacy.utf8)
        )

        #expect(config.exposeToNetwork)
        #expect(config.exposureAutoEnabledByBonjour == false)
    }

    @Test("the flag round-trips through encode and decode")
    func flagRoundTrips() throws {
        var config = ServerConfiguration.default
        config.exposeToNetwork = true
        config.exposureAutoEnabledByBonjour = true

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ServerConfiguration.self, from: data)

        #expect(decoded.exposeToNetwork)
        #expect(decoded.exposureAutoEnabledByBonjour)
    }

    // MARK: - Reconciliation

    @Test("a Bonjour agent opens exposure and records that it did")
    @MainActor
    func bonjourAgentOpensExposure() async {
        let controller = ServerController()
        controller.configuration.exposeToNetwork = false
        controller.configuration.exposureAutoEnabledByBonjour = false

        await controller.reconcileBonjourExposure(shouldExpose: true)

        #expect(controller.configuration.exposeToNetwork)
        #expect(controller.configuration.exposureAutoEnabledByBonjour)
    }

    @Test("losing the last Bonjour agent retracts an exposure Bonjour opened")
    @MainActor
    func retractsItsOwnExposure() async {
        // The trap this fixes: before provenance tracking, this transition did
        // nothing and the server stayed exposed for good.
        let controller = ServerController()
        controller.configuration.exposeToNetwork = true
        controller.configuration.exposureAutoEnabledByBonjour = true

        await controller.reconcileBonjourExposure(shouldExpose: false)

        #expect(controller.configuration.exposeToNetwork == false)
        #expect(controller.configuration.exposureAutoEnabledByBonjour == false)
    }

    @Test("losing the last Bonjour agent leaves a user's exposure alone")
    @MainActor
    func leavesUserExposureAlone() async {
        // `--expose` and pre-flag configs both look like this.
        let controller = ServerController()
        controller.configuration.exposeToNetwork = true
        controller.configuration.exposureAutoEnabledByBonjour = false

        await controller.reconcileBonjourExposure(shouldExpose: false)

        #expect(controller.configuration.exposeToNetwork)
        #expect(controller.configuration.exposureAutoEnabledByBonjour == false)
    }

    @Test("a Bonjour agent arriving does not seize a user's exposure")
    @MainActor
    func doesNotSeizeUserExposure() async {
        // Already exposed by the user, so Bonjour has nothing to open and must
        // not claim ownership — otherwise removing the agent later would close
        // a port the user opened themselves.
        let controller = ServerController()
        controller.configuration.exposeToNetwork = true
        controller.configuration.exposureAutoEnabledByBonjour = false

        await controller.reconcileBonjourExposure(shouldExpose: true)
        #expect(controller.configuration.exposureAutoEnabledByBonjour == false)

        await controller.reconcileBonjourExposure(shouldExpose: false)
        #expect(controller.configuration.exposeToNetwork)
    }

    @Test("no Bonjour agent and no exposure is a no-op")
    @MainActor
    func noOpWhenNothingToDo() async {
        let controller = ServerController()
        controller.configuration.exposeToNetwork = false
        controller.configuration.exposureAutoEnabledByBonjour = false

        await controller.reconcileBonjourExposure(shouldExpose: false)

        #expect(controller.configuration.exposeToNetwork == false)
        #expect(controller.configuration.exposureAutoEnabledByBonjour == false)
    }

    @Test("the full add-then-remove cycle returns to the starting state")
    @MainActor
    func cycleIsReversible() async {
        // The user-visible promise: enabling Bonjour on an agent and then
        // turning it off leaves the machine exactly as it was found.
        let controller = ServerController()
        controller.configuration.exposeToNetwork = false
        controller.configuration.exposureAutoEnabledByBonjour = false

        await controller.reconcileBonjourExposure(shouldExpose: true)
        await controller.reconcileBonjourExposure(shouldExpose: false)

        #expect(controller.configuration.exposeToNetwork == false)
        #expect(controller.configuration.exposureAutoEnabledByBonjour == false)
    }
}
