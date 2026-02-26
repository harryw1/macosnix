{ ... }:

{
  # ── Git ────────────────────────────────────────────────────────────────────
  programs.git = {
    enable = true;
    settings = {
      user.name  = "Harrison Weiss";
      user.email = "harrisonrweiss1@gmail.com";
      init.defaultBranch = "main";
      pull.rebase = true;
      push.autoSetupRemote = true;
      core.editor = "nvim";
    };
  };

  programs.delta = {
    enable = true;
    enableGitIntegration = true;
    options = {
      navigate = true;
      line-numbers = true;
      side-by-side = false;
    };
  };
}
