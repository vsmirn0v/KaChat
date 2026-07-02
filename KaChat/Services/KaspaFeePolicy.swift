import Foundation

enum KaspaFeePolicy {
    static let minimumRelayFeePerGramSompi: UInt64 = 100
    static let normalizedTransientMassPerByte: UInt64 = 2

    static func minimumStandardFee(computeMass: UInt64, estimatedTransactionBytes: UInt64) -> UInt64 {
        let transientMass = estimatedTransactionBytes.saturatingMultiplied(by: normalizedTransientMassPerByte)
        let feeMass = max(computeMass, transientMass)
        return feeMass.saturatingMultiplied(by: minimumRelayFeePerGramSompi)
    }
}

private extension UInt64 {
    func saturatingMultiplied(by value: UInt64) -> UInt64 {
        let result = multipliedReportingOverflow(by: value)
        return result.overflow ? UInt64.max : result.partialValue
    }
}
