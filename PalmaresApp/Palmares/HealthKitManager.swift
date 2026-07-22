import Foundation
import HealthKit

// Reads the health metrics that feed the site's "True Age" card - VO2 max,
// resting heart rate, HRV, date of birth, biological sex, and body mass -
// and publishes them as a JSON payload that ContentView injects into the
// page via window.receiveHealthData(...). Read-only: the app never writes
// anything to HealthKit.
//
// All queries are best-effort: any metric the user hasn't granted (the
// HealthKit permission sheet allows per-metric choices) or simply doesn't
// have data for (e.g. no Apple Watch = no VO2 max samples) is omitted from
// the payload, and the web side falls back to its Settings/estimate values
// for just that metric.
final class HealthKitManager: ObservableObject {
    @Published var payloadJSON: String? = nil

    private let store = HKHealthStore()

    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = []
        types.insert(HKObjectType.quantityType(forIdentifier: .vo2Max)!)
        types.insert(HKObjectType.quantityType(forIdentifier: .restingHeartRate)!)
        types.insert(HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!)
        types.insert(HKObjectType.quantityType(forIdentifier: .bodyMass)!)
        types.insert(HKObjectType.characteristicType(forIdentifier: .dateOfBirth)!)
        types.insert(HKObjectType.characteristicType(forIdentifier: .biologicalSex)!)
        return types
    }

    func requestAndFetch() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        store.requestAuthorization(toShare: nil, read: readTypes) { [weak self] granted, _ in
            // HealthKit intentionally doesn't reveal which *read* permissions
            // were granted - queries for denied types just return no samples.
            // So fetch unconditionally and let each query succeed or come up
            // empty on its own.
            guard granted, let self else { return }
            self.fetchAll()
        }
    }

    private func fetchAll() {
        var payload: [String: Any] = ["source": "healthkit"]
        let group = DispatchGroup()
        let lock = NSLock()
        func set(_ key: String, _ value: Any?) {
            guard let value else { return }
            lock.lock(); payload[key] = value; lock.unlock()
        }

        // Characteristics are synchronous reads.
        if let dob = try? store.dateOfBirthComponents(), let dobDate = dob.date {
            let age = Calendar.current.dateComponents([.year], from: dobDate, to: Date()).year
            set("age", age)
        }
        if let sex = try? store.biologicalSex() {
            switch sex.biologicalSex {
            case .male: set("biologicalSex", "male")
            case .female: set("biologicalSex", "female")
            default: break
            }
        }

        // Latest VO2 max sample (Apple Watch writes these after outdoor
        // walks/runs/hikes of sufficient effort).
        group.enter()
        fetchLatestSample(.vo2Max) { sample in
            if let sample {
                let mlKgMin = HKUnit(from: "ml/kg*min")
                set("vo2max", (sample.quantity.doubleValue(for: mlKgMin) * 10).rounded() / 10)
                set("vo2maxDate", ISO8601DateFormatter().string(from: sample.endDate))
            }
            group.leave()
        }

        // Resting HR and HRV: 30-day averages smooth out day-to-day noise
        // (sleep, stress, alcohol) that a single latest sample would carry.
        group.enter()
        fetchAverage(.restingHeartRate, days: 30, unit: HKUnit.count().unitDivided(by: .minute())) { avg in
            if let avg { set("restingHR", (avg * 10).rounded() / 10) }
            group.leave()
        }
        group.enter()
        fetchAverage(.heartRateVariabilitySDNN, days: 30, unit: HKUnit.secondUnit(with: .milli)) { avg in
            if let avg { set("hrvSDNN", (avg * 10).rounded() / 10) }
            group.leave()
        }

        group.enter()
        fetchLatestSample(.bodyMass) { sample in
            if let sample {
                set("weightKg", (sample.quantity.doubleValue(for: .gramUnit(with: .kilo)) * 10).rounded() / 10)
            }
            group.leave()
        }

        group.notify(queue: .main) { [weak self] in
            guard let self,
                  let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else { return }
            self.payloadJSON = json
        }
    }

    private func fetchLatestSample(_ id: HKQuantityTypeIdentifier, completion: @escaping (HKQuantitySample?) -> Void) {
        guard let type = HKObjectType.quantityType(forIdentifier: id) else { completion(nil); return }
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        let query = HKSampleQuery(sampleType: type, predicate: nil, limit: 1, sortDescriptors: [sort]) { _, samples, _ in
            completion(samples?.first as? HKQuantitySample)
        }
        store.execute(query)
    }

    private func fetchAverage(_ id: HKQuantityTypeIdentifier, days: Int, unit: HKUnit, completion: @escaping (Double?) -> Void) {
        guard let type = HKObjectType.quantityType(forIdentifier: id) else { completion(nil); return }
        let start = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate)
        let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .discreteAverage) { _, stats, _ in
            completion(stats?.averageQuantity()?.doubleValue(for: unit))
        }
        store.execute(query)
    }
}
