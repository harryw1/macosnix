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
      gaps = {
        inner.horizontal = 8;
        inner.vertical   = 8;
        outer.left       = 8;
        outer.bottom     = 8;
        outer.top        = 8;
        outer.right      = 8;
      };

      mode.main.binding = {
        # Layouts
        alt-slash = "layout tiles horizontal vertical";
        alt-comma = "layout accordion horizontal vertical";

        # Focus
        alt-h = "focus left";
        alt-j = "focus down";
        alt-k = "focus up";
        alt-l = "focus right";

        # Move
        alt-shift-h = "move left";
        alt-shift-j = "move down";
        alt-shift-k = "move up";
        alt-shift-l = "move right";

        # Workspaces
        alt-1 = "workspace 1";
        alt-2 = "workspace 2";
        alt-3 = "workspace 3";
        alt-4 = "workspace 4";
        alt-5 = "workspace 5";

        alt-shift-1 = "move-node-to-workspace 1";
        alt-shift-2 = "move-node-to-workspace 2";
        alt-shift-3 = "move-node-to-workspace 3";
        alt-shift-4 = "move-node-to-workspace 4";
        alt-shift-5 = "move-node-to-workspace 5";

        # System
        alt-shift-semicolon = "mode service";
      };

      mode.service.binding = {
        esc = [ "reload-config" "mode main" ];
        r   = [ "flatten-workspace-tree" "mode main" ]; # reset layout
        f   = [ "layout floating tiling" "mode main" ]; # toggle floating
        backspace = [ "close-all-windows-but-current" "mode main" ];

        alt-shift-h = [ "join-with left"  "mode main" ];
        alt-shift-j = [ "join-with down"  "mode main" ];
        alt-shift-k = [ "join-with up"    "mode main" ];
        alt-shift-l = [ "join-with right" "mode main" ];
      };
    };
  };
}
