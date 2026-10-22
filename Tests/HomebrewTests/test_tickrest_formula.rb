require "fileutils"
require "minitest/autorun"
require "open3"
require "pathname"
require "tmpdir"

# Load the actual launcher generator without installing a tap or changing the
# user's Homebrew files. Only the unrelated Formula metadata DSL is stubbed.
class Formula
  def self.desc(*) end
  def self.homepage(*) end
  def self.url(*) end
  def self.version(*) end
  def self.license(*) end
  def self.depends_on(*) end
  def self.skip_clean(*) end
  def self.test(&block) end
end

require_relative "../../tickrest"

class TickrestFormulaTests < Minitest::Test
  def setup
    @root = Pathname.new(Dir.mktmpdir("tickrest-formula-"))
    @applications = @root/"Applications with spaces"
    @applications.mkpath
    @opt = @root/"opt/tickrest"
    @opt.dirname.mkpath
    @keg = make_keg("1.0.0")
    File.symlink(@keg, @opt)
    @app = @opt/"libexec/Tick Rest.app"
    @link = @applications/"Tick Rest.app"
    @opened = @root/"opened.txt"
    opener = @root/"fake open"
    opener.write("#!/bin/sh\nprintf '%s\\n' \"$@\" > #{@opened.to_s.shellescape}\n")
    opener.chmod(0755)
    formula = Tickrest.new
    opt_libexec = @opt/"libexec"
    formula.define_singleton_method(:opt_libexec) { opt_libexec }
    @launcher = @root/"tickrest"
    @launcher.write(formula.launcher_script(applications_dir: @applications, opener: opener))
    @launcher.chmod(0755)
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def make_keg(version)
    keg = @root/"Cellar/tickrest/#{version}"
    app = keg/"libexec/Tick Rest.app"
    (app/"Contents/MacOS").mkpath
    executable = app/"Contents/MacOS/Tick Rest"
    executable.write("#!/bin/sh\nexit 0\n")
    executable.chmod(0755)
    (app/"Contents/Info.plist").write(<<~PLIST)
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>#{version}</string></dict></plist>
    PLIST
    keg
  end

  def run_launcher(*args)
    Open3.capture3(@launcher.to_s, *args)
  end

  def test_first_launch_creates_stable_link_and_preserves_arguments
    _stdout, stderr, status = run_launcher("--example", "argument with spaces")
    assert status.success?, stderr
    assert_equal @app.to_s, @link.readlink.to_s
    assert_equal [@app.to_s, "--args", "--example", "argument with spaces"], @opened.read.lines.map(&:chomp)
  end

  def test_repeated_launch_keeps_the_existing_link
    run_launcher
    inode = @link.lstat.ino
    _stdout, stderr, status = run_launcher
    assert status.success?, stderr
    assert_equal inode, @link.lstat.ino
  end

  def test_upgrade_switches_app_without_recreating_applications_entry
    run_launcher
    inode = @link.lstat.ino
    newer = make_keg("1.1.0")
    @opt.unlink
    File.symlink(newer, @opt)
    # Removing the old keg must not break the entry.
    FileUtils.remove_entry(@keg)
    _stdout, stderr, status = run_launcher
    assert status.success?, stderr
    assert_equal inode, @link.lstat.ino
    assert_equal (newer/"libexec/Tick Rest.app").realpath, @link.realpath
    stdout, stderr, status = run_launcher("--version")
    assert status.success?, stderr
    assert_equal "1.1.0", stdout.strip
  end

  def test_independent_app_is_preserved_but_managed_app_can_still_launch
    @link.mkpath
    marker = @link/"user-file"
    marker.write("preserve")
    _stdout, stderr, status = run_launcher
    assert status.success?, stderr
    assert_includes stderr, "Preserved existing app or link"
    assert_equal "preserve", marker.read
    refute @link.symlink?
    assert @opened.file?
    refute (@link/"Tick Rest.app").exist?
  end

  def test_explicit_link_refuses_foreign_and_dangling_links
    [@root/"missing.app", make_keg("9.0.0")/"libexec/Tick Rest.app"].each do |target|
      File.symlink(target, @link)
      _stdout, _stderr, status = run_launcher("--link-app")
      refute status.success?
      assert_equal target.to_s, @link.readlink.to_s
      refute @opened.exist?
      @link.unlink
    end
  end

  def test_link_and_unlink_do_not_open_or_delete_the_installed_app
    _stdout, stderr, status = run_launcher("--link-app")
    assert status.success?, stderr
    assert @link.symlink?
    refute @opened.exist?
    _stdout, stderr, status = run_launcher("--unlink-app")
    assert status.success?, stderr
    refute @link.symlink?
    assert @app.directory?
    assert run_launcher("--unlink-app").last.success?
  end

  def test_unlink_refuses_unmanaged_entries
    @link.mkpath
    refute run_launcher("--unlink-app").last.success?
    assert @link.directory?
    @link.rmdir
    target = @root/"foreign.app"
    File.symlink(target, @link)
    refute run_launcher("--unlink-app").last.success?
    assert_equal target.to_s, @link.readlink.to_s
  end

  def test_missing_applications_directory_does_not_block_launch
    @applications.rmdir
    _stdout, _stderr, status = run_launcher
    assert status.success?
    assert @opened.file?
    refute @link.symlink?
    refute run_launcher("--link-app").last.success?
  end

  def test_missing_app_never_creates_broken_entry_or_opens_gui
    FileUtils.remove_entry(@keg)
    _stdout, stderr, status = run_launcher
    refute status.success?
    assert_includes stderr, "brew reinstall fthux/tap/tickrest"
    refute @link.symlink?
    refute @opened.exist?
  end

  def test_unwritable_applications_directory_does_not_block_launch
    skip "Root can write regardless of mode bits" if Process.euid.zero?
    @applications.chmod(0555)
    _stdout, stderr, status = run_launcher
    assert status.success?, stderr
    assert_includes stderr, "Check directory permissions"
    assert @opened.file?
    refute @link.symlink?
  ensure
    @applications.chmod(0755) if @applications.directory?
  end

  def test_help_and_version_have_no_filesystem_or_gui_side_effects
    stdout, stderr, status = run_launcher("--version")
    assert status.success?, stderr
    assert_equal "1.0.0", stdout.strip
    stdout, stderr, status = run_launcher("--help")
    assert status.success?, stderr
    assert_includes stdout, "--link-app"
    refute @link.symlink?
    refute @opened.exist?
  end
end
