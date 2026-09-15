.pragma library

// A small, made-up library for rendering the panes offscreen. The shapes
// follow the service's search / get_reference / get_alphaxiv_overview results.

var projects = [
  {id: "p-grl", name: "GRL", description: "General reading list"},
  {id: "p-thesis", name: "Thesis", description: ""}
]

var hits = [
  {id: "r1", citekey: "rivera_tidal_2026", title: "Tidal Coupling in Shallow Estuaries: A Field Study Across Four Seasons", authors: "Rivera, Ana and Holt, Jonas", year: "2026", created_at: "2026-09-15T08:10:00Z", has_pdf: false, has_abstract: true, has_overview: false, note_count: 0, note_matches: []},
  {id: "r2", citekey: "okafor_sparse_2026", title: "Sparse Attention Is Enough for Long-Horizon Forecasting", authors: "Okafor, Chidi and Lindqvist, Maja and Perez, Tomas", year: "2026", created_at: "2026-09-15T06:00:00Z", has_pdf: true, has_abstract: true, has_overview: true, note_count: 2, note_matches: []},
  {id: "r3", citekey: "chen_lattice_2025", title: "Lattice Models of Opinion Spread with Stubborn Agents", authors: "Chen, Wei", year: "2025", created_at: "2026-09-14T21:00:00Z", has_pdf: true, has_abstract: false, has_overview: false, note_count: 0, note_matches: []},
  {id: "r4", citekey: "moreau_survey_2024", title: "Survey Weighting Under Nonresponse: Practical Guidance for Panel Studies", authors: "Moreau, Claire and Dubois, Luc", year: "2024", created_at: "2026-09-13T10:00:00Z", has_pdf: false, has_abstract: true, has_overview: false, note_count: 1, note_matches: [{note_id: "n9", project_id: "p-thesis", snippet: "Weighting section is the clearest summary of raking I have seen", project_name: "Thesis"}]},
  {id: "r5", citekey: "ito_reef_2023", title: "Coral Reef Soundscapes as Indicators of Recovery", authors: "Ito, Haruka", year: "2023", created_at: "2026-09-10T10:00:00Z", has_pdf: true, has_abstract: true, has_overview: false, note_count: 0, note_matches: []}
]

var overview = [
  "# Research Report: “Sparse Attention Is Enough for Long-Horizon Forecasting”",
  "",
  "## 1. Authors and Institutions",
  "",
  "The paper was written by **Chidi Okafor**, **Maja Lindqvist** and **Tomas Perez** at a university forecasting lab.",
  "",
  "## 2. Position within the Broader Research Landscape",
  "",
  "Long-horizon forecasting has leaned on *dense* attention, whose cost grows with the square of the context. This work asks whether a sparse pattern keeps the accuracy. See [the benchmark](https://example.org/bench) and the `top-k` routing rule.",
  "",
  "## 3. Key Objectives and Motivation",
  "",
  "1. Test whether sparse attention matches dense attention on horizons beyond 720 steps.",
  "2. Measure the memory saved at each context length.",
  "3. Explain *when* sparsity fails.",
  "",
  "### Sub-question",
  "",
  "- Does the gain hold on irregular series?",
  "- Is routing stable across seeds?",
  "",
  "## 4. Methodology and Approach",
  "",
  "> The authors fix the compute budget and vary only the attention pattern.",
  "",
  "| Dataset | Horizon | Dense MAE | Sparse MAE |",
  "|---|---|---|---|",
  "| Traffic | 720 | 0.41 | 0.40 |",
  "| Weather | 336 | 0.22 | 0.23 |",
  "",
  "## 5. Main Findings and Results",
  "",
  "Sparse attention matched dense attention within 2% on every horizon while using a third of the memory.",
  "",
  "## 6. Significance and Potential Impact",
  "",
  "Cheaper long-context forecasting makes hourly models practical on a single GPU."
].join("\n")

var ref = {
  id: "r2", citekey: "okafor_sparse_2026", revision: 3, entry_type: "misc", year: "2026",
  title: "Sparse Attention Is Enough for Long-Horizon Forecasting",
  authors: "Okafor, Chidi and Lindqvist, Maja and Perez, Tomas",
  abstract: "Transformers for time series forecasting usually attend densely over the full context, which limits how far back they can look. We show that a simple top-k sparse attention pattern keeps accuracy on horizons up to 720 steps while cutting memory use by two thirds. Across six public benchmarks the sparse model is within two percent of the dense baseline, and it fails only when the series has abrupt regime changes that the router does not see during training.",
  source: "arXiv", created_at: "2026-09-15T06:00:00Z",
  pdf_path: "/home/reader/.local/share/omabib/pdfs/okafor_sparse_2026.pdf",
  fields: {doi: "10.48550/arxiv.2609.01234", publisher: "arXiv", url: "https://arxiv.org/abs/2609.01234", howpublished: "Preprint"},
  projects: [{id: "p-grl", name: "GRL"}],
  attachments: [
    {id: "a1", exists: true, file_type: "pdf", path: "/home/reader/.local/share/omabib/pdfs/okafor_sparse_2026.pdf"},
    {id: "a2", exists: false, file_type: "pdf", path: "/home/reader/Downloads/okafor-supplement.pdf"}
  ],
  notes: [
    {id: "n1", body: "Table 2 is the headline result: sparse within 2% of dense at a third of the memory. Worth citing in the related-work paragraph on efficient transformers.", project_id: "p-thesis", project_name: "Thesis", labels: ["efficiency", "related-work"], evidence: "PDF p. 6 · /home/reader/.local/share/omabib/pdfs/okafor_sparse_2026.pdf", provenance: "human", revision: 1, created_at: "2026-09-15T07:00:00Z", updated_at: "2026-09-15T07:00:00Z", image: null},
    {id: "n2", body: "Failure mode: abrupt regime changes. Check whether our panel data has these.", project_id: null, project_name: null, labels: [], evidence: "Section 5.3", provenance: "codex", revision: 2, created_at: "2026-09-14T12:00:00Z", updated_at: "2026-09-14T13:00:00Z", image: null}
  ],
  next_note_cursor: null,
  other_project_note_count: 1,
  bibtex: "@misc{okafor_sparse_2026,\n  title = {Sparse Attention Is Enough for Long-Horizon Forecasting},\n  author = {Okafor, Chidi and Lindqvist, Maja and Perez, Tomas},\n  year = {2026},\n  doi = {10.48550/arxiv.2609.01234},\n  publisher = {arXiv}\n}"
}

var repo = {configured: true, ahead: 0, behind: 0, last_error: null, last_success: "2026-09-15T05:00:00Z", pending: {any: true, new_references: 2}}

// The other shape alphaXiv serves: a prose opening, ### sections and nested
// bullets.
var overviewProse = [
  "This report provides a detailed analysis of the research paper “Sparse Attention Is Enough for Long-Horizon Forecasting.”",
  "",
  "### 1. Authors and Institution(s)",
  "",
  "The research was conducted by Chidi Okafor and Maja Lindqvist.",
  "",
  "### 5. Main Findings and Results",
  "",
  "*   **Behavioral Patterns:**",
  "    *   **Stable routers (Traffic, Weather):** within 2% of dense attention.",
  "    *   **Unstable routers (Exchange):** accuracy drops after abrupt",
  "        regime changes.",
  "*   **Memory:** a third of the dense baseline at every context length."
].join("\n")
