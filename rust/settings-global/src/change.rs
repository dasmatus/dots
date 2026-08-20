use std::process::exit;

use dialoguer::{Confirm, Input, Select};

use crate::{
    cf::CONFIG_FIELDS,
    change::ToChange::{Claude, Codex, Exit, GitEmail, GitName, Hostname, Ollama},
};
pub enum ToChange {
    GitName,
    GitEmail,
    Ollama,
    Claude,
    Codex,
    Hostname,
    Exit,
}
#[allow(static_mut_refs)]
impl ToChange {
    pub fn run() {
        let opts = [
            "Git Name",
            "Git Email",
            "AI (Ollama)",
            "Enable Claude Code harness",
            "Codex harness",
            "Exit",
        ];
        let select = Select::new()
            .items(opts)
            .with_prompt("Settings - please select one of these options to continue")
            .interact()
            .unwrap();
        match select {
            0 => Self::sel(GitName),
            1 => Self::sel(GitEmail),
            2 => Self::sel(Ollama),
            3 => Self::sel(Claude),
            4 => Self::sel(Codex),
            5 => Self::sel(Hostname),
            6 => Self::sel(Exit),
            _ => unimplemented!(),
        }
    }
    fn sel(sel: Self) {
        match sel {
            ToChange::GitName => unsafe {
                CONFIG_FIELDS.set_git_name(
                    Input::new()
                        .with_prompt("Set new Git name")
                        .with_initial_text(CONFIG_FIELDS.git_name())
                        .interact()
                        .unwrap(),
                )
            },
            ToChange::GitEmail => unsafe {
                CONFIG_FIELDS.set_git_email(
                    Input::new()
                        .with_prompt("Set new Git name")
                        .with_initial_text(CONFIG_FIELDS.git_email())
                        .interact()
                        .unwrap(),
                );
            },

            ToChange::Codex => unsafe {
                CONFIG_FIELDS.set_ai_codex(
                    Confirm::new()
                        .with_prompt("Do you want to enable/disable OpenAI Codex CLI")
                        .default(CONFIG_FIELDS.ai_codex())
                        .interact()
                        .unwrap(),
                );
            },
            ToChange::Hostname => unsafe {
                CONFIG_FIELDS.set_hostname(
                    Input::new()
                        .with_prompt("Set new hostname")
                        .with_initial_text(CONFIG_FIELDS.hostname())
                        .interact()
                        .unwrap(),
                )
            },
            ToChange::Exit => exit(0),
            Ollama => unsafe {
                CONFIG_FIELDS.set_ai_ollama(
                    Confirm::new()
                        .with_prompt("Do you want to enable/disable Ollama?")
                        .default(CONFIG_FIELDS.ai_ollama())
                        .interact()
                        .unwrap(),
                );
            },
            Claude => unsafe {
                CONFIG_FIELDS.set_ai_claude(
                    Confirm::new()
                        .with_prompt("Do you want to enable/disable Claude Code CLI?")
                        .default(CONFIG_FIELDS.ai_claude())
                        .interact()
                        .unwrap(),
                );
            },
        }
    }
}
