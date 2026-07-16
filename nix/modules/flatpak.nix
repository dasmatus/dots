{ pkgs, flatpaks, ... }: {
  services.flatpak = {
    enable = true;

  };
}
