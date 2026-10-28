import Foundation

/// Slider display bounds never rewrite a stored value until the user edits it.
public struct DashboardSettingSlider: Equatable, Sendable {
  public let minimum: Double
  public let maximum: Double
  public let step: Double

  public init?(_ field: DashboardSettingInput) {
    let minimum = field.min ?? 0
    let maximum = field.max ?? 100
    let step = field.step ?? 1
    guard minimum.isFinite, maximum.isFinite, step.isFinite,
      maximum > minimum, step > 0, ((maximum - minimum) / step).isFinite else { return nil }
    self.minimum = minimum
    self.maximum = maximum
    self.step = step
  }

  public func displayValue(_ value: DashboardSettingValue?) -> Double {
    guard case .number(let number) = value, number.isFinite else { return minimum }
    return min(maximum, max(minimum, number))
  }

  public func snapped(_ value: Double) -> Double {
    guard value.isFinite else { return minimum }
    let bounded = min(maximum, max(minimum, value))
    let lastStep = floor((maximum - minimum) / step + 1e-10)
    let index = min(lastStep, max(0, ((bounded - minimum) / step).rounded()))
    if let origin = Decimal(string: String(minimum)), let increment = Decimal(string: String(step)) {
      let number = NSDecimalNumber(decimal: origin + Decimal(index) * increment).doubleValue
      if number.isFinite { return number }
    }
    return minimum + index * step
  }
}

/// Keep the original JSON object, including a valid zone and optional metadata,
/// when editing coordinates. Picking another search result replaces the place.
public struct DashboardSettingLocation: Equatable, Sendable {
  public let properties: [String: DashboardSettingValue]
  public let latitude: Double
  public let longitude: Double

  public init?(_ value: DashboardSettingValue?) {
    guard case .object(let object) = value,
      case .number(let latitude) = object["latitude"],
      case .number(let longitude) = object["longitude"],
      Self.valid(latitude: latitude, longitude: longitude) else { return nil }
    properties = object
    self.latitude = latitude
    self.longitude = longitude
  }

  public var name: String { properties["name"]?.settingText ?? "" }
  public var timezone: String { properties["timezone"]?.settingText ?? "" }
  public var summary: String {
    name.isEmpty ? "\(latitude.formatted()), \(longitude.formatted())" : name
  }

  public static func valid(latitude: Double, longitude: Double) -> Bool {
    latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude)
      && (-180...180).contains(longitude)
  }

  public static func coordinates(
    latitude: Double, longitude: Double, name: String, timezone: String,
    preserving original: DashboardSettingValue?
  ) -> DashboardSettingValue? {
    guard valid(latitude: latitude, longitude: longitude),
      timezone.isEmpty || TimeZone(identifier: timezone) != nil else { return nil }
    var object: [String: DashboardSettingValue] =
      if case .object(let saved) = original { saved } else { [:] }
    object["latitude"] = .number(latitude)
    object["longitude"] = .number(longitude)
    object["name"] = .string(name.trimmingCharacters(in: .whitespacesAndNewlines))
    if timezone.isEmpty { object.removeValue(forKey: "timezone") }
    else { object["timezone"] = .string(timezone) }
    return .object(object)
  }
}

/// A swatch for common CSS colors. Other CSS/theme expressions remain editable
/// as their original text; opening a picker never converts that stored text.
public struct DashboardSettingColor: Equatable, Sendable {
  public let red: Double
  public let green: Double
  public let blue: Double
  public let opacity: Double

  public init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
    self.red = red
    self.green = green
    self.blue = blue
    self.opacity = opacity
  }

  public init?(css: String) {
    let named: [String: String] = [
      "black": "000000", "white": "ffffff", "red": "ff0000", "green": "008000",
      "blue": "0000ff", "yellow": "ffff00", "gray": "808080", "grey": "808080",
      "orange": "ffa500", "purple": "800080", "pink": "ffc0cb", "brown": "a52a2a",
      "navy": "000080", "teal": "008080", "lime": "00ff00", "aqua": "00ffff",
      "cyan": "00ffff", "magenta": "ff00ff", "fuchsia": "ff00ff", "silver": "c0c0c0",
      "maroon": "800000", "olive": "808000", "transparent": "00000000",
    ]
    let text = css.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let raw: String
    if text.hasPrefix("#") { raw = String(text.dropFirst()) }
    else if let hex = named[text] { raw = hex }
    else { return nil }
    let expanded = [3, 4].contains(raw.count)
      ? raw.map { String(repeating: String($0), count: 2) }.joined() : raw
    guard [6, 8].contains(expanded.count), let number = UInt64(expanded, radix: 16) else { return nil }
    let rgba = expanded.count == 6 ? (number << 8) | 255 : number
    self.init(red: Double((rgba >> 24) & 255) / 255,
      green: Double((rgba >> 16) & 255) / 255,
      blue: Double((rgba >> 8) & 255) / 255, opacity: Double(rgba & 255) / 255)
  }

  public var css: String {
    func byte(_ value: Double) -> Int {
      value.isFinite ? Int((min(1, max(0, value)) * 255).rounded()) : 0
    }
    let rgb = String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    return byte(opacity) == 255 ? rgb : rgb + String(format: "%02X", byte(opacity))
  }
}
