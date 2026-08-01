# Acknowledgements

This Vim9 port exists because [`lean.nvim`](https://github.com/Julian/lean.nvim)
first did the difficult work of turning Lean's editor protocols into an
excellent, thoughtful editing experience.

Our sincere thanks go to **Julian Berman**, to every lean.nvim contributor,
reviewer, bug reporter, and user, and to the **Lean FRO**, whose sponsorship
has supported part of lean.nvim's development. This port follows lean.nvim's
feature organization, command and mapping vocabulary, Unicode input model,
infoview behavior, project discovery, and many small usability decisions. Its
scope would have been much harder to understand—and its interface much less
coherent—without that body of work.

We are especially grateful to the contributors behind the syntax and snippet
files retained here, including syntax-file maintainer **Gabriel Ebner**, and
to the maintainers of the
[`vscode-lean4`](https://github.com/leanprover/vscode-lean4) Unicode input data.
Thanks also go to the Lean language-server, ProofWidgets, and editor-extension
teams whose protocols and documentation make alternative editor clients
possible.

Please consider contributing improvements that apply to Neovim back to
lean.nvim. This repository is an independent port and is not an official
lean.nvim project or an endorsement by its maintainers.

Formal copyright and license details are recorded in [NOTICE](NOTICE),
[LICENSE](LICENSE), and [LICENSES/Apache-2.0.txt](LICENSES/Apache-2.0.txt).
