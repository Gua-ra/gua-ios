//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// RFC 6962 Merkle tree hashing behind the transparency log. Domain separated so a leaf and an interior node
/// cannot be confused: `leaf = SHA-256(0x00 || data)`, `node = SHA-256(0x01 || left || right)`.
enum MerkleTree {
    static func leafData(index: Int, type: String, homeserverId: String?, payloadHash: String, recordedAtEpochMilliseconds: Int64) -> String {
        "\(index)|\(type)|\(homeserverId ?? "")|\(payloadHash)|\(recordedAtEpochMilliseconds)"
    }

    static func leafHash(_ data: [UInt8]) -> String {
        ResolverVerificationCrypto.sha256Hex([0x00] + data)
    }

    private static func nodeHash(_ left: [UInt8], _ right: [UInt8]) -> [UInt8] {
        ResolverVerificationCrypto.sha256([0x01] + left + right)
    }

    /// The Merkle Tree Hash over hex leaf hashes; the empty tree hashes to SHA-256 of nothing. `nil` when a
    /// leaf hash is not hex.
    static func root(leafHashes: [String]) -> String? {
        if leafHashes.isEmpty { return ResolverVerificationCrypto.sha256Hex([]) }
        var nodes = [[UInt8]]()
        for hash in leafHashes {
            guard let bytes = ResolverVerificationHex.bytes(hash) else { return nil }
            nodes.append(bytes)
        }
        return ResolverVerificationHex.string(mth(nodes[...]))
    }

    private static func mth(_ nodes: ArraySlice<[UInt8]>) -> [UInt8] {
        if nodes.count == 1 { return nodes[nodes.startIndex] }
        let k = largestPowerOfTwo(lessThan: nodes.count)
        let split = nodes.startIndex + k
        return nodeHash(mth(nodes[nodes.startIndex..<split]), mth(nodes[split...]))
    }

    private static func largestPowerOfTwo(lessThan n: Int) -> Int {
        var k = 1
        while k << 1 < n {
            k <<= 1
        }
        return k
    }

    /// Whether `newRoot` (of `second` leaves) is an append-only extension of `oldRoot` (of `first` leaves), checked
    /// as RFC 9162 section 2.1.4.2 describes.
    static func verifyConsistency(first: Int, second: Int, oldRoot: String, newRoot: String, proof: [String]) -> Bool {
        if first == 0 { return second >= 0 }
        if first == second { return proof.isEmpty && oldRoot == newRoot }
        var path = proof.compactMap(ResolverVerificationHex.bytes)
        guard first < second, !path.isEmpty, path.count == proof.count, let oldRootBytes = ResolverVerificationHex.bytes(oldRoot) else {
            return false
        }
        if first & (first - 1) == 0 { path.insert(oldRootBytes, at: 0) }
        var fn = first - 1
        var sn = second - 1
        while fn & 1 == 1 {
            fn >>= 1
            sn >>= 1
        }
        var fr = path[0]
        var sr = path[0]
        for node in path.dropFirst() {
            // Hashes left over once the path has reached the new root fail the proof.
            guard sn != 0 else { return false }
            if fn & 1 == 1 || fn == sn {
                fr = nodeHash(node, fr)
                sr = nodeHash(node, sr)
                while fn & 1 == 0, fn != 0 {
                    fn >>= 1
                    sn >>= 1
                }
            } else {
                sr = nodeHash(sr, node)
            }
            fn >>= 1
            sn >>= 1
        }
        return ResolverVerificationHex.string(fr) == oldRoot && ResolverVerificationHex.string(sr) == newRoot && sn == 0
    }
}
