import Foundation
import Testing
@testable import PerformanceModule

@Suite("HeavyConsumersRanker")
struct HeavyConsumersRankerTests {
    let ranker = HeavyConsumersRanker()
    let gb: Int64 = 1_000_000_000

    @Test func defaults() {
        #expect(ranker.cpuThreshold == 20)
        #expect(ranker.memoryThreshold == 1_000_000_000)
        let custom = HeavyConsumersRanker(cpuThreshold: 50, memoryThreshold: 2 * gb)
        #expect(custom.cpuThreshold == 50)
        #expect(custom.memoryThreshold == 2 * gb)
    }

    @Test func thresholdsAreInclusiveAndEitherSuffices() {
        let samples = [
            sample(1, "idle", cpu: 19.9, memory: gb - 1),
            sample(2, "cpu", cpu: 20, memory: 0),
            sample(3, "mem", cpu: 0, memory: gb),
            sample(4, "both", cpu: 30, memory: 2 * gb),
        ]
        #expect(ranker.rank(samples).map(\.id) == [4, 3, 2])
    }

    @Test func systemProcessesNeedDoubleThresholds() {
        let samples = [
            sample(1, "kernel_task", cpu: 39, memory: 2 * gb - 1, system: true),
            sample(2, "WindowServer", cpu: 40, memory: 0, system: true),
            sample(3, "mds", cpu: 0, memory: 2 * gb, system: true),
            sample(4, "app", cpu: 39, memory: 0),
        ]
        #expect(ranker.rank(samples).map(\.id) == [3, 2, 4])
        let custom = HeavyConsumersRanker(cpuThreshold: 10, memoryThreshold: 100)
        #expect(custom.rank([sample(5, "sys", cpu: 19, memory: 199, system: true)]).isEmpty)
        #expect(custom.rank([sample(5, "sys", cpu: 20, memory: 0, system: true)]).count == 1)
        #expect(custom.rank([sample(5, "sys", cpu: 0, memory: 200, system: true)]).count == 1)
    }

    @Test func orderedByScoreThenPid() {
        let samples = [
            sample(30, "c", cpu: 100, memory: 0),            // score 1.0
            sample(10, "a", cpu: 0, memory: 4 * gb),          // score 1.0
            sample(20, "b", cpu: 50, memory: 2 * gb),         // score 1.0
            sample(40, "d", cpu: 400, memory: 0),             // score 4.0
            sample(50, "e", cpu: 25, memory: 8 * gb),         // score 2.25
        ]
        #expect(ranker.rank(samples).map(\.id) == [40, 50, 10, 20, 30])
        #expect(HeavyConsumersRanker.score(sample(1, "x", cpu: 50, memory: 2 * gb)) == 1.0)
    }

    @Test func rankIsDeterministicRegardlessOfInputOrder() {
        let samples = [
            sample(3, "c", cpu: 25), sample(1, "a", cpu: 25), sample(2, "b", cpu: 25),
        ]
        #expect(ranker.rank(samples).map(\.id) == [1, 2, 3])
        #expect(ranker.rank(samples.reversed()).map(\.id) == [1, 2, 3])
    }

    @Test func hungListsUnresponsiveByName() {
        let samples = [
            sample(9, "Zed", responsive: false),
            sample(2, "Alpha", responsive: true),
            sample(5, "Beta", responsive: nil),
            sample(7, "Alpha", responsive: false),
            sample(1, "alpha", responsive: false),
            sample(3, "Alpha", responsive: false),
        ]
        #expect(ranker.hung(samples).map(\.id) == [3, 7, 9, 1])
        #expect(ranker.hung([]).isEmpty)
    }

    @Test func sampleRoundTripsThroughJSON() throws {
        let original = ProcessSample(id: 42, name: "Thing", bundleIdentifier: "com.thing", cpuPercent: 12.5,
                                     residentBytes: 123, energyImpact: 3.5, isResponsive: false, isSystem: true)
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(ProcessSample.self, from: data) == original)
    }
}
