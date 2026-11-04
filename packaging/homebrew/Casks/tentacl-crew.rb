cask "tentacl-crew" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/kerhun/tentacl-crew/releases/download/v#{version}/TentaclCrew-#{version}.zip"
  name "Tentacl Crew"
  desc "Local panel that runs a team of coding agents"
  homepage "https://github.com/kerhun/tentacl-crew"

  livecheck do
    url :url
    strategy :github_latest
    regex(/v?(\d+(?:\.\d+)+(?:-beta\.\d+)?)/i)
  end

  depends_on macos: :sonoma

  app "Tentacl.app"

  zap trash: [
    "~/.config/tentacl",
    "~/Library/Application Support/Tentacl",
    "~/Library/Caches/com.kerhun.Tentacl",
    "~/Library/Preferences/com.kerhun.Tentacl.plist",
    "~/Library/Saved Application State/com.kerhun.Tentacl.savedState",
  ]

  caveats <<~EOS
    Tentacl Crew is ad hoc signed, not notarized. Open it once, then allow it in
    System Settings → Privacy & Security → "Open Anyway".
  EOS
end
