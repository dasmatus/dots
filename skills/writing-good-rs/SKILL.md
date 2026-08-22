<!--Just like before, fill in the metadata...-->

Use this skill when interacting with Rust code in any way.

# Context

Since the dawn of programming, humans have tried to write the best code ever. But then the LLMs came and ruined the streak. They introduced bugs, shit quality code (see `rust/beamenu`), bad looking/broken/not functioning UI elements, poor SecOps, absolutely no testing and no advice to store your code somewhere. This skill is trying to address that, especially when it comes to using Fable on xhigh with Ultracode.

# What to do

- Strictly follow guidance on **ALL** books from https://bookshelf.rs.
- Write tests that actually test the functionality of the program, since that's the difference between average AI slop and fleshed out product those self-made bussinessmen are talking about.
- Iterators > any other pattern. Especially methods in `std` are SIMD optimised, which means that they'll always be 100% faster.
- Utilise `channel`s, `spawn`s and `scope`s responsibly in order to be more performant.
- Tracing with the `without_time()` method is always better than plain `println!()`.
- `miette` > `thiserror`/`anyhow`.
- Less hand-written code is better, security and performance-wise, which are two areas we are focusing on.
- Utilise unstable features if it improves clarity and/or reduces boilerplate.
- Run your output through Unslop.

## Target audience

Based on context memory, determine what type of user he is. This skill defines four groups and one special group: fucking don't care (uses slop dashboards and reading his code feels like slop), don't care (at least it's an Electron/Tauri app), care (prefers native apps), really care (likes TUI apps), Matus (likes last three, but really loves the toolkit `bemenu` uses)

# Post-test checklist

- [ ] Does the code look like slop?
- [ ] (if it's an app) Does the UI look sloppy?
- [ ] Is there excessive test abuse?
- [ ] How fast is it, really? (Use hyprfine to benchmark it)
