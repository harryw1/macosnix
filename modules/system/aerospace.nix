{ ... }:

{
  # ── AeroSpace ──────────────────────────────────────────────────────────────
  # A tiling window manager for macOS with a focus on simplicity and speed.
  # Managed via nix-darwin service (launchd).
  # ───────────────────────────────────────────────────────────────────────────

  services.aerospace = {
    enable = true;

    # The settings below map directly to the AeroSpace TOML configuration format.
    # See: https://nikitabobko.github.io/AeroSpace/guide#configuring-aerospace
    settings = {

      # ── Global behaviour ────────────────────────────────────────────────────
      # Move the mouse to the focused window on any focus change — replaces the
      # removed top-level focus-follows-mouse key.
      on-focus-changed = ["move-mouse window-lazy-center"];

      # Auto-alternate split direction on each new window — mimics Hyprland's
      # dwindle layout where splits rotate between horizontal and vertical.
      default-root-container-orientation = "auto";
      default-root-container-layout = "tiles";

      # Bring back apps that macOS silently hides after workspace switches.
      automatically-unhide-macos-hidden-apps = true;

      # ── Gaps (Hyprland-style: tighter inner, wider outer) ──────────────────
      gaps = {
        inner.horizontal = 6;
        inner.vertical   = 6;
        outer.left       = 12;
        outer.bottom     = 12;
        outer.top        = 12;
        outer.right      = 12;
      };

      # ── Window rules (like Hyprland's windowrulev2) ────────────────────────
      # Automatically assign apps to workspaces on launch.
      on-window-detected = [
        # Browsers → workspace 1
        { "if".app-id = "com.apple.Safari";               run = "move-node-to-workspace 1"; }
        { "if".app-id = "com.google.Chrome";              run = "move-node-to-workspace 1"; }
        { "if".app-id = "org.mozilla.firefox";            run = "move-node-to-workspace 1"; }
        { "if".app-id = "company.thebrowser.Browser";     run = "move-node-to-workspace 1"; } # Arc
        # Terminals → workspace 2
        { "if".app-id = "net.kovidgoyal.kitty";           run = "move-node-to-workspace 2"; }
        { "if".app-id = "com.apple.Terminal";             run = "move-node-to-workspace 2"; }
        { "if".app-id = "io.alacritty";                   run = "move-node-to-workspace 2"; }
        { "if".app-id = "com.mitchellh.ghostty";          run = "move-node-to-workspace 2"; }
        # Editors / IDEs → workspace 3
        { "if".app-id = "com.microsoft.VSCode";           run = "move-node-to-workspace 3"; }
        { "if".app-id = "com.todesktop.230313mzl4w4u92"; run = "move-node-to-workspace 3"; } # Cursor
        { "if".app-id = "com.apple.dt.Xcode";            run = "move-node-to-workspace 3"; }
        # Chat / comms → workspace 4
        { "if".app-id = "com.tinyspeck.slackmacgap";     run = "move-node-to-workspace 4"; }
        { "if".app-id = "com.hnc.Discord";                run = "move-node-to-workspace 4"; }
        { "if".app-id = "com.apple.Messages";             run = "move-node-to-workspace 4"; }
        { "if".app-id = "ru.keepcoder.Telegram";          run = "move-node-to-workspace 4"; }
        # Music / media → workspace 5
        { "if".app-id = "com.spotify.client";             run = "move-node-to-workspace 5"; }
        { "if".app-id = "com.apple.Music";                run = "move-node-to-workspace 5"; }
      ];

      mode.main.binding = {
        # ── Window actions (mirrors common Hyprland SUPER binds) ─────────────
        alt-shift-q     = "close";                   # SUPER+Q  close window
        alt-f           = "fullscreen";              # SUPER+F  fullscreen
        alt-shift-space = "layout floating tiling";  # SUPER+V  toggle floating

        # ── Layouts ───────────────────────────────────────────────────────────
        alt-slash = "layout tiles horizontal vertical";
        alt-comma = "layout accordion horizontal vertical";

        # ── Focus (vim-style, equivalent to Hyprland SUPER+arrow) ─────────────
        alt-h = "focus left";
        alt-j = "focus down";
        alt-k = "focus up";
        alt-l = "focus right";

        # ── Move ──────────────────────────────────────────────────────────────
        alt-shift-h = "move left";
        alt-shift-j = "move down";
        alt-shift-k = "move up";
        alt-shift-l = "move right";

        # ── Workspace cycling (like Hyprland SUPER+scroll) ────────────────────
        alt-tab       = "workspace --wrap-around next";
        alt-shift-tab = "workspace --wrap-around prev";

        # ── Workspaces 1–9 (like Hyprland SUPER+1–9) ──────────────────────────
        alt-1 = "workspace 1";
        alt-2 = "workspace 2";
        alt-3 = "workspace 3";
        alt-4 = "workspace 4";
        alt-5 = "workspace 5";
        alt-6 = "workspace 6";
        alt-7 = "workspace 7";
        alt-8 = "workspace 8";
        alt-9 = "workspace 9";

        alt-shift-1 = "move-node-to-workspace 1";
        alt-shift-2 = "move-node-to-workspace 2";
        alt-shift-3 = "move-node-to-workspace 3";
        alt-shift-4 = "move-node-to-workspace 4";
        alt-shift-5 = "move-node-to-workspace 5";
        alt-shift-6 = "move-node-to-workspace 6";
        alt-shift-7 = "move-node-to-workspace 7";
        alt-shift-8 = "move-node-to-workspace 8";
        alt-shift-9 = "move-node-to-workspace 9";

        # ── Modes ─────────────────────────────────────────────────────────────
        alt-r               = "mode resize";   # SUPER+R resize submap in Hyprland
        alt-shift-semicolon = "mode service";
      };

      # ── Resize mode (like Hyprland's resize submap) ───────────────────────
      mode.resize.binding = {
        h       = "resize width -50";
        j       = "resize height +50";
        k       = "resize height -50";
        l       = "resize width +50";
        # Larger steps with shift
        shift-h = "resize width -200";
        shift-j = "resize height +200";
        shift-k = "resize height -200";
        shift-l = "resize width +200";
        esc     = "mode main";
        enter   = "mode main";
      };

      mode.service.binding = {
        esc       = [ "reload-config" "mode main" ];
        r         = [ "flatten-workspace-tree" "mode main" ]; # reset layout
        f         = [ "layout floating tiling" "mode main" ]; # toggle floating
        backspace = [ "close-all-windows-but-current" "mode main" ];

        alt-shift-h = [ "join-with left"  "mode main" ];
        alt-shift-j = [ "join-with down"  "mode main" ];
        alt-shift-k = [ "join-with up"    "mode main" ];
        alt-shift-l = [ "join-with right" "mode main" ];
      };
    };
  };
}
