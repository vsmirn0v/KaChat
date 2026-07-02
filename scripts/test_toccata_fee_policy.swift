import Foundation

// Run with:
// swiftc -parse-as-library KaChat/Services/KaspaFeePolicy.swift scripts/test_toccata_fee_policy.swift -o /tmp/toccata_fee_policy_test && /tmp/toccata_fee_policy_test

func expectEqual(_ actual: UInt64, _ expected: UInt64, _ message: String) {
    guard actual == expected else {
        fputs("FAIL: \(message). expected \(expected), got \(actual)\n", stderr)
        exit(1)
    }
}

func expectGreaterThan(_ actual: UInt64, _ threshold: UInt64, _ message: String) {
    guard actual > threshold else {
        fputs("FAIL: \(message). expected > \(threshold), got \(actual)\n", stderr)
        exit(1)
    }
}

@main
struct ToccataFeePolicyTest {
    static func main() {
        let standardComputeMass: UInt64 = 1_624
        let standardTxBytes: UInt64 = 264
        let standardFee = KaspaFeePolicy.minimumStandardFee(
            computeMass: standardComputeMass,
            estimatedTransactionBytes: standardTxBytes
        )
        expectEqual(
            standardFee,
            162_400,
            "standard P2PK transaction fee should be 100 sompi per compute-mass gram"
        )

        let payloadHeavyFee = KaspaFeePolicy.minimumStandardFee(
            computeMass: 11_624,
            estimatedTransactionBytes: 10_264
        )
        expectEqual(
            payloadHeavyFee,
            2_052_800,
            "payload-heavy transaction fee should be based on normalized transient mass"
        )
        expectGreaterThan(
            payloadHeavyFee,
            1_162_400,
            "payload-heavy fee must exceed compute-only fee"
        )

        print("Toccata fee policy tests passed")
    }
}
