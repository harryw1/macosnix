{ username, ... }:

# ─── macOS system.defaults ────────────────────────────────────────────────────
# Active settings below reflect sensible defaults (informed by the current
# system configuration). Commented-out options show what you can add.
# After changing anything here, run:
#   darwin-rebuild switch --flake .#aristotle
# Some settings (e.g. Dock, keyboard) need a logout/restart to fully take
# effect. To apply most without logging out, include the postUserActivation
# snippet at the bottom.
#
# Settings that deviate from macOS factory defaults are marked [non-default].
# Review these before first activation — enable only what you want from day one.
# ─────────────────────────────────────────────────────────────────────────────

{
  system.defaults = {

    # ── Dock ──────────────────────────────────────────────────────────────────
    dock = {
      autohide = true;              # [non-default] macOS default: false
      orientation = "bottom";       # macOS default: "bottom" — no change
      tilesize = 38;                # [non-default] macOS default: 48
      show-recents = true;          # macOS default: true — no change
      expose-group-apps = true;     # [non-default] macOS default: false — recommended for AeroSpace

      mineffect = "genie";          # macOS default: "genie" — no change
      minimize-to-application = true; # [non-default] macOS default: false
      # mru-spaces = false;         # don't rearrange spaces by recent use
      # launchanim = false;         # disable app launch animation
      # expose-animation-duration = 0.1;
      # scroll-to-open = true;      # scroll on app icon to show its windows
    };

    # ── Finder ────────────────────────────────────────────────────────────────
    finder = {
      AppleShowAllExtensions = false; # macOS default: false — no change
      FXPreferredViewStyle = "clmv";  # [non-default] macOS default: "icnv" (icon view)
                                      # "clmv"=column, "Nlsv"=list, "Flwv"=gallery
      # AppleShowAllFiles = true;     # show hidden files (currently off on this system)
      # ShowStatusBar = true;
      # ShowPathbar = true;
      # FXEnableExtensionChangeWarning = false;
      # FXDefaultSearchScope = "SCcf";   # search current folder by default
      # _FXShowPosixPathInTitle = true;
      # CreateDesktop = false;           # don't show icons on desktop
    };

    # ── NSGlobalDomain ────────────────────────────────────────────────────────
    # (system-wide preferences)
    NSGlobalDomain = {
      # Key repeat — [non-default] macOS defaults: InitialKeyRepeat=25, KeyRepeat=6
      InitialKeyRepeat = 15;   # 15 = ~225ms before repeat starts
      KeyRepeat = 2;           # 2 = ~30ms between repeats (very fast — tune to taste)
      ApplePressAndHoldEnabled = false;   # [non-default] macOS default: true
                                          # false = key repeat; true = accent picker popup

      # Automatic text corrections — [non-default] macOS defaults: all true
      NSAutomaticCapitalizationEnabled = false;
      NSAutomaticDashSubstitutionEnabled = false;
      NSAutomaticQuoteSubstitutionEnabled = false;
      NSAutomaticSpellingCorrectionEnabled = false;
      # NSAutomaticPeriodSubstitutionEnabled = false;   # macOS default: true

      # Dark mode — leave unset here; control it through System Settings instead.
      # Managing this via Nix means switching light/dark always needs a rebuild.
      # Uncomment only if you want to permanently lock to dark mode:
      # AppleInterfaceStyle = "Dark";   # [non-default] macOS default: unset (Light)

      # AppleShowAllExtensions = true;    # also settable here (same as finder above)
      # NSNavPanelExpandedStateForSaveMode = true;
      # NSNavPanelExpandedStateForSaveMode2 = true;
      # PMPrintingExpandedStateForPrint = true;
      # PMPrintingExpandedStateForPrint2 = true;
      # AppleFontSmoothing = 0;           # 0=off, 1=light, 2=medium (for non-Retina)
      # AppleKeyboardUIMode = 3;          # enable full keyboard access for all controls
    };

    # ── Screencapture ─────────────────────────────────────────────────────────
    screencapture = {
      # location = "/Users/harryweiss/Screenshots";  # custom save location
      type = "png";               # macOS default: "png" — no change
      # disable-shadow = true;    # no drop shadow on window screenshots
    };

    # ── Trackpad ──────────────────────────────────────────────────────────────
    trackpad = {
      Clicking = true;                  # [non-default] macOS default: false (tap-to-click off)
      TrackpadThreeFingerDrag = false;  # macOS default: false — no change
      # TrackpadRightClick = true;      # two-finger right-click (enabled by default)
    };

    # ── Login Window ──────────────────────────────────────────────────────────
    loginwindow = {
      GuestEnabled = false;         # macOS default: false — no change
      # DisableConsoleAccess = true;
      # LoginwindowText = "Property of Harry Weiss";
    };

    # ── Software Update ───────────────────────────────────────────────────────
    SoftwareUpdate = {
      AutomaticallyInstallMacOSUpdates = false; # [non-default] macOS default: true
    };

    # ── Window Manager (Sequoia+) ─────────────────────────────────────────────
    WindowManager = {
      EnableTiledWindowMargins = true; # [macOS 15+] true = gaps around tiled windows
    };

    # ── Spaces ────────────────────────────────────────────────────────────────
    spaces.spans-displays = false;  # each display has its own Space

    # ── Universal Access ──────────────────────────────────────────────────────
    # universalaccess = {
    #   reduceMotion = true;
    #   reduceTransparency = true;
    # };

    # ── Control Center ────────────────────────────────────────────────────────
    controlcenter = {
      BatteryShowPercentage = true;
    };

    # ── Custom User Preferences (escape hatch for unexduced options) ──────────
    # Use CustomUserPreferences to set any `defaults` key that nix-darwin
    # doesn't expose natively. Keys here are written via `defaults write`.
    CustomUserPreferences = {
      "com.apple.Spotlight" = {
        MenuItemHidden = 1;
      };
      # "com.apple.finder" = {
      #   ShowExternalHardDrivesOnDesktop = false;
      #   ShowRemovableMediaOnDesktop = false;
      # };
      # "com.apple.desktopservices" = {
      #   DSDontWriteNetworkStores = true;
      #   DSDontWriteUSBStores = true;
      # };
    };
  };

  # Apply new defaults without requiring a logout.
  # Runs as root after every `darwin-rebuild switch`; sudo -u runs activateSettings
  # as the primary user so macOS picks up the per-user defaults immediately.
  system.activationScripts.postActivation.text = ''
    sudo -u ${username} /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u
  '';
}
