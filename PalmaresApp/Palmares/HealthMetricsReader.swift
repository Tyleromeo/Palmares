//
//  HealthMetricsReader.swift
//  Palmares (app target)
//
//  Self-contained HealthKit reader that gathers everything the web app's
//  window.receiveHealthData consumer understands - the four fields the
//  original HealthKitManager.swift sent (vo2max, restingHR, hrvSDNN, age)
//  PLUS the recovery fields the coaching card now uses:
//
//    sleepHours  - last night's total asleep time, in hours
//    hrv7day     - mean HRV (SDNN) over the trailing 7 days, ms
//    hrv30day    - mean HRV (SDNN) over the trailing 30 days, ms (baseline)
//
//  Every field is optional on the JS side, so partial data is fine.
//
//  Integration: either call HealthMetricsReader.push(into: webView) from
//  webView(_:didFinish:) where HealthKitManager currently pushes, or fold
//  the three gather* functions into the existing manager. If replacing the
//  manager entirely, remember its Info.plist prerequisites still apply
//  (NSHealthShareUsageDescription + the HealthKit capability), and add the
//  new read types below to the authorization request.
//

import Foundation
import HealthKit
import WebKit

enum HealthMetricsReader {

    private static let store = HKHealthStore()

    private static let readTypes: Set<HKObjectType> = {
        var types = Set<HKObjectType>()
        types.insert(HKObjectType.quantityType(forIdentifier: .vo2Max)!)
        types.insert(HKObjectType.quantityType(forIdentifier: .restingHeartRate)!)
        types.insert(HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!)
        types.insert(HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!)
        types.insert(HKObjectType.characteristicType(forIdentifier: .dateOfBirth)!)
        // Body weight feeds the first-run profile import (power-to-weight).
        // Health's figure is typically fresher than the one on a Strava profile.
        types.insert(HKObjectType.quantityType(forIdentifier: .bodyMass)!)
        return types
    }()

    /// Gather all metrics and inject them into the page via
    /// window.receiveHealthData. Call after the page finishes loading.
    static func push(into webView: WKWebView) {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        store.requestAuthorization(toShare: nil, read: readTypes) { granted, _ in
            guard granted else { return }
            gather { payload in
                guard
                    let json = try? JSONSerialization.data(withJSONObject: payload),
                    let jsonString = String(data: json, encoding: .utf8)
                else { return }
                DispatchQueue.main.async {
                    webView.evaluateJavaScript(
                        "window.receiveHealthData && window.receiveHealthData(\(jsonString));",
                        completionHandler: nil
                    )
                }
            }
        }
    }

    // MARK: - Gathering

    private static func gather(completion: @escaping ([String: Any]) -> Void) {
        var payload: [String: Any] = ["source": "healthkit"]
        let group = DispatchGroup()
        let lock = NSLock()
        func set(_ key: String, _ value: Any?) {
            guard let value else { return }
            lock.lock(); payload[key] = value; lock.unlock()
        }

        // Age from date of birth (a characteristic, not a query)
        if let dob = try? store.dateOfBirthComponents().date {
            let age = Calendar.current.dateComponents([.year], from: dob, to: Date()).year
            set("age", age)
        }

        // Most recent VO2 max measurement
        group.enter()
        latestQuantity(.vo2Max, unit: HKUnit(from: "ml/kg*min")) { v in
            set("vo2max", v); group.leave()
        }

        // VO2 max broken down by where it came from. Apple Watch derives its
        // figure from outdoor walks/runs/hikes only - never cycling - so it is
        // a RUNNING number. A Garmin (or other) sample written into Health can
        // be a cycling number, and the two legitimately differ by several
        // points for the same person. Taking whichever synced last silently
        // mixed the two, so the page now gets each source separately and can
        // pick the one that matches the reference norms it compares against.
        group.enter()
        latestQuantityPerSource(.vo2Max, unit: HKUnit(from: "ml/kg*min")) { bySource in
            if !bySource.isEmpty { set("vo2maxBySource", bySource) }
            group.leave()
        }

        // Most recent body weight, in kg to match how the page stores it.
        group.enter()
        latestQuantity(.bodyMass, unit: .gramUnit(with: .kilo)) { v in
            set("weightKg", v.map { round($0 * 10) / 10 }); group.leave()
        }

        // Resting HR: 30-day average (matches what the JS labels it as)
        group.enter()
        averageQuantity(.restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()), days: 30) { v in
            set("restingHR", v.map { Int($0.rounded()) }); group.leave()
        }

        // HRV SDNN: 30-day baseline (kept as hrvSDNN for the True Age card,
        // duplicated as hrv30day for the coaching card) and 7-day trend.
        group.enter()
        averageQuantity(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), days: 30) { v in
            set("hrvSDNN", v); set("hrv30day", v); group.leave()
        }
        group.enter()
        averageQuantity(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), days: 7) { v in
            set("hrv7day", v); group.leave()
        }

        // Last night's sleep
        group.enter()
        lastNightSleepHours { v in
            set("sleepHours", v); group.leave()
        }

        group.notify(queue: .global()) { completion(payload) }
    }

    // MARK: - Query helpers

    private static func latestQuantity(
        _ id: HKQuantityTypeIdentifier, unit: HKUnit,
        completion: @escaping (Double?) -> Void
    ) {
        guard let type = HKObjectType.quantityType(forIdentifier: id) else { return completion(nil) }
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        let query = HKSampleQuery(sampleType: type, predicate: nil, limit: 1, sortDescriptors: [sort]) { _, samples, _ in
            let value = (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit)
            completion(value)
        }
        store.execute(query)
    }

    /// Most recent VO2 max per originating app/device, keyed by source name
    /// (e.g. "Apple Watch", "Garmin Connect"). Health can hold several sources
    /// at once and they are not interchangeable - see the call site.
    private static func latestQuantityPerSource(
        _ id: HKQuantityTypeIdentifier, unit: HKUnit,
        completion: @escaping ([String: Double]) -> Void
    ) {
        guard let type = HKObjectType.quantityType(forIdentifier: id) else { return completion([:]) }
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        // 200 samples is far more than enough to see every source that has
        // written recently, without walking the whole history.
        let query = HKSampleQuery(sampleType: type, predicate: nil, limit: 200,
                                  sortDescriptors: [sort]) { _, samples, _ in
            var out: [String: Double] = [:]
            for case let sample as HKQuantitySample in samples ?? [] {
                let name = sample.sourceRevision.source.name
                // Sorted newest-first, so the first hit for a source wins.
                if out[name] == nil { out[name] = sample.quantity.doubleValue(for: unit) }
            }
            completion(out)
        }
        store.execute(query)
    }

    private static func averageQuantity(
        _ id: HKQuantityTypeIdentifier, unit: HKUnit, days: Int,
        completion: @escaping (Double?) -> Void
    ) {
        guard let type = HKObjectType.quantityType(forIdentifier: id) else { return completion(nil) }
        let start = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date())
        let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate,
                                      options: .discreteAverage) { _, stats, _ in
            completion(stats?.averageQuantity()?.doubleValue(for: unit))
        }
        store.execute(query)
    }

    /// Total time actually asleep (not just in bed) since 6pm yesterday.
    /// Overlapping stage samples from multiple sources (watch + phone) are
    /// merged into a union of intervals so the total can't double-count.
    private static func lastNightSleepHours(completion: @escaping (Double?) -> Void) {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return completion(nil) }

        var sixPMYesterday = Calendar.current.date(
            bySettingHour: 18, minute: 0, second: 0,
            of: Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        )!
        // If it's evening already, "last night" still means the previous night.
        if Date().timeIntervalSince(sixPMYesterday) > 30 * 3600 {
            sixPMYesterday = Calendar.current.date(byAdding: .day, value: 1, to: sixPMYesterday)!
        }

        let predicate = HKQuery.predicateForSamples(withStart: sixPMYesterday, end: Date())
        let query = HKSampleQuery(sampleType: type, predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
            let asleepValues: Set<Int> = {
                if #available(iOS 16.0, *) {
                    return Set(HKCategoryValueSleepAnalysis.allAsleepValues.map(\.rawValue))
                }
                return [HKCategoryValueSleepAnalysis.asleep.rawValue]
            }()

            let intervals = (samples as? [HKCategorySample] ?? [])
                .filter { asleepValues.contains($0.value) }
                .map { ($0.startDate, $0.endDate) }
                .sorted { $0.0 < $1.0 }

            guard !intervals.isEmpty else { return completion(nil) }

            // Merge overlaps
            var total: TimeInterval = 0
            var (curStart, curEnd) = intervals[0]
            for (s, e) in intervals.dropFirst() {
                if s <= curEnd { curEnd = max(curEnd, e) }
                else { total += curEnd.timeIntervalSince(curStart); (curStart, curEnd) = (s, e) }
            }
            total += curEnd.timeIntervalSince(curStart)
            completion(total / 3600.0)
        }
        store.execute(query)
    }
}
