# Run with: HOMEBREW_DEVELOPER=1 brew ruby Tests/HomebrewTests/test_tickrest_dev_cask.rb
# Uses Homebrew's actual Cask DSL and temporary apps; never launches the app.
require "cask/cask_loader"
require "digest"
require "json"
require "tmpdir"

root = Pathname(__dir__).parent.parent
source = Pathname(ENV.fetch("HOMEBREW_TICKREST_DEV_CASK", (root/"tickrest-dev.rb").to_s)).read
original_arch = ENV["HOMEBREW_TICKREST_DEV_ARCH"]

begin
  variants = { nil => "universal", "universal" => "universal", "arm" => "arm64",
               "arm64" => "arm64", "intel" => "x86_64", "x86_64" => "x86_64" }
  variants.each do |selection, expected|
    selection ? ENV["HOMEBREW_TICKREST_DEV_ARCH"] = selection : ENV.delete("HOMEBREW_TICKREST_DEV_ARCH")
    cask = Cask::CaskLoader::FromContentLoader.new(source).load(config: nil)
    app = cask.artifacts.find { |artifact| artifact.is_a?(Cask::Artifact::App) }
    raise "Wrong cask token" unless cask.token == "tickrest-dev"
    raise "Wrong selected app" unless app.source.basename.to_s == "Tick Rest-#{expected}.app"
    raise "Wrong default target" unless app.target.to_s == "/Applications/Tick Rest.app"
    required_arch = case expected
    when "arm64" then [{ type: :arm, bits: 64 }]
    when "x86_64" then [{ type: :intel, bits: 64 }]
    end
    raise "Wrong architecture restriction" unless cask.depends_on.arch == required_arch
    raise "Wrong conflicts" unless cask.conflicts_with.to_h.fetch(:cask) == ["tickrest"]
    puts "PASS selection #{selection || '(default)'} -> #{expected}"
  end

  ENV["HOMEBREW_TICKREST_DEV_ARCH"] = "invalid"
  begin
    Cask::CaskLoader::FromContentLoader.new(source).load(config: nil)
    raise "Invalid architecture was accepted"
  rescue ArgumentError => e
    raise unless e.message.include?("HOMEBREW_TICKREST_DEV_ARCH")
  end
  puts "PASS invalid architecture rejected"

  %w[universal arm64 x86_64].each do |architecture|
    ENV["HOMEBREW_TICKREST_DEV_ARCH"] = architecture
    Dir.mktmpdir("tickrest cask test ") do |temporary|
      config = Cask::Config.new(explicit: { appdir: temporary })
      cask = Cask::CaskLoader::FromContentLoader.new(source).load(config: config)
      # Loading an installed token restores its receipt config, even with config: above.
      # Override it explicitly before running any artifact, so postflight cannot touch /Applications.
      cask.config = config
      raise "Unsafe test appdir" unless cask.config.appdir == Pathname(temporary)
      app_artifact = cask.artifacts.find { |artifact| artifact.is_a?(Cask::Artifact::App) }
      raise "Unsafe test target" unless app_artifact.target == Pathname(temporary)/"Tick Rest.app"
      uri = URI(cask.url.to_s)
      archive = case uri.scheme
      when "file"
        Pathname(URI::DEFAULT_PARSER.unescape(uri.path))
      when "https"
        if ENV["HOMEBREW_TICKREST_DEV_ARCHIVE_DIR"]
          Pathname(ENV.fetch("HOMEBREW_TICKREST_DEV_ARCHIVE_DIR"))/File.basename(uri.path)
        else
          download = Pathname(temporary)/"download.zip"
          system "/usr/bin/curl", "-fLsS", "--retry", "2", "--connect-timeout", "15", "--max-time", "120",
                 "-o", download.to_s, uri.to_s, exception: true
          download
        end
      else
        raise "Unsupported archive URL scheme: #{uri.scheme}"
      end
      raise "ZIP checksum mismatch" unless Digest::SHA256.file(archive).hexdigest == cask.sha256.to_s
      system "/usr/bin/ditto", "-x", "-k", archive.to_s, temporary, exception: true
      target = Pathname(temporary)/"Tick Rest.app"
      (Pathname(temporary)/"Tick Rest-#{architecture}.app").rename(target)
      info = JSON.parse(IO.popen(["/usr/bin/plutil", "-convert", "json", "-o", "-",
                                 (target/"Contents/Info.plist").to_s], &:read))
      raise "Wrong bundle ID" unless info.fetch("CFBundleIdentifier") == "app.tickrest.desktop"
      raise "Cask/App version mismatch" unless cask.version.to_s ==
                                                  "#{info.fetch('CFBundleShortVersionString')},#{info.fetch('CFBundleVersion')}"
      executable = target/"Contents/MacOS/Tick Rest"
      actual = IO.popen(["/usr/bin/lipo", "-archs", executable.to_s], &:read).split.sort
      expected = architecture == "universal" ? %w[arm64 x86_64] : [architecture]
      raise "Wrong ZIP binary architecture: #{actual}" unless actual == expected
      system "/usr/bin/codesign", "--verify", "--deep", "--strict", target.to_s, exception: true
      [target, executable].each do |path|
        system "/usr/bin/xattr", "-w", "com.apple.quarantine", "0081;00000000;TickRestTest;", path.to_s,
               exception: true
        system "/usr/bin/xattr", "-w", "org.tickrest.cask-test", "preserve", path.to_s, exception: true
      end
      postflight = cask.artifacts.find { |artifact| artifact.is_a?(Cask::Artifact::PostflightSteps) }
      2.times { postflight.install_phase }
      [target, executable].each do |path|
        attributes = IO.popen(["/usr/bin/xattr", path.to_s], &:read).lines.map(&:chomp)
        raise "Quarantine was not removed recursively" if attributes.include?("com.apple.quarantine")
        raise "Unrelated attribute was removed" unless attributes.include?("org.tickrest.cask-test")
      end
      puts "PASS #{architecture}: checksum, ZIP, version, signature, binary and idempotent postflight"
    end
  end
ensure
  original_arch ? ENV["HOMEBREW_TICKREST_DEV_ARCH"] = original_arch : ENV.delete("HOMEBREW_TICKREST_DEV_ARCH")
end
