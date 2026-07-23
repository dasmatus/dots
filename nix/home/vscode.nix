{ pkgs, ... }: {
  programs.vscodium = {
    enable = true;
    profiles.default.extensions = with pkgs.vscode-extensions; [
      enkia.tokyo-night
      asvetliakov.vscode-neovim
      continue.continue
      fill-labs.dependi
      rust-lang.rust-analyzer
    ];
  };
}
