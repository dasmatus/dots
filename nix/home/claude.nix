# Native port of files/claude/settings.json (deleted — see git history).
# ccbar used to be an imperative `cargo install ccbar` (~/.cargo/bin); it is
# now built from its crates.io release below and wired into the statusline,
# and goes on PATH so the 5-hour/weekly limits can be polled directly.
{ pkgs, lib, ... }:
let
  # Claude Code statusline with 5-hour and 7-day (weekly) rate-limit bars.
  # Hashes verified by building against the pinned nixpkgs; pure-Rust deps
  # (serde, serde_json, toml, ureq/rustls), no native libraries.
  ccbar = pkgs.rustPlatform.buildRustPackage rec {
    pname = "ccbar";
    version = "0.3.0";
    src = pkgs.fetchCrate {
      inherit pname version;
      hash = "sha256-1FMxK/DfbLQAn4qG+gwvUUsELQpxHCIGlgZq4Of89uE=";
    };
    cargoHash = "sha256-GM0ofr1uPrF2/5keE/4TZXiXg+wodJefTBhzYHOvTCs=";
    meta = {
      description = "Fast, configurable statusline for Claude Code";
      homepage = "https://github.com/Saturate/ccbar";
      license = lib.licenses.mit;
      mainProgram = "ccbar";
    };
  };
in
{
  home.packages = [ ccbar ];

  programs.claude-code = {
    enable = true;
    settings = {
      ultracode = true;
      permissions = {
        allow = [
          "Bash(git init *)"
          "Bash(git add *)"
          "Bash(git commit *)"
          "Bash(git *)"
          "Bash(sudo mkosi summary)"
          "Bash(mkosi summary *)"
          "Bash(mkosi *)"
          "Bash(python3 -c \"import importlib.metadata; print\\(importlib.metadata.version\\('mkosi'\\)\\)\")"
          "Bash(python3 -c ' *)"
          "Bash(python3 *)"
          "Bash(pacman -Ql rust)"
          "Bash(rustup which *)"
          "Read(//home/matus/.cargo/bin/**)"
          "Bash(curl -s \"https://archlinux.org/packages/extra/x86_64/rust/\")"
          "Bash(chmod +x *)"
          "Bash(bash -n /var/home/matus/Dokumente/schule/demo-maturitna-praca/mkosi.extra/usr/local/sbin/oci-sysupdate)"
          "Bash(cargo vendor *)"
        ];
        defaultMode = "auto";
      };

      disableClaudeAiConnectors = true;

      statusLine = {
        type = "command";
        command = lib.getExe ccbar;
        refreshInterval = 1;
      };

      enabledPlugins = {
        "superpowers@claude-plugins-official" = true;
        "explanatory-output-style@claude-plugins-official" = true;
        "learning-output-style@claude-plugins-official" = true;
        "clangd-lsp@claude-plugins-official" = true;
        "linux-computer@claude-linux-computer" = true;
      };

      extraKnownMarketplaces = {
        "claude-linux-computer" = {
          source = {
            source = "git";
            url = "https://github.com/Nige-l/claude-linux-computer.git";
          };
        };
      };

      skipWorkflowUsageWarning = true;
      theme = "dark";
      tui = "fullscreen";
      disableAgentView = true;
      remoteControlAtStartup = true;
      inputNeededNotifEnabled = true;
      agentPushNotifEnabled = true;

      model = "claude-fable-5[1m]";
    };
  };
}
