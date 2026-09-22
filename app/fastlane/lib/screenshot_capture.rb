require "json"
require "shellwords"

# Drives `flutter drive`-based App Store screenshot capture across the
# three required device classes (see design.md: "One device per required
# App Store Connect size class"). Only `flutter drive` actually writes
# screenshot PNGs to disk (via its driver script's `onScreenshot`
# callback) — `flutter test -d <device>` never does, on any platform, so
# every device here (including macOS) goes through `flutter drive`.
module ScreenshotCapture
  DEVICES = [
    {
      prefix: "iphone",
      simulator_name: "iPhone 17 Pro Max",
      device_type: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max",
    },
    {
      prefix: "ipad",
      simulator_name: "iPad Pro 13-inch (M5)",
      device_type: "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB",
    },
    # macOS runs directly on the fastlane host, not a simulator.
    {prefix: "mac", simulator_name: nil, device_type: nil},
  ].freeze

  # Captures every device in DEVICES against `server` (a started
  # ScreenshotServer), writing prefixed PNGs into output_dir. Raises on the
  # first device that fails — no partial/best-effort screenshot sets.
  def self.capture_all!(flutter_root:, server:, output_dir:, ui: nil)
    DEVICES.each do |d|
      message(ui, "Capturing #{d[:prefix]} screenshots...")
      target = d[:simulator_name] ? simulator_udid(d[:simulator_name], d[:device_type], ui: ui) : "macos"
      drive!(
        flutter_root: flutter_root,
        target: target,
        prefix: d[:prefix],
        server: server,
        output_dir: output_dir
      )
    end
  end

  def self.drive!(flutter_root:, target:, prefix:, server:, output_dir:)
    cmd = <<~SH.tr("\n", " ").strip
      cd #{flutter_root.shellescape} &&
      SCREENSHOT_OUTPUT_DIR=#{output_dir.shellescape}
      SCREENSHOT_PREFIX=#{prefix.shellescape}
      flutter drive
      --driver=test_driver/integration_test.dart
      --target=integration_test/screenshot_test.dart
      --dart-define=SCREENSHOT_CAPTURE=true
      --dart-define=SCREENSHOT_SERVER_URL=#{server.base_url.shellescape}
      --dart-define=SCREENSHOT_API_KEY=#{server.api_key.shellescape}
      -d #{target.shellescape}
    SH
    raise "flutter drive failed capturing #{prefix} screenshots (target #{target})" unless system(cmd)
  end

  # Finds an already-available simulator matching `name`, creating one
  # against the newest available iOS runtime if none exists, then boots it
  # if it isn't already. Returns its UDID.
  def self.simulator_udid(name, device_type_id, ui: nil)
    existing = simulator_by_name(name)
    return boot!(existing.fetch("udid")) if existing

    message(ui, "No existing '#{name}' simulator; creating one against the newest available iOS runtime...")
    runtime_id = latest_ios_runtime_id
    udid = `xcrun simctl create #{name.shellescape} #{device_type_id.shellescape} #{runtime_id.shellescape}`.strip
    raise "failed to create simulator '#{name}' (runtime #{runtime_id})" if udid.empty?

    boot!(udid)
  end

  # This machine has more than one simulator matching a given name (Xcode
  # provisions one per installed iOS runtime, e.g. 26.5 and 27.0), and
  # booting an extra one alongside an already-booted match wastes real
  # time and memory — observed hanging a capture run for 30+ minutes with
  # 4 simulators booted simultaneously. So: prefer an already-booted
  # match over any other candidate.
  def self.simulator_by_name(name)
    candidates = JSON.parse(`xcrun simctl list devices available -j`)
                     .fetch("devices")
                     .values
                     .flatten
                     .select { |d| d["name"] == name }
    candidates.find { |d| d["state"] == "Booted" } || candidates.first
  end

  def self.boot!(udid)
    devices = JSON.parse(`xcrun simctl list devices -j`).fetch("devices").values.flatten
    state = devices.find { |d| d["udid"] == udid }&.fetch("state", nil)
    unless state == "Booted"
      ok = system("xcrun simctl boot #{udid.shellescape}")
      raise "failed to boot simulator #{udid}" unless ok
    end
    udid
  end

  def self.latest_ios_runtime_id
    runtimes = JSON.parse(`xcrun simctl list runtimes available -j`).fetch("runtimes")
    ios_runtimes = runtimes.select { |r| r["name"].start_with?("iOS") }
    raise "no available iOS simulator runtime found" if ios_runtimes.empty?

    ios_runtimes.max_by { |r| Gem::Version.new(r["version"]) }.fetch("identifier")
  end

  def self.message(ui, text)
    ui ? ui.message(text) : puts(text)
  end
end
