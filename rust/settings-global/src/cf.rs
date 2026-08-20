use serde::{Deserialize, Serialize};
use serde_json::to_string;
use std::fs::write;
use std::{collections::HashMap, env::temp_dir, fs::read_to_string, sync::LazyLock};

pub static mut CONFIG_FIELDS: LazyLock<ConfigFields> = LazyLock::new(ConfigFields::load);

#[derive(Serialize, Deserialize)]
pub struct ConfigFields {
    #[serde(rename = "gitName")]
    git_name: String,
    #[serde(rename = "gitEmail")]
    git_email: String,
    #[serde(rename = "aiOllama")]
    ai_ollama: bool,
    #[serde(rename = "aiCodex")]
    ai_codex: bool,
    #[serde(rename = "aiClaude")]
    ai_claude: bool,
    hostname: String,
}

impl ConfigFields {
    fn load() -> Self {
        let config = get_current_vals();
        Self {
            git_name: config.get("gitName").unwrap().into(),
            git_email: config.get("gitEmail").unwrap().into(),
            ai_ollama: config.get("aiOllama").unwrap().parse().unwrap(),
            ai_codex: config.get("aiCodex").unwrap().parse().unwrap(),
            ai_claude: config.get("aiClaude").unwrap().parse().unwrap(),
            hostname: config.get("hostname").unwrap().to_string(),
        }
    }

    pub fn git_name(&self) -> &str {
        &self.git_name
    }

    pub fn git_email(&self) -> &str {
        &self.git_email
    }

    pub fn ai_ollama(&self) -> bool {
        self.ai_ollama
    }

    pub fn ai_codex(&self) -> bool {
        self.ai_codex
    }

    pub fn ai_claude(&self) -> bool {
        self.ai_claude
    }

    pub fn hostname(&self) -> &str {
        &self.hostname
    }

    pub fn set_git_name(&mut self, git_name: String) {
        self.git_name = git_name;
    }

    pub fn set_git_email(&mut self, git_email: String) {
        self.git_email = git_email;
    }

    pub fn set_ai_ollama(&mut self, ai_ollama: bool) {
        self.ai_ollama = ai_ollama;
    }

    pub fn set_ai_codex(&mut self, ai_codex: bool) {
        self.ai_codex = ai_codex;
    }

    pub fn set_ai_claude(&mut self, ai_claude: bool) {
        self.ai_claude = ai_claude;
    }

    pub fn set_hostname(&mut self, hostname: String) {
        self.hostname = hostname;
    }
}

fn get_current_vals<'a>() -> HashMap<String, String>
where
    'a: 'static,
{
    let f = read_to_string("/var/lib/dots/settings.nix").unwrap();
    let config = f
        .lines()
        .filter(|brace| brace.ne(&"{") || brace.ne(&"}"))
        .map(|kv| kv.split_once(" = ").unwrap())
        .map(|(k, v)| (k.to_string(), v.to_string()));
    HashMap::from_iter(config)
}
impl Drop for ConfigFields {
    fn drop(&mut self) {
        let json = to_string(&self).unwrap();
        let nix = json
            .lines()
            .map(|line| line.replace(':', "=").replace(",", ";"));
        write(temp_dir().join("settings.nix"), nix.collect::<String>()).unwrap();
    }
}
