{ flavor, ... }:

{
  programs.starship = {
    enable = true;
    settings = (builtins.fromTOML (builtins.readFile ./starship.toml)) // {
      palette = "catppuccin_${flavor}";
    };
  };
}
