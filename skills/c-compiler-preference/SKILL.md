<!--Fill in the metadata-->

Use this skill when working with C or C++.

# Context

I had a PTSD and almost a stroke when I saw Fable write C code.

# What to do?

- Always utilise control-flow integrity and thin link-time optimisation.
- Always use Clang since it uses the same backend as `rustc` and has a better ecosystem.
- Rust > C++ > C, follow this rule very closely.
  - When you have to work with patches to a C program, always write C++ code in the latest version since it doesn't have header hell and is pattern-wise similar to Rust. Please use Web Search on https://cppreference.com to determine the latest C++ version.
- **ALWAYS** verify for safety and memory leakage and all other things C/C++ get wrong.
