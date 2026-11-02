cask "strata" do
  version "0.7.6"
  sha256 :no_check

  url "https://github.com/jonaprieto/strata-files/releases/download/fork-#{version}/Strata-#{version}.zip"
  name "Strata Files"
  desc "Native file manager with instant search and dual panes (personal fork)"
  homepage "https://github.com/jonaprieto/strata-files"

  # Same token and bundle identifier as upstream's Strata, so only one of them can be installed;
  # always use the full name jonaprieto/tap/strata.
  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "Strata.app"
  binary "#{appdir}/Strata.app/Contents/Helpers/strata"

  # The build is ad-hoc signed and not notarized, so clear the quarantine flag.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-cr", "{{appdir}}/Strata.app"]
  end

  caveats <<~EOS
    An ad-hoc signature changes with every build, so macOS asks for folder access again after each
    update. For Full Disk Access, remove Strata from that list in System Settings and add it again.
  EOS
end
