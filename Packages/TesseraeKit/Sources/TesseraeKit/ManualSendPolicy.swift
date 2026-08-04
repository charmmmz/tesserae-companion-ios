public enum ManualSendPolicy {
    /// Deliberate user actions publish immediately. Quiet hours continue to
    /// protect scheduled and automated delivery paths.
    public static let overridesQuietHours = true
}
