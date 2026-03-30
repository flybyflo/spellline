# Spellline

**Spellline** is an iPhone app for drafting prompts: as you type, matching phrases become inline controls—sliders, steppers, menus, toggles, and more—so you can tune a prompt without leaving the sentence.

It is a **UI/UX prototype** for trying out and evaluating this form of interaction—inline, in-flow controls tied to natural language. The plan is to carry what works into **real products** where people interact with **AI-based prompting**: assistants, copilots, and similar flows, so those experiences can feel clearer, faster, and more direct than plain text boxes alone.

<img src="simulator_screenshot.png" width="400" alt="Spellline running in the iOS Simulator">

## Requirements

- Xcode (current release recommended)
- **iOS 26.4** or later (deployment target)

## Run locally

1. Open `Spellline.xcodeproj` in Xcode.
2. Select an iPhone simulator or device.
3. Build and run (**⌘R**).

## Project structure

- `Spellline/Features/Editor/` — editor screen view, UIKit bridge, layout metrics, and background styling.
- `Spellline/Features/InlineTokens/Core/` — inline token UIKit/SwiftUI control implementations (stepper, slider, menus, clock wheel).
- `Spellline/Domain/Prompt/Models/` — prompt domain model types.
- `Spellline/Domain/Prompt/Snapshot/` — rendered snapshot and sizing helpers for inline token presentation.
- `Spellline/Domain/Prompt/Matching/` — prompt matching heuristics and station search index.
- `Spellline/Domain/Prompt/Store/` — observable prompt document store/state transitions.

## GTFS schedule data (ÖBB)

Spellline can use **ÖBB GTFS** schedule data. Download the current **GTFS Fahrplan** ZIP from [ÖBB Open Data — GTFS Soll-Fahrplan](https://data.oebb.at/de/datensaetze~soll-fahrplan-gtfs~): accept the terms on that page, then use **Download**. Extract the archive so the GTFS files (for example `agency.txt`, `routes.txt`, `trips.txt`, …) sit directly under a folder named **`gtfs_data`** at the root of this repository:

```text
Spellline/
  gtfs_data/
    agency.txt
    routes.txt
    …
```

Currently the GTFS data is required for building the project.

That folder is listed in `.gitignore`, so local GTFS files stay out of git. The dataset is published under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) (see the license block on the ÖBB page).

## License

Licensed under the [GNU Affero General Public License v3.0](LICENSE) (AGPL-3.0).  
Copyright © 2026 Florian Ritzmaier.
