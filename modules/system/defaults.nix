{ ... }:

# ─── macOS system.defaults ────────────────────────────────────────────────────
# Active settings below reflect sensible defaults (informed by the current
# system configuration). Commented-out options show what you can add.
# After changing anything here, run:
#   darwin-rebuild switch --flake .#aristotle
# Some settings (e.g. Dock, keyboard) need a logout/restart to fully take
# effect. To apply most without logging out, include the postUserActivation
# snippet at the bottom.
# ─────────────────────────────────────────────────────────────────────────────

{
  system.defaults = {

    # ── Dock ──────────────────────────────────────────────────────────────────
    dock = {
      autohide = true;
      orientation = "bottom";
      tilesize = 38;               # current system value
      show-recents = true;        # don't show recent apps section

      mineffect = "genie";       # "genie" | "scale" | "suck"
      minimize-to-application = true;
      # mru-spaces = false;        # don't rearrange spaces by recent use
      # launchanim = false;        # disable app launch animation
      # expose-animation-duration = 0.1;
      # scroll-to-open = true;     # scroll on app icon to show its windows
    };

    # ── Finder ────────────────────────────────────────────────────────────────
    finder = {
      AppleShowAllExtensions = false;
      FXPreferredViewStyle = "clmv";   # column view (Nlsv=list, icnv=icon, Flwv=gallery)
      # AppleShowAllFiles = true;      # show hidden files (currently off on this system)
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
      # Key repeat — current system values (fast repeat, short initial delay)
      InitialKeyRepeat = 15;   # 15 = ~225ms before repeat starts (25 is default)
      KeyRepeat = 2;           # 2 = ~30ms between repeats (6 is default)
      ApplePressAndHoldEnabled = false;   # allow key repeat instead of accent picker

      # Automatic text corrections — current system has most of these disabled
      NSAutomaticCapitalizationEnabled = false;
      NSAutomaticDashSubstitutionEnabled = false;
      NSAutomaticQuoteSubstitutionEnabled = false;
      NSAutomaticSpellingCorrectionEnabled = false;
      # NSAutomaticPeriodSubstitutionEnabled = false;   # currently ON on this system

      AppleInterfaceStyle = "Dark";       # dark mode — currently active, but
                                          # managing this via Nix means switching
                                          # modes always needs a rebuild. Leave
                                          # unset to control through System Settings.

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
      type = "png";
      # disable-shadow = true;   # no drop shadow on window screenshots
    };

    # ── Trackpad ──────────────────────────────────────────────────────────────
    trackpad = {
      Clicking = true;                  # tap-to-click (currently enabled on this system)
      TrackpadThreeFingerDrag = false;  # use three-finger swipe for Mission Control instead
      # TrackpadRightClick = true;      # two-finger right-click (enabled by default)
    };

    # ── Login Window ──────────────────────────────────────────────────────────
    loginwindow = {
      GuestEnabled = false;
      # DisableConsoleAccess = true;
      # LoginwindowText = "Property of Harry Weiss";
    };

    # ── Software Update ───────────────────────────────────────────────────────
    SoftwareUpdate = {
      AutomaticallyInstallMacOSUpdates = false;
    };

    # ── Spaces ────────────────────────────────────────────────────────────────
    # spaces.spans-displays = false;  # each display has its own Space

    # ── Universal Access ──────────────────────────────────────────────────────
    # universalaccess = {
    #   reduceMotion = true;
    #   reduceTransparency = true;
    # };

    # ── Custom User Preferences (escape hatch for unexduced options) ──────────
    # Use CustomUserPreferences to set any `defaults` key that nix-darwin
    # doesn't expose natively. Keys here are written via `defaults write`.
    # CustomUserPreferences = {
    #   "com.apple.finder" = {
    #     ShowExternalHardDrivesOnDesktop = false;
    #     ShowRemovableMediaOnDesktop = false;
    #   };
    #   "com.apple.desktopservices" = {
    #     DSDontWriteNetworkStores = true;
    #     DSDontWriteUSBStores = true;
    #   };
    # };
  };

  # Apply new defaults without requiring a logout.
  # Activates after every `darwin-rebuild switch`.
  system.activationScripts.postUserActivation.text = ''
    /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u
  '';
}
