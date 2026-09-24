import Foundation
import CoreLocation

/// Coordinate conversion used before injecting a simulated location.
///
/// MapKit's displayed coordinates in mainland China follow the GCJ-02 mapping
/// convention, while Core Location's simulated location service expects the
/// underlying WGS-84 coordinate. Without converting, the injected fix can be
/// displaced by several hundred meters in mainland China.
enum ChinaCoordinateTransform {
    private static let a = 6378245.0
    private static let ee = 0.00669342162296594323

    static func injectionCoordinate(from mapCoordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        guard isInMainlandChina(mapCoordinate) else { return mapCoordinate }
        return gcj02ToWGS84(mapCoordinate)
    }

    static func isInMainlandChina(_ coordinate: CLLocationCoordinate2D) -> Bool {
        let lat = coordinate.latitude
        let lon = coordinate.longitude
        return lon >= 72.004 && lon <= 137.8347 && lat >= 0.8293 && lat <= 55.8271
    }

    /// Iteratively invert WGS84 -> GCJ02 so the result is more accurate than
    /// the common one-pass approximation.
    private static func gcj02ToWGS84(_ gcj: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        var wgs = CLLocationCoordinate2D(latitude: gcj.latitude, longitude: gcj.longitude)
        for _ in 0..<8 {
            let projected = wgs84ToGCJ02(wgs)
            let dLat = projected.latitude - gcj.latitude
            let dLon = projected.longitude - gcj.longitude
            wgs.latitude -= dLat
            wgs.longitude -= dLon
            if abs(dLat) < 1e-7 && abs(dLon) < 1e-7 { break }
        }
        return wgs
    }

    private static func wgs84ToGCJ02(_ wgs: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        guard isInMainlandChina(wgs) else { return wgs }
        var dLat = transformLat(wgs.longitude - 105.0, wgs.latitude - 35.0)
        var dLon = transformLon(wgs.longitude - 105.0, wgs.latitude - 35.0)
        let radLat = wgs.latitude / 180.0 * .pi
        var magic = sin(radLat)
        magic = 1 - ee * magic * magic
        let sqrtMagic = sqrt(magic)
        dLat = (dLat * 180.0) / ((a * (1 - ee)) / (magic * sqrtMagic) * .pi)
        dLon = (dLon * 180.0) / (a / sqrtMagic * cos(radLat) * .pi)
        return CLLocationCoordinate2D(latitude: wgs.latitude + dLat, longitude: wgs.longitude + dLon)
    }

    private static func transformLat(_ x: Double, _ y: Double) -> Double {
        var ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        ret += (20.0 * sin(y * .pi) + 40.0 * sin(y / 3.0 * .pi)) * 2.0 / 3.0
        ret += (160.0 * sin(y / 12.0 * .pi) + 320 * sin(y * .pi / 30.0)) * 2.0 / 3.0
        return ret
    }

    private static func transformLon(_ x: Double, _ y: Double) -> Double {
        var ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        ret += (20.0 * sin(x * .pi) + 40.0 * sin(x / 3.0 * .pi)) * 2.0 / 3.0
        ret += (150.0 * sin(x / 12.0 * .pi) + 300.0 * sin(x / 30.0 * .pi)) * 2.0 / 3.0
        return ret
    }
}
