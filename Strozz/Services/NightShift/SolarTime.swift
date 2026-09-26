import Foundation

/// Pure sunrise/sunset math (no network, no CoreLocation) used by Night Shift to
/// ramp its warm tint against the real sun. It's a compact port of the standard
/// "sunrise equation" (NOAA's solar-position approximation) and is accurate to
/// about a minute for the latitudes people actually live at — more than enough
/// to fade a screen tint in and out.
///
/// Intentionally plain Foundation so it stays portable to an iOS companion app.
enum SolarTime {
  /// Sunrise and sunset (as absolute `Date`s) for the local calendar day that
  /// contains `reference` at the given coordinates.
  ///
  /// Returns `nil` for polar day / polar night, where the sun never crosses the
  /// horizon on that date (the caller treats that as "no transition today").
  ///
  /// - Parameters:
  ///   - latitude: Degrees north (negative = south).
  ///   - longitude: Degrees east (negative = west).
  ///   - reference: Any instant within the day of interest.
  ///   - timeZone: The location's time zone, used only to pick which calendar
  ///     day `reference` falls on. The returned `Date`s are absolute, so they
  ///     compare correctly against `Date()` regardless of zone.
  static func sunriseSunset(
    latitude: Double,
    longitude: Double,
    on reference: Date,
    timeZone: TimeZone
  ) -> (sunrise: Date, sunset: Date)? {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let comps = calendar.dateComponents([.year, .month, .day], from: reference)
    guard let year = comps.year, let month = comps.month, let day = comps.day else { return nil }

    // Julian Day Number for the calendar date (Fliegel–Van Flandern).
    let a = (14 - month) / 12
    let y = year + 4800 - a
    let m = month + 12 * a - 3
    let jdn = Double(
      day + (153 * m + 2) / 5 + 365 * y + y / 4 - y / 100 + y / 400 - 32045
    )

    let rad = Double.pi / 180
    let deg = 180 / Double.pi

    // Days since 2000-01-01 12:00 TT (the 0.0008 term folds in leap seconds).
    let n = (jdn - 2451545.0 + 0.0008).rounded()
    // Mean solar noon (east-positive longitude advances the clock).
    let meanNoon = n - longitude / 360.0
    // Solar mean anomaly.
    let anomaly = (357.5291 + 0.98560028 * meanNoon).truncatingRemainder(dividingBy: 360)
    let anomalyR = anomaly * rad
    // Equation of the center.
    let center = 1.9148 * sin(anomalyR) + 0.0200 * sin(2 * anomalyR) + 0.0003 * sin(3 * anomalyR)
    // Ecliptic longitude of the sun.
    let lambda = (anomaly + center + 282.9372).truncatingRemainder(dividingBy: 360)
    let lambdaR = lambda * rad
    // Solar transit (local solar noon, in Julian days).
    let transit = 2451545.0 + meanNoon + 0.0053 * sin(anomalyR) - 0.0069 * sin(2 * lambdaR)
    // Sun's declination.
    let declination = asin(sin(lambdaR) * sin(23.4397 * rad))
    // Hour angle at the horizon, with the standard −0.833° refraction/disc term.
    let cosHourAngle =
      (sin(-0.833 * rad) - sin(latitude * rad) * sin(declination)) /
      (cos(latitude * rad) * cos(declination))
    guard cosHourAngle >= -1, cosHourAngle <= 1 else { return nil }
    let hourAngle = acos(cosHourAngle) * deg

    let sunset = transit + hourAngle / 360.0
    let sunrise = transit - hourAngle / 360.0

    return (date(fromJulian: sunrise), date(fromJulian: sunset))
  }

  /// Converts a Julian date to a Foundation `Date` (2440587.5 = Unix epoch).
  private static func date(fromJulian julian: Double) -> Date {
    Date(timeIntervalSince1970: (julian - 2440587.5) * 86400.0)
  }
}
