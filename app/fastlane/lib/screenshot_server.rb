require "fileutils"
require "net/http"
require "socket"
require "tmpdir"

# Builds and runs a disposable robot-notes server instance for App Store
# screenshot capture, then tears it down again.
#
# Boots the server the same production-parity way `test-hermes-plugin-e2e`
# and `server/Dockerfile` do (`dart_frog build` + `dart build cli`), not via
# `dart_frog dev` or a bare `dart run main.dart` — both of those skip the
# Dart build hooks `package:sqlite3` needs to bundle a native `libsqlite3`,
# which resolves by luck on most developer machines but fails outright on a
# bare CI runner ("No available native assets"). See Makefile:90-108 for the
# original writeup of this gotcha.
class ScreenshotServer
  API_KEY = "screenshot-capture-key-not-a-secret".freeze
  HEALTH_TIMEOUT_SECONDS = 90

  attr_reader :base_url, :api_key

  # server_root: path to the `server/` directory (production build lives here)
  def initialize(server_root:, ui: nil)
    @server_root = File.expand_path(server_root)
    @ui = ui
    @api_key = API_KEY
    @pid = nil
    @data_dir = nil
  end

  # Builds the server (once) and starts a fresh instance against a new temp
  # data dir. Raises if the build fails or the server doesn't become healthy
  # within HEALTH_TIMEOUT_SECONDS.
  def start
    build_dir = File.join(@server_root, "build")
    bundle_bin = File.join(build_dir, "out", "bundle", "bin", "server")

    message("Building robot-notes server for screenshot capture...")
    FileUtils.rm_rf(build_dir)
    run!(["dart_frog", "build"], chdir: @server_root)

    generated_entrypoint = File.join(build_dir, "bin", "server.dart")
    patch_loopback_address(generated_entrypoint)

    run!(["dart", "pub", "get"], chdir: build_dir)
    run!(["dart", "build", "cli", "-o", "out"], chdir: build_dir)
    raise "expected compiled server bundle at #{bundle_bin}" unless File.executable?(bundle_bin)

    @data_dir = Dir.mktmpdir("robot-notes-screenshot-data-")
    port = free_tcp_port
    @base_url = "http://127.0.0.1:#{port}"

    message("Starting ephemeral server on #{@base_url} (data dir #{@data_dir})...")
    log_path = File.join(@data_dir, "server.log")
    @pid = Process.spawn(
      {
        "ROBOT_NOTES_API_KEY" => @api_key,
        "ROBOT_NOTES_DATA_DIR" => @data_dir,
        "ROBOT_NOTES_PORT" => port.to_s,
      },
      bundle_bin,
      out: log_path,
      err: [:child, :out],
      pgroup: true
    )

    wait_for_health!(log_path)
    self
  end

  # Kills the server process group and removes its temp data dir. Safe to
  # call multiple times and safe to call even if `start` never succeeded.
  def stop
    if @pid
      begin
        Process.kill("-TERM", @pid)
        Process.waitpid(@pid)
      rescue Errno::ESRCH, Errno::ECHILD
        # already gone
      end
      @pid = nil
    end
    if @data_dir && Dir.exist?(@data_dir)
      FileUtils.rm_rf(@data_dir)
      @data_dir = nil
    end
  end

  private

  def patch_loopback_address(path)
    raise "expected generated entrypoint at #{path}" unless File.exist?(path)

    contents = File.read(path)
    patched = contents.sub("InternetAddress.anyIPv6", "InternetAddress.loopbackIPv4")
    raise "expected to find InternetAddress.anyIPv6 in #{path}" if patched == contents

    File.write(path, patched)
  end

  def free_tcp_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1]
  ensure
    server&.close
  end

  def wait_for_health!(log_path)
    deadline = Time.now + HEALTH_TIMEOUT_SECONDS
    uri = URI("#{@base_url}/healthz")
    loop do
      begin
        response = Net::HTTP.get_response(uri)
        return if response.is_a?(Net::HTTPSuccess)
      rescue StandardError
        # not up yet
      end
      if Time.now > deadline
        log = File.exist?(log_path) ? File.read(log_path) : "(no log)"
        raise "robot-notes screenshot server did not become healthy within " \
              "#{HEALTH_TIMEOUT_SECONDS}s\n--- server log ---\n#{log}"
      end
      sleep 1
    end
  end

  def run!(cmd, chdir:)
    ok = system(*cmd, chdir: chdir)
    raise "command failed (#{$?.exitstatus}): #{cmd.join(' ')} (in #{chdir})" unless ok
  end

  def message(text)
    @ui ? @ui.message(text) : puts(text)
  end
end
