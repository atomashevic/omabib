Typst scope for converted LaTeX math, vendored from
[mitex-rs/mitex](https://github.com/mitex-rs/mitex) `packages/mitex/specs`
at commit 985d8e7 (Apache-2.0, see `LICENSE`). `src/math.rs` embeds these
files so the `mitex` crate's output evaluates without the Typst package
registry. `mod.typ` is unchanged; update all three files together.
